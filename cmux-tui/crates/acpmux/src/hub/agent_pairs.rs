//! The runaway guard for agent-to-agent messages: two sessions that keep messaging each other
//! without progress, or that exchange too many messages with no input from the person, are
//! paused as a pair until the person resumes them.
//!
//! Every agent message reaches a session here, checked in `Hub::prompt_with` before the prompt
//! is recorded: a `session/prompt` whose provenance is `agent_message` (`prompt_provenance.rs`):
//! `cmux agent message` and every tool built on it, `agents_chat_send` included (the cmux
//! daemon's delivery pump); and a prompt one sub-session family member sends another
//! (`subsession_message`, `subsessions.rs`): cmux-subsessions `send_message` and
//! `start_session`'s first prompt; and a prompt a session sends another from inside itself
//! with no provenance of its own (`session_message`, `prompt_provenance.rs`: `acpmux send`); and
//! a lane's report of its turn to its parent (`lane_report`, `lane_reports.rs`).
//! All count toward the same pair. Only a sender that is a
//! session of this daemon counts: the person's `cmux agent message` (sender `cli`), a terminal,
//! or any other address passes untouched.
//!
//! A pair is the unordered pair of sender and receiver sessions. A message the receiver accepts
//! (queued or started) is an exchange; one refused before that is none. Progress resets the
//! pair: since the pair's last exchange, either session made a tool call that is not itself a
//! messaging call (a cmux-subsessions tool other than `start_session`, `agents_chat_send` or
//! `agents_chat_read`, or a shell command that is only `cmux agent message` or `cmux agent
//! inbox`), or wrote a file. Without progress the pair trips when either
//!
//! - `alternations` exchanges in a row go back and forth (default 10), or
//! - one sender sends the receiver `repeats` near-identical messages in a row (default 3): the
//!   same words once case, digits and punctuation are dropped, token Jaccard at least
//!   `similarity` (default 0.9).
//!
//! Progress or not, the pair also trips (`cap`) once it exchanges more than `max_messages`
//! messages within `window` (default 20 in 10 minutes) with no prompt from the person into either
//! session in between. `0` for either turns the cap off.
//!
//! The message that trips the pair, and every later one between the two, is held, not delivered
//! (at most [`MAX_HELD`] a pair; more are refused): the sender's `session/prompt` is refused
//! with `agent_pair.paused` (data `held: true`), whose text tells the agent the user resumes the
//! pair, so it stops retrying. Both transcripts record `agent_pair_paused`; the receiver's
//! records each `agent_pair_held`, with all the prompt needs to run and its pair-wide `order`, so
//! a restarted daemon rebuilds the pause, in arrival order, from both logs (`queue.rs`
//! `restore_queue`): every held message that never reached the receiver and no release settled. Both chats are marked unread and the daemon's `notify_command` fires.
//!
//! Only the person resumes: `_acpmux/agent_pair_resume` from a connection that proved the person
//! key (`hub/person.rs`), or a prompt such a connection sends into either session. Both record
//! `agent_pair_resumed` (`by: request | person`) and deliver the held messages in order, each
//! accepted (queued or started) before the next is sent; until the last is, a new message in the
//! pair waits behind them. Each accepted one is logged `agent_pair_released` in its receiver; a
//! restart mid-release goes on delivering the rest once the daemon starts (`resume_queues`), as
//! the pair's last `agent_pair_resumed` record says, rather than holding them again behind a
//! transcript that reads resumed. One that fails before acceptance stays held and
//! pauses the pair again (`release_failed`); failing a second time it is dropped
//! (`agent_pair_dropped`, in both logs).
//! A released message neither steers into nor interrupts the receiver's turn, whatever it was
//! sent with: it waits its turn. A cmux-subsessions `send_message` with `interrupt` stops the
//! receiver's turn only once the message is accepted, so a held one stops nothing
//! (`subsessions.rs`).
//!
//! The guard and its thresholds are read at daemon start (`PairGuard::from_env`); the app's
//! Debug Settings toggle `agent.pairGuard` turns it off (`ACPMUX_AGENT_PAIR_GUARD=0`), and
//! `agent.pairCap` / `agent.pairWindow` set the cap.

use super::*;
use std::collections::{BTreeSet, HashSet, VecDeque};

#[path = "agent_pair_progress.rs"]
mod progress;
pub(super) use progress::progress_record;

/// `0` turns the guard off.
pub const GUARD_ENV: &str = "ACPMUX_AGENT_PAIR_GUARD";
/// Exchanges back and forth without progress that pause a pair.
pub const ALTERNATIONS_ENV: &str = "ACPMUX_AGENT_PAIR_ALTERNATIONS";
/// Near-identical messages in a row from one sender that pause a pair.
pub const REPEATS_ENV: &str = "ACPMUX_AGENT_PAIR_REPEATS";
/// How alike two messages must be to count as the same, in percent.
pub const SIMILARITY_ENV: &str = "ACPMUX_AGENT_PAIR_SIMILARITY";
/// Messages a pair may exchange within the window with no input from the person; `0`: no cap.
pub const MAX_MESSAGES_ENV: &str = "ACPMUX_AGENT_PAIR_MAX_MESSAGES";
/// The cap's window, in seconds; `0`: no cap.
pub const WINDOW_ENV: &str = "ACPMUX_AGENT_PAIR_WINDOW_SECS";

