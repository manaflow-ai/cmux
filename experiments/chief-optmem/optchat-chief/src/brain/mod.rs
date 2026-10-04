//! The brain: one thread that owns the host state and turns inputs (daemon
//! events, acpmux events, turn workers' reports) into effects. It keeps the
//! queue of new messages and runs the turn loop of section 7:
//!
//! ```text
//! on message: if a call is running: deliver it between tool calls
//!             else: queue.push(text); if idle: turn()
//! turn: settle (worker) -> take the queue -> render the view -> log the
//!       messages as `user` -> fresh call (worker) -> post the reply
//! ```
//!
//! Delivery between tool calls depends on the engine. The native engine
//! (`Engine::Native`, the host's own Messages API loop) asks the brain for
//! queued messages at every tool boundary, so MASTER's "messages the user
//! sends while you work reach you between tool calls" holds. The acpmux
//! engine cannot: claude-sr reports no steering. There a human message
//! stops the running turn (`session/cancel`; its steps are already in the
//! log) and the next fresh turn takes the message with the view of
//! everything the stopped turn did. A turn that hangs is stopped by
//! `Settings::turn_limit`.

mod children;
mod inbox;
mod outbox;
mod recover;
mod turns;

use std::collections::{HashMap, HashSet, VecDeque};
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::mpsc::{Receiver, RecvTimeoutError, Sender};
use std::time::{Duration, Instant};

use cmux_chief::acp::SessionSummary;
use cmux_conversation::{Op, Part, Summary};
use optchat_host::OptChat;

use crate::acpmux::{AgentEvent, AgentPort};
use crate::daemon::{ConversationPort, DaemonEvent};
use crate::state::{HostState, OutboxEntry, StateFile};
use crate::turn::{TurnOutcome, TurnStart};

/// Everything the brain reacts to.
pub enum Input {
    Daemon(Box<DaemonEvent>),
    Agents(Box<AgentEvent>),
    /// A turn worker settled the view and asks for its turn (None: nothing to do).
    Settled(Sender<Option<TurnStart>>),
    /// A turn worker could not settle (shutdown or a failed write).
    SettleFailed,
    /// A turn worker has waited for the compactor for a while and a node keeps
    /// failing: what to tell the conversation (once per wait).
    Stalled(String),
    /// An acpmux turn's session and how far its events are folded.
    TurnProgress {
        key: String,
        session_id: String,
        after: u64,
    },
    /// A native turn is between tool calls: the brain logs what is queued
    /// and answers with the texts to deliver (section 7).
    Boundary {
        key: String,
        reply: Sender<Vec<String>>,
    },
    TurnEnded {
        key: String,
        outcome: TurnOutcome,
    },
    /// Something the user must hear once (the compactor cannot build a
    /// node): posted in the Chief conversation, with `key` as its
    /// idempotency key, as soon as the conversation is known.
    Notice {
        key: String,
        text: String,
    },
}

impl From<DaemonEvent> for Input {
    fn from(event: DaemonEvent) -> Input {
        Input::Daemon(Box::new(event))
    }
}

impl From<AgentEvent> for Input {
    fn from(event: AgentEvent) -> Input {
        Input::Agents(Box::new(event))
    }
}

/// What runs a turn.
#[derive(Clone)]
pub enum Engine {
    /// A fresh acpmux session per turn (claude-sr, codex, ...).
    Acpmux,
    /// The host's own Messages API loop (sections 7 and 8 in full).
    Native(Arc<crate::native::Native>),
}

impl std::fmt::Debug for Engine {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Engine::Acpmux => f.write_str("Acpmux"),
            Engine::Native(_) => f.write_str("Native"),
        }
    }
}

/// How turns run.
#[derive(Clone, Debug)]
pub struct Settings {
    /// The constant working directory of every turn session.
    pub session_dir: PathBuf,
    /// `MUX_HARNESS` (default claude-sr).
    pub harness: String,
    /// `MUX_POLICY` (default approve-all).
    pub policy: String,
    pub model: Option<String>,
    /// The value of the `mux.parent` tag on the Chief's children.
    pub parent: String,
    /// Turn session names are `<turn_prefix>-<first id>`; `optchat-<home id>`,
    /// so two homes on one acpmux daemon never remove each other's turns.
    pub turn_prefix: String,
    /// The owner's agent gap plus a margin (mux/host: 2.2 s).
    pub agent_gap: Duration,
    /// Longest a turn may run (None: no limit).
    pub turn_limit: Option<Duration>,
    pub engine: Engine,
}

/// How long a turn waits for the compactor before it tells the conversation
/// which node keeps failing (section 6 expects seconds).
const STALL_NOTICE: Duration = Duration::from_secs(60);

/// The start of the `mux.parent` value on sessions this Chief started;
/// mux/host uses `mux`, so the two never claim each other's children.
pub const PARENT: &str = "optchat-chief";

