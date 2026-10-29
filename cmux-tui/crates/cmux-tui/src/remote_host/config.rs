//! Remote hosting state on this machine: `<home>/.cmux/host/remote.json`
//! (0600 in a 0700 directory). The running listener rereads it on every
//! connection, so `cmux host allow|disable` take effect for the next
//! connection; `deny` also restarts the listener to close open ones.

use std::path::{Path, PathBuf};

use anyhow::{Context as _, anyhow};
use serde::{Deserialize, Serialize};

/// The listener port on every tailnet address (remote-hosts.md 7).
pub(crate) const DEFAULT_PORT: u16 = 7319;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct Config {
    pub version: u32,
    pub enabled: bool,
    /// The one login with owner access. `None` until `enable` resolves it.
    #[serde(default)]
    pub owner: Option<String>,
    /// More logins with full access, added one by one (`cmux host allow`).
    #[serde(default)]
    pub allow: Vec<String>,
    /// The daemon session to serve; `None` is the CLI's default session.
    #[serde(default)]
    pub session: Option<String>,
    #[serde(default = "default_port")]
    pub port: u16,
    /// Start the session daemon when it is not running. The Mac app turns
    /// this off for its own session: only the app starts that daemon.
    #[serde(default = "default_true")]
    pub spawn: bool,
    /// Teammate access (teammate-access-DESIGN.md), off by default: while
    /// off, `grants` are ignored. `cmux host grant` turns it on.
    #[serde(default)]
    pub teammate_access: bool,
    /// Scoped, consented grants for allowlisted logins (`cmux host grant`).
    #[serde(default)]
    pub grants: Vec<super::grant::Grant>,
    #[serde(default)]
    pub shares: Vec<super::shares::Share>,
}

fn default_port() -> u16 {
    DEFAULT_PORT
}

fn default_true() -> bool {
    true
}

impl Default for Config {
    fn default() -> Self {
        Self {
            version: 1,
            enabled: false,
            owner: None,
            allow: Vec::new(),
            session: None,
            port: DEFAULT_PORT,
            spawn: true,
            teammate_access: false,
            grants: Vec::new(),
            shares: Vec::new(),
        }
    }
}

static DIR_OVERRIDE: std::sync::OnceLock<PathBuf> = std::sync::OnceLock::new();

/// `serve --dir DIR`: the services pass the directory `enable` used, so a
/// `CMUX_HOST_DIR` in the enabling shell reaches the listener too.
pub(crate) fn set_dir(dir: PathBuf) {
    let _ = DIR_OVERRIDE.set(dir);
}

/// `serve --dir`, else `CMUX_HOST_DIR`, else `<home>/.cmux/host`.
pub(crate) fn dir() -> anyhow::Result<PathBuf> {
    if let Some(dir) = DIR_OVERRIDE.get() {
        return Ok(dir.clone());
    }
    if let Some(dir) = std::env::var_os("CMUX_HOST_DIR").filter(|v| !v.is_empty()) {
        return Ok(PathBuf::from(dir));
    }
    cmux_tui_core::platform::home_dir()
        .map(|home| home.join(".cmux").join("host"))
        .ok_or_else(|| anyhow!("cannot find the home directory"))
}

fn path() -> anyhow::Result<PathBuf> {
    Ok(dir()?.join("remote.json"))
}

pub(crate) fn load() -> anyhow::Result<Config> {
    load_from(&path()?)
}

pub(crate) fn load_from(path: &Path) -> anyhow::Result<Config> {
    match std::fs::read(path) {
        Ok(bytes) => serde_json::from_slice(&bytes)
            .with_context(|| format!("{} is not valid", path.display())),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Config::default()),
        Err(e) => Err(e).with_context(|| format!("cannot read {}", path.display())),
    }
}

/// Who restarts the running listener after a [`commit`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Listener {
    /// The commit restarts a running listener: every connection open was admitted under the
    /// config before, and keeps what it was admitted with until the listener closes it (a
    /// `shell` splice, an `agents` proxy, an `allow` login).
    Restart,
    /// The verb replaces or stops the listener itself right after (`enable` restarts it on
    /// every run, `disable` stops it); only those two pass this.
    Caller,
}

/// The one way to change `remote.json`: `config` is written under `held` (taken before it was
/// loaded), and with [`Listener::Restart`] a running listener restarts, so no open connection
/// outlives the config it was admitted under. It restarts even when nothing changed: a retry after
/// a failed restart must still close what the first try left open. Returns the restart's note; an
/// error when the old listener did not stop (the config is saved, its connections are not closed).
pub(crate) fn commit(
    config: &Config,
    held: &ConfigLock,
    listener: Listener,
) -> anyhow::Result<Option<String>> {
    commit_with(
        listener,
        || save(config, held),
        || super::service::running_pid().is_some(),
        || super::service::restart(&super::self_exe()?, super::service::installed()),
    )
}

