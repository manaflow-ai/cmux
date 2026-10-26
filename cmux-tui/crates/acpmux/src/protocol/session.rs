//! Session shapes: `_acpmux/sessions` and `_acpmux/session_changed`.

use std::collections::BTreeMap;

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::require_all;

/// One session as every list shows it (`Hub::session_summary`). A peer's
/// session arrives as the peer daemon's own summary plus `peer`, with
/// `status` `unreachable` while the peer is gone; a peer on an older
/// acpmux may lack newer fields, so nullable ones are optional here.
#[derive(Debug, Clone, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct SessionSummary {
    pub session_id: String,
    pub name: String,
    pub harness: String,
    pub family: Option<String>,
    /// Lossy when the path is not UTF-8.
    pub cwd: String,
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
    /// The session whose agent started this one (its `spawnedBy` tag), kept
    /// only while that parent is listed; one level.
    pub spawned_by: Option<String>,
    /// The pull request URLs its `gh pr create` calls printed, oldest first;
    /// absent from a peer on an older acpmux.
    #[serde(default)]
    #[schemars(default)]
    pub pull_requests: Vec<String>,
    /// The session whose agent started this one with its `start_session`
    /// tool (`hub/subsessions.rs`); null for a session a person or client
    /// started. Kept when the parent is closed or gone, so a client draws
    /// the tree from these links at any depth.
    pub started_by: Option<String>,
    /// Its name among its parent's sub-sessions; null for a root.
    pub short_name: Option<String>,
    /// 0 for a root session, 1 for its sub-sessions, and so on.
    pub depth: u32,
    /// Its sub-sessions that are not closed.
    pub children: u32,
    pub title: Option<String>,
    /// Who supplied `title`: `prompt` is the first-prompt fallback, while
    /// `harness`, `generated` and `adopted` are real chat titles. Older peers
    /// may omit this field.
    #[serde(default)]
    #[schemars(default)]
    pub title_source: Option<String>,
    pub last_prompt: Option<String>,
    pub preview: Option<String>,
    /// One sidebar line; null before the first prompt.
    pub last_message: Option<LastMessage>,
    pub queued: u64,
    /// A turn failed: the prompts behind it wait for a client to resume them.
    pub queue_paused: bool,
    /// A sub-session whose queued prompt waits for a free run slot of its parent: the parent
    /// runs as many sub-sessions as its `maxRunning` allows (`hub/subsession_runs.rs`). Absent
    /// otherwise, and from a peer on an older acpmux.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    #[schemars(default)]
    pub waits_for_slot: bool,
    /// Being moved to another daemon; it takes no prompt meanwhile.
    pub moving: bool,
    /// The family of a conversation another app runs that this chat only shows; null otherwise.
    pub watching: Option<String>,
    /// The agent takes a prompt mid-turn.
    pub steering: bool,
    /// `_acpmux/process/background` (Ctrl-B) moves its foreground work: its
    /// harness is Claude Code (claude-stdio), whatever the harness's name.
    /// Clients offer Ctrl-B from this, not from `harness`.
    pub backgrounds_work: bool,
    pub turn: Option<TurnSummary>,
    pub queue: Vec<QueuedPromptSummary>,
    pub pending_permissions: u64,
    /// What it waits on the person for: `question` (an agent question) or
    /// `permission`; null while nothing is pending. Only the person allows a permission.
    pub waiting_on: Option<String>,
    /// The first prompt of the question it waits on, cut to 120 characters.
    pub waiting_prompt: Option<String>,
    /// Since when it waits on the person (`lane`); null while it does not.
    pub input_since: Option<u64>,
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
    /// The automatic retry of its failed last turn that waits (`hub/auto_resume.rs`); null
    /// when none waits.
    pub retry: Option<RetrySummary>,
    /// Its last turn failed on an error an automatic retry answers, and whether, and when, it
    /// is retried is not settled yet: `retry` is about to be set or stay null, or the retry is
    /// starting or runs (`hub/auto_resume.rs`). `_acpmux/wait` answers for that turn once it is
    /// settled. Absent otherwise, and from a peer on an older acpmux.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    #[schemars(default)]
    pub retry_deciding: bool,
    /// Attached clients.
    pub attached: u64,
    /// Some attached client shows the chat.
    pub shown: bool,
    /// The chat's tools (`hub/tools.rs`).
    pub tools: Vec<ToolSummary>,
    /// `_acpmux/set_tools` can change them.
    pub tools_mutable: bool,
    /// The MCP servers the harness says it loaded, from its own report (Claude
    /// Code's system/init); null when it reports none (every ACP harness).
    pub mcp_servers: Option<Vec<McpServerSummary>>,
    /// The status dot every client draws (`status_indicator`); null for none.
    pub indicator: Option<Indicator>,
    /// What it is doing and since when (`views::lane`); null for a closed session.
    pub lane: Option<Lane>,
    /// An optional controller/daemon lifecycle receipt. It is absent until a
    /// producer supplies a validated receipt; clients must not infer one from
    /// status or placement fields.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub lifecycle_receipt: Option<LifecycleReceipt>,
    /// The peer daemon a remote session runs on; absent for this daemon's own.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub peer: Option<String>,
}

