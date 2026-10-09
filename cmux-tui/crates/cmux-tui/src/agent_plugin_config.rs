//! The `agents` section of cmux-tui.json: which userland agent plugin the
//! daemon supervises (spec/plugins.md, "Agent Plugins").
//!
//! An explicit `agents.plugin` always wins; an invalid one disables agent
//! plugins and never falls back. Without one, the screen-detection plugin
//! that ships beside the daemon (`cmux-agent-screen-detection`, the sibling of
//! its own executable, as the cmux-next app bundles it in Contents/Resources/bin)
//! runs as producer `cmux_screen_detection`, unless `agents.screen_detection`
//! is `false`. The plugin is Unix-only, so other platforms never run it.

use std::path::{Path, PathBuf};

use cmux_tui_core::JournalPluginOptions;
use serde::Deserialize;

/// Journal producer id of the bundled plugin. Reserved by convention: the
/// default never runs beside an explicit plugin, so ids cannot collide.
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
    /// Restart key of the bundled plugin: the daemon's own build, since both
    /// ship together.
    pub(crate) revision: &'a str,
    /// Whether this platform can run the bundled plugin (Unix only).
    pub(crate) supported: bool,
}

/// The agent plugin the daemon should supervise, if any.
pub(crate) fn agent_plugin(raw: RawAgents, host: &DaemonHost<'_>) -> Option<JournalPluginOptions> {
    if let Some(plugin) = raw.plugin {
        return explicit_plugin(plugin);
    }
    if raw.screen_detection == Some(false) || !host.supported {
        return None;
    }
    let path = host.exe_dir?.join(BUNDLED_SCREEN_DETECTION_FILE);
    if !path.is_file() {
        return None;
    }
    let options = JournalPluginOptions {
        id: BUNDLED_SCREEN_DETECTION_ID.to_string(),
        command: vec![path.to_str()?.to_string()],
        cwd: None,
        revision: Some(host.revision.chars().take(128).collect()),
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

/// [`agent_plugin`] for this process: the daemon executable's directory
/// (symlinks resolved, so a PATH link to the bundled `cmux` still finds its
/// siblings) and this build's version.
pub(crate) fn agent_plugin_for_this_daemon(raw: RawAgents) -> Option<JournalPluginOptions> {
    let exe_dir = this_daemon_dir();
    let revision = crate::version_string();
    let host = DaemonHost {
        exe_dir: exe_dir.as_deref(),
        revision: &revision,
        supported: this_daemon_supports_bundled_plugin(),
    };
    agent_plugin(raw, &host)
}

pub(crate) fn this_daemon_supports_bundled_plugin() -> bool {
    cfg!(unix)
}

fn this_daemon_dir() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?;
    let exe = std::fs::canonicalize(&exe).unwrap_or(exe);
    exe.parent().map(Path::to_path_buf)
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
mod tests {
    use super::*;

    fn raw(json: &str) -> RawAgents {
        serde_json::from_str(json).expect("agents section parses")
    }

    fn host_with_sibling() -> (tempfile::TempDir, PathBuf) {
        let directory = tempfile::tempdir().expect("temp dir");
        let sibling = directory.path().join(BUNDLED_SCREEN_DETECTION_FILE);
        std::fs::write(&sibling, b"#!/bin/sh\n").expect("write sibling");
        (directory, sibling)
    }

    fn host(exe_dir: Option<&Path>, supported: bool) -> DaemonHost<'_> {
        DaemonHost { exe_dir, revision: "0.1.0 (abc123)", supported }
    }

    #[test]
    fn bundled_sibling_runs_with_the_reserved_producer_id() {
        let (directory, sibling) = host_with_sibling();
        let options =
            agent_plugin(raw("{}"), &host(Some(directory.path()), true)).expect("default plugin");
        assert_eq!(options.id, BUNDLED_SCREEN_DETECTION_ID);
        assert_eq!(options.id, "cmux_screen_detection");
        assert_eq!(options.command, vec![sibling.to_str().unwrap().to_string()]);
        assert_eq!(options.cwd, None);
        assert_eq!(options.revision.as_deref(), Some("0.1.0 (abc123)"));
        options.validate().expect("the default passes the supervisor's validation");
    }

    #[test]
    fn screen_detection_true_keeps_the_default() {
        let (directory, _sibling) = host_with_sibling();
        let options =
            agent_plugin(raw(r#"{"screen_detection":true}"#), &host(Some(directory.path()), true));
        assert_eq!(options.map(|options| options.id).as_deref(), Some(BUNDLED_SCREEN_DETECTION_ID));
    }

    #[test]
    fn screen_detection_false_opts_out() {
        let (directory, _sibling) = host_with_sibling();
        let options =
            agent_plugin(raw(r#"{"screen_detection":false}"#), &host(Some(directory.path()), true));
        assert!(options.is_none(), "agents.screen_detection=false must run no bundled plugin");
    }

    #[test]
    fn explicit_plugin_wins_over_the_bundled_sibling() {
        let (directory, _sibling) = host_with_sibling();
        let json = r#"{"plugin":{"id":"mine","command":["/opt/mine/plugin"],"revision":"r1"}}"#;
        let options =
            agent_plugin(raw(json), &host(Some(directory.path()), true)).expect("explicit plugin");
        assert_eq!(options.id, "mine");
        assert_eq!(options.command, vec!["/opt/mine/plugin".to_string()]);
        assert_eq!(options.revision.as_deref(), Some("r1"));
    }

    #[test]
    fn explicit_plugin_still_runs_when_screen_detection_is_off() {
        let (directory, _sibling) = host_with_sibling();
        let json =
            r#"{"screen_detection":false,"plugin":{"id":"mine","command":["/opt/mine/plugin"]}}"#;
        let options = agent_plugin(raw(json), &host(Some(directory.path()), true));
        assert_eq!(options.map(|options| options.id).as_deref(), Some("mine"));
    }

    #[test]
    fn invalid_explicit_plugin_disables_and_never_falls_back() {
        let (directory, _sibling) = host_with_sibling();
        for json in [
            r#"{"plugin":{"command":["/opt/mine/plugin"]}}"#,
            r#"{"plugin":{"id":"mine","command":[]}}"#,
            r#"{"plugin":{"id":"mine","command":["relative/plugin"]}}"#,
            r#"{"plugin":{"id":"cmux_agent","command":["/opt/mine/plugin"]}}"#,
        ] {
            let options = agent_plugin(raw(json), &host(Some(directory.path()), true));
            assert!(options.is_none(), "{json} must disable agent plugins, not select the default");
        }
    }

    #[test]
    fn missing_sibling_runs_nothing() {
        let directory = tempfile::tempdir().expect("temp dir");
        assert!(agent_plugin(raw("{}"), &host(Some(directory.path()), true)).is_none());
        assert!(agent_plugin(raw("{}"), &host(None, true)).is_none());
    }

    #[test]
    fn a_directory_named_like_the_plugin_is_not_a_sibling() {
        let directory = tempfile::tempdir().expect("temp dir");
        std::fs::create_dir(directory.path().join(BUNDLED_SCREEN_DETECTION_FILE)).unwrap();
        assert!(agent_plugin(raw("{}"), &host(Some(directory.path()), true)).is_none());
    }

    #[test]
    fn unsupported_platform_runs_nothing() {
        // Windows: the plugin is Unix-only, so the daemon passes supported=false.
        let (directory, _sibling) = host_with_sibling();
        assert!(agent_plugin(raw("{}"), &host(Some(directory.path()), false)).is_none());
    }

    #[test]
    fn this_daemon_supports_the_default_only_on_unix() {
        assert_eq!(this_daemon_supports_bundled_plugin(), cfg!(unix));
    }

    #[test]
    fn unknown_agents_keys_are_still_rejected() {
        assert!(serde_json::from_str::<RawAgents>(r#"{"screen_detect":false}"#).is_err());
    }
}