/// [`commit`]'s decision, with the write, the running check and the restart passed in (tests).
fn commit_with(
    listener: Listener,
    save: impl FnOnce() -> anyhow::Result<()>,
    running: impl FnOnce() -> bool,
    restart: impl FnOnce() -> anyhow::Result<String>,
) -> anyhow::Result<Option<String>> {
    save()?;
    if listener == Listener::Caller || !running() {
        return Ok(None);
    }
    restart().map(Some)
}

/// Whether `remote.json` exists (an error when its directory cannot be found), for readers that
/// skip a machine that never enabled hosting.
pub(crate) fn exists() -> anyhow::Result<bool> {
    Ok(path()?.exists())
}

/// Where `remote.json` is, for `status` to show; never for writing it (only [`commit`] writes).
pub(crate) fn shown_path() -> Option<String> {
    path().ok().map(|p| p.display().to_string())
}

/// Writes the file atomically (temp file + rename), owner-only. Private: every writer goes
/// through [`commit`].
fn save(config: &Config, _held: &ConfigLock) -> anyhow::Result<()> {
    let dir = ensure_dir()?;
    let path = dir.join("remote.json");
    let tmp = dir.join(format!(".remote.json.{}", std::process::id()));
    {
        use std::io::Write as _;
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create(true).truncate(true);
        #[cfg(unix)]
        std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
        let mut file = options.open(&tmp)?;
        file.write_all(&serde_json::to_vec_pretty(config)?)?;
    }
    cmux_tui_core::platform::restrict_file(&tmp)?;
    std::fs::rename(&tmp, &path).with_context(|| format!("cannot write {}", path.display()))?;
    Ok(())
}

/// An exclusive lock on the config for one read-check-write (released when the file closes),
/// so a change confirmed at a prompt applies to the config as it is then. `File::lock` is
/// `flock` on Unix and `LockFileEx` on Windows, so every platform that hosts takes it.
pub(crate) struct ConfigLock {
    _file: std::fs::File,
}

/// Takes [`ConfigLock`], waiting for another holder.
pub(crate) fn lock() -> anyhow::Result<ConfigLock> {
    let mut options = std::fs::OpenOptions::new();
    options.read(true).write(true).create(true).truncate(false);
    #[cfg(unix)]
    std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
    let file = options
        .open(ensure_dir()?.join("remote.json.lock"))
        .context(crate::localization::catalog().host_share.lock)?;
    file.lock().context(crate::localization::catalog().host_share.lock)?;
    Ok(ConfigLock { _file: file })
}

/// Creates the state directory owner-only (config, pid lock and log).
pub(crate) fn ensure_dir() -> anyhow::Result<PathBuf> {
    let dir = dir()?;
    std::fs::create_dir_all(&dir).with_context(|| format!("cannot create {}", dir.display()))?;
    cmux_tui_core::platform::restrict_directory(&dir)?;
    Ok(dir)
}

/// Logins compare without case (tailnet logins are email-shaped).
pub(crate) fn same_login(a: &str, b: &str) -> bool {
    a.trim().eq_ignore_ascii_case(b.trim())
}

#[cfg(test)]
mod commit_tests {
    use super::{Listener, commit_with};
    use std::cell::Cell;

    /// One commit: whether the write fails and a listener runs; returns (result, restarts).
    fn commit(
        listener: Listener,
        save_fails: bool,
        running: bool,
    ) -> (anyhow::Result<Option<String>>, usize) {
        let restarts = Cell::new(0);
        let result = commit_with(
            listener,
            || if save_fails { anyhow::bail!("disk full") } else { Ok(()) },
            || running,
            || {
                restarts.set(restarts.get() + 1);
                Ok("restarted".to_owned())
            },
        );
        (result, restarts.get())
    }

    #[test]
    fn a_write_restarts_a_running_listener_every_time() {
        // The same write twice (a retry after a failed restart) restarts twice: no comparison.
        for _ in 0..2 {
            let (result, restarts) = commit(Listener::Restart, false, true);
            assert_eq!(result.unwrap().as_deref(), Some("restarted"));
            assert_eq!(restarts, 1);
        }
    }

    #[test]
    fn nothing_restarts_without_a_listener_or_for_the_verbs_that_handle_it() {
        let (result, restarts) = commit(Listener::Restart, false, false);
        assert!(result.unwrap().is_none() && restarts == 0);
        let (result, restarts) = commit(Listener::Caller, false, true);
        assert!(
            result.unwrap().is_none() && restarts == 0,
            "enable and disable replace it themselves"
        );
    }

    #[test]
    fn a_failed_write_or_restart_is_an_error() {
        let (result, restarts) = commit(Listener::Restart, true, true);
        assert!(
            result.is_err() && restarts == 0,
            "nothing restarts for a write that did not happen"
        );
        let failed =
            commit_with(Listener::Restart, || Ok(()), || true, || anyhow::bail!("still running"));
        assert!(failed.is_err(), "a listener that did not stop is never reported restarted");
    }
}
