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

mod bounded;
mod children;
mod daemon;
mod inbox;
mod outbox;
mod turns;

pub use bounded::{Bounded, MAX_AUTHORS};
pub use children::permission_session;

/// The timer key of the one-shot outbox retry.
pub const OUTBOX_TIMER: &str = "outbox";
/// The timer key prefix of a rejected prompt's retry (`prompt:<prompt id>`).
pub const PROMPT_TIMER_PREFIX: &str = "prompt:";
/// The timer key of the session-list retry.
pub const SESSIONS_TIMER: &str = "sessions";
/// Retry backoff of a failed session list or a rejected prompt: 1 s, doubling to 30 s.
pub const RETRY_INITIAL_MS: u64 = 1_000;
pub const RETRY_MAX_MS: u64 = 30_000;
/// Retries of a refused prompt before it stops (answered, with the error posted).
pub const MAX_PROMPT_RETRIES: u32 = 10;

/// The delay of retry `attempt` (1-based).
pub fn retry_delay(attempt: u32) -> u64 {
    let doubled = RETRY_INITIAL_MS.saturating_mul(1_u64 << attempt.saturating_sub(1).min(30));
    doubled.min(RETRY_MAX_MS)
}

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
    /// A `prompt` request returned. `rejected`: acpmux answered it with an
    /// error; the core sends it again on the clock (`prompt:<id>`, 1 s
    /// doubling to 30 s), at most `MAX_PROMPT_RETRIES` times; then the
    /// prompt is answered and `error` is posted in its conversation. A prompt
    /// lost with its connection is sent again on the next acpmux connect.
    PromptSettled {
        prompt_id: String,
        #[serde(default, skip_serializing_if = "std::ops::Not::not")]
        rejected: bool,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        error: Option<String>,
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
    authors: Bounded,
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
    /// Failed session lists in a row (the retry backoff).
    sessions_failures: u32,
    /// Rejections per outstanding prompt (the retry backoff), until acpmux accepts it.
    prompt_rejections: BTreeMap<String, u32>,
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
            Input::SessionChanged { session } => {
                // A pending permission's session now waits: list again at once.
                if session.status == SessionStatus::Waiting
                    && self.pending_permissions.iter().any(|p| p.session_id == session.session_id)
                {
                    self.emit(Effect::FetchSessions);
                }
                self.session_changed(session);
            }
            Input::PermissionPending { session_id, permission_id, request } => {
                self.permission(session_id, permission_id, request);
            }
            Input::Sessions { sessions, failed } => {
                if !failed {
                    self.sessions_failures = 0;
                    self.sessions(&sessions);
                } else if !self.pending_permissions.is_empty() {
                    self.sessions_failures += 1;
                    let delay = retry_delay(self.sessions_failures);
                    self.log(format!("session list failed; retrying in {delay} ms"));
                    let at = self.now + delay;
                    self.emit(Effect::ArmTimer { key: SESSIONS_TIMER.to_owned(), at });
                }
            }
            Input::ChildEvents { session_id, events } => {
                if let Some(session) = self.pending_children.remove(&session_id) {
                    self.finish_child(&session, &last_reply(&events));
                    self.replay_held(&session_id);
                    self.flush_outbox();
                }
            }
            Input::PromptSettled { prompt_id, rejected, error } => {
                self.prompt_settled(&prompt_id, rejected, error.as_deref());
            }
            Input::Timer { key } => self.timer(&key),
            Input::Disconnected { port } => self.disconnected(port),
        }
        self.drive();
        let mut effects = std::mem::take(&mut self.effects);
        if std::mem::take(&mut self.dirty) {
            effects.insert(0, Effect::Persist { state: Box::new(self.state.clone()) });
        }
        effects
    }

    /// A prompt request returned. A refusal retries on the clock, at most
    /// `MAX_PROMPT_RETRIES` times; then the prompt stops.
    fn prompt_settled(&mut self, prompt_id: &str, rejected: bool, error: Option<&str>) {
        self.accept(prompt_id);
        if !rejected || !self.state.prompts.contains_key(prompt_id) {
            return;
        }
        let rejections = self.prompt_rejections.get(prompt_id).copied().unwrap_or(0) + 1;
        if rejections > MAX_PROMPT_RETRIES {
            self.stop_refused_prompt(prompt_id, error.unwrap_or("refused"));
            return;
        }
        self.prompt_rejections.insert(prompt_id.to_owned(), rejections);
        let delay = retry_delay(rejections);
        self.log(format!("prompt {prompt_id} rejected; sending again in {delay} ms"));
        let key = format!("{PROMPT_TIMER_PREFIX}{prompt_id}");
        self.emit(Effect::ArmTimer { key, at: self.now + delay });
    }

    /// A prompt refused past its retries: answered (never sent again), its
    /// error posted in its conversation.
    fn stop_refused_prompt(&mut self, prompt_id: &str, error: &str) {
        let conversation = self.conversation_for(Some(prompt_id));
        self.prompt_rejections.remove(prompt_id);
        self.state.mark_answered(prompt_id);
        self.dirty = true;
        let tries = MAX_PROMPT_RETRIES + 1;
        self.log(format!("prompt {prompt_id} refused {tries} times; giving up: {error}"));
        let Some(conversation) = conversation else { return };
        let key = format!("failed:{prompt_id}");
        self.state.outbox.push(crate::state::OutboxEntry {
            conversation,
            idempotency_key: key.clone(),
            rate_retried: false,
            not_before: None,
            op: Op::MessageSend {
                client_msg_id: key,
                parts: vec![cmux_conversation::Part::Text {
                    text: format!("(turn failed: {error})"),
                    runs: None,
                }],
                reply_to: None,
            },
            child: None,
        });
        self.flush_outbox();
    }

    fn timer(&mut self, key: &str) {
        if key == OUTBOX_TIMER {
            self.outbox_timer_at = None;
            self.flush_outbox();
        } else if let Some(prompt_id) = key.strip_prefix(PROMPT_TIMER_PREFIX) {
            // Answered or dropped meanwhile: nothing to send.
            self.send_prompt(prompt_id);
        } else if key == SESSIONS_TIMER && !self.pending_permissions.is_empty() && self.acpmux_up {
            self.emit(Effect::FetchSessions);
        }
    }

    fn emit(&mut self, effect: Effect) {
        self.effects.push(effect);
    }

    fn log(&mut self, line: String) {
        self.emit(Effect::Log { line });
    }
}
