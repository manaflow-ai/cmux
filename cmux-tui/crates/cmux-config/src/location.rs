//! Where cmux.json lives (Swift `CmuxConfigFile.defaultURL` and the Rust
//! CLI's `cli::mcp::config::path`).

use std::ffi::OsString;
use std::path::PathBuf;

/// Environment variable that names another settings file, so test launches
/// of tagged builds never read or write the user's file.
pub const CONFIG_OVERRIDE: &str = "CMUX_NEXT_CONFIG_FILE";

/// The settings file: `CMUX_NEXT_CONFIG_FILE` (a leading `~` expands to
/// `$HOME`), else `$HOME/.config/cmux/cmux.json`.
pub fn config_path() -> PathBuf {
    config_path_from(|name| std::env::var_os(name).filter(|value| !value.is_empty()))
}

/// `config_path` with an injected environment (tests).
pub fn config_path_from(env: impl Fn(&str) -> Option<OsString>) -> PathBuf {
    if let Some(path) = env(CONFIG_OVERRIDE).filter(|value| !value.is_empty()) {
        let path = PathBuf::from(path);
        if let Ok(rest) = path.strip_prefix("~")
            && let Some(home) = env("HOME")
        {
            return PathBuf::from(home).join(rest);
        }
        return path;
    }
    let home = env("HOME").map(PathBuf::from).unwrap_or_default();
    home.join(".config/cmux/cmux.json")
}

/// The cold-start cache file under the daemon's state directory.
pub fn cache_path(state_dir: &std::path::Path) -> PathBuf {
    state_dir.join("settings").join("effective.json")
}
