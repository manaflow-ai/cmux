//! The login spare (Cloud V0 item 1, staging only: `pool.loginSpare` or `ACPMUX_LOGIN_SPARE=1`,
//! off by default). Leo: "A chat starts in a few seconds: ready spare, harness login attached in
//! advance, ...". A Cloud spare never ran a harness, so it has no spare of its own
//! (`spare.rs`), and an agent started before the person's login is there would never be served:
//! the login is part of the pool key (`auth.rs`). So the moment a login install lands
//! (`~/.config/cmux/agent-auth/claude.login`, the login's digest and cmux account, written by the
//! warm's copy on the person's intent, ahead of the chat) and the image's launcher uses that login
//! (`claude` holds `own`),
//! this daemon starts a Claude spare in the home folder, on the model a plain new chat starts on.
//! The chat that claims the machine then takes a started agent.
//!
//! It is an ordinary spare under the pool's rules: hidden, matched by the exact key, so a chat of
//! another model, folder, settings or account starts cold and the agent is discarded, never served;
//! the chat's mode is set on it at the take; it gets `initialize` and nothing else, so nothing
//! reaches the model before the person's first prompt (`tests/login_spare.rs`).
//!
//! Event-driven: an inotify watch (`quiet_dirs`, changes only) of the two mark files and Claude
//! Code's `settings.json`, read once at daemon start too. A settings change after the install
//! (the model stub's endpoint, a person's edit) is part of the key, so the spare is wanted again
//! under it: the old one is discarded and a matching one starts. Linux only (Cloud machines);
//! elsewhere only the start reads them. Started once, at daemon start, when the switch is on then.

use super::*;
use std::path::Path;

/// A burst of writes (the install writes the choice, then the mark) is read once after this quiet.
#[cfg(target_os = "linux")]
const QUIET: Duration = Duration::from_millis(300);
/// The harness the login install copies, and the spare it starts.
const HARNESS: &str = "claude";

/// The marks' folder under `home`.
fn marks(home: &Path) -> PathBuf {
    home.join(super::auth::CMUX_AGENT_AUTH)
}

/// Whether `home` holds an installed login the launcher uses: the mark names a login (its digest;
/// the cmux account is there too when the app knew it) and the choice is `own`. Blocking (two
/// small reads).
pub(super) fn installed(home: &Path) -> bool {
    let dir = marks(home);
    let own = std::fs::read_to_string(dir.join(HARNESS)).is_ok_and(|s| s.trim() == "own");
    let login = std::fs::read(dir.join(format!("{HARNESS}.login")))
        .ok()
        .and_then(|b| serde_json::from_slice::<Value>(&b).ok())
        .and_then(|v| v.get("digest").and_then(Value::as_str).map(str::to_owned))
        .is_some_and(|d| !d.is_empty());
    own && login
}

impl Hub {
    /// Daemon start (`restore_spares`): read the marks once, and follow them.
    pub(super) async fn login_spare_start(self: &Arc<Self>) {
        if !self.config.read().await.pool.login_spare_enabled() {
            return;
        }
        let Some(home) = dirs::home_dir() else { return };
        #[cfg(target_os = "linux")]
        watch(Arc::downgrade(self), home.clone());
        self.login_spare_check(home).await;
    }

    /// Want the Claude spare in `home` when a login is installed there. A key that did not change
    /// keeps its entry; another login's replaces it (one spare per harness).
    async fn login_spare_check(self: &Arc<Self>, home: PathBuf) {
        if !self.config.read().await.pool.login_spare_enabled() {
            return;
        }
        let at = home.clone();
        if !tokio::task::spawn_blocking(move || installed(&at)).await.unwrap_or(false) {
            return;
        }
        let model = Some(spare::SpareModel::StartDefault);
        match self.pool_spec_in(Some(HARNESS.to_owned()), None, home, model).await {
            Ok(spec) => {
                tracing::info!("a login was installed: a Claude spare starts in the home folder");
                self.pool_want(Role::Spare, spec).await;
            }
            Err(e) => tracing::debug!("no login spare: {}", e.message),
        }
    }
}

/// Follows the two mark files and `settings.json`; each burst of changes reads them again on the
/// runtime.
#[cfg(target_os = "linux")]
fn watch(hub: std::sync::Weak<Hub>, home: PathBuf) {
    use crate::quiet_dirs::{QuietDirs, Target};
    let Ok(rt) = tokio::runtime::Handle::try_current() else { return };
    let dir = marks(&home);
    let files = vec![
        dir.join(HARNESS),
        dir.join(format!("{HARNESS}.login")),
        home.join(".claude/settings.json"),
    ];
    let targets = files.iter().cloned().map(Target::File).collect();
    let (tx, rx) = std::sync::mpsc::channel();
    let source = match QuietDirs::follow(tx, "acpmux-login-spare-inotify", targets) {
        Ok(source) => source,
        Err(e) => {
            tracing::warn!("login spare: the mark watch cannot start: {e}");
            return;
        }
    };
    let spawned =
        std::thread::Builder::new().name("acpmux-login-spare-watch".into()).spawn(move || {
            let _source = source;
            while let Ok(event) = rx.recv() {
                // `~/.claude` also holds files Claude Code writes on every prompt.
                if !touches(&event, &files) {
                    continue;
                }
                // The rest of the burst.
                while rx.recv_timeout(QUIET).is_ok() {}
                let Some(hub) = hub.upgrade() else { return };
                let home = home.clone();
                rt.spawn(async move { hub.login_spare_check(home).await });
            }
        });
    if let Err(e) = spawned {
        tracing::warn!("login spare: the mark watch thread cannot start: {e}");
    }
}

/// Whether an event may have changed one of `files`: one of them, or a folder on the way to one
/// (made, removed or replaced). An error may have dropped events: read them.
#[cfg(target_os = "linux")]
fn touches(event: &notify::Result<notify::Event>, files: &[PathBuf]) -> bool {
    match event {
        Ok(event) => event.paths.iter().any(|p| files.iter().any(|f| f.starts_with(p))),
        Err(_) => true,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_an_installed_own_login_counts() {
        let home = std::env::temp_dir().join(format!("login-spare-{}", uuid::Uuid::now_v7()));
        let dir = marks(&home);
        std::fs::create_dir_all(&dir).unwrap();
        assert!(!installed(&home), "nothing installed");
        std::fs::write(dir.join("claude.login"), r#"{"account":"user_a","digest":"d"}"#).unwrap();
        assert!(!installed(&home), "no launcher choice");
        std::fs::write(dir.join("claude"), "team\n").unwrap();
        assert!(!installed(&home), "the team login");
        std::fs::write(dir.join("claude"), "own\n").unwrap();
        assert!(installed(&home));
        // The app passes the account when it knows it; the login's digest is always there.
        std::fs::write(dir.join("claude.login"), r#"{"account":"","digest":"d"}"#).unwrap();
        assert!(installed(&home), "an install with no account named");
        std::fs::write(dir.join("claude.login"), r#"{"account":"user_a","digest":""}"#).unwrap();
        assert!(!installed(&home), "no login");
        let _ = std::fs::remove_dir_all(&home);
    }
}
