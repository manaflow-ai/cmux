//! The sans-I/O brain host (plans/cmux-next/chief-mac.md section 3):
//! `Core::step(input, now_ms) -> effects`. A port of the TypeScript core
//! (`mux/packages/brain/src/core/core.ts`), which is the behavior source:
//! both pass the corpus that `mux/packages/brain/conformance/generate.ts`
//! writes, and a difference is fixed here, never in the corpus.
//!
//! The host shell does every read, write and timer the effects name and
//! reports results back as inputs. When a step changed the durable state,
//! its first effect is `persist`: the shell writes it before it runs the
//! other effects (write-ahead), so a crash only replays keyed effects that
//! an owner dedupes.
//!
//! Shell contract: a daemon read (`list_conversations`, `fetch_snapshot`,
//! `fetch_history`) that the owner refuses is `fetch_refused`; one that fails
//! with the connection, or times out, is `disconnected {daemon}` (the shell
//! drops that connection and connects again). A failed session list answers
//! with `sessions {failed: true}`; failed child events with an empty
//! `child_events`. A `*_connected` input while that port is up counts as a
//! disconnect first: the core drops what it held for the old connection.
//!
//! Layout: this file holds the types and `step`; the handlers are in
//! `daemon`, `inbox`, `turns` (the acpmux port), `outbox` and `children`.

use cmux_conversation::{Change, Message, Op, Summary};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{BTreeMap, VecDeque};

use crate::acp::{AcpmuxEvent, SessionStatus, SessionSummary, TurnFolder, last_reply};
use crate::state::HostState;

mod children;
mod daemon;
mod inbox;
mod outbox;
mod turns;

pub use children::permission_session;

/// The timer key of the one-shot outbox retry.
pub const OUTBOX_TIMER: &str = "outbox";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Port {
    Daemon,
    Acpmux,
}

/// What the shell reports to the core.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Input {
    /// The daemon port is up: the default conversation exists (created with
    /// `DEFAULT_CONVERSATION_KEY`) and writes are stamped `agent_mux`.
    DaemonConnected {
        conversation: Summary,
    },
    ConversationsListed {
        conversations: Vec<Summary>,
    },
    Snapshot {
        conversation: Summary,
        messages: Vec<Message>,
    },
    History {
        conversation: String,
        messages: Vec<Message>,
    },
    /// The owner refused a read (a reject with a reason, not a lost
    /// connection): the list when `conversation` is absent, else that
    /// conversation's snapshot or history page. The core skips that read;
    /// the shell does not reconnect.
    FetchRefused {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        conversation: Option<String>,
        reason: String,
    },
    ConversationChanged {
        conversation: String,
        change: Change,
    },
    /// The owner answered a `conversation_op`: `reason` is set on a reject.
    OpResult {
        idempotency_key: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        reason: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        change: Option<Change>,
    },
    /// The acpmux port is up: the Chief's session exists and `events` is the
    /// attach replay. `cursor_reset`: acpmux refused the saved cursor
    /// (`cursor_future`, a re-imported session), so the replay starts at 0.
    AcpmuxConnected {
        session_id: String,
        sessions: Vec<SessionSummary>,
        events: Vec<AcpmuxEvent>,
        #[serde(default, skip_serializing_if = "std::ops::Not::not")]
        cursor_reset: bool,
        /// The log's identity: the `at` of its seq 1 event (absent for an
        /// empty log). Anything but a non-negative safe integer is ignored
        /// with a log, as in TypeScript.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        log_id: Option<Value>,
        /// The shell created the session on this connect: its log is new,
        /// nothing can reuse its keys.
        #[serde(default, skip_serializing_if = "std::ops::Not::not")]
        created: bool,
    },
    AcpmuxEvent {
        event: AcpmuxEvent,
    },
    SessionChanged {
        session: SessionSummary,
    },
    PermissionPending {
        session_id: String,
        permission_id: String,
        request: Value,
    },
    /// The answer to `fetch_sessions`. `failed`: the request failed
    /// (sessions is empty); pending permissions stay for the next list or
    /// acpmux connect.
    Sessions {
        sessions: Vec<SessionSummary>,
        #[serde(default, skip_serializing_if = "std::ops::Not::not")]
        failed: bool,
    },
    /// The answer to `fetch_child_events` (empty when the request failed).
    ChildEvents {
        session_id: String,
        events: Vec<AcpmuxEvent>,
    },
    /// A `prompt` request returned (accepted or failed; a failed one is sent
    /// again on the next acpmux connect).
    PromptSettled {
        prompt_id: String,
    },
    Timer {
        key: String,
    },
    Disconnected {
        port: Port,
    },
}

