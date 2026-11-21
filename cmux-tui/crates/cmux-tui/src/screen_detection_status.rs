//! What a daemon does for agent screen detection, as `daemon status` says
//! it: the bundled `cmux-agent-screen-detection` plugin runs beside the
//! daemon's executable, or why it does not (`agent_plugin_config.rs`
//! decides). Without the plugin a dismissed agent dialog clears only from
//! the agent's own status report or its next hook, so a missing plugin must
//! be visible.

use std::path::PathBuf;

use serde_json::{Value, json};

/// The screen-detection state of one daemon.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum ScreenDetection {
    /// The bundled plugin is at `path`. A daemon started before it was put
    /// there runs it from its next start.
    Installed { path: PathBuf },
    /// No executable plugin at any of `looked_in`.
    NotInstalled { looked_in: Vec<PathBuf> },
    /// `agents.screen_detection` is `false`.
    Off,
    /// An explicit `agents.plugin` runs instead.
    Replaced { id: String },
    /// The agents settings could not be read, so no plugin runs.
    Unreadable,
    /// The platform cannot run the plugin.
    Unsupported,
    /// The daemon did not say where its executable is.
    Unknown,
}

/// The `screen_detection` object of `daemon status` for the daemon whose
/// `identify` reply is `identity`: its own executable (`cli_path`), under
/// this user's config.
pub(crate) fn of_daemon(identity: &Value) -> Value {
    crate::agent_plugin_config::screen_detection_status(
        crate::config::load_raw_agents(),
        identity.get("cli_path").and_then(Value::as_str).map(std::path::Path::new),
    )
    .wire()
}

impl ScreenDetection {
    /// The `screen_detection` object of `daemon status`: a stable `state`,
    /// the plugin path or the places looked in, and a localized `message`.
    pub(crate) fn wire(&self) -> Value {
        let text = &crate::localization::catalog().local_server;
        let paths = |paths: &[PathBuf]| -> Vec<String> {
            paths.iter().map(|path| path.display().to_string()).collect()
        };
        match self {
            Self::Installed { path } => json!({
                "state": "installed",
                "path": path.display().to_string(),
                "message": text.screen_detection_installed.replace("{path}", &path.display().to_string()),
            }),
            Self::NotInstalled { looked_in } => json!({
                "state": "not-installed",
                "looked_in": paths(looked_in),
                "message": text
                    .screen_detection_not_installed
                    .replace("{paths}", &paths(looked_in).join(", ")),
            }),
            Self::Off => json!({"state": "off", "message": text.screen_detection_off}),
            Self::Replaced { id } => json!({
                "state": "replaced",
                "plugin": id,
                "message": text.screen_detection_replaced.replace("{id}", id),
            }),
            Self::Unreadable => {
                json!({"state": "unreadable", "message": text.screen_detection_unreadable})
            }
            Self::Unsupported => {
                json!({"state": "unsupported", "message": text.screen_detection_unsupported})
            }
            Self::Unknown => json!({"state": "unknown", "message": text.screen_detection_unknown}),
        }
    }
}
