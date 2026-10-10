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
pub(crate) struct DaemonHost<'a> {
    /// Directory of the daemon executable; the bundled plugin is looked up here.
    pub(crate) exe_dir: Option<&'a Path>,
    /// Whether this platform can run the bundled plugin (Unix only).
    pub(crate) supported: bool,
}

/// The agent plugin the daemon should supervise, if any.
pub(crate) fn agent_plugin(raw: RawAgents, host: &DaemonHost<'_>) -> Option<JournalPluginOptions> {
    if raw.unreadable {
        return None;
    }
    if let Some(plugin) = raw.plugin {
        return explicit_plugin(plugin);
    }
    if raw.screen_detection == Some(false) || !host.supported {
        return None;
    }
    let path = host.exe_dir?.join(BUNDLED_SCREEN_DETECTION_FILE);
    if !is_executable_file(&path) {
        return None;
    }
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

/// [`agent_plugin`] for this process: the daemon executable's directory
/// (symlinks resolved, so a PATH link to the bundled `cmux` still finds its
/// siblings).
pub(crate) fn agent_plugin_for_this_daemon(raw: RawAgents) -> Option<JournalPluginOptions> {
    let exe_dir = this_daemon_dir();
    let host = DaemonHost { exe_dir: exe_dir.as_deref(), supported: cfg!(unix) };
    agent_plugin(raw, &host)
}

fn this_daemon_dir() -> Option<PathBuf> {
    test_daemon_dir().or_else(|| daemon_dir_of(&std::env::current_exe().ok()?))
}

#[cfg(not(test))]
fn test_daemon_dir() -> Option<PathBuf> {
    None
}

#[cfg(test)]
fn test_daemon_dir() -> Option<PathBuf> {
    TEST_DAEMON_DIR.with(|dir| dir.borrow().clone())
}

/// The directory of `exe` with symlinks resolved (`exe`'s own directory when
/// it cannot be resolved).
fn daemon_dir_of(exe: &Path) -> Option<PathBuf> {
    let exe = std::fs::canonicalize(exe).unwrap_or_else(|_| exe.to_path_buf());
    exe.parent().map(Path::to_path_buf)
}

#[cfg(test)]
thread_local! {
    static TEST_DAEMON_DIR: std::cell::RefCell<Option<PathBuf>> =
        const { std::cell::RefCell::new(None) };
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