/// What the core asks the shell to do, in order.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Effect {
    /// Write the durable state (always the first effect of its step).
    Persist {
        state: Box<HostState>,
    },
    ConversationOp {
        conversation: String,
        idempotency_key: String,
        op: Op,
    },
    Typing {
        conversation: String,
        on: bool,
    },
    Prompt {
        prompt_id: String,
        text: String,
    },
    ListConversations,
    FetchSnapshot {
        conversation: String,
        tail: u32,
    },
    FetchHistory {
        conversation: String,
        before_seq: u64,
        limit: u32,
    },
    FetchSessions,
    FetchChildEvents {
        session_id: String,
        after: u64,
    },
    Reconnect {
        port: Port,
    },
    ArmTimer {
        key: String,
        at: u64,
    },
    /// Both ports are up and a catch-up ran.
    Ready,
    Log {
        line: String,
    },
}

/// Inbox work, one item at a time. `CatchUp` and `Ready` continue a running
/// catch-up: they need only the daemon (a catch-up that started goes on when
/// acpmux drops; its prompts stay outstanding).
#[derive(Debug, Clone, PartialEq)]
enum InboxItem {
    Live(Box<Message>),
    CatchUpAll,
    CatchUp(String),
    Ready,
}

impl InboxItem {
    fn is_continuation(&self) -> bool {
        matches!(self, Self::CatchUp(_) | Self::Ready)
    }
}

#[derive(Debug, Clone, PartialEq)]
struct Paging {
    summary: Summary,
    from: u64,
    pending: Vec<Message>,
}

/// Messages handled in order with a copy of the summary taken when the task
/// started (later summary events do not change it).
#[derive(Debug, Clone, PartialEq)]
struct Handling {
    summary: Summary,
    queue: VecDeque<Message>,
    /// The prompt id and message seq waiting for acpmux.
    waiting: Option<(String, u64)>,
}

#[derive(Debug, Clone, Default, PartialEq)]
enum Task {
    #[default]
    Idle,
    Listing,
    /// A live message in a conversation the core has no summary for: its
    /// tail-1 snapshot.
    Summary(Box<Message>),
    Snapshot(String),
    History(Box<Paging>),
    Handling(Box<Handling>),
}

/// How the acpmux port came up (`Input::AcpmuxConnected` flags).
#[derive(Debug, Clone, Copy)]
struct Connect {
    cursor_reset: bool,
    log_id: Option<u64>,
    created: bool,
}

#[derive(Debug, Clone, PartialEq)]
struct PendingPermission {
    session_id: String,
    permission_id: String,
    request: Value,
}

