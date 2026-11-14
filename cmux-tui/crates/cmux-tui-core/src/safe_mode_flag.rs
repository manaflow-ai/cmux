//! The safe mode flag file (docs/cmux-next/extensions/safe-mode.md): one
//! small JSON file at the daemon's state root, `<root>/safe-mode.json`, where
//! `<root>` holds the session folders (`CMUX_TUI_STATE_DIR`, else the
//! platform default `cmux_tui_platform::platform::workspace_state_dir`).
//!
//! The daemon reads it once when its app supervisor starts and writes it when
//! safe mode changes. `cmux safe-mode on|off` writes it directly when no
//! daemon answers, so the next start comes up in safe mode even when the
//! app's UI is wedged. A missing or unreadable file is "off": a broken flag
//! can never keep extensions off by accident, and never turns them on when
//! the daemon already holds safe mode in memory.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

/// The file name at the state root.
pub const FILE: &str = "safe-mode.json";

/// `CMUX_SAFE_MODE=1` at daemon start enters safe mode for that run.
pub const ENV: &str = "CMUX_SAFE_MODE";

/// Why safe mode is on.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Reason {
    /// The person turned it on (the CLI, a menu item, the palette).
    User,
    /// The app crashed in a loop at launch (apps/safe_mode.rs).
    CrashLoop,
    /// `CMUX_SAFE_MODE=1` when the daemon started.
    Env,
}

impl Reason {
    pub fn as_str(self) -> &'static str {
        match self {
            Reason::User => "user",
            Reason::CrashLoop => "crash-loop",
            Reason::Env => "env",
        }
    }
}

/// Safe mode as the file stores it and `safe_mode.get` answers it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Flag {
    pub on: bool,
    pub reason: Reason,
    /// When it turned on, Unix milliseconds.
    pub since_ms: u64,
    /// For a crash loop: the extensions that were mounted in the launches
    /// that never settled, so the notice can name them.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub extensions: Vec<String>,
}

#[derive(Serialize, Deserialize)]
struct FileBody {
    version: u32,
    #[serde(flatten)]
    flag: Flag,
}

/// `<root>/safe-mode.json`.
pub fn path_in(root: &Path) -> PathBuf {
    root.join(FILE)
}

/// The flag file this process would use with no daemon to ask: the state
/// root a daemon started from this environment uses.
pub fn default_path() -> Option<PathBuf> {
    cmux_tui_platform::platform::workspace_state_dir().map(|root| path_in(&root))
}

/// The flag at `path`; `None` when the file is missing, unreadable, or says
/// off.
pub fn read(path: &Path) -> Option<Flag> {
    let raw = std::fs::read(path).ok()?;
    let body: FileBody = serde_json::from_slice(&raw).ok()?;
    (body.version == 1 && body.flag.on).then_some(body.flag)
}

/// Writes `flag` durably (temp file, fsync, rename); `None` removes the
/// file (off). Creates the folder when it is missing.
pub fn write(path: &Path, flag: Option<&Flag>) -> std::io::Result<()> {
    use std::io::Write as _;
    let Some(flag) = flag.filter(|flag| flag.on) else {
        return match std::fs::remove_file(path) {
            Err(error) if error.kind() != std::io::ErrorKind::NotFound => Err(error),
            _ => Ok(()),
        };
    };
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let temp = path.with_extension("json.tmp");
    let body = serde_json::to_vec_pretty(&FileBody { version: 1, flag: flag.clone() })
        .map_err(std::io::Error::other)?;
    let mut file = std::fs::File::create(&temp)?;
    file.write_all(&body)?;
    file.sync_all()?;
    std::fs::rename(&temp, path)
}

/// Whether `CMUX_SAFE_MODE` asks for safe mode (`1`, `true`, `yes`, `on`).
pub fn env_requests(value: Option<&str>) -> bool {
    value.is_some_and(|v| {
        matches!(v.trim().to_ascii_lowercase().as_str(), "1" | "true" | "yes" | "on")
    })
}

/// Unix milliseconds now.
pub fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| u64::try_from(d.as_millis()).unwrap_or(u64::MAX))
        .unwrap_or_default()
}

#[cfg(test)]
mod tests;
