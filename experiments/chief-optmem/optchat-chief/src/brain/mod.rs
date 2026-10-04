//! The brain: one thread that owns the host state and turns inputs (daemon
//! events, acpmux events, turn workers' reports) into effects. It keeps the
//! queue of new messages and runs the turn loop of section 7:
//!
//! ```text
//! on message: queue.push(text); if idle: turn()
//! turn: settle (worker) -> take the queue -> render the view -> log the
//!       messages as `user` -> fresh session (worker) -> post the reply
//! ```
//!
//! Messages that arrive while a turn runs wait in the queue for the next
//! turn: acpmux can steer a running session only when its agent reports
//! steering support, and the Claude Code harness (claude-sr) reports none,
//! so "delivered between tool calls" (section 7) is not available here.
//! MASTER still says so, verbatim; the README lists this deviation. There is
//! no user cancel either (the brain-host contract has no cancel action); a
//! turn that hangs is stopped by `Settings::turn_limit`.

mod children;
mod inbox;
mod outbox;

use std::collections::{HashMap, HashSet, VecDeque};
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::mpsc::{Receiver, RecvTimeoutError, Sender, channel};
use std::time::{Duration, Instant};

use cmux_chief::acp::SessionSummary;
use cmux_conversation::{Op, Part, Summary};
use optchat_core::Kind;
use optchat_host::OptChat;

