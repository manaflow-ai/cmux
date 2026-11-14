//! The `agents` section of cmux-tui.json: which userland agent plugin the
//! daemon supervises (spec/plugins.md, "Agent Plugins").
//!
//! An explicit `agents.plugin` always wins; an invalid one disables agent
//! plugins and never falls back. Without one, the screen-detection plugin
//! that ships beside the daemon (`cmux-agent-screen-detection`, the sibling of
//! its own executable, as the cmux-next app bundles it in Contents/Resources/bin)
//! runs as producer `cmux_screen_detection`, unless `agents.screen_detection`
//! is `false`, or the agents settings could not be read (a config file or
//! `agents` section that failed to parse). The plugin is Unix-only, so other
//! platforms never run it.

use std::path::{Path, PathBuf};

use cmux_tui_core::JournalPluginOptions;
use serde::Deserialize;

/// Journal producer id of the bundled plugin, reserved for it: an explicit
/// `agents.plugin` with this id is refused.
pub(crate) const BUNDLED_SCREEN_DETECTION_ID: &str = "cmux_screen_detection";
/// File name of the bundled plugin beside the daemon executable.
pub(crate) const BUNDLED_SCREEN_DETECTION_FILE: &str = "cmux-agent-screen-detection";

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct RawAgents {
    /// Optional background process that reports generic agent journal events.
    plugin: Option<RawAgentPlugin>,
    /// `false` stops the bundled screen-detection plugin. Default `true`.
    screen_detection: Option<bool>,
    /// The config file or its `agents` section failed to parse, so the user's
    /// choice is unknown and no plugin runs.
    #[serde(skip)]
    unreadable: bool,
}

impl RawAgents {
    /// Agents settings that could not be read (see `unreadable`).
    pub(crate) fn invalid() -> Self {
        Self { unreadable: true, ..Self::default() }
    }
}

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct RawAgentPlugin {
    id: Option<String>,
    command: Option<Vec<String>>,
    cwd: Option<String>,
    revision: Option<String>,
}

/// What the default selection needs to know about the running daemon.
pub(crate) struct DaemonHost {
    /// Where the bundled plugin may be, first match wins
    /// ([`DaemonHost::for_exe`]).
    pub(crate) candidates: Vec<PathBuf>,
    /// Whether this platform can run the bundled plugin (Unix only).
    pub(crate) supported: bool,
}

impl DaemonHost {
    /// The places the daemon executable `exe` looks for the bundled plugin:
    /// beside its resolved file (symlinks resolved, so a PATH link to the
    /// bundled `cmux` still finds the app's bin/ siblings), under the name
    /// with the same suffix as the executable's when it has one
    /// (`cmux-tui-aarch64-apple-darwin` next to
    /// `cmux-agent-screen-detection-aarch64-apple-darwin`), then beside the
    /// path it was started by (a folder of links to such files).
    pub(crate) fn for_exe(exe: &Path) -> Self {
        let resolved = std::fs::canonicalize(exe).unwrap_or_else(|_| exe.to_path_buf());
        let mut candidates = Vec::new();
        if let Some(dir) = resolved.parent() {
            candidates.push(dir.join(BUNDLED_SCREEN_DETECTION_FILE));
            let name = resolved.file_name().and_then(|name| name.to_str()).unwrap_or_default();
            let suffix = ["cmux-tui", "cmux"].iter().find_map(|stem| name.strip_prefix(stem));
            if let Some(suffix) = suffix.filter(|suffix| suffix.starts_with('-')) {
                candidates.push(dir.join(format!("{BUNDLED_SCREEN_DETECTION_FILE}{suffix}")));
            }
        }
        if let Some(dir) = exe.parent() {
            let beside_link = dir.join(BUNDLED_SCREEN_DETECTION_FILE);
            if !candidates.contains(&beside_link) {
                candidates.push(beside_link);
            }
        }
        Self { candidates, supported: cfg!(unix) }
    }

    /// The first candidate that is an executable file.
    fn installed(&self) -> Option<&Path> {
        self.candidates.iter().map(PathBuf::as_path).find(|path| is_executable_file(path))
    }
}

/// The agent plugin the daemon should supervise, if any.
pub(crate) fn agent_plugin(raw: RawAgents, host: &DaemonHost) -> Option<JournalPluginOptions> {
    if raw.unreadable {
        return None;
    }
    if let Some(plugin) = raw.plugin {
        return explicit_plugin(plugin);
    }
    if raw.screen_detection == Some(false) || !host.supported {
        return None;
    }
    let path = host.installed()?.to_path_buf();
    let options = JournalPluginOptions {
        id: BUNDLED_SCREEN_DETECTION_ID.to_string(),
        command: vec![path.to_str()?.to_string()],
        cwd: None,
        revision: bundled_revision(&path),
    };
    match options.validate() {
        Ok(()) => Some(options),
        Err(error) => {
            crate::client_log::stderr_log!(
                "config",
                "{BIN}: not running the bundled {BUNDLED_SCREEN_DETECTION_FILE}: {error}"
            );
            None
        }
    }
}