/// The `mux.parent` value of the Chief of `home`: two homes sharing one
/// acpmux daemon (tagged builds) never claim each other's children.
pub fn parent_tag(home: &std::path::Path) -> String {
    format!("{PARENT}:{}", crate::paths::home_id(home))
}

/// Longest reply text posted (the owner refuses more than 64 KiB per message).
const REPLY_BYTES: usize = 60_000;

/// One queued new message.
#[derive(Clone, Debug, PartialEq, Eq)]
struct Queued {
    text: String,
    source: Source,
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum Source {
    /// A human message of the Chief conversation.
    Message { seq: u64 },
    /// A child's report; its record turns `Reported` with this floor when logged.
    Child { session_id: String, floor: u64 },
    /// Anything else (a child's permission request).
    Note,
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum Phase {
    Idle,
    /// A worker waits for the view to settle.
    Settling,
    Running,
}

pub type Log = Arc<dyn Fn(&str) + Send + Sync>;

/// Runs after every turn with its key (persist and back up, section 10).
pub type TurnHook = Arc<dyn Fn(&str) + Send + Sync>;

pub struct Brain {
    chat: Arc<OptChat>,
    agents: Arc<dyn AgentPort>,
    settings: Settings,
    file: StateFile,
    state: HostState,
    tx: Sender<Input>,
    log: Log,
    daemon: Option<Box<dyn ConversationPort>>,
    reconnect: Option<Box<dyn Fn() + Send>>,
    summary: Option<Summary>,
    /// Ids of the Chief's own messages (the wake rule's reply-to check).
    mux_messages: HashSet<String>,
    /// Highest conversation seq handled (queued or skipped).
    handled: u64,
    queue: VecDeque<Queued>,
    phase: Phase,
    agents_up: bool,
    sessions: HashMap<String, SessionSummary>,
    /// Turn sessions left by a host that stopped mid-turn before it knew
    /// their id, removed by name once acpmux is up.
    stale_sessions: Vec<String>,
    outbox_timer: Option<Instant>,
    fatal: Option<String>,
    /// A human message arrived while an acpmux turn ran: that turn is
    /// being stopped, and its end posts nothing.
    stop_wanted: bool,
    /// The running turn's interrupt (a new one per turn).
    interrupt: Arc<crate::turn::Interrupt>,
    after_turn: Option<TurnHook>,
    /// Notices waiting for the conversation to be known.
    notices: Vec<(String, String)>,
    /// Notice keys already handled (each is posted once per process).
    noticed: HashSet<String>,
}

impl Brain {
    pub fn new(
        chat: Arc<OptChat>,
        agents: Arc<dyn AgentPort>,
        settings: Settings,
        file: StateFile,
        tx: Sender<Input>,
        log: Log,
    ) -> Brain {
        let mut state = file.load();
        let acpmux = matches!(settings.engine, Engine::Acpmux);
        let mut stale_sessions = recover::recover(&chat, &mut state, acpmux);
        // Only this home's turn sessions: a name without its prefix is a
        // host before audit round 3's or another home's, never removed.
        let own = format!("{}-", settings.turn_prefix);
        stale_sessions.retain(|name| name.starts_with(&own));
        let handled = state.logged_seq;
        let brain = Brain {
            chat,
            agents,
            settings,
            file,
            state,
            tx,
            log,
            daemon: None,
            reconnect: None,
            summary: None,
            mux_messages: HashSet::new(),
            handled,
            queue: VecDeque::new(),
            phase: Phase::Idle,
            agents_up: false,
            sessions: HashMap::new(),
            stale_sessions,
            outbox_timer: None,
            fatal: None,
            stop_wanted: false,
            interrupt: Arc::new(crate::turn::Interrupt::new()),
            after_turn: None,
            notices: Vec::new(),
            noticed: HashSet::new(),
        };
        brain.save();
        brain
    }

    /// Runs `hook` after every turn (the host snapshots the memory there).
    pub fn on_turn_end(mut self, hook: TurnHook) -> Brain {
        self.after_turn = Some(hook);
        self
    }

    /// acpmux sessions the brain keeps a summary of (its children only).
    pub fn known_sessions(&self) -> usize {
        self.sessions.len()
    }

    pub fn state(&self) -> &HostState {
        &self.state
    }

    /// Why the host must stop, once it must.
    pub fn fatal(&self) -> Option<&str> {
        self.fatal.as_deref()
    }

    pub fn is_idle(&self) -> bool {
        self.phase == Phase::Idle && self.queue.is_empty()
    }

    /// When the outbox timer fires, if armed.
    pub fn next_timer(&self) -> Option<Instant> {
        self.outbox_timer
    }

    /// Runs until a fatal error; returns it.
    pub fn run(mut self, rx: Receiver<Input>) -> String {
        loop {
            if let Some(fatal) = &self.fatal {
                return fatal.clone();
            }
            let input = match self.outbox_timer {
                Some(at) => match rx.recv_timeout(at.saturating_duration_since(Instant::now())) {
                    Ok(input) => input,
                    Err(RecvTimeoutError::Timeout) => {
                        self.on_timer();
                        continue;
                    }
                    Err(RecvTimeoutError::Disconnected) => return "input channel closed".into(),
                },
                None => match rx.recv() {
                    Ok(input) => input,
                    Err(_) => return "input channel closed".into(),
                },
            };
            self.step(input);
        }
    }

    pub fn step(&mut self, input: Input) {
        match input {
            Input::Daemon(event) => self.on_daemon(*event),
            Input::Agents(event) => self.on_agents(*event),
            Input::Settled(reply) => {
                let start = self.settled();
                let _ = reply.send(start);
            }
            Input::SettleFailed => {
                self.phase = Phase::Idle;
                let status = self.chat.status();
                if let Some(fatal) = status.fatal {
                    self.fatal = Some(format!("the memory stopped writing: {fatal}"));
                }
            }
            Input::Stalled(text) => self.stalled(&text),
            Input::TurnProgress {
                key,
                session_id,
                after,
            } => self.progress(&key, session_id, after),
            Input::Boundary { key, reply } => {
                let texts = self.boundary(&key);
                let _ = reply.send(texts);
            }
            Input::TurnEnded { key, outcome } => self.turn_ended(&key, outcome),
            Input::Notice { key, text } => self.notice(key, text),
        }
    }

    /// Whether a turn can start now: the memory writes, and the engine's
    /// owner is connected (the native engine needs no acpmux).
    fn ready(&self) -> bool {
        self.fatal.is_none()
            && (self.agents_up || matches!(self.settings.engine, Engine::Native(_)))
    }

    /// Tells the conversation, once per wait, that its message waits on a
    /// failing compactor node (section 6 expects the wait to take seconds).
    fn stalled(&mut self, text: &str) {
        if self.phase != Phase::Settling {
            return;
        }
        let Some(conversation) = self.state.conversation.clone() else {
            return;
        };
        (self.log)(text);
        let key = format!(
            "stall:optchat:{}:{}",
            self.handled,
            self.chat.status().messages
        );
        self.state
            .outbox
            .push(reply_entry(conversation, &key, text));
        self.save();
        self.flush_outbox();
    }

    /// Posts a notice once, now or as soon as the conversation is known.
    fn notice(&mut self, key: String, text: String) {
        if !self.noticed.insert(key.clone()) {
            return;
        }
        (self.log)(&text);
        self.notices.push((key, text));
        self.post_notices();
    }

    /// Moves waiting notices into the outbox once the conversation is known.
    pub(super) fn post_notices(&mut self) {
        let Some(conversation) = self.state.conversation.clone() else {
            return;
        };
        if self.notices.is_empty() {
            return;
        }
        for (key, text) in std::mem::take(&mut self.notices) {
            self.state
                .outbox
                .push(reply_entry(conversation.clone(), &key, &text));
        }
        self.save();
        self.flush_outbox();
    }

    pub fn on_timer(&mut self) {
        self.outbox_timer = None;
        self.flush_outbox();
    }

    fn save(&self) {
        if let Err(e) = self.file.save(&self.state) {
            (self.log)(&format!("saving the host state failed: {e}"));
        }
    }

    fn queue(&mut self, text: String, source: Source) {
        let human = matches!(source, Source::Message { .. });
        self.queue.push_back(Queued { text, source });
        if human {
            self.interrupt_for_newer();
        }
        self.maybe_start_turn();
    }
}

/// A turn's reply key: `turn:optchat:<first new message id>:<its stamp>`.
/// Ids start again at 0 after a memory reset or a restored backup, while the
/// owner keeps every key it saw, so the id alone would collide (and the
/// owner would refuse or silently replay the reply). The millisecond stamp
/// of message `first` tells the two apart.
fn reply_key(chat: &OptChat, first: u64) -> String {
    let stamp: String = chat
        .stamp(first)
        .unwrap_or_default()
        .chars()
        .filter(char::is_ascii_digit)
        .collect();
    format!("turn:optchat:{first}:{stamp}")
}

/// A turn reply: `message.send` whose client_msg_id is the turn key, so a
/// retry never posts twice.
fn reply_entry(conversation: String, key: &str, text: &str) -> OutboxEntry {
    let text = if text.len() > REPLY_BYTES {
        let mut cut = REPLY_BYTES;
        while !text.is_char_boundary(cut) {
            cut -= 1;
        }
        format!(
            "{}\n\n[reply cut: {cut} of {} bytes shown]",
            &text[..cut],
            text.len()
        )
    } else {
        text.to_owned()
    };
    OutboxEntry {
        conversation,
        idempotency_key: key.to_owned(),
        op: Op::MessageSend {
            client_msg_id: key.to_owned(),
            parts: vec![Part::Text { text, runs: None }],
            reply_to: None,
        },
        rate_retried: false,
        not_before: None,
    }
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}
