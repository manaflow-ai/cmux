//! Minimal JSON-RPC 2.0 framing over newline-delimited JSON.
//!
//! acpmux keeps every message as a `serde_json::Value` so that unknown
//! methods, `_meta` blocks, and vendor extensions pass through untouched.

use crate::no_panic::JsonExt;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

/// A request id. ACP peers use integers or strings.
pub type Id = Value;

#[derive(Debug, Clone, PartialEq)]
pub enum Message {
    Request { id: Id, method: String, params: Option<Value> },
    Notification { method: String, params: Option<Value> },
    Response { id: Id, result: Option<Value>, error: Option<RpcError> },
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RpcError {
    pub code: i64,
    pub message: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub data: Option<Value>,
}

impl RpcError {
    pub fn new(code: i64, message: impl Into<String>) -> Self {
        Self { code, message: message.into(), data: None }
    }
    pub fn with_data(mut self, data: Value) -> Self {
        self.data = Some(data);
        self
    }
    pub fn invalid_params(message: impl Into<String>) -> Self {
        Self::new(-32602, message)
    }
    pub fn method_not_found(method: &str) -> Self {
        Self::new(-32601, format!("Method not found: {method}"))
    }
    pub fn internal(message: impl Into<String>) -> Self {
        Self::new(-32603, message)
    }
    pub fn not_found(message: impl Into<String>) -> Self {
        Self::new(-32002, message)
    }
    /// A request whose handler waited on an agent past its deadline
    /// (cx-m5up). `data.reason` is `deadline_exceeded`, `data.wait` names
    /// the wait, and the request may be retried.
    pub fn deadline_exceeded(wait: &str, timeout: std::time::Duration) -> Self {
        Self::new(-32000, format!("{wait} did not finish within {timeout:?}")).with_data(
            serde_json::json!({
                "reason": "deadline_exceeded",
                "wait": wait,
                "timeoutMs": u64::try_from(timeout.as_millis()).unwrap_or(u64::MAX),
                "retryable": true,
            }),
        )
    }
}

/// The most one JSON-RPC message takes on any acpmux transport. The app accepts 32 MiB frames and
/// the daemon accepts 64 MiB WebSocket frames, so 31 MiB leaves room for the envelope and a peer
/// relay's metadata without falling back to a connection-reset failure.
pub const MAX_MESSAGE_BYTES: usize = 31 << 20;

impl RpcError {
    /// A message over [`MAX_MESSAGE_BYTES`]: it fails alone, the connection stays.
    pub fn too_large(bytes: usize) -> Self {
        Self::new(
            -32000,
            format!("message too large to send: {bytes} bytes, the limit is {MAX_MESSAGE_BYTES}"),
        )
        .with_data(
            json!({"reason": "message.too_large", "bytes": bytes, "limit": MAX_MESSAGE_BYTES}),
        )
    }
}

impl std::fmt::Display for RpcError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{} (code {})", self.message, self.code)
    }
}

impl std::error::Error for RpcError {}

impl Message {
    pub fn parse(line: &str) -> Result<Self, RpcError> {
        let value: Value = serde_json::from_str(line)
            .map_err(|e| RpcError::new(-32700, format!("Parse error: {e}")))?;
        Self::from_value(value)
    }

    /// Moves the fields out of `value`: no part of it is copied (perf100: the copy of
    /// each streamed delta's params ran on every message, in the host and the daemon).
    pub fn from_value(value: Value) -> Result<Self, RpcError> {
        let Value::Object(mut obj) = value else {
            return Err(RpcError::new(-32600, "Invalid request: not an object"));
        };
        let method = match obj.remove("method") {
            Some(Value::String(m)) => Some(m),
            _ => None,
        };
        let id = obj.remove("id").filter(|v| !v.is_null());
        match (method, id) {
            (Some(method), Some(id)) => {
                Ok(Message::Request { id, method, params: obj.remove("params") })
            }
            (Some(method), None) => {
                Ok(Message::Notification { method, params: obj.remove("params") })
            }
            (None, Some(id)) => {
                let error = match obj.remove("error") {
                    Some(e) if !e.is_null() => Some(
                        serde_json::from_value::<RpcError>(e.clone())
                            .unwrap_or_else(|_| RpcError::internal(e.to_string())),
                    ),
                    _ => None,
                };
                Ok(Message::Response { id, result: obj.remove("result"), error })
            }
            (None, None) => Err(RpcError::new(-32600, "Invalid request: no method or id")),
        }
    }

    /// `to_value`, moving the params and result instead of copying them.
    pub fn into_value(self) -> Value {
        let mut obj = serde_json::Map::new();
        obj.insert("jsonrpc".into(), Value::from("2.0"));
        match self {
            Message::Request { id, method, params } => {
                obj.insert("id".into(), id);
                obj.insert("method".into(), Value::String(method));
                if let Some(p) = params {
                    obj.insert("params".into(), p);
                }
            }
            Message::Notification { method, params } => {
                obj.insert("method".into(), Value::String(method));
                if let Some(p) = params {
                    obj.insert("params".into(), p);
                }
            }
            Message::Response { id, result, error } => {
                obj.insert("id".into(), id);
                match error {
                    Some(e) => {
                        obj.insert("error".into(), json!(e));
                    }
                    None => {
                        obj.insert("result".into(), result.unwrap_or(Value::Null));
                    }
                }
            }
        }
        Value::Object(obj)
    }

