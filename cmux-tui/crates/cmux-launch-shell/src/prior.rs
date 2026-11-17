//! Whether a launch with no launch record is a first launch ever: `Reason::FreshInstall` only on
//! positive evidence, else no stage-0 window (today's launch). No record alone proves nothing: an
//! upgrade from a build without the writer has none either, beside a session that restores windows.
//! The Swift original is `LaunchKind.of` with `LaunchSnapshotLocation.registryExists`. One directory
//! listing and a stat; no process, socket or network.
use std::ffi::OsString;
use std::path::{Path, PathBuf};

/// Whether the session has a registry folder (`<session>-<id>`) in the daemon's state directory.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Registry {
    /// The directory does not exist, or holds no folder of the session.
    Absent,
    Present,
    /// The directory could not be listed, or not be found (no home): it may hold one.
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

/// Whether `dir` holds a registry folder of `session`: one listing. A directory that does not
/// exist has none; one that cannot be listed may.
pub fn registry(session: &str, dir: &Path) -> Registry {
    if session.is_empty() {
        return Registry::Unknown;
    }
    match dir.try_exists() {
        Ok(false) => return Registry::Absent,
        Ok(true) => {}
        Err(_) => return Registry::Unknown,
    }
    let Ok(entries) = std::fs::read_dir(dir) else { return Registry::Unknown };
    for entry in entries {
        let Ok(entry) = entry else { return Registry::Unknown };
        if is_registry_name(entry.file_name().as_encoded_bytes(), session) {
            return Registry::Present;
        }
    }
    Registry::Absent
}

/// `<session>-<id>` with one id part, so `cmux-app-a` never takes `cmux-app-a-b`'s registry
/// (Swift `LaunchSnapshotLocation.find`).
fn is_registry_name(name: &[u8], session: &str) -> bool {
    name.strip_prefix(session.as_bytes())
        .and_then(|rest| rest.strip_prefix(b"-"))
        .is_some_and(|id| !id.contains(&b'-'))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn registry_names_have_one_id_part() {
        assert!(is_registry_name(b"cmux-app-a-1f2e", "cmux-app-a"));
        assert!(!is_registry_name(b"cmux-app-a-b-1f2e", "cmux-app-a"));
        assert!(!is_registry_name(b"cmux-app-a", "cmux-app-a"));
        assert!(!is_registry_name(b"cmux-app-ab", "cmux-app-a"));
        assert!(!is_registry_name(b"other-1f2e", "cmux-app-a"));
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