/// A durable lifecycle fact supplied by an explicit producer. This contract
/// is intentionally optional and opaque to the session sidebar until a
/// producer wires it to a real controller receipt.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
#[schemars(transform = require_all)]
pub struct LifecycleReceipt {
    pub id: String,
    #[schemars(range(min = 1))]
    pub sequence: u64,
    pub state: String,
    pub source: String,
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

/// One row of a chat's tool list (`store::ToolRow`).
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
#[schemars(transform = require_all)]
pub struct ToolSummary {
    /// `mcp:<server>`, `skill:<name>` or `plugin:<name>`, unique in the chat.
    pub id: String,
    pub name: String,
    /// `mcp`, `skill`, `plugin`, or `cmux` for cmux's own tools.
    pub kind: String,
    /// What gives it: `cmux`, or the harness that reported it (`claude`).
    pub source: String,
    pub enabled: bool,
    /// `_acpmux/set_tools` can turn it on or off in this chat.
    pub can_toggle: bool,
}

impl From<&crate::store::ToolRow> for ToolSummary {
    fn from(row: &crate::store::ToolRow) -> Self {
        Self {
            id: row.id.clone(),
            name: row.name.clone(),
            kind: row.kind.clone(),
            source: row.source.clone(),
            enabled: row.enabled,
            can_toggle: row.can_toggle,
        }
    }
}

/// One MCP server a harness loaded (`SessionSummary::mcp_servers`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[schemars(transform = require_all)]
pub struct McpServerSummary {
    pub name: String,
    pub status: McpServerStatus,
}

/// `failed` also for one that waits on a sign-in (Claude Code `needs-auth`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum McpServerStatus {
    Connected,
    Failed,
    Pending,
}

impl McpServerSummary {
    /// The servers among a chat's tool rows that its harness reported
    /// loaded; one the user's own config turned off (`disabled`) was not.
    /// None when the harness reported no server.
    pub fn loaded(rows: &[crate::store::ToolRow]) -> Option<Vec<Self>> {
        let servers: Vec<Self> = rows
            .iter()
            .filter_map(|row| {
                let name = row.id.strip_prefix("mcp:")?.to_owned();
                let status = match row.status.as_deref()? {
                    "disabled" => return None,
                    "connected" => McpServerStatus::Connected,
                    "pending" => McpServerStatus::Pending,
                    _ => McpServerStatus::Failed,
                };
                Some(Self { name, status })
            })
            .collect();
        (!servers.is_empty()).then_some(servers)
    }
}

/// The session's lane (cx-v9k2f), decided once by the daemon (`views::lane`).
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[schemars(transform = require_all)]
pub struct Lane {
    pub state: LaneState,
    /// Unix ms the state began; null when the daemon does not know.
    pub since: Option<u64>,
    /// The failed or lost turn's error text, secrets masked (`secret_scan`).
    pub error: Option<String>,
    /// What the session is doing now, one line: the running turn's prompt,
    /// else the agent's last reply line, secrets masked (`secret_scan`).
    pub step: Option<String>,
    /// The session's title, else its latest prompt, one line, secrets masked
    /// (`secret_scan`).
    pub title: Option<String>,
    /// A `working` lane that has stalled: since when its turn has had no tool
    /// call in flight and no sign of its model (`turn.stalledSince`); null
    /// otherwise. The state stays `working`, so a client that reads only it
    /// is unchanged.
    #[serde(default, rename = "stalledSince")]
    pub stalled_since: Option<u64>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum LaneState {
    Working,
    Input,
    Failed,
    Lost,
    Idle,
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
    /// What the turn does right now: its latest tool call's title; null
    /// until it calls one (`hub/activity.rs`).
    pub activity: Option<String>,
    /// Its plan's entry in progress; null without one.
    pub plan_step: Option<String>,
    /// Since when it has stalled: no tool call in flight and no sign of its
    /// model since then, for `stalledTurnMs` or more (`hub/activity.rs`);
    /// null while it has not.
    pub stalled_since: Option<u64>,
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
    /// The images it sends, in its order; `_acpmux/attachment` reads each by its id.
    #[serde(default)]
    pub images: Vec<QueuedImage>,
    /// The sending agent's name when it is another agent's message, null for the person's: an
    /// app draws it as a received message waiting for the turn, not as a composer row.
    pub from_agent: Option<String>,
    /// The teammate who queued it in a shared chat (`_meta.provenance` `person_message`,
    /// `author.rs`), null for the owner's and for an agent's message: an app shows it under their
    /// name and offers none of its own actions on it (only they change it, `queue.not_author`).
    /// Kept across a restart and by their own edit.
    pub author: Option<QueuedAuthor>,
}

/// The person who queued a prompt in a shared chat.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
#[schemars(transform = require_all)]
pub struct QueuedAuthor {
    /// `tailnet:<login>` or `user_…`.
    pub id: String,
    pub name: String,
}

/// An image a queued prompt sends.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
#[schemars(transform = require_all)]
pub struct QueuedImage {
    /// The SHA-256 of its bytes (64 lowercase hex digits): `_acpmux/attachment {sessionId, id}`
    /// reads it, and `_acpmux/queue_edit` `update` `images` keeps it.
    pub id: String,
    pub mime_type: String,
    /// Its file name, when the client gave one.
    pub name: Option<String>,
}

/// What limits the session's agent as far as acpmux can tell.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[schemars(transform = require_all)]
pub struct Enforcement {
    /// The acpmux permission policy (the session's own, else the daemon
    /// default), or `unknown`.
    pub policy: String,
    /// Always `native_policy`.
    pub label: String,
    pub isolation: super::permission::Isolation,
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
    /// Why a turn ended without an answer, e.g. `outcome_unknown`.
    pub detail: Option<String>,
    /// What kind of failure a failed turn was (`recovery.rs`): `disk.full`, `disk.low`,
    /// `peer.unreachable`, `daemon.restarting`, `spawn.failed` or `agent.exited`. A client
    /// treats a kind it does not know as a plain error. The same key is on a request's error
    /// `data` and on the `turn_error` and `turn_result` records.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error_kind: Option<String>,
    /// One sentence saying what to do about the failure.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub recovery: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub details: Option<ErrorDetails>,
    pub ended_at: u64,
}

/// The facts of a typed failure (`errorKind`); only the keys that apply are present.
#[derive(Debug, Clone, Default, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ErrorDetails {
    /// The folder whose disk is full or low.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub free_bytes: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub total_bytes: Option<u64>,
    /// The peer, by its name in `acpmux host ls`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub peer: Option<String>,
    /// When the peer last answered (RFC 3339).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_seen_at: Option<String>,
    /// The program that could not start.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub binary: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exit_code: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub signal: Option<String>,
    /// The message is held in the durable outbox and goes when the peer or daemon is back.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub queued: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub retry_after_ms: Option<u64>,
}