/// The refusal reason of a held message.
pub const PAUSED_REASON: &str = "agent_pair.paused";
/// The refusal reason of a message a paused pair has no room to hold.
pub const FULL_REASON: &str = "agent_pair.held_full";
/// The refusal reason of a resume that is not the person's.
pub const RESUME_REFUSED: &str = "agent_pair.resume_refused";
/// Messages one paused pair holds.
pub const MAX_HELD: usize = 50;

/// The person's own sender address on the cmux daemon (`agent_message_store.rs` `CLI_SENDER`).
const PERSON_SENDER: &str = "cli";

/// Releases of one held message that may fail before it is dropped.
const RELEASE_TRIES: u32 = 2;

/// The guard's settings.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PairGuard {
    pub enabled: bool,
    pub alternations: u32,
    pub repeats: u32,
    /// 0.0 to 1.0.
    pub similarity: f64,
    /// Messages the pair may exchange within `window` with no prompt from the person; `0`: no cap.
    pub max_messages: u32,
    /// The cap's window; zero: no cap.
    pub window: std::time::Duration,
}

impl Default for PairGuard {
    fn default() -> Self {
        Self {
            enabled: true,
            alternations: 10,
            repeats: 3,
            similarity: 0.9,
            max_messages: 20,
            window: std::time::Duration::from_secs(600),
        }
    }
}

impl PairGuard {
    fn capped(&self) -> bool {
        self.max_messages > 0 && !self.window.is_zero()
    }
}

impl PairGuard {
    /// The settings `var` names (the process environment at daemon start): unset or unreadable
    /// values keep their defaults; a loop threshold under 2 does too (one message is no loop).
    /// The cap and its window take any number, `0` turning the cap off.
    pub fn from_env(var: impl Fn(&str) -> Option<String>) -> Self {
        let d = Self::default();
        let count = |key: &str, default: u32| {
            var(key)
                .and_then(|v| v.trim().parse::<u32>().ok())
                .filter(|n| *n >= 2)
                .unwrap_or(default)
        };
        let similarity = var(SIMILARITY_ENV)
            .and_then(|v| v.trim().parse::<u32>().ok())
            .filter(|p| (1..=100).contains(p))
            .map_or(d.similarity, |p| f64::from(p) / 100.0);
        let number = |key: &str| var(key).and_then(|v| v.trim().parse::<u64>().ok());
        Self {
            enabled: var(GUARD_ENV).is_none_or(|v| v.trim() != "0"),
            alternations: count(ALTERNATIONS_ENV, d.alternations),
            repeats: count(REPEATS_ENV, d.repeats),
            similarity,
            max_messages: number(MAX_MESSAGES_ENV)
                .map_or(d.max_messages, |n| u32::try_from(n).unwrap_or(u32::MAX)),
            window: number(WINDOW_ENV).map_or(d.window, std::time::Duration::from_secs),
        }
    }
}

/// Every pair the daemon has seen messages between.
#[derive(Default)]
pub(crate) struct AgentPairs {
    guard: StdMutex<PairGuard>,
    state: StdMutex<PairsState>,
    /// The last held message's pair-wide order (Unix microseconds, made unique): restored
    /// pauses merge both receivers' held messages by it.
    order: AtomicU64,
}

type PairKey = (String, String);

#[derive(Default)]
struct PairsState {
    pairs: HashMap<PairKey, Pair>,
    /// Prompt ids of held messages a resume is delivering: they pass once.
    releasing: HashSet<String>,
    /// Pairs a restart found resumed with messages still to deliver: `resume_queues` delivers
    /// them (`Hub::resume_agent_pair_drains`).
    restored_drains: Vec<PairKey>,
    /// By chat, the peers its log names in pair records (a pause is written to both chats'
    /// logs): a restart that reads the logs lazily reads theirs before it resumes or drains a
    /// pair of that chat (`log_load.rs`). Emptied once every log is read.
    peers: HashMap<String, HashSet<String>>,
}

#[derive(Default)]
struct Pair {
    /// Exchanges in a row that went back and forth with no progress, the last one included.
    alternating: u32,
    last: Option<Exchange>,
    /// By sender: near-identical messages in a row to the other, and the last one's words.
    repeats: HashMap<String, (u32, BTreeSet<String>)>,
    /// When each exchange since the person last prompted either session was accepted, within
    /// the cap's window.
    recent: VecDeque<std::time::Instant>,
    paused: Option<Paused>,
}

#[derive(Clone)]
struct Exchange {
    from: String,
    to: String,
    /// Each session's last log sequence when it was accepted: progress is looked for after them.
    from_mark: u64,
    to_mark: u64,
}

struct Paused {
    held: VecDeque<Held>,
    /// A resume is delivering `held`: new messages queue behind it.
    draining: bool,
}