    pub fn to_value(&self) -> Value {
        match self {
            Message::Request { id, method, params } => {
                let mut v = json!({"jsonrpc": "2.0", "id": id, "method": method});
                if let Some(p) = params {
                    v.set("params", p.clone());
                }
                v
            }
            Message::Notification { method, params } => {
                let mut v = json!({"jsonrpc": "2.0", "method": method});
                if let Some(p) = params {
                    v.set("params", p.clone());
                }
                v
            }
            Message::Response { id, result, error } => match error {
                Some(e) => json!({"jsonrpc": "2.0", "id": id, "error": e}),
                None => {
                    json!({"jsonrpc": "2.0", "id": id, "result": result.clone().unwrap_or(Value::Null)})
                }
            },
        }
    }

    /// The message as one JSON line, serialized from the borrowed fields (`to_value`
    /// copied every param first; each client got one copy per streamed update).
    /// The fields are in the sorted key order `to_value().to_string()` writes, so
    /// the bytes are the same as before: `server/list_reply.rs` writes reply lines
    /// itself and relies on that.
    pub fn to_line(&self) -> String {
        #[derive(Serialize)]
        struct Line<'a> {
            #[serde(skip_serializing_if = "Option::is_none")]
            error: Option<ErrorLine<'a>>,
            #[serde(skip_serializing_if = "Option::is_none")]
            id: Option<&'a Value>,
            jsonrpc: &'static str,
            #[serde(skip_serializing_if = "Option::is_none")]
            method: Option<&'a str>,
            #[serde(skip_serializing_if = "Option::is_none")]
            params: Option<&'a Value>,
            #[serde(skip_serializing_if = "Option::is_none")]
            result: Option<&'a Value>,
        }
        /// [`RpcError`] with its keys sorted, as `to_value` writes it.
        #[derive(Serialize)]
        struct ErrorLine<'a> {
            code: i64,
            #[serde(skip_serializing_if = "Option::is_none")]
            data: Option<&'a Value>,
            message: &'a str,
        }
        const NULL: Value = Value::Null;
        let line = match self {
            Message::Request { id, method, params } => Line {
                jsonrpc: "2.0",
                id: Some(id),
                method: Some(method),
                params: params.as_ref(),
                result: None,
                error: None,
            },
            Message::Notification { method, params } => Line {
                jsonrpc: "2.0",
                id: None,
                method: Some(method),
                params: params.as_ref(),
                result: None,
                error: None,
            },
            Message::Response { id, result, error } => Line {
                jsonrpc: "2.0",
                id: Some(id),
                method: None,
                params: None,
                result: if error.is_some() { None } else { Some(result.as_ref().unwrap_or(&NULL)) },
                error: error.as_ref().map(|error| ErrorLine {
                    code: error.code,
                    data: error.data.as_ref(),
                    message: &error.message,
                }),
            },
        };
        let mut s = serde_json::to_string(&line).unwrap_or_else(|_| self.to_value().to_string());
        s.push('\n');
        s
    }

    /// The line to send when it fits in [`MAX_MESSAGE_BYTES`]. A reply that does not is sent as
    /// the error reply for its id instead; a request or notification that does not is `Err`, with
    /// its size, for its sender to fail alone. A line near the cap or over it is counted and
    /// warned of (`wire_size.rs`).
    pub fn bounded_line(&self) -> Result<String, usize> {
        self.bounded_line_replying(None)
    }

    /// [`Self::bounded_line`] for a reply whose request's method the sender knows: the size
    /// watch names it (`reply to <method>`).
    pub fn bounded_line_replying(&self, reply_to: Option<&str>) -> Result<String, usize> {
        let line = self.to_line();
        crate::wire_size::observe(crate::wire_size::What::of(self, reply_to), line.len());
        if line.len() <= MAX_MESSAGE_BYTES {
            return Ok(line);
        }
        match self {
            Message::Response { id, .. } => {
                Ok(Message::err(id.clone(), RpcError::too_large(line.len())).to_line())
            }
            _ => Err(line.len()),
        }
    }

    pub fn request(id: impl Into<Id>, method: &str, params: Value) -> Self {
        Message::Request { id: id.into(), method: method.to_owned(), params: Some(params) }
    }

    pub fn notification(method: &str, params: Value) -> Self {
        Message::Notification { method: method.to_owned(), params: Some(params) }
    }

    pub fn ok(id: Id, result: Value) -> Self {
        Message::Response { id, result: Some(result), error: None }
    }

    pub fn err(id: Id, error: RpcError) -> Self {
        Message::Response { id, result: None, error: Some(error) }
    }

    pub fn method(&self) -> Option<&str> {
        match self {
            Message::Request { method, .. } | Message::Notification { method, .. } => Some(method),
            Message::Response { .. } => None,
        }
    }

    pub fn params(&self) -> Option<&Value> {
        match self {
            Message::Request { params, .. } | Message::Notification { params, .. } => {
                params.as_ref()
            }
            Message::Response { .. } => None,
        }
    }
}

