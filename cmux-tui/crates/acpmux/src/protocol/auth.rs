//! `_acpmux/session/auth`: what this daemon knows of a chat's sign-in (`hub/session_auth.rs`).

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

/// A chat by `sessionId`, or by `target` before it has a session (a new tab before its first
/// send). Exactly one of the two. `refresh`: probe the route and run the harness's own sign-in
/// check that reads no keychain, when no newer evidence answers.
#[derive(Debug, Clone, Default, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct SessionAuthParams {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub target: Option<SessionAuthTarget>,
    #[serde(default)]
    pub refresh: bool,
}

/// The chat a send would start: its harness, the peer it runs on (`host`, a peer name; absent:
/// this daemon) and the route the picker selected (absent: the harness's default route, as at
/// spawn).
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct SessionAuthTarget {
    pub harness: String,
    /// Absolute project directory on the destination daemon. Absent: project auth is unknown.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<std::path::PathBuf>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub host: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub route_id: Option<String>,
}

/// What `_acpmux/session/auth` answers. A client blocks a send only on `signedOut`, `expired`
/// or `routeAuthNeeded`; `unknown` never blocks.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct SessionAuthResult {
    pub state: SessionAuthState,
    pub source: SessionAuthSource,
    /// When the evidence was observed (ms since the epoch); null when `source` is `none`.
    pub evidence_at: Option<u64>,
    /// One sentence: the probe's status, the turn's error, or the check that ran.
    pub detail: String,
    pub harness: String,
    /// The peer the chat runs on; null on this daemon.
    pub host: Option<String>,
    /// The route the chat is bound to; null when it is not routed.
    pub route_id: Option<String>,
    /// How to sign in: only for `signedOut`, `expired` and `routeAuthNeeded`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub login: Option<SessionAuthLogin>,
    /// The chat whose turn is the evidence (`source` `turn`): for a `target`, a chat on this
    /// daemon with the same harness, account home and route.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub from_session_id: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum SessionAuthState {
    Ready,
    SignedOut,
    Expired,
    RouteAuthNeeded,
    RouteUnreachable,
    PeerUnreachable,
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum SessionAuthSource {
    PeerLink,
    RouteProbe,
    Turn,
    AuthCheck,
    None,
}

/// `terminal`: run `command` in a terminal on `host` (null: this machine). `route`: edit or
/// sign in again to the route `routeId`.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct SessionAuthLogin {
    pub kind: SessionAuthLoginKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub command: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub host: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub route_id: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum SessionAuthLoginKind {
    Terminal,
    Route,
}