/// A message a paused pair holds, with what `prompt_with` needs to deliver it later. Its
/// `agent_pair_held` record carries all of it ([`Held::record`], [`Held::from_record`]).
#[derive(Clone)]
struct Held {
    from: String,
    to: String,
    blocks: Vec<Value>,
    client: String,
    steer: bool,
    steer_only: bool,
    interrupt: bool,
    prompt_id: String,
    provenance: Value,
    control: Control,
    trust_gate: bool,
    /// Its place among the pair's held messages, both ways (`AgentPairs::order`).
    order: u64,
    /// Releases that failed before the receiver accepted it.
    failures: u32,
}

impl Held {
    fn record(&self, from_name: &str) -> Value {
        let text = prompt_text(&self.blocks);
        json!({
            "from": self.from, "fromName": from_name, "to": self.to, "promptId": self.prompt_id,
            "text": short_text(message_body(&text), 200), "provenance": self.provenance,
            "prompt": self.blocks, "client": self.client, "steer": self.steer,
            "steerOnly": self.steer_only, "interrupt": self.interrupt,
            "control": self.control.as_str(), "trustGate": self.trust_gate, "order": self.order,
        })
    }

    fn from_record(to: &str, msg: &Value) -> Option<Self> {
        let s = |k: &str| msg.get(k).and_then(Value::as_str).map(str::to_owned);
        let b = |k: &str| msg.get(k).and_then(Value::as_bool).unwrap_or(false);
        Some(Self {
            from: s("from")?,
            to: to.to_owned(),
            blocks: msg.get("prompt").and_then(Value::as_array)?.clone(),
            client: s("client").unwrap_or_else(|| "acpmux".to_owned()),
            steer: b("steer"),
            steer_only: b("steerOnly"),
            interrupt: b("interrupt"),
            prompt_id: s("promptId")?,
            provenance: msg.get("provenance").filter(|p| p.is_object())?.clone(),
            control: Control::from_recorded(msg.get("control").and_then(Value::as_str)),
            trust_gate: b("trustGate"),
            order: msg.get("order").and_then(Value::as_u64).unwrap_or(0),
            failures: 0,
        })
    }
}

/// Why a pair tripped.
#[derive(Clone, Copy)]
enum Trip {
    Alternating(u32),
    Repeating(u32),
    /// More than the cap within its window.
    Capped(u32),
}

impl Trip {
    fn reason(self) -> &'static str {
        match self {
            Trip::Alternating(_) => "alternating",
            Trip::Repeating(_) => "repeating",
            Trip::Capped(_) => "cap",
        }
    }

    fn count(self) -> u32 {
        match self {
            Trip::Alternating(n) | Trip::Repeating(n) | Trip::Capped(n) => n,
        }
    }
}

/// What holding a message found.
enum Hold {
    /// It tripped the pair.
    Tripped(Trip),
    /// The pair was paused already.
    Paused,
    /// A resume is delivering what the pair held; this one follows.
    Draining,
}

/// An accepted message's exchange, counted once the receiver records it.
struct Pending {
    key: PairKey,
    from: Arc<Session>,
    to: Arc<Session>,
    alternating: u32,
    repeats: u32,
    said: BTreeSet<String>,
    progressed: bool,
}

fn pair_key(a: &str, b: &str) -> PairKey {
    if a <= b { (a.to_owned(), b.to_owned()) } else { (b.to_owned(), a.to_owned()) }
}

/// The message itself: the body of a cmux-rendered message (between its `---` lines), else all
/// of the prompt's text.
pub(super) fn message_body(text: &str) -> &str {
    if !text.starts_with("[cmux agent message") {
        return text;
    }
    let Some(start) = text.find("\n---\n").map(|i| i + 5) else { return text };
    let end = text.rfind("\n--- end of message").filter(|e| *e >= start).unwrap_or(text.len());
    &text[start..end]
}

/// The message's words: lowercase, without digits or punctuation.
pub(super) fn words(text: &str) -> BTreeSet<String> {
    text.split(|c: char| !c.is_alphabetic())
        .filter(|w| !w.is_empty())
        .map(str::to_lowercase)
        .collect()
}

/// Token Jaccard similarity; two empty messages are the same.
pub(super) fn similarity(a: &BTreeSet<String>, b: &BTreeSet<String>) -> f64 {
    let union = a.union(b).count();
    if union == 0 {
        return 1.0;
    }
    a.intersection(b).count() as f64 / union as f64
}

/// What a receiver's log shows its pairs still owe it.
#[derive(Default)]
struct Owed {
    /// In the order they were held.
    held: Vec<Held>,
    /// The peers whose pair's last `agent_pair_paused` or `agent_pair_resumed` record here is a
    /// resume: a resume was delivering what they held when the daemon stopped.
    resumed: HashSet<String>,
}

/// The messages a receiver's log shows held and still owed, in the order they were held: an
/// `agent_pair_held` whose prompt id never reached the session (`recorded`) and that no
/// `agent_pair_released` or `agent_pair_dropped` settled. A resend of a message held already
/// keeps its first place.
fn still_held(session: &str, records: Vec<EventRecord>, recorded: &HashSet<String>) -> Owed {
    let mut owed = Owed::default();
    let held = &mut owed.held;
    for rec in records {
        let peer = rec.msg.get("peer").and_then(Value::as_str).map(str::to_owned);
        match rec.kind.as_str() {
            "agent_pair_paused" => {
                owed.resumed.remove(&peer.unwrap_or_default());
            }
            "agent_pair_resumed" => {
                owed.resumed.extend(peer);
            }
            "agent_pair_held" => {
                if let Some(h) = Held::from_record(session, &rec.msg)
                    && !recorded.contains(&h.prompt_id)
                    && !held.iter().any(|x| x.prompt_id == h.prompt_id)
                {
                    held.push(h);
                }
            }
            "agent_pair_released" | "agent_pair_dropped" => {
                if let Some(id) = rec.msg.get("promptId").and_then(Value::as_str) {
                    held.retain(|h| h.prompt_id != id);
                }
            }
            _ => {}
        }
    }
    owed
}

