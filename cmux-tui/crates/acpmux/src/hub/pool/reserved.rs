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
//! entry and takes it. That take reserves a fresh folder and warms it at once
//! ([`Hub::refill_reserved_home`]), so the second and every later home chat on the machine takes
//! a warm agent too: production app-chat probes on the 11-24 nightly paid `session_new` 3.6 to
//! 10.4 s on a second chat (52 s once) against 0.8 to 1.6 s warm.
//!
//! A chat that names a model connection (a credential in its key), or runs with
//! `CMUX_AGENT_DISPLAYS=per-workspace` (the workspace id is in the key), misses and starts cold.
//!
//! Personal spares (ask-30d56720f6; on by default, off with `ACPMUX_SPARE_PERSONAL=0`): the
//! default harness and model is only one person's pick. With the switch on, a reserve also
//! warms, in the reserved
//! folder, a spare (`Role::Spare`, the harness's one spare) for each shape the app names
//! (`shapes`: the harnesses and models this person set up) and each harness a home chat on this
//! machine used, so a Codex chat or a chat on a picked model takes a running agent, MCP servers
//! started, as the default one does. The shapes are remembered in `pool-spares.json` with the
//! reserved folder as their folder; each refill moves them to the next folder, and a home chat's
//! own use keeps its harness's spare in the next folder, never the one it took.

use std::path::{Path, PathBuf};

use super::*;

/// The ticket file in `~/chats`.
const TICKET: &str = ".reserved";
/// How long a reserve waits for its agent to come up when asked to.
const READY_WAIT: Duration = Duration::from_secs(45);
/// Most shapes one reserve takes (the harnesses a person sets up are a handful).
const MAX_SHAPES: usize = 4;

/// One harness and model a person set up, as the app names it in `shapes`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HomeShape {
    pub harness: String,
    pub preset: Option<String>,
    pub model: Option<String>,
}

/// `shapes` of a `reserveHome` prewarm: at most [`MAX_SHAPES`] of
/// `{"harness": ID, "preset"?: NAME, "model"?: ID}`; a harness or preset id is 1 to 64 of
/// `[A-Za-z0-9._-]`, a model 1 to 200 printable characters. Absent: none.
pub fn parse_shapes(value: Option<&Value>) -> Result<Vec<HomeShape>, RpcError> {
    let Some(value) = value.filter(|v| !v.is_null()) else { return Ok(Vec::new()) };
    let bad = |why: &str| RpcError::invalid_params(format!("shapes: {why}"));
    let list = value.as_array().ok_or_else(|| bad("not a list"))?;
    if list.len() > MAX_SHAPES {
        return Err(bad("more than 4"));
    }
    let id = |v: &Value, k: &str| -> Result<Option<String>, RpcError> {
        match v.get(k) {
            None | Some(Value::Null) => Ok(None),
            Some(Value::String(s))
                if (1..=64).contains(&s.len())
                    && s.bytes().all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b)) =>
            {
                Ok(Some(s.clone()))
            }
            Some(_) => Err(bad(&format!("{k} is not an id"))),
        }
    };
    let mut shapes = Vec::new();
    for v in list {
        let harness = id(v, "harness")?.ok_or_else(|| bad("a shape has no harness"))?;
        let preset = id(v, "preset")?;
        let model = match v.get("model") {
            None | Some(Value::Null) => None,
            Some(Value::String(m))
                if (1..=200).contains(&m.len()) && !m.chars().any(char::is_control) =>
            {
                Some(m.clone())
            }
            Some(_) => return Err(bad("model is not a model id")),
        };
        let shape = HomeShape { harness, preset, model };
        if !shapes.contains(&shape) {
            shapes.push(shape);
        }
    }
    Ok(shapes)
}

/// Whether `cwd` is a home chat's folder that a reserve made: `<home>/chats/r<32 hex>`.
pub(super) fn is_home_chat_folder(home: &Path, cwd: &Path) -> bool {
    cwd.parent().is_some_and(|p| p == home.join("chats"))
        && cwd.file_name().and_then(|n| n.to_str()).is_some_and(is_reserved_name)
}