/// ACP method names used by acpmux. Kept as constants so the wire is explicit.
pub mod method {
    pub const INITIALIZE: &str = "initialize";
    pub const AUTHENTICATE: &str = "authenticate";
    pub const SESSION_NEW: &str = "session/new";
    pub const SESSION_LOAD: &str = "session/load";
    pub const SESSION_RESUME: &str = "session/resume";
    pub const SESSION_LIST: &str = "session/list";
    pub const SESSION_FORK: &str = "session/fork";
    pub const SESSION_CLOSE: &str = "session/close";
    pub const SESSION_DELETE: &str = "session/delete";
    pub const SESSION_PROMPT: &str = "session/prompt";
    pub const SESSION_CANCEL: &str = "session/cancel";
    /// Dedicated, scoped Cloud trigger chat operations. These never fall
    /// through to the ordinary session/new, session/prompt or info paths.
    pub const TRIGGER_CHAT_ENSURE: &str = "trigger/chat.ensure";
    pub const TRIGGER_CHAT_SEND: &str = "trigger/chat.send";
    pub const TRIGGER_CHAT_STATUS: &str = "trigger/chat.status";
    pub const SESSION_SET_MODE: &str = "session/set_mode";
    pub const SESSION_SET_MODEL: &str = "session/set_model";
    pub const SESSION_SET_CONFIG_OPTION: &str = "session/set_config_option";
    /// Turn one of a chat's tools on or off (`hub/tools.rs`): `{sessionId,
    /// id, enabled}`.
    pub const MUX_SET_TOOLS: &str = "_acpmux/set_tools";
    /// Reconnect one of a Claude Code chat's MCP servers (`hub/tools.rs`):
    /// `{sessionId, server}`.
    pub const MUX_MCP_RECONNECT: &str = "_acpmux/mcp/reconnect";
    pub const SESSION_UPDATE: &str = "session/update";
    pub const SESSION_REQUEST_PERMISSION: &str = "session/request_permission";
    pub const CANCEL_REQUEST: &str = "$/cancel_request";