impl Hub {
    /// The guard's settings from now on (the daemon sets them from its environment at start).
    pub fn set_agent_pair_guard(&self, guard: PairGuard) {
        *self.agent_pairs.guard.lock().unwrap_or_else(|e| e.into_inner()) = guard;
    }

    fn agent_pair_guard(&self) -> PairGuard {
        *self.agent_pairs.guard.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn pairs_state(&self) -> std::sync::MutexGuard<'_, PairsState> {
        self.agent_pairs.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// The sending session of an agent message (`agent_message`), of a prompt a session sent from
    /// inside itself (`session_message`, `acpmux send`), or of a cmux-subsessions
    /// `send_message` or `start_session` (`subsession_message`): a session of this daemon, by
    /// its exact id (the cmux daemon writes it `acp:<id>`). `None` for any other prompt, for a
    /// sender that is no session here (the person's `cli`, a terminal, another actor), and for
    /// acpmux's own withdraw notices.
    fn agent_message_sender(&self, provenance: Option<&Value>) -> Option<Arc<Session>> {
        let p = provenance?;
        let kind = p.get("kind").and_then(Value::as_str);
        if !matches!(
            kind,
            Some(
                "agent_message"
                    | "session_message"
                    | super::subsessions::PROVENANCE_KIND
                    | super::lane_reports::KIND
            )
        ) {
            return None;
        }
        if p.get("msgId").and_then(Value::as_str).is_some_and(|id| id.ends_with(".withdrawn")) {
            return None;
        }
        let from = p.get("from").and_then(Value::as_str)?;
        let from = from.strip_prefix("acp:").unwrap_or(from);
        if from == PERSON_SENDER {
            return None;
        }
        self.resolve(from).ok().filter(|s| s.id == from)
    }

    /// Whether `session` did work after log sequence `mark`: its last progress record
    /// (`Session::last_progress`, kept as records are appended) came after it.
    fn progressed_since(&self, session: &str, mark: u64) -> bool {
        self.resolve(session).is_ok_and(|s| s.last_progress.load(Ordering::SeqCst) > mark)
    }

    /// A pair-wide order for a held message: Unix microseconds, after every earlier one.
    fn next_held_order(&self) -> u64 {
        let now = u64::try_from(
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_micros(),
        )
        .unwrap_or(u64::MAX);
        let order = &self.agent_pairs.order;
        let mut last = order.load(Ordering::SeqCst);
        loop {
            let next = now.max(last + 1);
            match order.compare_exchange(last, next, Ordering::SeqCst, Ordering::SeqCst) {
                Ok(_) => return next,
                Err(seen) => last = seen,
            }
        }
    }

    /// The guard for one prompt into `session`: Ok to deliver it (its exchange counts once the
    /// session accepts it), else the refusal of a held message (kept for the resume).
    pub(super) fn agent_pair_check(
        self: &Arc<Self>,
        session: &Arc<Session>,
        blocks: &[Value],
        client: &str,
        steer: bool,
        opts: &mut PromptOptions,
    ) -> Result<(), RpcError> {
        let guard = self.agent_pair_guard();
        if !guard.enabled {
            return Ok(());
        }
        let Some(sender) = self.agent_message_sender(opts.provenance.as_ref()) else {
            return Ok(());
        };
        let (from, to) = (sender.id.clone(), session.id.clone());
        if from == to {
            return Ok(());
        }
        if let Some(id) = &opts.prompt_id
            && self.pairs_state().releasing.remove(id)
        {
            return Ok(());
        }
        // A steer-only message the receiver cannot take now is refused unrecorded by
        // `run_prompt` (`steer.unavailable`): it is no exchange, and never pauses. Into a paused
        // pair it is held all the same, so a turn starting meanwhile cannot let it steer in.
        let can_steer = session.steering.load(Ordering::SeqCst) && session.turn().is_some();
        let paused = |hub: &Self| {
            hub.pairs_state().pairs.get(&pair_key(&from, &to)).is_some_and(|p| p.paused.is_some())
        };
        if steer && opts.steer_only && !can_steer && !paused(self) {
            return Ok(());
        }
        let prompt_id =
            opts.prompt_id.get_or_insert_with(|| uuid::Uuid::now_v7().to_string()).clone();
        let text = prompt_text(blocks);
        let said = words(message_body(&text));
        let key = pair_key(&from, &to);
        let last = self.pairs_state().pairs.get(&key).and_then(|p| p.last.clone());
        // Work in either session since the last exchange.
        let progressed = last.as_ref().is_some_and(|l| {
            self.progressed_since(&l.to, l.to_mark) || self.progressed_since(&l.from, l.from_mark)
        });
        let mut held = Held {
            from: from.clone(),
            to: to.clone(),
            blocks: blocks.to_vec(),
            client: client.to_owned(),
            steer,
            steer_only: opts.steer_only,
            interrupt: opts.interrupt,
            prompt_id: prompt_id.clone(),
            provenance: opts.provenance.clone().unwrap_or(Value::Null),
            control: opts.control,
            trust_gate: opts.trust_gate,
            order: 0,
            failures: 0,
        };
        let now = std::time::Instant::now();
        // A resend of a message held already: its answer says so (`resent`), so the sender's
        // attachments of this copy go (`attach::Saved`).
        let mut resent = false;
        let hold = {
            let mut state = self.pairs_state();
            // Under the lock, so the order held here is the order a restart restores.
            held.order = self.next_held_order();
            let pair = state.pairs.entry(key.clone()).or_default();
            if let Some(paused) = pair.paused.as_mut() {
                if paused.held.iter().any(|h| h.prompt_id == prompt_id) {
                    resent = true;
                } else if paused.held.len() >= MAX_HELD {
                    return Err(RpcError::new(
                        -32000,
                        format!(
                            "{FULL_REASON}: this message to session {to} was NOT delivered and is \
                             not held: the paused pair already holds {MAX_HELD} messages. Stop \
                             messaging {to}; tell the user what you need."
                        ),
                    )
                    .with_data(
                        json!({"reason": FULL_REASON, "held": false, "promptId": prompt_id,
                                      "sessions": [from, to], "limit": MAX_HELD}),
                    ));
                } else {
                    paused.held.push_back(held.clone());
                }
                if paused.draining { Hold::Draining } else { Hold::Paused }
            } else {
                let alternating = if progressed { 0 } else { pair.alternating };
                let back = pair.last.as_ref().is_some_and(|l| l.from == to && l.to == from);
                let alternating = if back { alternating + 1 } else { 1 };
                let repeats = match pair.repeats.get(&from) {
                    Some((n, before))
                        if !progressed && similarity(before, &said) >= guard.similarity =>
                    {
                        n + 1
                    }
                    _ => 1,
                };
                while pair.recent.front().is_some_and(|at| now.duration_since(*at) >= guard.window)
                {
                    pair.recent.pop_front();
                }
                let in_window = u32::try_from(pair.recent.len()).unwrap_or(u32::MAX) + 1;
                let trip = if alternating >= guard.alternations {
                    Some(Trip::Alternating(alternating))
                } else if repeats >= guard.repeats {
                    Some(Trip::Repeating(repeats))
                } else if guard.capped() && in_window > guard.max_messages {
                    Some(Trip::Capped(in_window))
                } else {
                    None
                };
                let Some(trip) = trip else {
                    drop(state);
                    let pending = Pending {
                        key,
                        from: sender,
                        to: session.clone(),
                        alternating,
                        repeats,
                        said,
                        progressed,
                    };
                    let hub = self.clone();
                    let next = opts.on_accepted.take();
                    opts.on_accepted = Some(Box::new(move |accepted: Value| {
                        if accepted.get("duplicate") != Some(&json!(true)) {
                            hub.count_exchange(pending);
                        }
                        if let Some(next) = next {
                            next(accepted);
                        }
                    }));
                    return Ok(());
                };
                pair.paused =
                    Some(Paused { held: VecDeque::from([held.clone()]), draining: false });
                Hold::Tripped(trip)
            }
        };
        let sender_name = sender.meta().name;
        if let Hold::Tripped(trip) = hold {
            let receiver_name = session.meta().name;
            let note = |peer: &str, peer_name: &str| {
                json!({"peer": peer, "peerName": peer_name, "reason": trip.reason(),
                       "count": trip.count(), "promptId": prompt_id,
                       "windowSecs": guard.window.as_secs(),
                       "resume": method::MUX_AGENT_PAIR_RESUME})
            };
            self.append(session, "mux", "agent_pair_paused", note(&from, &sender_name));
            self.mark_unread(session);
            self.append(&sender, "mux", "agent_pair_paused", note(&to, &receiver_name));
            self.mark_unread(&sender);
        }
        self.append(session, "mux", "agent_pair_held", held.record(&sender_name));
        const RESUMES: &str =
            "The user resumes the pair; held messages are then delivered in order.";
        let (why, then) = match hold {
            Hold::Tripped(Trip::Repeating(n)) => {
                (format!("it sent {n} near-identical messages in a row"), RESUMES)
            }
            Hold::Tripped(Trip::Alternating(n)) => (
                format!(
                    "the two sessions exchanged {n} messages with no tool call or file change \
                     in between"
                ),
                RESUMES,
            ),
            Hold::Tripped(Trip::Capped(n)) => (
                format!(
                    "the two sessions exchanged {n} messages within {} minutes with no input \
                     from the user",
                    guard.window.as_secs().div_ceil(60)
                ),
                RESUMES,
            ),
            Hold::Paused => ("the pair is paused".to_owned(), RESUMES),
            Hold::Draining => (
                "the user resumed the pair and its held messages are being delivered".to_owned(),
                "It is delivered after them, in order.",
            ),
        };
        let message = format!(
            "{PAUSED_REASON}: this message to session {to} is held, not delivered yet: cmux \
             paused this session and {to} because {why}. {then} Do not send it again; tell the \
             user what you need."
        );
        let trip = match hold {
            Hold::Tripped(trip) => Some(trip.reason()),
            _ => None,
        };
        Err(RpcError::new(-32000, message).with_data(json!({
            "reason": PAUSED_REASON,
            "held": true,
            "resent": resent,
            "promptId": prompt_id,
            "sessions": [from, to],
            "trip": trip,
        })))
    }

    /// `run_prompt` for a new prompt (`turns.rs` `prompt_with`, after a resend was answered from
    /// the ledger or the log): an agent message between a paused pair is held instead and never
    /// recorded, so `prompt_with` forgets its id, which may come again once the pair resumes.
    pub(super) async fn prompt_unless_held(
        self: &Arc<Self>,
        session: &Arc<Session>,
        blocks: Vec<Value>,
        client: &str,
        steer: bool,
        mut opts: PromptOptions,
    ) -> Result<Value, RpcError> {
        self.agent_pair_check(session, &blocks, client, steer, &mut opts)?;
        self.run_prompt(session, blocks, client, steer, opts).await
    }

    /// For a cmux-subsessions `send_message` with `interrupt` (`subsessions.rs`), called with the
    /// prompt's acceptance: one queued behind the turn `to` is running now stops that turn,
    /// unless it ended meanwhile. A message the guard holds is never accepted, so it stops nothing.
    pub(super) fn interrupt_once_queued(
        self: &Arc<Self>,
        to: &Arc<Session>,
        interrupt: bool,
    ) -> impl FnOnce(&Value) + Send + 'static {
        let running = if interrupt { to.turn().map(|t| t.turn_id) } else { None };
        let (hub, to) = (self.clone(), to.clone());
        move |accepted: &Value| {
            let Some(turn_id) = running.filter(|_| accepted.get("queued") == Some(&json!(true)))
            else {
                return;
            };
            tokio::spawn(async move {
                if to.turn().is_some_and(|t| t.turn_id == turn_id)
                    && let Err(e) = hub.cancel(&to).await
                {
                    tracing::warn!(session = %to.id, "interrupt: {}", e.message);
                }
            });
        }
    }

