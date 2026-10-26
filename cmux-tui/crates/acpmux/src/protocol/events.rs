//! Attaching to a session and reading its log: `_acpmux/attach`,
//! `_acpmux/events`, `_acpmux/detach`, `_acpmux/view`, `_acpmux/markUnread`,
//! `_acpmux/watch` and the `_acpmux/event` notification.
//!
//! A session is named by `sessionId`; the daemon also takes `session` or a
//! session `name` there (`server::session_key`), which these types leave out.

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::require_all;
use super::session::SessionSummary;

/// One record of a session's log (`server::event_value`).
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
#[schemars(transform = require_all)]
pub struct SessionEvent {
    pub session_id: String,
    pub seq: u64,
    /// Unix ms.
    pub at: u64,
    /// `in` (agent to acpmux), `out` (acpmux to agent), `mux` (acpmux's own)
    /// or `peer`.
    pub dir: String,
    /// The JSON-RPC method, the `sessionUpdate` value, or an acpmux kind such
    /// as `status`.
    pub kind: String,
    /// The raw JSON-RPC message, or acpmux's payload.
    pub msg: Value,
}

/// Which records a page or an event stream carries: one kind, or any of
/// several. Absent or null: every record.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(untagged)]
pub enum EventKinds {
    One(String),
    Any(Vec<String>),
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
#[schemars(deny_unknown_fields)]
pub struct AttachParams {
    pub session_id: String,
    pub kinds: Option<EventKinds>,
    /// Send every matching record as `_acpmux/event`; else the agent's
    /// updates arrive as ACP `session/update` and acpmux's own as
    /// `_acpmux/event`.
    pub event_stream: Option<bool>,
    /// False attaches without showing the chat (`hub/seen.rs`); default true.
    pub visible: Option<bool>,
    /// Page forward from here (oldest first) when `beforeSeq` is absent.
    pub after_seq: Option<u64>,
    /// The newest `limit` records before this one.
    pub before_seq: Option<u64>,
    /// Default 2000.
    pub limit: Option<u64>,
    pub max_bytes: Option<u64>,
}

/// A session as `_acpmux/attach` returns it: its summary plus what an
/// attached client draws (`Hub::session_detail`).
#[derive(Debug, Clone, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct SessionDetail {
    #[serde(flatten)]
    pub summary: SessionSummary,
    /// The agent's ACP session modes.
    pub modes: Option<Value>,
    pub config_options: Option<Value>,
    pub models: Option<Value>,
    pub agent_info: Option<Value>,
    pub agent_capabilities: Option<Value>,
    pub usage: Option<Value>,
    /// The session's permission rules.
    pub rules_json: Option<Value>,
    /// Permission requests waiting for an answer.
    pub pending: Vec<Value>,
}

#[derive(Debug, Clone, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
#[schemars(transform = require_all)]
pub struct AttachResult {
    #[schemars(with = "SessionDetail")]
    pub session: Value,
    pub events: Vec<SessionEvent>,
    /// More records lie beyond this page.
    pub has_more: bool,
    pub last_seq: u64,
    /// Who has the chat open now, this attachment included (`hub/presence.rs`).
    pub presence: super::presence::PresenceNote,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
#[schemars(deny_unknown_fields)]
pub struct EventsParams {
    pub session_id: String,
    pub kinds: Option<EventKinds>,
    /// Records after this one; it may not lie beyond the last record.
    pub after_seq: Option<u64>,
    /// The newest `limit` records before this one.
    pub before_seq: Option<u64>,
    /// Default 5000.
    pub limit: Option<u64>,
    pub max_bytes: Option<u64>,
}

#[derive(Debug, Clone, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
#[schemars(transform = require_all)]
pub struct EventsResult {
    pub events: Vec<SessionEvent>,
    pub has_more: bool,
    pub last_seq: u64,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
#[schemars(deny_unknown_fields)]
pub struct SessionRef {
    pub session_id: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
#[schemars(deny_unknown_fields)]
pub struct ViewParams {
    pub session_id: String,
    /// The attached client shows the chat (`hub/seen.rs`).
    pub visible: bool,
    /// An author changes only that person's presence (`hub/presence.rs`), not whether the
    /// chat counts as shown.
    #[serde(rename = "_meta", skip_serializing_if = "Option::is_none")]
    pub meta: Option<super::presence::AuthorMeta>,
}

/// An acknowledgement with nothing in it.
#[derive(Debug, Clone, Default, Serialize, Deserialize, JsonSchema)]
pub struct Done {}

#[derive(Debug, Clone, Default, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
#[schemars(deny_unknown_fields)]
pub struct WatchParams {
    /// Default true: every session's changes arrive as
    /// `_acpmux/session_changed`.
    pub enabled: Option<bool>,
    pub limit: Option<u64>,
    pub cursor: Option<String>,
}