    // acpmux extension namespace. Everything a plain ACP client does not need.
    pub const MUX_STATUS: &str = "_acpmux/status";
    pub const MUX_SESSIONS: &str = "_acpmux/sessions";
    /// The asking-mode table and the remote guard's lists, for the native
    /// relay; unix socket only.
    pub const MUX_WEB_MODES: &str = "_acpmux/web_modes";
    /// A new dashboard token, served at once (`hub/web_token.rs`); unix
    /// socket only.
    pub const MUX_WEB_TOKEN_ROTATE: &str = "_acpmux/web_token_rotate";
    pub const MUX_HARNESSES: &str = "_acpmux/harnesses";
    /// Reload catalog configuration without touching existing sessions.
    pub const MUX_RELOAD_CONFIG: &str = "_acpmux/reload_config";
    pub const MUX_DEFAULTS: &str = "_acpmux/defaults";
    /// Client-side only: the reader puts this on the notification stream
    /// when the daemon closes the socket, so stream consumers notice.
    pub const MUX_DISCONNECTED: &str = "_acpmux/disconnected";
    pub const MUX_PRESETS: &str = "_acpmux/presets";
    pub const MUX_ATTACH: &str = "_acpmux/attach";
    pub const MUX_VIEW: &str = "_acpmux/view";
    pub const MUX_MARK_UNREAD: &str = "_acpmux/markUnread";
    /// A person in an attached chat starts or stops typing (`hub/presence.rs`).
    pub const MUX_TYPING: &str = "_acpmux/typing";
    /// Who has a chat open and who types in it, to its attached connections.
    pub const MUX_PRESENCE: &str = "_acpmux/presence";
    pub const MUX_DETACH: &str = "_acpmux/detach";
    pub const MUX_WATCH: &str = "_acpmux/watch";
    pub const MUX_RENAME: &str = "_acpmux/rename";
    pub const MUX_KILL: &str = "_acpmux/kill";
    pub const MUX_KEEP: &str = "_acpmux/keep";
    pub const MUX_WATCH_TAKE_OVER: &str = "_acpmux/watch_take_over";
    /// Stop one of a session's background subagents (a Claude background
    /// agent or workflow): `{sessionId, subagentSessionId}`.
    pub const MUX_SUBAGENT_STOP: &str = "_acpmux/subagent_stop";
    /// One of a session's subagents' transcripts, a page at a time, from the
    /// files Claude Code writes (a workflow agent's, a background agent's):
    /// `{sessionId, runId?, agentId, before?, after?, limit?}`
    /// (`claude_stdio/agent_transcript.rs`).
    pub const MUX_SUBAGENT_TRANSCRIPT: &str = "_acpmux/subagent_transcript";
    /// A chat's older turns, read from its Claude Code transcript a page at a time:
    /// `{sessionId, before}` → `{events, before, turns, read}`, `before` a `native_history`
    /// cursor (`hub/native_history.rs`).
    pub const MUX_NATIVE_HISTORY: &str = "_acpmux/native_history";
    /// Every Claude workflow of this daemon's chats: `{includeEnded?}` →
    /// `{workflows}` (`hub/workflow_index.rs`).
    pub const MUX_WORKFLOWS: &str = "_acpmux/workflows";
    /// The app pane's reply in place, checked and signed (`server/app_reply.rs`).
    pub const MUX_APP_REPLY: &str = "_acpmux/app_reply";
    pub const MUX_QUEUE_REMOVE: &str = "_acpmux/queue_remove";
    pub const MUX_QUEUE_EDIT: &str = "_acpmux/queue_edit";
    /// The owner lets a person's prompt that waits for them run, `{sessionId, promptId}`
    /// (`hub/queue_approve.rs`): `{sessionId, promptId, turnId, revision, approved}`.
    pub const MUX_QUEUE_APPROVE: &str = "_acpmux/queue_approve";
    /// The owner drops a person's prompt that waits for them, `{sessionId, promptId}`: its
    /// `session/prompt` answers `queue.declined`. `{sessionId, promptId, declined}`.
    pub const MUX_QUEUE_DECLINE: &str = "_acpmux/queue_decline";
    /// One queued prompt's whole text and blocks, `{sessionId, promptId}` →
    /// `{sessionId, promptId, turnId, text, prompt, fromAgent, fromSessionId, fromHarness}`
    /// (`hub/queue_text.rs`); the queue list carries a 200-character preview only.
    pub const MUX_QUEUE_TEXT: &str = "_acpmux/queue_text";
    /// The owner reads a queued prompt whole before answering it, `{sessionId, promptId}`
    /// (`hub/queue_approve.rs`): `{promptId, turnId, revision, text, prompt, inlineParts, author,
    /// provenance, awaitingOwner}`.
    pub const MUX_QUEUE_GET: &str = "_acpmux/queue_get";
    /// To the agent adapter, `{sessionId}`: stop the agent's current step so it reads the steers
    /// that wait for it, and keep the turn (Send now on a steer, `hub/queue_edit.rs`). Answers
    /// `{interrupted}`, false when no steer waits; an agent without it answers an error.
    pub const MUX_STEP_NOW: &str = "_acpmux/step_now";
    /// To the agent adapter, `{sessionId, promptId}`: take back that prompt's steer while the
    /// agent has not read it (the X on a waiting steer, `hub/queue_edit.rs` `withdraw`). Answers
    /// `{withdrawn}`, false once it was read; an agent without it answers an error.
    pub const MUX_STEER_WITHDRAW: &str = "_acpmux/steer_withdraw";
    /// An agent message's sender takes it back (`hub/withdraw.rs`).
    pub const MUX_PROMPT_WITHDRAW: &str = "_acpmux/prompt_withdraw";
    /// `acpmux session inbox NAME --digest`: the agent messages waiting go in as one digest
    /// (`hub/inbox_digest.rs`).
    pub const MUX_INBOX_DIGEST: &str = "_acpmux/inbox_digest";
    /// `acpmux send --no-wait`: queue a prompt for this daemon to deliver (`hub/outbox.rs`).
    pub const MUX_SEND_QUEUE: &str = "_acpmux/send_queue";
    pub const MUX_SEND_STATUS: &str = "_acpmux/send_status";
    /// Local socket: enqueue or read a mesh lifecycle control receipt.
    pub const MUX_MESH_CONTROL: &str = "_acpmux/mesh_control";
    /// Resume agent message pairs the runaway guard paused (`hub/agent_pairs.rs`).
    pub const MUX_AGENT_PAIR_RESUME: &str = "_acpmux/agent_pair_resume";
    /// Retry a chat's failed last turn now (`hub/auto_resume/retry_turn.rs`).
    pub const MUX_RETRY: &str = "_acpmux/retry";
    /// What this daemon knows of a chat's sign-in (`hub/session_auth.rs`).
    pub const MUX_SESSION_AUTH: &str = "_acpmux/session/auth";
    pub const MUX_INFO: &str = "_acpmux/info";
    /// Sign a daemon-owned proof for the currently live turn.
    pub const MUX_TURN_ATTESTATION: &str = "_acpmux/turn_attestation";
    /// Metadata-only paths for a session's config and state files; local Unix socket only.
    pub const MUX_SESSION_FILES: &str = "_acpmux/session_files";
    pub const MUX_EVENTS: &str = "_acpmux/events";
    /// One GitHub action for an agent on a machine the person added, run by the Mac that lends it
    /// its `gh` login; never a credential (`github_broker.rs`).
    pub const MUX_GITHUB_ACTION: &str = "_acpmux/github_action";
    /// The app lends this daemon its cmux sign-in for GitHub App tokens, or takes it back
    /// (`github_app_token.rs`); the unix socket only.
    pub const MUX_GITHUB_APP_LEASE: &str = "_acpmux/github_app_lease";
    /// Durable inter-session mailbox: send, page/wait, and recipient-only ack.
    pub const MUX_MAIL_SEND: &str = "_acpmux/mail/send";
    pub const MUX_MAIL_READ: &str = "_acpmux/mail/read";
    pub const MUX_MAIL_WAIT: &str = "_acpmux/mail/wait";
    pub const MUX_MAIL_ACK: &str = "_acpmux/mail/ack";
    /// Team-scoped relay messaging (Labs gated): send and inspect durable inbox entries.
    pub const MUX_TEAM_SEND: &str = "_acpmux/team/send";
    pub const MUX_TEAM_INBOX: &str = "_acpmux/team/inbox";
    pub const MUX_TEAM_READ: &str = "_acpmux/team/read";
    pub const MUX_TEAM_ACK: &str = "_acpmux/team/ack";
    /// An image a session's prompt sent, by its id (`hub/prompt_images.rs`).
    pub const MUX_ATTACHMENT: &str = "_acpmux/attachment";
    pub const MUX_PERMISSION_RESPOND: &str = "_acpmux/permission_respond";
    /// The signed app gives this launch's person key (`hub/person.rs`).
    pub const MUX_PERSON_ENROLL: &str = "_acpmux/person_enroll";
    /// The signed app gives the daemon its legacy Computer Use agent endpoint.
    pub const MUX_COMPUTER_USE_ENROLL: &str = "_acpmux/computer_use_enroll";
    /// The person proof for this connection's challenge (`hub/person.rs`).
    pub const MUX_PERSON_PROVE: &str = "_acpmux/person_prove";
    pub const MUX_PERSON_HOLDS: &str = "_acpmux/person_holds";
    /// Explicit person-only controls for the daemon-owned embedded tailnet.
    pub const MUX_TAILNET_START: &str = "_acpmux/tailnet/start";
    pub const MUX_TAILNET_LOGIN: &str = "_acpmux/tailnet/login";
    pub const MUX_TAILNET_STATE: &str = "_acpmux/tailnet/state";
    pub const MUX_TAILNET_LOGOUT: &str = "_acpmux/tailnet/logout";
    /// The person's phones that may sign an allow (`hub/approvers.rs`).
    pub const MUX_APPROVERS_SET: &str = "_acpmux/approvers_set";
    /// The person's app: the folders of the workspaces its daemon lists now,
    /// which a remote (Web) connection may also start sessions in.
    pub const MUX_WORKSPACE_ROOTS_SET: &str = "_acpmux/workspace_roots_set";
    /// The person's app: the agent and model its New Tab page picked last,
    /// anywhere and per folder (`newTab.lastPicks`), which `_acpmux/harnesses`
    /// shows a remote device so its New Agent Chat starts where the app's does.
    pub const MUX_NEW_CHAT_PICKS_SET: &str = "_acpmux/new_chat_picks_set";
    pub const MUX_APPROVERS: &str = "_acpmux/approvers";
    /// The person's app: this machine's own approver key, which `host enroll`
    /// enrolls on a peer (`hub/mac_approvers.rs`).
    pub const MUX_MAC_APPROVER_SET: &str = "_acpmux/mac_approver_set";
    /// The Macs enrolled here and this machine's own key; `reload` reads the file again.
    pub const MUX_MAC_APPROVERS: &str = "_acpmux/mac_approvers";
    pub const MUX_PERMISSION_GROUPS: &str = "_acpmux/permission_groups";
    pub const MUX_PERMISSION_GROUP_RESPOND: &str = "_acpmux/permission_group_respond";
    pub const MUX_PERMISSION_CHAT_REVOKE: &str = "_acpmux/permission_chat_revoke";
    pub const MUX_SET_POLICY: &str = "_acpmux/set_policy";
    pub const MUX_SET_RULES: &str = "_acpmux/set_rules";
    /// A session's turn cap (`hub/turn_cap.rs`): `{sessionId, turnCapMs?}`, a number sets it
    /// (0 turns it off), null clears it, absent reads it.
    pub const MUX_SET_TURN_CAP: &str = "_acpmux/set_turn_cap";
    pub const AGENT_SESSION_TURN_PREPARE: &str = "agent-session-turn-prepare";
    pub const AGENT_SESSION_TURN_ABANDON: &str = "agent-session-turn-abandon";
    /// A chat's inbox threads (`hub/inbox.rs`): `{sessionId}`.
    pub const MUX_INBOX_THREADS: &str = "_acpmux/inbox_threads";
    /// One inbox thread's messages: `{sessionId, threadId, markRead?}`.
    pub const MUX_INBOX_THREAD: &str = "_acpmux/inbox_thread";
    /// An answer in an inbox thread, to its sender's inbox: `{sessionId, threadId, text}`.
    pub const MUX_INBOX_REPLY: &str = "_acpmux/inbox_reply";
    pub const MUX_TAG: &str = "_acpmux/tag";
    /// The chat menu's Archive (`archived: true`) or Unarchive of one session:
    /// the `archived` tag, valued with when (milliseconds), set or removed.
    pub const MUX_ARCHIVE: &str = "_acpmux/archive";
    /// New side chat: tags the fork `sessionId` as a side chat of `chat` (the
    /// `side` tag, valued with that session), which keeps it off the lists.
    pub const MUX_SIDE: &str = "_acpmux/side";
    pub const MUX_WAIT: &str = "_acpmux/wait";
    pub const MUX_WATCH_ADD: &str = "_acpmux/watch_add";
    pub const MUX_WATCH_LS: &str = "_acpmux/watch_ls";
    pub const MUX_WATCH_RM: &str = "_acpmux/watch_rm";
    /// Start the agent children for the most recent project sessions.
    pub const MUX_WARM: &str = "_acpmux/warm";
    /// The harness the pane is about to switch to: a hidden session for it
    /// starts (debounced), so the switch takes a ready session.
    pub const MUX_PREWARM: &str = "_acpmux/prewarm";
    /// The permission mode a plain new chat on a harness would start in
    /// (`hub/start_mode.rs`), for the pane's pending chat. Read only.
    pub const MUX_START_MODE: &str = "_acpmux/start_mode";
    pub const MUX_HISTORY: &str = "_acpmux/history";
    /// Personal stats over every session log (`stats.rs`); the local unix
    /// socket only (the app reaches it there), never a WebSocket origin.
    pub const MUX_STATS: &str = "_acpmux/stats";
    /// Stop and delete every chat of one cmux workspace, an incognito one when its window
    /// closes (`server/chats/workspace_purge.rs`); the local unix socket only.
    pub const MUX_WORKSPACE_PURGE: &str = "_acpmux/workspace_purge";
    /// Read or replace the unsent composer text for one session.
    pub const MUX_DRAFT_GET: &str = "_acpmux/draft_get";
    pub const MUX_DRAFT_SET: &str = "_acpmux/draft_set";
    pub const MUX_COMPOSER_SET: &str = "_acpmux/composer_set";
    pub const MUX_COMPOSERS: &str = "_acpmux/composers";
    pub const MUX_BOOKMARK_GET: &str = "_acpmux/bookmark_get";
    pub const MUX_BOOKMARK_SET: &str = "_acpmux/bookmark_set";
    pub const MUX_ASK: &str = "_acpmux/ask";
    /// A side session about a chat (`/btw`, `hub/btw.rs`): read-only, on a
    /// cheap model, sent the question; answers with its session id at once.
    pub const MUX_BTW: &str = "_acpmux/btw";
    pub const MUX_SCHEMA: &str = "_acpmux/schema";
    /// The protocol IR this daemon was built with (`protocol::ir()`).
    pub const MUX_PROTOCOL: &str = "_acpmux/protocol";
    pub const MUX_EXPORT: &str = "_acpmux/export";
    pub const MUX_IMPORT: &str = "_acpmux/import";
    /// A file the person dropped into a chat, saved on the machine that runs it
    /// (`hub/file_uploads.rs`).
    pub const MUX_FILE_PUT: &str = "_acpmux/file_put";
    pub const MUX_FILE_PUT_BEGIN: &str = "_acpmux/file_put_begin";
    pub const MUX_FILE_PUT_CHUNK: &str = "_acpmux/file_put_chunk";
    pub const MUX_FILE_PUT_FINISH: &str = "_acpmux/file_put_finish";
    pub const MUX_FILE_PUT_CANCEL: &str = "_acpmux/file_put_cancel";
    pub const MUX_FILE_PUT_STATUS: &str = "_acpmux/file_put_status";
    /// A binary data frame's method (`server/upload_frames.rs`); never a text request.
    pub const MUX_FILE_PUT_DATA: &str = "_acpmux/file_put_data";
    pub const MUX_DISPATCH: &str = "_acpmux/dispatch";
    pub const MUX_STEER: &str = "_acpmux/steer";
    pub const MUX_BRIEFS: &str = "_acpmux/briefs";
    pub const MUX_REPORT: &str = "_acpmux/report";
    /// A brief for a session already on this daemon, and a session's tasks (`hub/tasks.rs`).
    pub const MUX_TASK_NEW: &str = "_acpmux/task_new";
    pub const MUX_TASKS: &str = "_acpmux/tasks";
    /// The session an agent link, id or name names, here or on a peer (`hub/locate.rs`).
    pub const MUX_RESOLVE: &str = "_acpmux/resolve";
    /// A chat's image or video, read on the machine that runs it (`hub/media_read.rs`).
    pub const MUX_MEDIA_OPEN: &str = "_acpmux/media_open";
    pub const MUX_MEDIA_RANGE: &str = "_acpmux/media_range";
    pub const MUX_SHUTDOWN: &str = "_acpmux/shutdown";
    /// Fork a session through its latest completed turn (`server/fork_through.rs`).
    pub const ACP_SESSION_FORK: &str = "acp.session.fork";
    /// Folder trust (`crate::trust`): the agents' levels for a folder and
    /// acpmux's own decision; `set` records the decision, never the agents' files.
    pub const ACP_TRUST_GET: &str = "acp.trust.get";
    pub const ACP_TRUST_SET: &str = "acp.trust.set";
    /// A folder harness profile's "Enable harness" prompt (no `sha256`), or
    /// the user's confirmation of exactly the bytes it showed (`sha256`).
    /// The unix socket and the local app only (BRING-YOUR-OWN-HARNESS H4).
    pub const MUX_HARNESS_ENABLE: &str = "_acpmux/harness_enable";
    // Your own harness from the app, the CLI and MCP (BRING-YOUR-OWN-HARNESS
    // H2; harness_admin.rs). add and doctor: the unix socket only; remove,
    // restore and registry: also the local app. Never Web or peer.
    pub const MUX_HARNESS_ADD: &str = "_acpmux/harness/add";
    pub const MUX_HARNESS_REMOVE: &str = "_acpmux/harness/remove";
    pub const MUX_HARNESS_RESTORE: &str = "_acpmux/harness/restore";
    pub const MUX_HARNESS_DOCTOR: &str = "_acpmux/harness/doctor";
    /// Store a harness env key's secret in the system secret store and point
    /// the profile at it (`{id, key, value}`; the value is never echoed).
    /// The unix socket only.
    pub const MUX_HARNESS_SECRET_SET: &str = "_acpmux/harness/secret/set";
    /// Set the icon of a profile in the user's harness folder (`{id, icon}`,
    /// `{id, data, ext}` for image bytes, or `{id, clear: true}`); the unix
    /// socket and the local app (Settings), never Web or peer.
    pub const MUX_HARNESS_ICON: &str = "_acpmux/harness/icon";
    /// The ACP Registry's agents and how each can start here.
    pub const MUX_REGISTRY: &str = "_acpmux/registry";
    /// Agent CLI health (hq #1875; `hub/health_view.rs`): the unix socket
    /// and the local app.
    pub const MUX_HARNESS_HEALTH: &str = "_acpmux/harness/health";
    /// An agent CLI's own sign-in on this machine (`agent_login.rs`): the
    /// unix socket, the local app and the owner's own peer daemon.
    pub const MUX_AGENT_LOGIN_START: &str = "_acpmux/agent_login/start";
    pub const MUX_AGENT_LOGIN_FINISH: &str = "_acpmux/agent_login/finish";
    pub const MUX_AGENT_LOGIN_CANCEL: &str = "_acpmux/agent_login/cancel";
    pub const MUX_AGENT_LOGIN_API_KEY: &str = "_acpmux/agent_login/api_key";
    /// Local socket only: bounded, cached inventory snapshots; no health control.
    pub const MUX_HARNESS_INVENTORY_WATCH: &str = "_acpmux/harness/inventory/watch";
    /// Local socket only: refresh registries for cached installs, never run CLIs or updates.
    pub const MUX_HARNESS_INVENTORY_REFRESH: &str = "_acpmux/harness/inventory/refresh";
    pub const MUX_HARNESS_UPDATE_PLAN: &str = "_acpmux/harness/update/plan";
    pub const MUX_HARNESS_UPDATE_PREPARE: &str = "_acpmux/harness/update/prepare";
    /// A complete partial-cache replacement on an explicitly subscribed local connection.
    pub const MUX_HARNESS_INVENTORY: &str = "_acpmux/harness_inventory";
    /// One cheap completion through the user's own harness login, for
    /// naming chats and workspaces (hq#1957, `crate::complete`): no chat
    /// session, tools, MCP, hooks or session file. The unix socket only.
    pub const MUX_COMPLETE: &str = "_acpmux/complete";
    /// Update Everything (cx-1mbnu; `hub/health_view.rs`): run now the
    /// no-sudo updater of the named outdated harnesses. The unix socket only.
    pub const MUX_HARNESS_UPDATE: &str = "_acpmux/harness/update";
    /// Update Everything: restart the live sessions' harness processes on
    /// the installed version and resume them (`hub/route_switch.rs`). The
    /// unix socket only.
    pub const MUX_SESSIONS_RESTART_HARNESS: &str = "_acpmux/sessions/restart_harness";
    // Routes: how a harness reaches its model provider (ROUTES R1-R3;
    // server/routes.rs). add, edit, remove, restore: the unix socket only;
    // the rest also the local app. Never Web or peer.
    pub const MUX_ROUTE_LIST: &str = "_acpmux/route/list";
    pub const MUX_ROUTE_SHOW: &str = "_acpmux/route/show";
    pub const MUX_ROUTE_ADD: &str = "_acpmux/route/add";
    pub const MUX_ROUTE_EDIT: &str = "_acpmux/route/edit";
    pub const MUX_ROUTE_REMOVE: &str = "_acpmux/route/remove";
    pub const MUX_ROUTE_RESTORE: &str = "_acpmux/route/restore";
    pub const MUX_ROUTE_TEST: &str = "_acpmux/route/test";
    pub const MUX_ROUTE_DEFAULT_SET: &str = "_acpmux/route/default.set";
    pub const MUX_CHAT_ROUTE_SET: &str = "_acpmux/chat/route.set";
    // Cross-harness handoff: a reviewed first message from one session to a
    // new session on another harness (see hub/handoff.rs).
    pub const MUX_HANDOFF_PREPARE: &str = "_acpmux/handoff_prepare";
    pub const MUX_HANDOFF_GET: &str = "_acpmux/handoff_get";
    pub const MUX_HANDOFF_DRAFT: &str = "_acpmux/handoff_draft";
    pub const MUX_HANDOFF_START: &str = "_acpmux/handoff_start";
    pub const MUX_HANDOFF_DISCARD: &str = "_acpmux/handoff_discard";
    /// An agent asks the person for a secret (`hub/secrets.rs`); the
    /// person's card answers with `secret_submit`, and `secret_run` spends
    /// the ref the agent got.
    pub const MUX_SECRET_REQUEST: &str = "_acpmux/secret_request";
    pub const MUX_SECRET_SUBMIT: &str = "_acpmux/secret_submit";
    pub const MUX_SECRET_RUN: &str = "_acpmux/secret_run";
    /// An agent offers the person a parallel chat (`hub/offers.rs`): a chip
    /// the person accepts or dismisses with `offer_respond`.
    pub const MUX_OFFER_SESSION: &str = "_acpmux/offer_session";
    pub const MUX_OFFER_RESPOND: &str = "_acpmux/offer_respond";
    /// Sub-sessions (`hub/subsessions.rs`, `server/subsessions.rs`): an agent
    /// session's own children, with the caller proven by its token.
    pub const MUX_SUBSESSION_START: &str = "_acpmux/subsession/start";
    pub const MUX_SUBSESSION_LIST: &str = "_acpmux/subsession/list";
    pub const MUX_SUBSESSION_GET: &str = "_acpmux/subsession/get";
    pub const MUX_SUBSESSION_SEND: &str = "_acpmux/subsession/send";
    pub const MUX_SUBSESSION_STOP: &str = "_acpmux/subsession/stop";
    /// Answers a descendant's pending question (never a permission prompt).
    pub const MUX_SUBSESSION_ANSWER: &str = "_acpmux/subsession/answer";
    /// Sets a session's limits: the person, or an ancestor session.
    pub const MUX_SUBSESSION_LIMITS: &str = "_acpmux/subsession/limits";
    /// Retries a descendant's failed last turn, as `_acpmux/retry` does.
    pub const MUX_SUBSESSION_RETRY: &str = "_acpmux/subsession/retry";
    /// Forum announcements (`forum.rs`, `hub/forum.rs`, `server/forum.rs`):
    /// post a rule by key, read the current rules, ack one.
    pub const MUX_FORUM_ANNOUNCE: &str = "_acpmux/forum/announce";
    pub const MUX_FORUM_RULES: &str = "_acpmux/forum/rules";
    pub const MUX_FORUM_ACK: &str = "_acpmux/forum/ack";
    /// The background-process registry (`hub/processes.rs`): list a chat's
    /// (or every chat's) background processes, read one's output, and stop
    /// one.
    pub const MUX_PROCESS_LIST: &str = "_acpmux/process/list";
    pub const MUX_PROCESS_TAIL: &str = "_acpmux/process/tail";
    pub const MUX_PROCESS_KILL: &str = "_acpmux/process/kill";
    /// Ctrl-B: move a chat's running work to the background, `{sessionId,
    /// toolCallId?}` -> `{backgrounded}`. Claude Code only.
    pub const MUX_PROCESS_BACKGROUND: &str = "_acpmux/process/background";
    /// Background tasks the daemon owns (`hub/bg_tasks.rs`): start one for a chat, list a
    /// chat's, read one's output, stop one.
    pub const MUX_BG_START: &str = "_acpmux/bg/start";
    pub const MUX_BG_LIST: &str = "_acpmux/bg/list";
    pub const MUX_BG_OUTPUT: &str = "_acpmux/bg/output";
    pub const MUX_BG_STOP: &str = "_acpmux/bg/stop";
    /// Worktree cleanup (`server/worktrees.rs`).
    pub const MUX_WORKTREE_REPORT: &str = "_acpmux/worktree/report";
    pub const MUX_WORKTREE_CLEAN: &str = "_acpmux/worktree/clean";
    pub const MUX_WORKTREE_RESTORE: &str = "_acpmux/worktree/restore";
    /// Compact closed chats' event logs (`hub/retention.rs`): `{dryRun?, archive?,
    /// olderThanDays?, only?}` -> the pass's report.
    pub const MUX_RETENTION: &str = "_acpmux/retention";
    // Pairing (`crate::pairing`, `server/pairing.rs`).
    pub const MUX_PAIR_TICKET_NEW: &str = "_acpmux/pair_ticket_new";
    pub const MUX_PAIR_LIST: &str = "_acpmux/pair_list";
    pub const MUX_PAIR_REVOKE: &str = "_acpmux/pair_revoke";
    pub const MUX_PAIR_ISSUE: &str = "_acpmux/pair_issue";
    pub const MUX_MACHINE_CONSENT_SET: &str = "_acpmux/machine_consent_set";
    pub const MUX_MACHINE_CONSENT_REFUSED: &str = "_acpmux/machine_consent_refused";
    pub const MUX_MACHINE_CONSENT_GET: &str = "_acpmux/machine_consent_get";
    pub const MUX_PAIR_SET: &str = "_acpmux/pair_set";
    pub const MUX_PAIR_REDEEM: &str = "_acpmux/pair_redeem";
    // Notifications from acpmux to attached clients.
    pub const MUX_EVENT: &str = "_acpmux/event";
    /// A persisted session-to-session message, projected separately so chat clients can render
    /// incoming and outgoing bubbles without decoding the generic event stream.
    pub const MUX_MESSAGE: &str = "_acpmux/message";
    pub const MUX_SESSION_CHANGED: &str = "_acpmux/session_changed";
    pub const MUX_PERMISSION_PENDING: &str = "_acpmux/permission_pending";
    /// To watchers when a harness profile source changed and the catalog
    /// reloaded: `{harnesses: string[], diagnostics}`.
    pub const MUX_HARNESSES_CHANGED: &str = "_acpmux/harnesses_changed";
    /// To local watchers when a new chat's start mode may have changed (a
    /// mode pick, a config reload): ask `_acpmux/start_mode` again. `{}`.
    pub const MUX_START_MODE_CHANGED: &str = "_acpmux/start_mode_changed";
    /// To watchers on each change of a peer link's state: `{peer, state, lastSeen, error, at}`
    /// (`protocol/peer_state.rs`).
    pub const MUX_PEER_STATE_CHANGED: &str = "_acpmux/peer_state_changed";
    /// Sent to the prompting connection as soon as a `session/prompt` is
    /// recorded, before the turn ends: `{sessionId, promptId, turnId, queued}`.
    pub const MUX_PROMPT_ACCEPTED: &str = "_acpmux/prompt_accepted";
    /// To the connection whose `session/cancel` notification was refused, which has no answer to
    /// read: `{sessionId, message, reason?, peer?}` (`server/requests/cancel_refused.rs`).
    pub const MUX_CANCEL_REFUSED: &str = "_acpmux/cancel_refused";
    /// To attached and watching clients when a background process starts or
    /// ends: `{process}` (`server/processes.rs`).
    pub const MUX_PROCESS_UPDATE: &str = "_acpmux/process_update";
}