use crate::acpmux::{AgentEvent, AgentPort, SessionSpec};
use crate::daemon::{ConversationPort, DaemonEvent};
use crate::prompt::turn_blocks;
use crate::state::{ChildStatus, HostState, OutboxEntry, PendingTurn, StateFile};
use crate::turn::{self, TurnOutcome, TurnStart};

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
    TurnEnded {
        key: String,
        outcome: TurnOutcome,
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
    /// The owner's agent gap plus a margin (mux/host: 2.2 s).
    pub agent_gap: Duration,
    /// Longest a turn may run (None: no limit).
    pub turn_limit: Option<Duration>,
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
    /// Turn sessions left by a host that stopped mid-turn, removed once acpmux is up.
    stale_sessions: Vec<String>,
    outbox_timer: Option<Instant>,
    fatal: Option<String>,
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
        let mut stale_sessions = Vec::new();
        if let Some(turn) = state.turn.take() {
            // The host stopped during this turn. How many of its messages
            // reached the log: all of them once the key is set; while it was
            // still logging, the log's length tells (a crash between the
            // append and the save must not log a message twice).
            let logged = match turn.first_id {
                _ if !turn.key.is_empty() => turn.seqs.len().max(1),
                Some(first) => {
                    let n = chat.status().messages.saturating_sub(first) as usize;
                    n.min(turn.seqs.len())
                }
                None => turn.seqs.len().max(1),
            };
            if let Some(seq) = turn.seqs[..logged.min(turn.seqs.len())]
                .iter()
                .flatten()
                .max()
            {
                state.logged_seq = state.logged_seq.max(*seq);
            }
            let key = if !turn.key.is_empty() {
                Some(turn.key.clone())
            } else if logged > 0 {
                turn.first_id.map(|first| reply_key(&chat, first))
            } else {
                None
            };
            // Messages in the log stay there, unanswered (section 7); the
            // conversation hears why, once. Messages that never reached it
            // are caught up again from the cursor and answered normally.
            if let (Some(conversation), Some(key)) = (turn.conversation, key) {
                let text = "(interrupted: the Chief stopped during this turn. Your message is in its memory; send it again for an answer.)";
                state.outbox.push(reply_entry(conversation, &key, text));
            }
            stale_sessions.push(turn.session);
        }
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
        };
        brain.save();
        brain
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
                let start = self.take_turn();
                if start.is_none() && self.phase == Phase::Settling {
                    self.phase = Phase::Idle;
                }
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
            Input::TurnEnded { key, outcome } => self.turn_ended(&key, outcome),
        }
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
        self.queue.push_back(Queued { text, source });
        self.maybe_start_turn();
    }

    /// Starts a turn worker when idle with something queued.
    fn maybe_start_turn(&mut self) {
        if self.phase != Phase::Idle
            || self.queue.is_empty()
            || !self.agents_up
            || self.fatal.is_some()
        {
            return;
        }
        self.phase = Phase::Settling;
        let (chat, agents, tx, log) = (
            self.chat.clone(),
            self.agents.clone(),
            self.tx.clone(),
            self.log.clone(),
        );
        let spawned = std::thread::Builder::new()
            .name("turn".into())
            .spawn(move || {
                // Section 6: no turn starts before every view line is a summary.
                // The wait has no deadline; a line each minute says what it
                // waits on, and the first one with a failing node also goes to
                // the conversation, so the user is not left without a word.
                let mut told = false;
                while !chat.settle(None, Some(STALL_NOTICE)) {
                    let status = chat.status();
                    if status.closed || status.fatal.is_some() {
                        let _ = tx.send(Input::SettleFailed);
                        return;
                    }
                    let failing: Vec<String> = status
                        .failures
                        .iter()
                        .map(|f| format!("{}: {}", f.node.name(), f.error))
                        .collect();
                    log(&format!(
                        "turn waits for the compactor: {} view lines unbuilt; failing: {}",
                        status.unbuilt,
                        if failing.is_empty() {
                            "none".to_owned()
                        } else {
                            failing.join("; ")
                        }
                    ));
                    if !told && let Some(first) = status.failures.first() {
                        told = true;
                        let _ = tx.send(Input::Stalled(format!(
                            "(waiting: the Chief's memory cannot summarize line {} yet, so your message waits. First error: {}. It is retried every 10 s.)",
                            first.node.name(),
                            first.error
                        )));
                    }
                }
                let (reply, start) = channel();
                if tx.send(Input::Settled(reply)).is_err() {
                    return;
                }
                let Ok(Some(start)) = start.recv() else {
                    return;
                };
                let outcome = turn::run(&*agents, &chat, &start, &*log);
                let _ = tx.send(Input::TurnEnded {
                    key: start.key,
                    outcome,
                });
            });
        if let Err(e) = spawned {
            (self.log)(&format!("starting a turn failed: {e}"));
            self.phase = Phase::Idle;
        }
    }

    /// Section 7 after `settle`: take every queued message, render the view
    /// BEFORE logging them, then log each as `user`.
    fn take_turn(&mut self) -> Option<TurnStart> {
        if self.queue.is_empty() {
            return None;
        }
        let items: Vec<Queued> = self.queue.drain(..).collect();
        let view = self.chat.render_view();
        // Saved before the first append: a crash between an append and the
        // next save must not log a message twice at restart (Brain::new).
        let first_id = self.chat.status().messages;
        self.state.turn = Some(PendingTurn {
            key: String::new(),
            conversation: self.state.conversation.clone(),
            session: format!("optchat-{first_id}"),
            first_id: Some(first_id),
            seqs: items
                .iter()
                .map(|i| match i.source {
                    Source::Message { seq } => Some(seq),
                    _ => None,
                })
                .collect(),
        });
        self.save();
        let mut first = None;
        for item in &items {
            match self.chat.append(Kind::User, &item.text) {
                Ok(id) => {
                    first.get_or_insert(id);
                }
                Err(e) => {
                    // Nothing is posted for a turn whose messages could not be
                    // logged; the conversation's cursor stays before them.
                    (self.log)(&format!("logging a message failed: {e}"));
                    self.fatal = Some(format!("the memory stopped writing: {e}"));
                    self.phase = Phase::Idle;
                    return None;
                }
            }
        }
        let first = first.expect("a non-empty queue logs a message");
        for item in &items {
            if let Source::Child { session_id, floor } = &item.source
                && let Some(record) = self.state.children.get_mut(session_id)
            {
                record.status = ChildStatus::Reported;
                record.floor = *floor;
            }
        }
        // The queue is empty now, so every handled seq is logged or needed no log.
        self.state.logged_seq = self.handled;
        let key = reply_key(&self.chat, first);
        let name = format!("optchat-{first}");
        if let Some(turn) = self.state.turn.as_mut() {
            turn.key = key.clone();
            turn.session = name.clone();
        }
        self.save();
        self.set_cursor(self.handled);
        self.set_typing(true);
        self.phase = Phase::Running;
        let texts: Vec<String> = items.into_iter().map(|i| i.text).collect();
        Some(TurnStart {
            prompt_id: format!("optchat:{first}"),
            session: SessionSpec {
                name,
                cwd: self.settings.session_dir.clone(),
                harness: self.settings.harness.clone(),
                policy: self.settings.policy.clone(),
                model: self.settings.model.clone(),
            },
            blocks: turn_blocks(&view.text, &texts),
            key,
            limit: self.settings.turn_limit,
        })
    }

    fn turn_ended(&mut self, key: &str, outcome: TurnOutcome) {
        let conversation = self
            .state
            .turn
            .as_ref()
            .filter(|t| t.key == key)
            .and_then(|t| t.conversation.clone());
        // A turn that failed after it said something posts both: its last
        // words alone (often "Let me check.") would read as the answer.
        let text = match (outcome.reply, outcome.error) {
            (Some(reply), Some(error)) => format!("{reply}\n\n(turn failed: {error})"),
            (Some(reply), None) => reply,
            (None, Some(error)) => format!("(turn failed: {error})"),
            (None, None) => String::new(),
        };
        if let Some(orphan) = outcome.orphan {
            self.state.orphans.push(orphan);
        }
        match conversation {
            Some(conversation) if !text.is_empty() => {
                self.state
                    .outbox
                    .push(reply_entry(conversation, key, &text));
            }
            Some(_) => {}
            None => (self.log)(&format!(
                "turn {key} ended with no conversation to answer in"
            )),
        }
        self.state.turn = None;
        self.save();
        self.flush_outbox();
        self.set_typing(false);
        self.phase = Phase::Idle;
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