/// Restart key of the bundled plugin from the file's identity: an app update
/// replaces the file (new inode and mtime), so the supervisor restarts the
/// child, while every config load of one install sees the same value. Cheap,
/// because every CLI invocation loads the config.
pub(crate) fn bundled_revision(path: &Path) -> Option<String> {
    let metadata = std::fs::metadata(path).ok()?;
    let modified = metadata.modified().ok()?.duration_since(std::time::UNIX_EPOCH).ok()?;
    #[cfg(unix)]
    let identity = {
        use std::os::unix::fs::MetadataExt;
        format!("{:x}-{:x}-", metadata.dev(), metadata.ino())
    };
    #[cfg(not(unix))]
    let identity = String::new();
    Some(format!("bundled-{identity}{:x}-{:x}", metadata.len(), modified.as_nanos()))
}

#[cfg(unix)]
fn is_executable_file(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(path)
        .is_ok_and(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0)
}

#[cfg(not(unix))]
fn is_executable_file(path: &Path) -> bool {
    path.is_file()
}

/// [`agent_plugin`] for this process ([`DaemonHost::for_exe`]).
pub(crate) fn agent_plugin_for_this_daemon(raw: RawAgents) -> Option<JournalPluginOptions> {
    agent_plugin(raw, &this_daemon_host())
}

fn this_daemon_host() -> DaemonHost {
    if let Some(dir) = test_daemon_dir() {
        return DaemonHost {
            candidates: vec![dir.join(BUNDLED_SCREEN_DETECTION_FILE)],
            supported: cfg!(unix),
        };
    }
    match std::env::current_exe() {
        Ok(exe) => DaemonHost::for_exe(&exe),
        Err(_) => DaemonHost { candidates: Vec::new(), supported: cfg!(unix) },
    }
}

/// What the daemon at `daemon_exe` does for screen detection under `raw`
/// (`daemon status`): the same decision as [`agent_plugin`], with the
/// places it looked.
pub(crate) fn screen_detection_status(
    raw: RawAgents,
    daemon_exe: Option<&Path>,
) -> crate::screen_detection_status::ScreenDetection {
    use crate::screen_detection_status::ScreenDetection;
    if raw.unreadable {
        return ScreenDetection::Unreadable;
    }
    if let Some(plugin) = raw.plugin {
        return ScreenDetection::Replaced { id: plugin.id.unwrap_or_default() };
    }
    if raw.screen_detection == Some(false) {
        return ScreenDetection::Off;
    }
    let Some(exe) = daemon_exe else { return ScreenDetection::Unknown };
    let host = DaemonHost::for_exe(exe);
    if !host.supported {
        return ScreenDetection::Unsupported;
    }
    match host.installed() {
        Some(path) => ScreenDetection::Installed { path: path.to_path_buf() },
        None => ScreenDetection::NotInstalled { looked_in: host.candidates },
    }
}

#[cfg(not(test))]
fn test_daemon_dir() -> Option<PathBuf> {
    None
}

#[cfg(test)]
fn test_daemon_dir() -> Option<PathBuf> {
    TEST_DAEMON_DIR.with(|dir| dir.borrow().clone())
}

#[cfg(test)]
thread_local! {
    static TEST_DAEMON_DIR: std::cell::RefCell<Option<PathBuf>> =
        const { std::cell::RefCell::new(None) };
}

/// Runs `body` as if this daemon's executable lived in `dir` (tests on this
/// thread only), so config tests can place a bundled sibling.
#[cfg(test)]
pub(crate) fn with_test_daemon_dir<T>(dir: &Path, body: impl FnOnce() -> T) -> T {
    TEST_DAEMON_DIR.with(|cell| *cell.borrow_mut() = Some(dir.to_path_buf()));
    let result = body();
    TEST_DAEMON_DIR.with(|cell| *cell.borrow_mut() = None);
    result
}

/// Validates a hand-written or plugin-manager `agents.plugin` entry. `None`
/// (logged) for an entry the supervisor cannot run.
fn explicit_plugin(plugin: RawAgentPlugin) -> Option<JournalPluginOptions> {
    let Some(id) = plugin.id else {
        crate::client_log::stderr_log!(
            "config",
            "{BIN}: ignoring agents.plugin without an explicit id"
        );
        return None;
    };
    if id == BUNDLED_SCREEN_DETECTION_ID {
        crate::client_log::stderr_log!(
            "config",
            "{BIN}: ignoring agents.plugin: id {id} is reserved for the bundled screen detector"
        );
        return None;
    }
    // Do not filter later argv entries. An empty value can be meaningful
    // to a plugin, while an empty executable must still disable config.
    let command = plugin.command.unwrap_or_default();
    if command.first().is_none_or(|arg| arg.trim().is_empty()) {
        crate::client_log::stderr_log!(
            "config",
            "{BIN}: ignoring agents.plugin with empty command"
        );
        return None;
    }
    let options = JournalPluginOptions {
        id,
        command,
        cwd: plugin.cwd.filter(|cwd| !cwd.trim().is_empty()),
        revision: plugin.revision.filter(|revision| !revision.trim().is_empty()),
    };
    if let Err(error) = options.validate() {
        crate::client_log::stderr_log!("config", "{BIN}: ignoring invalid agents.plugin: {error}");
        return None;
    }
    Some(options)
}

#[cfg(test)]
mod tests;
