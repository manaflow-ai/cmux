//! Session shapes: `_acpmux/sessions` and `_acpmux/session_changed`.

use std::collections::BTreeMap;
use std::path::PathBuf;

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::require_all;

/// One session as every list shows it (`Hub::session_summary`). A peer's
/// session arrives as the peer daemon's own summary, with `status`
/// `unreachable` while the peer is gone.
#[derive(Debug, Clone, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
#[schemars(transform = require_all)]
pub struct SessionSummary {
    pub session_id: String,
    pub name: String,
    pub harness: String,
    pub family: Option<String>,
    pub cwd: PathBuf,
    /// `idle`, `ready`, `running`, `waiting`, `disconnected` or `closed`;
    /// a peer's session also `unreachable`.
    pub status: String,
    pub agent_session_id: Option<String>,
    pub created_at: u64,
    pub updated_at: u64,
    pub last_seq: u64,
    pub event_count: u64,
    pub turn_count: u64,
    pub parent_id: Option<String>,
    /// Where a fork branched off its parent.
    pub fork_seq: Option<u64>,
    pub title: Option<String>,
    pub last_prompt: Option<String>,
    pub preview: Option<String>,
    /// One sidebar line; null before the first prompt.
    pub last_message: Option<LastMessage>,
    pub queued: u64,
    /// A turn failed: the prompts behind it wait for a client to resume them.
    pub queue_paused: bool,
    /// Being moved to another daemon; it takes no prompt meanwhile.
    pub moving: bool,
    /// The agent takes a prompt mid-turn.
    pub steering: bool,
    pub turn: Option<TurnSummary>,
    pub queue: Vec<QueuedPromptSummary>,
    pub pending_permissions: u64,
    #[schemars(with = "Option<String>")]
    pub current_mode_id: Value,
    pub model: Option<String>,
    pub policy: Option<String>,
    #[schemars(with = "Enforcement")]
    pub enforcement: Value,
    /// The session has its own permission rules.
    pub rules: bool,
    /// Tags that have not expired.
    #[schemars(with = "BTreeMap<String, String>")]
    pub tags: Value,
    pub state_seq: u64,
    pub unread: bool,
    #[schemars(with = "Option<LastTurn>")]
    pub last_turn: Option<Value>,
    /// Attached clients.
    pub attached: u64,
    /// Some attached client shows the chat.
    pub shown: bool,
    /// The status dot every client draws (`status_indicator`); null for none.
    pub indicator: Option<Indicator>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum Indicator {
    Input,
    Working,
    Failed,
    Lost,
    Done,
}

impl Indicator {
    pub fn from_wire(text: &str) -> Option<Self> {
        Some(match text {
            "input" => Self::Input,
            "working" => Self::Working,
            "failed" => Self::Failed,
            "lost" => Self::Lost,
            "done" => Self::Done,
            _ => return None,
        })
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum MessageRole {
    Agent,
    User,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct LastMessage {
    pub role: MessageRole,
    pub text: String,
}

/// The running turn.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
#[schemars(transform = require_all)]
pub struct TurnSummary {
    pub started_at: u64,
    pub client: String,
    pub prompt: String,
    pub turn_id: String,
    pub prompt_id: String,
    pub turn_seq: u64,
}

/// A prompt waiting for the running turn to end.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
#[schemars(transform = require_all)]
pub struct QueuedPromptSummary {
    pub prompt_id: String,
    pub turn_id: String,
    pub client: String,
    pub prompt: String,
    pub queued_at: u64,
    /// Waits behind a failed turn until the queue is resumed.
    pub held: bool,
}

/// What limits the session's agent as far as acpmux can tell.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[schemars(transform = require_all)]
pub struct Enforcement {
    /// The acpmux permission policy (the session's own, else the daemon
    /// default), or `unknown`.
    pub policy: String,
    pub label: String,
    pub isolation: String,
    pub detail: String,
}

/// The outcome of the session's last turn. Keys the turn result lacked
/// are absent.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct LastTurn {
    pub turn_id: Option<String>,
    pub prompt_id: Option<String>,
    /// `completed`, `failed` or `cancelled`.
    pub status: Option<String>,
    pub stop_reason: Option<String>,
    pub error_text: Option<String>,
    pub error_source: Option<String>,
    pub ended_at: u64,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, JsonSchema)]
pub struct SessionsParams {}

#[derive(Debug, Clone, Serialize, JsonSchema)]
pub struct SessionsResult {
    /// Local and peer sessions, newest first.
    pub sessions: Vec<SessionSummary>,
}

/// A purged session: only its id is left.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct PurgedSession {
    pub session_id: String,
}

#[derive(Debug, Clone, Serialize, JsonSchema)]
#[serde(untagged)]
pub enum ChangedSession {
    Summary(Box<SessionSummary>),
    Purged(PurgedSession),
}

/// To watchers when a session changed: its new summary (only its id when
/// purged), the coarse `kind` and the log record behind it.
#[derive(Debug, Clone, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct SessionChanged {
    pub session_id: String,
    pub session: ChangedSession,
    /// The record kind, or `queue`, `permission_resolved` or `purged`.
    pub kind: String,
    pub record_kind: String,
    pub seq: u64,
    /// The peer a remote session runs on.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub peer: Option<String>,
}