/// [`ensure_folder`] one at a time in this daemon: a refill and a home chat's use asking at once
/// get the same next folder, never two.
pub(super) fn ensure_folder_serial(home: &Path) -> Option<PathBuf> {
    static ONE: StdMutex<()> = StdMutex::new(());
    let _one = lock(&ONE);
    ensure_folder(home)
}

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
    crate::home_fs::create_dir(path, 0o700)
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
            let mut options = crate::home_fs::OpenOptions::new();
            options.write(true).create_new(true).mode(0o600);
            std::io::Write::write_all(&mut options.open(&tmp).ok()?, name.as_bytes()).ok()?;
            // Atomic: a reader sees the old ticket or the new one, never half of it.
            crate::home_fs::rename(&tmp, &ticket).ok()?;
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
    /// `shapes`: the harnesses and models the person set up, warmed beside it when personal
    /// spares are on (the module doc).
    pub async fn reserve_home_warm(
        self: &Arc<Self>,
        wait: bool,
        shapes: Vec<HomeShape>,
    ) -> Result<Value, RpcError> {
        self.reserve_home_warm_after(None, wait, shapes).await
    }

    /// A home chat just took the reserved entry for `taken`: reserve the next folder and warm it,
    /// in the background.
    pub(super) fn refill_reserved_home(&self, taken: PathBuf) {
        let Some(hub) = self.hub_ref.get().and_then(std::sync::Weak::upgrade) else { return };
        self.scope.spawn_named("pool-reserve-refill", async move {
            match hub.reserve_home_warm_after(Some(taken), false, Vec::new()).await {
                Ok(answer) => tracing::info!(%answer, "the next home chat's folder is reserved"),
                Err(error) => {
                    tracing::info!(?error, "the next home chat's folder was not reserved")
                }
            }
        });
    }

    /// [`reserve_home_warm`](Self::reserve_home_warm); `taken`: the folder a chat just took,
    /// never warmed again (its ticket still names it when the chat came without taking it).
    async fn reserve_home_warm_after(
        self: &Arc<Self>,
        taken: Option<PathBuf>,
        wait: bool,
        shapes: Vec<HomeShape>,
    ) -> Result<Value, RpcError> {
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
        let at = home.clone();
        let folder = tokio::task::spawn_blocking(move || ensure_folder_serial(&at))
            .await
            .ok()
            .flatten()
            .ok_or_else(|| {
                RpcError::invalid_params("the reserved chat folder could not be made")
            })?;
        if taken.as_ref() == Some(&folder) {
            return Ok(json!({"accepted": false,
                "reason": "the reserved folder's ticket still names the folder a chat took"}));
        }
        self.wait_startup().await;
        // The default harness and model, as a home chat's `session/new` with no pick takes them.
        let spec =
            self.pool_spec_in(None, None, folder.clone(), None, &PrewarmShape::default()).await?;
        let key = spec.key.clone();
        self.pool_want(Role::Reserved, spec).await;
        let personal = if crate::config::spare_personal_enabled() {
            self.spare_home_shapes(&home, &folder, &key, shapes).await
        } else {
            Vec::new()
        };
        let mut state = self.reserved_state(&key);
        let mut states: Vec<_> = personal.iter().map(|k| self.reserved_state(k)).collect();
        if wait {
            let end = tokio::time::Instant::now() + READY_WAIT;
            while (state == "warming" || states.contains(&"warming"))
                && tokio::time::Instant::now() < end
            {
                tokio::time::sleep(Duration::from_millis(100)).await;
                state = self.reserved_state(&key);
                states = personal.iter().map(|k| self.reserved_state(k)).collect();
            }
        }
        let spares: Vec<Value> = personal
            .iter()
            .zip(&states)
            .map(|(k, s)| json!({"harness": k.harness, "state": s}))
            .collect();
        let mut answer = json!({"accepted": true, "state": state, "cwd": key.cwd});
        if !spares.is_empty() {
            answer["spares"] = Value::Array(spares);
        }
        Ok(answer)
    }

    /// The state of the entry for `key`: `ready`, `warming`, `empty` or `none`.
    fn reserved_state(&self, key: &PoolKey) -> &'static str {
        lock(&self.pool.pool).view().into_iter().find(|v| &v.key == key).map_or("none", |v| v.state)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn home(tag: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("acpmux-reserved-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::canonicalize(dir).unwrap()
    }

    #[test]
    fn a_reserved_folder_is_private_named_by_its_ticket_and_kept_until_taken() {
        let home = home("ensure");
        let first = ensure_folder(&home).expect("a folder");
        let name = first.file_name().unwrap().to_str().unwrap().to_owned();
        assert!(is_reserved_name(&name), "{name}");
        assert!(!name.bytes().all(|b| b.is_ascii_digit()), "never a surface id");
        assert!(private_dir(&home.join("chats")) && private_dir(&first));
        assert_eq!(std::fs::read_to_string(home.join("chats/.reserved")).unwrap(), name);
        // Asked again before a chat took it: the same folder, no second one.
        assert_eq!(ensure_folder(&home), Some(first.clone()));
        // A chat took the ticket: the next ask makes a new folder.
        std::fs::rename(home.join("chats/.reserved"), home.join("chats/.claimed-7")).unwrap();
        let second = ensure_folder(&home).expect("a new folder");
        assert_ne!(second, first);
        assert!(first.is_dir(), "the taken folder is the chat's");
        let _ = std::fs::remove_dir_all(home);
    }

    #[cfg(unix)]
    #[test]
    fn a_link_in_place_of_the_chats_folder_is_never_followed() {
        let home = home("link");
        let elsewhere = home.join("elsewhere");
        std::fs::create_dir_all(&elsewhere).unwrap();
        std::os::unix::fs::symlink(&elsewhere, home.join("chats")).unwrap();
        assert_eq!(ensure_folder(&home), None);
        assert_eq!(std::fs::read_dir(&elsewhere).unwrap().count(), 0);
        let _ = std::fs::remove_dir_all(home);
    }

    #[test]
    fn shapes_are_a_short_list_of_harness_ids_with_optional_models() {
        assert_eq!(parse_shapes(None).unwrap(), vec![]);
        let v = json!([
            {"harness": "codex", "model": "gpt-5.5"},
            {"harness": "claude", "preset": "work", "model": "claude-opus-5-5[1m]"},
            {"harness": "codex", "model": "gpt-5.5"}
        ]);
        let got = parse_shapes(Some(&v)).unwrap();
        assert_eq!(got.len(), 2, "a repeated shape counts once");
        assert_eq!(got[1].preset.as_deref(), Some("work"));
        assert_eq!(got[1].model.as_deref(), Some("claude-opus-5-5[1m]"));
        for bad in [
            json!({"harness": "codex"}),
            json!([{"model": "x"}]),
            json!([{"harness": "../codex"}]),
            json!([{"harness": "codex", "model": "a\nb"}]),
            json!([{"harness": "a"}, {"harness": "b"}, {"harness": "c"}, {"harness": "d"}, {"harness": "e"}]),
        ] {
            assert!(parse_shapes(Some(&bad)).is_err(), "{bad}");
        }
    }

    #[test]
    fn only_a_reserved_folder_in_home_chats_is_a_home_chat_folder() {
        let home = Path::new("/home/p");
        let name = "r0123456789abcdef0123456789abcdef";
        assert!(is_home_chat_folder(home, &home.join("chats").join(name)));
        assert!(!is_home_chat_folder(home, &home.join("chats/12345")), "a surface id folder");
        assert!(!is_home_chat_folder(home, &home.join("src").join(name)));
    }
}