    /// Counts an exchange its receiver accepted.
    fn count_exchange(&self, p: Pending) {
        let mut state = self.pairs_state();
        let pair = state.pairs.entry(p.key).or_default();
        if pair.paused.is_some() {
            return;
        }
        if p.progressed {
            pair.repeats.clear();
        }
        pair.alternating = p.alternating;
        pair.repeats.insert(p.from.id.clone(), (p.repeats, p.said));
        pair.recent.push_back(std::time::Instant::now());
        pair.last = Some(Exchange {
            from: p.from.id.clone(),
            to: p.to.id.clone(),
            from_mark: p.from.seq.load(Ordering::SeqCst),
            to_mark: p.to.seq.load(Ordering::SeqCst),
        });
    }

    /// Rebuilds the pauses `session`'s log shows (`queue.rs` `restore_queue`, at load and for a
    /// chat moved here): messages held for it that never reached it (`recorded`: the prompt ids
    /// of its `queued` and `user_message` records) and no release accepted or dropped, merged
    /// with what the peer's log held by their pair-wide order. A pair a resume was delivering
    /// when the daemon stopped goes on draining once `resume_queues` runs: the person resumed it,
    /// and its transcript says so.
    pub(super) fn restore_agent_pairs(
        &self,
        session: &str,
        records: Vec<EventRecord>,
        recorded: &HashSet<String>,
    ) {
        if !self.logs_loaded() {
            let named = records.iter().filter_map(|r| {
                r.msg.get("peer").or_else(|| r.msg.get("from")).and_then(Value::as_str)
            });
            let mut state = self.pairs_state();
            let peers = state.peers.entry(session.to_owned()).or_default();
            peers.extend(named.map(str::to_owned));
            peers.remove(session);
        }
        let Owed { held, resumed } = still_held(session, records, recorded);
        if let Some(last) = held.iter().map(|h| h.order).max() {
            self.agent_pairs.order.fetch_max(last, Ordering::SeqCst);
        }
        let mut state = self.pairs_state();
        let mut drains = Vec::new();
        for h in held {
            let key = pair_key(&h.from, session);
            let drain = resumed.contains(&h.from);
            let pair = state.pairs.entry(key.clone()).or_default();
            let paused = pair
                .paused
                .get_or_insert_with(|| Paused { held: VecDeque::new(), draining: false });
            if !paused.held.iter().any(|x| x.prompt_id == h.prompt_id) {
                paused.held.push_back(h);
            }
            paused.held.make_contiguous().sort_by_key(|h| h.order);
            if drain && !paused.draining {
                paused.draining = true;
                drains.push(key);
            }
        }
        state.restored_drains.extend(drains);
    }

