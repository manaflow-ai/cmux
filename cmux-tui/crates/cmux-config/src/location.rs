//! Where the settings file lives (Swift `CmuxConfigFile.defaultURL` and
//! `prepareDefaultURL`): `~/.config/cmux/cmux-next.json` (on macOS
//! `~/.config/cmux-next/cmux-next.json`, beside no file of cmux Classic's).
//! Classic cmux's settings are imported by the app only after the person
//! consents.

use std::ffi::OsString;
use std::path::{Path, PathBuf};

/// Environment variable that names another settings file, so test launches
/// of tagged builds never read or write the user's file.
pub const CONFIG_OVERRIDE: &str = "CMUX_NEXT_CONFIG_FILE";

/// cmux NEXT's own folder name under `~/.config`, `~/.local/state`,
/// `Application Support` and `Caches`: `cmux-next` on macOS, where `cmux` is
/// cmux Classic's (NEXT writes nothing there), `cmux` elsewhere (Classic
/// ships on macOS only, so Linux state stays where it is).
pub const NEXT_DIR: &str = if cfg!(target_os = "macos") { "cmux-next" } else { "cmux" };

/// The folder name before cmux NEXT had its own (every platform's old `cmux`).
pub const LEGACY_DIR: &str = "cmux";

/// The settings file's name inside [`NEXT_DIR`].
pub const NEXT_FILE_NAME: &str = "cmux-next.json";

/// The settings file: `CMUX_NEXT_CONFIG_FILE` (a leading `~` expands to
/// `$HOME`), else `$HOME/.config/<NEXT_DIR>/cmux-next.json`. On macOS, the
/// first call without the override moves a file left at the old
/// `~/.config/cmux/cmux-next.json` to the new place ([`migrate_legacy_file`]).
pub fn config_path() -> PathBuf {
    migrate_legacy_once();
    config_path_from(|name| std::env::var_os(name).filter(|value| !value.is_empty()))
}

/// [`migrate_legacy_file`] for this process's `HOME`, at most once per
/// process, and only on macOS without `CMUX_NEXT_CONFIG_FILE`. Every reader
/// of the default settings file calls it first.
pub fn migrate_legacy_once() {
    if NEXT_DIR == LEGACY_DIR {
        return;
    }
    static MIGRATED: std::sync::Once = std::sync::Once::new();
    MIGRATED.call_once(|| {
        let env = |name: &str| std::env::var_os(name).filter(|value| !value.is_empty());
        if env(CONFIG_OVERRIDE).is_none()
            && let Some(home) = env("HOME")
        {
            let _ = migrate_legacy_file(Path::new(&home), NEXT_DIR);
        }
    });
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
    home.join(".config").join(NEXT_DIR).join(NEXT_FILE_NAME)
}

/// Moves `<home>/.config/cmux/cmux-next.json` to
/// `<home>/.config/<next_dir>/cmux-next.json` once, so a CLI that runs before
/// the app's own launch-time move does not start from empty settings. Only a
/// regular file moves; an existing new file is never overwritten (a hard link
/// claims the new name exclusively, then the old name goes). The new folder
/// is made 0700. `Ok(true)` when it moved the file.
pub fn migrate_legacy_file(home: &Path, next_dir: &str) -> std::io::Result<bool> {
    if next_dir == LEGACY_DIR {
        return Ok(false);
    }
    let old = home.join(".config").join(LEGACY_DIR).join(NEXT_FILE_NAME);
    let new_dir = home.join(".config").join(next_dir);
    let new = new_dir.join(NEXT_FILE_NAME);
    if new.symlink_metadata().is_ok() {
        return Ok(false);
    }
    match old.symlink_metadata() {
        Ok(meta) if meta.file_type().is_file() => {}
        _ => return Ok(false),
    }
    if new_dir.symlink_metadata().is_err() {
        let mut builder = std::fs::DirBuilder::new();
        builder.recursive(true);
        #[cfg(unix)]
        std::os::unix::fs::DirBuilderExt::mode(&mut builder, 0o700);
        builder.create(&new_dir)?;
    }
    match std::fs::hard_link(&old, &new) {
        Ok(()) => {}
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => return Ok(false),
        Err(error) => return Err(error),
    }
    std::fs::remove_file(&old)?;
    Ok(true)
}

