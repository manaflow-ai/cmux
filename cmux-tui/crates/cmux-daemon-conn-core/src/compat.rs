//! What one cmux-tui daemon can do for the app, from its `identify` (or from
//! the handshake that refused it). Features follow the capabilities, never
//! the version string.

use crate::handshake::{DAEMON_APP, PROTOCOL_VERSION};
use crate::identity::Identity;
use serde::Serialize;
use std::collections::BTreeSet;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Level {
    /// Every capability the app uses.
    Current,
    /// Connects; the features behind `missing_optional` are off.
    Limited,
    /// The handshake refused the daemon; nothing works until it is updated.
    Incompatible,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Compatibility {
    pub level: Level,
    /// `identify.version`; empty when the handshake refused the daemon first.
    pub version: String,
    pub build_commit: Option<String>,
    pub session_id: Option<String>,
    pub session_name: Option<String>,
    pub protocol: Option<i64>,
    /// Why the handshake refused the daemon (capabilities, or a protocol or app).
    pub missing_required: Vec<String>,
    /// Optional capabilities the app would use that this daemon lacks, in `optional` order.
    pub missing_optional: Vec<String>,
    pub version_label: String,
}

/// `0.1.0 (3412812eae76)`: the version and a 12-character commit.
pub fn version_label(version: &str, build_commit: Option<&str>) -> String {
    let Some(commit) = build_commit.filter(|c| !c.is_empty()) else { return version.to_string() };
    let short: String = commit.chars().take(12).collect();
    if version.is_empty() { short } else { format!("{version} ({short})") }
}

/// The compatibility of a connected daemon. `not_needed` names optional
/// capabilities the app does not use on it (home-only state on a remote
/// machine), so their absence does not make it limited.
pub fn of_identity(
    identity: &Identity,
    required: &[String],
    optional: &[String],
    not_needed: &BTreeSet<String>,
) -> Compatibility {
    let have = identity.capability_set();
    let missing_required: Vec<String> =
        required.iter().filter(|c| !have.contains(c.as_str())).cloned().collect();
    let missing_optional: Vec<String> = optional
        .iter()
        .filter(|c| !not_needed.contains(*c) && !have.contains(c.as_str()))
        .cloned()
        .collect();
    let level = if !missing_required.is_empty() {
        Level::Incompatible
    } else if missing_optional.is_empty() {
        Level::Current
    } else {
        Level::Limited
    };
    Compatibility {
        level,
        version: identity.version.clone(),
        build_commit: identity.build_commit.clone(),
        session_id: identity.session_id(),
        session_name: Some(identity.session.clone()).filter(|s| !s.is_empty()),
        protocol: Some(identity.protocol),
        missing_required,
        missing_optional,
        version_label: version_label(&identity.version, identity.build_commit.as_deref()),
    }
}

/// A refusal of the handshake, as the app's error carries it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Refusal {
    MissingCapabilities(Vec<String>),
    UnsupportedProtocol(i64),
    WrongApp(String),
}

/// The compatibility a refused handshake shows.
pub fn of_refusal(refusal: &Refusal) -> Compatibility {
    let missing_required = match refusal {
        Refusal::MissingCapabilities(names) => names.clone(),
        Refusal::UnsupportedProtocol(version) => {
            vec![format!("protocol {version} (need {PROTOCOL_VERSION})")]
        }
        Refusal::WrongApp(app) => vec![format!("app {app} (need {DAEMON_APP})")],
    };
    Compatibility {
        level: Level::Incompatible,
        version: String::new(),
        build_commit: None,
        session_id: None,
        session_name: None,
        protocol: None,
        missing_required,
        missing_optional: Vec::new(),
        version_label: String::new(),
    }
}