    /// Delivers what the pairs `restore_agent_pairs` found mid-resume still hold (`queue.rs`
    /// `resume_queues`, after the daemon's startup).
    pub(super) fn resume_agent_pair_drains(self: &Arc<Self>) {
        let keys = std::mem::take(&mut self.pairs_state().restored_drains);
        for key in keys {
            let hub = self.clone();
            tokio::spawn(async move {
                hub.wait_startup().await;
                hub.drain_pair(key).await;
            });
        }
    }

    /// After a restart, before the guard checks an agent's message: the sender's log too. A
    /// pause the restart keeps may be only there (what the pair held for the sender), and the
    /// receiver's log is read already (`turns.rs` `prompt_with`, `log_load.rs`).
    pub(super) async fn pair_logs(self: &Arc<Self>, provenance: Option<&Value>) {
        if self.logs_loaded() {
            return;
        }
        if let Some(sender) = self.agent_message_sender(provenance) {
            self.session_log(&sender).await;
        }
    }

    /// After a restart, before a pair of `session` is resumed: its log and its peers' logs, so
    /// every pause it is in is restored with what both sides held (immediate once every log is
    /// read).
    pub(crate) async fn pair_peer_logs(self: &Arc<Self>, session: &Arc<Session>) {
        self.session_log(session).await;
        if self.logs_loaded() {
            return;
        }
        let peers: Vec<String> =
            self.pairs_state().peers.get(&session.id).into_iter().flatten().cloned().collect();
        for peer in peers {
            if let Ok(s) = self.resolve(&peer) {
                self.session_log(&s).await;
            }
        }
    }