#[cfg(test)]
mod bounded_tests {
    use super::*;

    /// A reply too large for one frame goes as the error reply for its id; a request or a
    /// notification that large is its sender's to fail. Neither goes out whole.
    #[test]
    fn a_message_too_large_for_one_frame_never_goes_out_whole() {
        let big = json!({"text": "x".repeat(MAX_MESSAGE_BYTES)});
        let reply = Message::ok(json!(7), big.clone()).bounded_line().unwrap();
        assert!(reply.len() < 1024, "{} bytes", reply.len());
        let Message::Response { id, error: Some(e), .. } = Message::parse(&reply).unwrap() else {
            panic!("not an error reply: {reply}");
        };
        assert_eq!(id, json!(7));
        assert_eq!(e.data.unwrap()["reason"], "message.too_large");
        assert!(Message::request(8, "session/prompt", big.clone()).bounded_line().is_err());
        assert!(Message::notification("_acpmux/event", big).bounded_line().is_err());
        let small = Message::ok(json!(9), json!({"ok": true}));
        assert_eq!(small.bounded_line().unwrap(), small.to_line());
    }
}

#[cfg(test)]
mod line_tests {
    use super::*;
    use serde_json::json;

    /// `to_line` writes from borrowed fields the bytes `to_value` wrote, keys in
    /// the same order, so readers that compare lines byte for byte
    /// (`server/list_reply.rs`) see no change.
    #[test]
    fn a_line_is_the_bytes_of_the_value() {
        let error =
            RpcError { code: -32000, message: "no".into(), data: Some(json!({"b": 1, "a": 2})) };
        for message in [
            Message::request(1, "session/prompt", json!({"z": 1, "a": [1, 2]})),
            Message::notification("_acpmux/event", json!({"kind": "x"})),
            Message::Request { id: json!(5), method: "session/cancel".into(), params: None },
            Message::Notification { method: "_acpmux/ping".into(), params: None },
            Message::Response { id: json!(6), result: None, error: None },
            Message::ok(json!("id"), json!({"ok": true})),
            Message::ok(json!(2), Value::Null),
            Message::err(json!(3), error),
            Message::err(json!(4), RpcError::new(-1, "bare")),
        ] {
            assert_eq!(message.to_line(), format!("{}\n", message.to_value()), "{message:?}");
        }
    }
}