/// The brain host's core. `state` is durable; the rest is rebuilt on connect.
#[derive(Debug, Clone, Default)]
pub struct Core {
    pub state: HostState,
    now: u64,
    dirty: bool,
    effects: Vec<Effect>,
    daemon_up: bool,
    acpmux_up: bool,
    mux_session: Option<String>,
    summaries: BTreeMap<String, Summary>,
    /// Highest message seq the inbox handled per conversation.
    handled: BTreeMap<String, u64>,
    /// Message id -> author, for the reply-to-Chief wake rule.
    authors: BTreeMap<String, String>,
    folder: TurnFolder,
    typing_in: Option<String>,
    session_status: BTreeMap<String, SessionStatus>,
    session_info: BTreeMap<String, SessionSummary>,
    /// Per child: the event seq when its previous turn ended.
    child_turn_floor: BTreeMap<String, u64>,
    /// Children whose turn ended, waiting for `child_events`.
    pending_children: BTreeMap<String, SessionSummary>,
    /// Later `session_changed` inputs of a child with a pending finish.
    held_changes: BTreeMap<String, VecDeque<SessionSummary>>,
    pending_permissions: Vec<PendingPermission>,
    inbox: VecDeque<InboxItem>,
    task: Task,
    /// The outbox head's key while the owner has not answered it.
    outbox_inflight: Option<String>,
    /// When the armed outbox timer fires (cleared when it fires).
    outbox_timer_at: Option<u64>,
    /// True while `acpmux_connected` folds the replay of a reset log: its
    /// promptless turns are history.
    reset_replay: bool,
}

impl Core {
    pub fn new(state: HostState) -> Self {
        Self { state, ..Self::default() }
    }

    pub fn step(&mut self, input: Input, now_ms: u64) -> Vec<Effect> {
        self.now = now_ms;
        match input {
            Input::DaemonConnected { conversation } => self.daemon_connected(conversation),
            Input::ConversationsListed { conversations } => self.listed(conversations),
            Input::Snapshot { conversation, messages } => self.snapshot(conversation, messages),
            Input::History { conversation, messages } => self.history(&conversation, messages),
            Input::FetchRefused { conversation, reason } => {
                self.fetch_refused(conversation.as_deref(), &reason);
            }
            Input::ConversationChanged { conversation, change } => {
                self.changed(&conversation, change);
            }
            Input::OpResult { idempotency_key, reason, change } => {
                self.op_result(&idempotency_key, reason.as_deref(), change);
            }
            Input::AcpmuxConnected {
                session_id,
                sessions,
                events,
                cursor_reset,
                log_id,
                created,
            } => {
                let log_id = match log_id {
                    None | Some(Value::Null) => None,
                    Some(value) => match crate::acp::lenient_count_value(&value) {
                        Some(id) => Some(id),
                        None => {
                            // JavaScript String(value), as the TypeScript log writes it.
                            let shown = crate::acp::js_string(&value);
                            self.log(format!(
                                "ignoring log_id {shown}: not a non-negative integer"
                            ));
                            None
                        }
                    },
                };
                let connect = Connect { cursor_reset, log_id, created };
                self.acpmux_connected(session_id, sessions, &events, connect);
            }
            Input::AcpmuxEvent { event } => {
                if event.session_id.is_some() && event.session_id == self.mux_session {
                    self.apply_mux_event(&event);
                }
            }
            Input::SessionChanged { session } => self.session_changed(session),
            Input::PermissionPending { session_id, permission_id, request } => {
                self.permission(session_id, permission_id, request);
            }
            Input::Sessions { sessions, failed } => {
                if !failed {
                    self.sessions(&sessions);
                } else if !self.pending_permissions.is_empty() {
                    self.log(
                        "session list failed; pending permissions wait for the next one".to_owned(),
                    );
                }
            }
            Input::ChildEvents { session_id, events } => {
                if let Some(session) = self.pending_children.remove(&session_id) {
                    self.finish_child(&session, &last_reply(&events));
                    self.replay_held(&session_id);
                    self.flush_outbox();
                }
            }
            Input::PromptSettled { prompt_id } => self.accept(&prompt_id),
            Input::Timer { key } => {
                if key == OUTBOX_TIMER {
                    self.outbox_timer_at = None;
                    self.flush_outbox();
                }
            }
            Input::Disconnected { port } => self.disconnected(port),
        }
        self.drive();
        let mut effects = std::mem::take(&mut self.effects);
        if std::mem::take(&mut self.dirty) {
            effects.insert(0, Effect::Persist { state: Box::new(self.state.clone()) });
        }
        effects
    }

    fn emit(&mut self, effect: Effect) {
        self.effects.push(effect);
    }

    fn log(&mut self, line: String) {
        self.emit(Effect::Log { line });
    }
}