    /// The person prompted `session`: every pair it is in starts over, and a paused one is
    /// resumed.
    pub fn agent_pair_person_prompt(self: &Arc<Self>, session: &Session) {
        self.agent_pair_resume_inner(&session.id, None, "person");
    }

    /// Every chat log is read: no pair needs a peer's log read first (`log_load.rs`).
    pub(super) fn forget_pair_peers(&self) {
        self.pairs_state().peers.clear();
    }

    /// `_acpmux/agent_pair_resume {sessionId, peerSessionId?}`: resumes the paused pairs of
    /// `sessionId` (only the one with `peerSessionId` when given) and delivers what they held.
    pub fn agent_pair_resume(self: &Arc<Self>, session: &str, peer: Option<&str>) -> Value {
        let (resumed, delivered) = self.agent_pair_resume_inner(session, peer, "request");
        json!({"sessionId": session, "resumed": resumed, "delivered": delivered})
    }

    /// The refusal of a resume from a connection that is not the person.
    pub fn agent_pair_resume_refused() -> RpcError {
        RpcError::new(-32000, "only the person resumes a paused agent pair (`hub/person.rs`)")
            .with_data(json!({"reason": RESUME_REFUSED}))
    }

    /// Resumes and resets the pairs; how many were paused, and how many messages they held.
    fn agent_pair_resume_inner(
        self: &Arc<Self>,
        session: &str,
        peer: Option<&str>,
        by: &str,
    ) -> (usize, usize) {
        let mut resumed: Vec<(PairKey, usize)> = Vec::new();
        {
            let mut state = self.pairs_state();
            let mine = |(a, b): &PairKey| {
                let other = if a == session {
                    b
                } else if b == session {
                    a
                } else {
                    return false;
                };
                peer.is_none_or(|p| p == other)
            };
            // A pair not paused starts over; a paused one drains, then starts over.
            state.pairs.retain(|key, pair| !mine(key) || pair.paused.is_some());
            for (key, pair) in state.pairs.iter_mut().filter(|(key, _)| mine(key)) {
                if let Some(paused) = pair.paused.as_mut()
                    && !paused.draining
                {
                    paused.draining = true;
                    resumed.push((key.clone(), paused.held.len()));
                }
            }
        }
        let pairs = resumed.len();
        let mut delivered = 0;
        for ((a, b), held) in resumed {
            delivered += held;
            let note = |peer: &str| json!({"peer": peer, "by": by, "delivered": held});
            if let Ok(s) = self.resolve(&a) {
                self.append(&s, "mux", "agent_pair_resumed", note(&b));
            }
            if let Ok(s) = self.resolve(&b) {
                self.append(&s, "mux", "agent_pair_resumed", note(&a));
            }
            let hub = self.clone();
            tokio::spawn(async move { hub.drain_pair((a, b)).await });
        }
        (pairs, delivered)
    }