/// An automatic retry of a failed turn that waits (`hub/auto_resume.rs`): attempt `attempt`
/// of `of`, at `nextAt` (epoch ms). It sends the prompt `promptId~resume-<attempt>` in the same
/// session, for the cut turn `turnId`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
#[schemars(transform = require_all)]
pub struct RetrySummary {
    pub attempt: u64,
    pub of: u64,
    pub reason: RetryReason,
    pub next_at: u64,
    pub prompt_id: String,
    pub turn_id: String,
}

/// Why a turn is retried (`hub::turn_errors::resume_cause`): the provider or the gateway had no
/// capacity (HTTP 503 or 529, overloaded, no account free), the connection dropped, or the
/// agent process died mid-turn.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum RetryReason {
    Capacity,
    Transport,
    AgentExited,
}

impl RetryReason {
    /// The reason `resume_cause` names, if it is one.
    pub fn from_cause(cause: &str) -> Option<Self> {
        match cause {
            "capacity" => Some(Self::Capacity),
            "transport" => Some(Self::Transport),
            "agent_exited" => Some(Self::AgentExited),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Capacity => "capacity",
            Self::Transport => "transport",
            Self::AgentExited => "agent_exited",
        }
    }
}

/// `_acpmux/retry` (the Retry button, `acpmux retry`): retry the chat's failed last turn now,
/// in the same session (`hub/auto_resume/retry_turn.rs`).
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
#[schemars(deny_unknown_fields)]
pub struct RetryParams {
    /// The chat's id, name or unique prefix.
    pub session_id: String,
    /// One of the chat's failed subagents to resume instead. Refused for now
    /// (`retry.subagent_unsupported`), never taken as the chat's own turn.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subagent_id: Option<String>,
}

/// What `_acpmux/retry` sent: the prompt `promptId` (`P~resume-n`, the next attempt of the
/// failed prompt) and the turn it started.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct RetryResult {
    pub prompt_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub turn_id: Option<String>,
    pub kind: RetryKind,
}

/// What `_acpmux/retry` retried: the chat's own turn, or one of its subagents.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum RetryKind {
    Turn,
    Subagent,
}

/// Also the page fields of `_acpmux/watch` (`hub::session_pages`).
#[derive(Debug, Clone, Default, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
#[schemars(deny_unknown_fields)]
pub struct SessionsParams {
    /// Page size, at least 1. Without it the reply is the whole list.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[schemars(range(min = 1))]
    pub limit: Option<u64>,
    /// A previous reply's `nextCursor`: the page starts after that session.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cursor: Option<String>,
    /// `_acpmux/sessions` only (a watch refuses it): only the sessions this acpmux peer owns
    /// (its name, e.g. `huge-blue`). Empty is no filter.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub peer: Option<String>,
    /// `_acpmux/sessions` only (a watch refuses it): only the sessions in this status
    /// (`running`, `ready`, `idle`, `waiting`, `closed`). Empty is no filter.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<String>,
}

#[derive(Debug, Clone, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct SessionsResult {
    /// Local and peer sessions, newest first, then by `sessionId`.
    pub sessions: Vec<SessionSummary>,
    /// With `limit`: the cursor for the next page, null when the list is
    /// done. Absent without `limit`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub next_cursor: Option<Option<String>>,
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
