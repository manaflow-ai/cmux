//! The fields of a daemon's `identify` reply the connection rules read.
//!
//! The daemon writes them in cmux-tui-core's `identify` (`server.rs`,
//! `server/capabilities.rs`); that crate is the daemon itself and is not
//! linked into the app, so this reads the same wire keys.

use serde::Deserialize;
use serde_json::Value;
use std::collections::BTreeSet;

#[derive(Clone, Debug, Default, Deserialize, PartialEq)]
pub struct Identity {
    pub app: String,
    #[serde(default)]
    pub version: String,
    #[serde(default)]
    pub build_commit: Option<String>,
    #[serde(rename = "protocol")]
    pub protocol: i64,
    #[serde(default)]
    pub capabilities: Vec<String>,
    #[serde(default)]
    pub session: String,
    #[serde(default)]
    pub registry_id: Option<String>,
    /// Fences one daemon boot; compared, never read.
    #[serde(default)]
    pub generation: Value,
}

impl Identity {
    pub fn supports(&self, capability: &str) -> bool {
        self.capabilities.iter().any(|c| c == capability)
    }

    /// The capabilities as a set, for many lookups.
    pub fn capability_set(&self) -> BTreeSet<&str> {
        self.capabilities.iter().map(String::as_str).collect()
    }

    /// The session's stable identity: `registry_id` lowercased; `None` when
    /// absent or empty.
    pub fn session_id(&self) -> Option<String> {
        self.registry_id.as_deref().filter(|id| !id.is_empty()).map(str::to_lowercase)
    }

    /// The identity in one reply line (`{"ok": true, "data": {...}}`).
    pub fn from_reply(line: &str) -> Result<Self, String> {
        #[derive(Deserialize)]
        struct Envelope {
            data: Identity,
        }
        serde_json::from_str::<Envelope>(line)
            .map(|e| e.data)
            .map_err(|e| format!("DaemonIdentity: {e}"))
    }
}
