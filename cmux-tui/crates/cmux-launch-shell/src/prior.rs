//! Whether a launch with no launch record is a first launch ever: `Reason::FreshInstall` only on
//! positive evidence, else no stage-0 window (today's launch). No record alone proves nothing: an
//! upgrade from a build without the writer has none either, beside a session that restores windows.
//! The Swift original is `LaunchKind.of` with `LaunchSnapshotLocation.registryExists`. Two stats,
//! never a directory listing; no process, socket or network.
use std::ffi::OsString;
use std::path::{Path, PathBuf};

/// Whether the session has its registry folder in the daemon's state directory.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Registry {
    /// Neither the directory nor the session's folder in it exists.
    Absent,
    Present,
    /// The folder could not be checked, or the directory not be found (no home): it may exist.
    Unknown,
}

/// What an earlier run may have left, read when there is no launch record.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PriorState {
    pub registry: Registry,
    /// A handshake recorded the session's launch snapshot path (the app's defaults,
    /// `cmuxNext.launchSnapshotPath.<session>`): the daemon of this session ran here.
    pub snapshot_path_recorded: bool,
    /// The app's `launch-times.jsonl` exists, or could not be checked.
    pub launch_times_exists: bool,
}

impl PriorState {
    /// Nothing known: not a fresh install.
    pub const UNKNOWN: Self = Self {
        registry: Registry::Unknown,
        snapshot_path_recorded: true,
        launch_times_exists: true,
    };

    /// A first launch ever: every sign of an earlier run is known to be absent.
    pub fn is_fresh(&self) -> bool {
        self.registry == Registry::Absent
            && !self.snapshot_path_recorded
            && !self.launch_times_exists
    }

    /// Reads the evidence. `state_dir`: the daemon's state directory, else `default_state_dir()`.
    /// `launch_times`: the app's `launch-times.jsonl` (Swift `LaunchTimesFile.app(bundleID:)`).
    pub fn gather(
        session: &str,
        state_dir: Option<&Path>,
        snapshot_path_recorded: bool,
        launch_times: &Path,
    ) -> Self {
        let dir = state_dir.map(Path::to_path_buf).or_else(default_state_dir);
        Self {
            registry: dir.map_or(Registry::Unknown, |dir| registry(session, &dir)),
            snapshot_path_recorded,
            // Only "not found" is absent; any other error may hide the file.
            launch_times_exists: launch_times.try_exists().unwrap_or(true),
        }
    }
}

/// cmux-tui's state directory (cmux-tui-platform's `workspace_state_dir`): `CMUX_TUI_STATE_DIR`
/// when not empty, else `~/Library/Application Support/cmux-tui/sessions`; `None` without a home.
pub fn default_state_dir() -> Option<PathBuf> {
    resolve_state_dir(std::env::var_os("CMUX_TUI_STATE_DIR"), std::env::var_os("HOME"))
}

fn resolve_state_dir(env_dir: Option<OsString>, home: Option<OsString>) -> Option<PathBuf> {
    if let Some(dir) = env_dir.filter(|d| !d.is_empty()) {
        return Some(dir.into());
    }
    let home = home.filter(|h| !h.is_empty())?;
    Some(PathBuf::from(home).join("Library/Application Support/cmux-tui/sessions"))
}

/// Whether `dir` holds `session`'s registry folder: one stat of its exact path, never a listing,
/// so a state directory of many sessions costs nothing more. Only "not found" is absent.
pub fn registry(session: &str, dir: &Path) -> Registry {
    if session.is_empty() {
        return Registry::Unknown;
    }
    match dir.join(storage_component(session)).try_exists() {
        Ok(false) => Registry::Absent,
        Ok(true) => Registry::Present,
        Err(_) => Registry::Unknown,
    }
}

/// The folder name cmux-tui gives `session` below its state directory (cmux-tui-core's
/// `session_storage_component`): its first 48 safe bytes, then its FNV-1a hash. Kept equal to it
/// by `the_registry_folder_is_named_as_cmux_tui_names_it`.
pub(crate) fn storage_component(session: &str) -> String {
    let mut readable = String::new();
    let mut hash = 0xcbf29ce484222325u64;
    for byte in session.bytes() {
        hash ^= u64::from(byte);
        hash = hash.wrapping_mul(0x100000001b3);
        if readable.len() < 48 && (byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_')) {
            readable.push(char::from(byte));
        } else if readable.len() < 48 {
            readable.push('_');
        }
    }
    if readable.is_empty() {
        readable.push_str("session");
    }
    format!("{readable}-{hash:016x}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_registry_folder_is_named_as_cmux_tui_names_it() {
        // FNV-1a 64 of the session's bytes, as cmux-tui-core's session_storage_component.
        let fnv = |s: &str| {
            s.bytes()
                .fold(0xcbf29ce484222325u64, |h, b| (h ^ u64::from(b)).wrapping_mul(0x100000001b3))
        };
        assert_eq!(storage_component("cmux-app"), format!("cmux-app-{:016x}", fnv("cmux-app")));
        assert_eq!(storage_component("a b/c"), format!("a_b_c-{:016x}", fnv("a b/c")));
        assert_eq!(storage_component("é"), format!("__-{:016x}", fnv("é")));
        assert_eq!(storage_component(&"x".repeat(60)).len(), 48 + 1 + 16);
    }

    #[test]
    fn the_state_dir_is_the_env_else_under_home() {
        assert_eq!(
            resolve_state_dir(Some("/s".into()), Some("/h".into())),
            Some(PathBuf::from("/s"))
        );
        assert_eq!(
            resolve_state_dir(Some("".into()), Some("/h".into())),
            Some(PathBuf::from("/h/Library/Application Support/cmux-tui/sessions"))
        );
        assert_eq!(resolve_state_dir(None, None), None);
        assert_eq!(resolve_state_dir(None, Some("".into())), None);
    }

    #[test]
    fn nothing_known_is_not_fresh() {
        assert!(!PriorState::UNKNOWN.is_fresh());
    }
}
