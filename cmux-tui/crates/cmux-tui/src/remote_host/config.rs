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

pub(crate) fn path() -> anyhow::Result<PathBuf> {
    Ok(dir()?.join("remote.json"))
}

pub(crate) fn load() -> anyhow::Result<Config> {
    load_from(&path()?)
}

pub(crate) fn load_from(path: &Path) -> anyhow::Result<Config> {
    match cmux_blocking::fs::read(path) {
        Ok(bytes) => serde_json::from_slice(&bytes)
            .with_context(|| format!("{} is not valid", path.display())),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Config::default()),
        Err(e) => Err(e).with_context(|| format!("cannot read {}", path.display())),
    }
}

/// Writes the file atomically (temp file + rename), owner-only.
pub(crate) fn save(config: &Config) -> anyhow::Result<()> {
    let dir = ensure_dir()?;
    let path = dir.join("remote.json");
    let tmp = dir.join(format!(".remote.json.{}", std::process::id()));
    {
        use std::io::Write as _;
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create(true).truncate(true);
        #[cfg(unix)]
        std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
        let mut file = crate::blocking::fs::open_with(&options, &tmp)?;
        file.write_all(&serde_json::to_vec_pretty(config)?)?;
    }
    cmux_tui_core::platform::restrict_file(&tmp)?;
    cmux_blocking::fs::rename(&tmp, &path)
        .with_context(|| format!("cannot write {}", path.display()))?;
    Ok(())
}

/// Creates the state directory owner-only (config, pid lock and log).
pub(crate) fn ensure_dir() -> anyhow::Result<PathBuf> {
    let dir = dir()?;
    cmux_blocking::fs::create_dir_all(&dir)
        .with_context(|| format!("cannot create {}", dir.display()))?;
    cmux_tui_core::platform::restrict_directory(&dir)?;
    Ok(dir)
}

/// Logins compare without case (tailnet logins are email-shaped).
pub(crate) fn same_login(a: &str, b: &str) -> bool {
    a.trim().eq_ignore_ascii_case(b.trim())
}
