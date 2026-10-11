//! Where the settings file lives (Swift `CmuxConfigFile.defaultURL` and
//! `prepareDefaultURL`): `~/.config/cmux/cmux-next.json`, seeded once from
//! classic cmux's `cmux.json`.

use std::ffi::OsString;
use std::path::PathBuf;

/// Environment variable that names another settings file, so test launches
/// of tagged builds never read or write the user's file.
pub const CONFIG_OVERRIDE: &str = "CMUX_NEXT_CONFIG_FILE";

/// The settings file: `CMUX_NEXT_CONFIG_FILE` (a leading `~` expands to
/// `$HOME`), else `$HOME/.config/cmux/cmux-next.json`.
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
    home.join(NEXT_FILE)
}

const NEXT_FILE: &str = ".config/cmux/cmux-next.json";
const CLASSIC_FILE: &str = ".config/cmux/cmux.json";

/// The file a missing settings file starts from: classic cmux's
/// `cmux.json`, like the app's first launch copies it. `None` when
/// `CMUX_NEXT_CONFIG_FILE` names the file (an override is never seeded from
/// the user's files).
pub fn seed_path() -> Option<PathBuf> {
    seed_path_from(|name| std::env::var_os(name).filter(|value| !value.is_empty()))
}

/// `seed_path` with an injected environment.
pub fn seed_path_from(env: impl Fn(&str) -> Option<OsString>) -> Option<PathBuf> {
    if env(CONFIG_OVERRIDE).is_some_and(|value| !value.is_empty()) {
        return None;
    }
    env("HOME").map(|home| PathBuf::from(home).join(CLASSIC_FILE))
}

/// The cold-start cache file under the daemon's state directory.
pub fn cache_path(state_dir: &std::path::Path) -> PathBuf {
    state_dir.join("settings").join("effective.json")
}

/// The saved team policy layer under the daemon's state directory. The app
/// sends the layer after it connects; until then (and after a daemon restart)
/// the owner enforces the saved one.
pub fn team_policy_path(state_dir: &std::path::Path) -> PathBuf {
    state_dir.join("settings").join("team-policy.json")
}
