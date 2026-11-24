//! The reserved folder of a Cloud machine's first home chat.
//!
//! A home chat's folder is `~/chats/<surface id>`, and the surface id exists only after the app
//! claims the machine, so nothing could be warmed for that chat before the claim: its start paid
//! the whole agent boot (about 3.5 s of the Cloud start, goal `cloud-instant-start-journey`).
//! Here the machine makes the folder ahead, `~/chats/r<32 hex>`, starts a pooled agent in it
//! (`Role::Reserved`: the default harness and model a home chat's `session/new` with no pick
//! resolves, kept as long as a spare) and writes the ticket `~/chats/.reserved` naming it.
//! `cmux-tui-core`'s `owner_cloud_cwd` gives the first home chat that folder by renaming the
//! ticket (one atomic winner, `agent_session_folders.rs`), so its `session/new` keys the warm
//! entry and takes it. The next home chat gets `~/chats/<surface id>` as before.
//!
//! A chat that names a model connection (a credential in its key), or runs with
//! `CMUX_AGENT_DISPLAYS=per-workspace` (the workspace id is in the key), misses and starts cold.

use std::path::{Path, PathBuf};

use super::*;

/// The ticket file in `~/chats`.
const TICKET: &str = ".reserved";
/// How long a reserve waits for its agent to come up when asked to.
const READY_WAIT: Duration = Duration::from_secs(45);

/// A fresh reserved folder name: `r` and 32 hex digits, never a surface id.
fn fresh_name() -> String {
    format!("r{}", uuid::Uuid::now_v7().simple())
}

fn is_reserved_name(name: &str) -> bool {
    name.strip_prefix('r').is_some_and(|hex| {
        hex.len() == 32 && hex.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    })
}

fn private_dir(path: &Path) -> bool {
    let Ok(metadata) = std::fs::symlink_metadata(path) else { return false };
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt as _;
        metadata.is_dir()
            && metadata.uid() == unsafe { libc::geteuid() }
            && metadata.mode() & 0o022 == 0
    }
    #[cfg(not(unix))]
    {
        metadata.is_dir()
    }
}

fn make_private_dir(path: &Path) -> std::io::Result<()> {
    if private_dir(path) {
        return Ok(());
    }
    let mut builder = std::fs::DirBuilder::new();
    #[cfg(unix)]
    std::os::unix::fs::DirBuilderExt::mode(&mut builder, 0o700);
    builder.create(path)
}

/// The reserved folder under `home`, canonical, made if there is none unclaimed: the one a
/// ticket already names (still there, not yet taken), else a fresh one with a new ticket.
/// `None`: the folders cannot be made safely (a link or another user's folder in the way).
pub(super) fn ensure_folder(home: &Path) -> Option<PathBuf> {
    let chats = home.join("chats");
    make_private_dir(&chats).ok().filter(|()| private_dir(&chats))?;
    let ticket = chats.join(TICKET);
    let named = std::fs::symlink_metadata(&ticket)
        .ok()
        .filter(|m| m.is_file() && m.len() <= 64)
        .and_then(|_| std::fs::read_to_string(&ticket).ok())
        .map(|s| s.trim().to_owned())
        .filter(|n| is_reserved_name(n) && private_dir(&chats.join(n)));
    let name = match named {
        Some(name) => name,
        None => {
            let name = fresh_name();
            make_private_dir(&chats.join(&name)).ok()?;
            let tmp = chats.join(format!("{TICKET}.{name}"));
            let mut options = std::fs::OpenOptions::new();
            options.write(true).create_new(true);
            #[cfg(unix)]
            std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
            std::io::Write::write_all(&mut options.open(&tmp).ok()?, name.as_bytes()).ok()?;
            // Atomic: a reader sees the old ticket or the new one, never half of it.
            std::fs::rename(&tmp, &ticket).ok()?;
            name
        }
    };
    std::fs::canonicalize(chats.join(name)).ok()
}

impl Hub {
    /// `_acpmux/prewarm` with `reserveHome`: make the reserved first home-chat folder of this
    /// machine and start a pooled agent in it. Idempotent: a folder not yet taken is kept and
    /// its entry wanted again. `wait`: answer once the agent is ready (or failed, or the wait
    /// ran out). Local, trusted callers only (the handler checks).
    pub async fn reserve_home_warm(self: &Arc<Self>, wait: bool) -> Result<Value, RpcError> {
        if crate::launch_policy::agent_launch_disabled() {
            return Ok(
                json!({"accepted": false, "reason": crate::launch_policy::DISABLED_MESSAGE}),
            );
        }
        if !self.pool_enabled().await {
            return Ok(json!({"accepted": false, "reason": "the session pool is off"}));
        }
        if crate::agent_displays::per_workspace() {
            return Ok(json!({"accepted": false,
                "reason": "a workspace-keyed pool entry cannot be reserved before its chat exists"}));
        }
        let Some(home) = dirs::home_dir() else {
            return Ok(json!({"accepted": false, "reason": "this machine has no home folder"}));
        };
        let folder = tokio::task::spawn_blocking(move || ensure_folder(&home))
            .await
            .ok()
            .flatten()
            .ok_or_else(|| {
                RpcError::invalid_params("the reserved chat folder could not be made")
            })?;
        self.wait_startup().await;
        // The default harness and model, as a home chat's `session/new` with no pick takes them.
        let spec = self.pool_spec_in(None, None, folder, None, &PrewarmShape::default()).await?;
        let key = spec.key.clone();
        self.pool_want(Role::Reserved, spec).await;
        let mut state = self.reserved_state(&key);
        if wait {
            let end = tokio::time::Instant::now() + READY_WAIT;
            while state == "warming" && tokio::time::Instant::now() < end {
                tokio::time::sleep(Duration::from_millis(100)).await;
                state = self.reserved_state(&key);
            }
        }
        Ok(json!({"accepted": true, "state": state, "cwd": key.cwd}))
    }

    /// The state of the entry for `key`: `ready`, `warming`, `empty` or `none`.
    fn reserved_state(&self, key: &PoolKey) -> &'static str {
        lock(&self.pool.pool).view().into_iter().find(|v| &v.key == key).map_or("none", |v| v.state)
    }
}

#[cfg(test)]
#[path = "reserved_tests.rs"]
mod tests;