    /// Delivers what a resumed pair holds, oldest first; each stays held until its receiver
    /// accepts it (queued or started), however long that takes, and only then is the next sent.
    /// Messages held meanwhile follow. Once it is empty the pair starts over. A message that
    /// fails before acceptance stays held and pauses the pair again; one that fails
    /// [`RELEASE_TRIES`] times is dropped, in both logs.
    async fn drain_pair(self: Arc<Self>, key: PairKey) {
        // After a restart, both receivers' held messages, merged in the order they were held,
        // before the first is chosen: `log_load.rs` reads each log on its own.
        for id in [&key.0, &key.1] {
            if let Ok(s) = self.resolve(id) {
                self.session_log(&s).await;
            }
        }
        loop {
            let next = {
                let mut state = self.pairs_state();
                let next = state
                    .pairs
                    .get(&key)
                    .and_then(|p| p.paused.as_ref())
                    .and_then(|p| p.held.front().cloned());
                match &next {
                    Some(h) => {
                        state.releasing.insert(h.prompt_id.clone());
                    }
                    None => {
                        state.pairs.remove(&key);
                    }
                }
                next
            };
            let Some(h) = next else { return };
            let Ok(session) = self.resolve(&h.to) else {
                // Its receiver is gone: nothing can take it.
                self.pairs_state().releasing.remove(&h.prompt_id);
                self.settle_held(&key, &h.prompt_id);
                crate::attach::held_dropped(&h.to, &h.prompt_id);
                continue;
            };
            let (tx, mut rx) = mpsc::unbounded_channel::<Result<(), RpcError>>();
            let accepted = tx.clone();
            let took = Arc::new(std::sync::atomic::AtomicBool::new(false));
            let took_it = took.clone();
            // A held prompt's durable provenance carries the original outbox
            // delivery id. Releasing it must reuse that id so the receiver's
            // and sender's message projections remain one delivery after a
            // pause, restart, and retry.
            let mut opts = PromptOptions {
                prompt_id: Some(h.prompt_id.clone()),
                on_accepted: Some(Box::new(move |_| {
                    took_it.store(true, Ordering::SeqCst);
                    let _ = accepted.send(Ok(()));
                })),
                // A message a restart rebuilt may have run before: the log answers it.
                resend: true,
                control: h.control,
                trust_gate: h.trust_gate,
                // The moment to steer has passed: a released message waits its turn, and
                // stops nothing (the turn running now may be the person's own prompt).
                steer_only: false,
                interrupt: false,
                provenance: Some(h.provenance.clone()),
                ..PromptOptions::default()
            };
            // Held provenance is durable state, so restore the original delivery id and (for a
            // peer-origin message) its sender identity before retrying the prompt.
            super::message_events::restore_message_options(&mut opts, Some(&h.provenance));
            let hub = self.clone();
            let (blocks, client, steer) = (h.blocks.clone(), h.client.clone(), false);
            let target = session.clone();
            let prompt_id = h.prompt_id.clone();
            tokio::spawn(async move {
                let done = hub.prompt_with(&target, blocks, &client, steer, opts).await;
                let _ = tx.send(done.map(|_| ()));
                // Taken and answered: its files stay if it ran (`attach.rs`).
                if took.load(Ordering::SeqCst) {
                    crate::attach::held_released(&hub, &target.id, &prompt_id).await;
                }
            });
            // Both ends gone with no word (the delivery task died): not accepted.
            let outcome = rx
                .recv()
                .await
                .unwrap_or_else(|| Err(RpcError::internal("the release ended unanswered")));
            self.pairs_state().releasing.remove(&h.prompt_id);
            match outcome {
                Ok(()) => {
                    self.append(
                        &session,
                        "mux",
                        "agent_pair_released",
                        json!({"promptId": h.prompt_id, "peer": h.from}),
                    );
                    self.settle_held(&key, &h.prompt_id);
                }
                Err(e) if h.failures + 1 >= RELEASE_TRIES => {
                    tracing::warn!(session = %session.id, "held agent message dropped: {}", e.message);
                    let note = |peer: &str| json!({"promptId": h.prompt_id, "peer": peer, "error": e.message});
                    self.append(&session, "mux", "agent_pair_dropped", note(&h.from));
                    if let Ok(sender) = self.resolve(&h.from) {
                        self.append(&sender, "mux", "agent_pair_dropped", note(&h.to));
                    }
                    self.settle_held(&key, &h.prompt_id);
                    crate::attach::held_dropped(&h.to, &h.prompt_id);
                }
                Err(e) => {
                    tracing::warn!(session = %session.id, "held agent message not released: {}", e.message);
                    {
                        let mut state = self.pairs_state();
                        if let Some(paused) =
                            state.pairs.get_mut(&key).and_then(|p| p.paused.as_mut())
                        {
                            paused.draining = false;
                            if let Some(front) =
                                paused.held.iter_mut().find(|x| x.prompt_id == h.prompt_id)
                            {
                                front.failures += 1;
                            }
                        }
                    }
                    let note = |peer: &str, peer_name: &str| {
                        json!({"peer": peer, "peerName": peer_name, "reason": "release_failed",
                               "promptId": h.prompt_id, "error": e.message,
                               "resume": method::MUX_AGENT_PAIR_RESUME})
                    };
                    let sender = self.resolve(&h.from).ok();
                    let sender_name = sender.as_ref().map(|s| s.meta().name).unwrap_or_default();
                    self.append(&session, "mux", "agent_pair_paused", note(&h.from, &sender_name));
                    self.mark_unread(&session);
                    if let Some(sender) = sender {
                        let receiver_name = session.meta().name;
                        self.append(
                            &sender,
                            "mux",
                            "agent_pair_paused",
                            note(&h.to, &receiver_name),
                        );
                        self.mark_unread(&sender);
                    }
                    return;
                }
            }
        }
    }

    /// Takes a released (or dropped) message off its pair's held queue.
    fn settle_held(&self, key: &PairKey, prompt_id: &str) {
        let mut state = self.pairs_state();
        if let Some(paused) = state.pairs.get_mut(key).and_then(|p| p.paused.as_mut()) {
            paused.held.retain(|h| h.prompt_id != prompt_id);
        }
    }
}

#[cfg(test)]
#[path = "agent_pairs_tests.rs"]
mod tests;