/// What only NEXT writes in the state folder's old `cmux` (cmux-customize's
/// state and each terminal's last chat), moved to [`NEXT_DIR`] once by
/// [`migrate_legacy_state`].
pub const STATE_ITEMS: &[&str] = &["customize", "last-chat.json"];

/// [`migrate_legacy_state`] for this process's state folder
/// (`XDG_STATE_HOME`, else `$HOME/.local/state`), at most once per process,
/// and only where [`NEXT_DIR`] differs from [`LEGACY_DIR`] (macOS). Every
/// reader of a [`STATE_ITEMS`] path calls it first.
pub fn migrate_legacy_state_once() {
    if NEXT_DIR == LEGACY_DIR {
        return;
    }
    static MIGRATED: std::sync::Once = std::sync::Once::new();
    MIGRATED.call_once(|| {
        let env = |name: &str| std::env::var_os(name).filter(|value| !value.is_empty());
        let state = env("XDG_STATE_HOME")
            .map(PathBuf::from)
            .or_else(|| env("HOME").map(|home| PathBuf::from(home).join(".local/state")));
        if let Some(state) = state {
            let _ = migrate_legacy_state(&state, NEXT_DIR);
        }
    });
}

/// Moves each of [`STATE_ITEMS`] from `<state>/cmux` to `<state>/<next_dir>`
/// once, with no link left. Never over anything at the new path: a file
/// claims its new name with a hard link before the old name goes, and a
/// folder moves only while nothing has its new name. Only a regular file or
/// a real folder moves (never a link). The new folder is made 0700. Returns
/// the names it moved.
pub fn migrate_legacy_state(state: &Path, next_dir: &str) -> std::io::Result<Vec<&'static str>> {
    let mut moved = Vec::new();
    if next_dir == LEGACY_DIR {
        return Ok(moved);
    }
    let (old_dir, new_dir) = (state.join(LEGACY_DIR), state.join(next_dir));
    for &name in STATE_ITEMS {
        let (old, new) = (old_dir.join(name), new_dir.join(name));
        let Ok(meta) = old.symlink_metadata() else { continue };
        let (is_file, is_dir) = (meta.file_type().is_file(), meta.file_type().is_dir());
        if !(is_file || is_dir) || new.symlink_metadata().is_ok() {
            continue;
        }
        if new_dir.symlink_metadata().is_err() {
            let mut builder = std::fs::DirBuilder::new();
            builder.recursive(true);
            #[cfg(unix)]
            std::os::unix::fs::DirBuilderExt::mode(&mut builder, 0o700);
            builder.create(&new_dir)?;
        }
        if is_file {
            match std::fs::hard_link(&old, &new) {
                Ok(()) => std::fs::remove_file(&old)?,
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(error) => return Err(error),
            }
        } else {
            std::fs::rename(&old, &new)?;
        }
        moved.push(name);
    }
    Ok(moved)
}

/// Classic cmux is never a Rust settings fallback. The app copies it after consent.
pub fn seed_path() -> Option<PathBuf> {
    None
}

/// Retained for callers while Classic import moves behind the app's consent boundary.
pub fn seed_path_from(_env: impl Fn(&str) -> Option<OsString>) -> Option<PathBuf> {
    None
}

/// keybindings.json: beside the settings file, so `CMUX_NEXT_CONFIG_FILE`
/// moves it too (a test launch never touches the user's keys).
pub fn keybindings_path(config_path: &Path) -> PathBuf {
    config_path
        .parent()
        .map_or_else(|| PathBuf::from(KEYBINDINGS_FILE), |dir| dir.join(KEYBINDINGS_FILE))
}

const KEYBINDINGS_FILE: &str = "keybindings.json";

/// The cold-start cache file under the daemon's state directory.
pub fn cache_path(state_dir: &Path) -> PathBuf {
    state_dir.join("settings").join("effective.json")
}

/// The saved team policy layer under the daemon's state directory. The app
/// sends the layer after it connects; until then (and after a daemon restart)
/// the owner enforces the saved one.
pub fn team_policy_path(state_dir: &Path) -> PathBuf {
    state_dir.join("settings").join("team-policy.json")
}

#[cfg(test)]
#[path = "location_tests.rs"]
mod tests;
