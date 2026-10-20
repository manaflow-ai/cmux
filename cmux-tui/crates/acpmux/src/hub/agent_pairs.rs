//! The runaway guard for agent-to-agent messages: two sessions that keep messaging each other
//! without progress are paused as a pair until the person resumes them. There is no cap on how
//! many messages a turn may send; only a loop is stopped.
//!
//! Every agent message reaches a session here, checked in `Hub::prompt_with` before the prompt
//! is recorded: a `session/prompt` whose provenance is `agent_message` (`prompt_provenance.rs`):
//! `cmux agent message` and every tool built on it, `agents_chat_send` included (the cmux
//! daemon's delivery pump); and a prompt one sub-session family member sends another
//! (`subsession_message`, `subsessions.rs`): cmux-subsessions `send_message` and
//! `start_session`'s first prompt. Both count toward the same pair. Only a sender that is a
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
//! The message that trips the pair, and every later one between the two, is held, not delivered
//! (at most [`MAX_HELD`] a pair; more are refused): the sender's `session/prompt` is refused
//! with `agent_pair.paused` (data `held: true`), whose text tells the agent the user resumes the
//! pair, so it stops retrying. Both transcripts record `agent_pair_paused`; the receiver's
//! records each `agent_pair_held`, with all the prompt needs to run, so a restarted daemon
//! rebuilds the pause from the log (`queue.rs` `restore_queue`): every held message that never
//! reached the receiver, including one a resume had not delivered yet when the daemon stopped.
//! Both chats are marked unread and the daemon's `notify_command` fires.
//!
//! Only the person resumes: `_acpmux/agent_pair_resume` from a connection that proved the person
//! key (`hub/person.rs`), or a prompt such a connection sends into either session. Both record
//! `agent_pair_resumed` (`by: request | person`) and deliver the held messages in order, flags
//! (steer, interrupt) as sent; until the last is recorded, a new message in the pair waits
//! behind them. One the receiver refuses then is dropped and recorded `agent_pair_dropped`.
//! A cmux-subsessions `send_message` with `interrupt` stops the receiver's turn only once the
//! message is accepted, so a held one stops nothing (`subsessions.rs`).
//!
//! The guard and its thresholds are read at daemon start (`PairGuard::from_env`); the app's
//! Debug Settings toggle `agent.pairGuard` turns it off (`ACPMUX_AGENT_PAIR_GUARD=0`).

use super::*;
use std::collections::{BTreeSet, HashSet, VecDeque};

/// `0` turns the guard off.
pub const GUARD_ENV: &str = "ACPMUX_AGENT_PAIR_GUARD";
/// Exchanges back and forth without progress that pause a pair.
pub const ALTERNATIONS_ENV: &str = "ACPMUX_AGENT_PAIR_ALTERNATIONS";
/// Near-identical messages in a row from one sender that pause a pair.
pub const REPEATS_ENV: &str = "ACPMUX_AGENT_PAIR_REPEATS";
/// How alike two messages must be to count as the same, in percent.
pub const SIMILARITY_ENV: &str = "ACPMUX_AGENT_PAIR_SIMILARITY";

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

/// The cmux-subsessions tools (`subsession_mcp.rs`) that only message, read, wait on or stop
/// another session of the family: never progress. `start_session` is not one: it hands work off.
const SUBSESSION_TOOLS: &[&str] = &[
    "send_message",
    "list_sessions",
    "get_session",
    "wait_for_sessions",
    "stop_session",
    "set_session_limits",
];
/// The cmux MCP tools that message or read another chat (`cmux-tui` `cli/mcp/agent_tools.rs`):
/// never progress, whatever the server is named.
const CHAT_TOOLS: &[&str] = &["agents_chat_send", "agents_chat_read"];

/// How long a release waits for each held message to be recorded before it sends the next.
const RELEASE_WAIT: std::time::Duration = std::time::Duration::from_secs(10);

/// The guard's settings.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PairGuard {
    pub enabled: bool,
    pub alternations: u32,
    pub repeats: u32,
    /// 0.0 to 1.0.
    pub similarity: f64,
}

impl Default for PairGuard {
    fn default() -> Self {
        Self { enabled: true, alternations: 10, repeats: 3, similarity: 0.9 }
    }
}

impl PairGuard {
    /// The settings `var` names (the process environment at daemon start): unset or unreadable
    /// values keep their defaults; a threshold under 2 does too (one message is no loop).
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
        Self {
            enabled: var(GUARD_ENV).is_none_or(|v| v.trim() != "0"),
            alternations: count(ALTERNATIONS_ENV, d.alternations),
            repeats: count(REPEATS_ENV, d.repeats),
            similarity,
        }
    }
}

/// Every pair the daemon has seen messages between.
#[derive(Default)]
pub(crate) struct AgentPairs {
    guard: StdMutex<PairGuard>,
    state: StdMutex<PairsState>,
}

type PairKey = (String, String);

#[derive(Default)]
struct PairsState {
    pairs: HashMap<PairKey, Pair>,
    /// Prompt ids of held messages a resume is delivering: they pass once.
    releasing: HashSet<String>,
}

#[derive(Default)]
struct Pair {
    /// Exchanges in a row that went back and forth with no progress, the last one included.
    alternating: u32,
    last: Option<Exchange>,
    /// By sender: near-identical messages in a row to the other, and the last one's words.
    repeats: HashMap<String, (u32, BTreeSet<String>)>,
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
}

impl Held {
    fn record(&self, from_name: &str) -> Value {
        let text = prompt_text(&self.blocks);
        json!({
            "from": self.from, "fromName": from_name, "to": self.to, "promptId": self.prompt_id,
            "text": short_text(message_body(&text), 200), "provenance": self.provenance,
            "prompt": self.blocks, "client": self.client, "steer": self.steer,
            "steerOnly": self.steer_only, "interrupt": self.interrupt,
            "control": self.control.as_str(), "trustGate": self.trust_gate,
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
        })
    }
}

/// Why a pair tripped.
#[derive(Clone, Copy)]
enum Trip {
    Alternating(u32),
    Repeating(u32),
}

impl Trip {
    fn reason(self) -> &'static str {
        match self {
            Trip::Alternating(_) => "alternating",
            Trip::Repeating(_) => "repeating",
        }
    }

    fn count(self) -> u32 {
        match self {
            Trip::Alternating(n) | Trip::Repeating(n) => n,
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

/// A shell command that is one `cmux agent message` or `cmux agent inbox` call and nothing else.
fn messaging_command(command: &str) -> bool {
    let command = command.trim();
    if ["&&", "||", ";", "|", "\n", "`", "$(", ">", "<", "&"].iter().any(|op| command.contains(op))
    {
        return false;
    }
    let mut words = command.split_whitespace();
    let program = words.next().unwrap_or("");
    let program = program.rsplit('/').next().unwrap_or(program);
    program == "cmux"
        && words.next() == Some("agent")
        && matches!(words.next(), Some("message" | "inbox"))
}

/// The command a tool call runs: a string, or an argv whose shell `-c` script is its last word.
fn tool_command(update: &Value) -> Option<String> {
    match update.pointer("/rawInput/command")? {
        Value::String(command) => Some(command.clone()),
        Value::Array(argv) => {
            let argv: Vec<&str> = argv.iter().filter_map(Value::as_str).collect();
            let shell = argv
                .first()
                .is_some_and(|p| matches!(p.rsplit('/').next(), Some("sh" | "bash" | "zsh")))
                && argv.get(1).is_some_and(|f| f.starts_with('-') && f.ends_with('c'));
            Some(if shell { argv.last().copied().unwrap_or("").to_owned() } else { argv.join(" ") })
        }
        _ => None,
    }
}

/// Whether a tool call only messages or reads another session.
fn messaging_call(update: &Value) -> bool {
    if let Some(command) = tool_command(update) {
        return messaging_command(&command);
    }
    let title = update.get("title").and_then(Value::as_str).unwrap_or("").trim();
    // Codex titles an MCP call `Tool: <server>/<tool>`.
    let title = title.strip_prefix("Tool: ").map_or(title, str::trim);
    if title.contains(char::is_whitespace) {
        return messaging_command(title);
    }
    messaging_tool(title)
}

/// Whether an MCP tool call's title (`mcp__cmux-subsessions__send_message`,
/// `cmux-subsessions.send_message`, `cmux-subsessions/send_message`, or the bare name) names a
/// messaging tool. A sub-session tool name another server also uses is that server's work.
fn messaging_tool(title: &str) -> bool {
    let title = title.strip_prefix("mcp__").unwrap_or(title);
    let (server, name) =
        match title.rsplit_once("__").or_else(|| title.rsplit_once(['.', '/', ':'])) {
            Some((server, name)) => (Some(server), name),
            None => (None, title),
        };
    CHAT_TOOLS.contains(&name)
        || (SUBSESSION_TOOLS.contains(&name)
            && server.is_none_or(|s| s == crate::subsession_mcp::SERVER_NAME))
}

/// The messages a receiver's log shows held and still owed, by sender, oldest first: an
/// `agent_pair_held` whose prompt id never reached the session (`recorded`) and has no
/// `agent_pair_dropped` after it.
fn still_held(
    session: &str,
    records: Vec<EventRecord>,
    recorded: &HashSet<String>,
) -> HashMap<String, Vec<Held>> {
    let mut held: HashMap<String, Vec<Held>> = HashMap::new();
    for rec in records {
        match rec.kind.as_str() {
            "agent_pair_held" => {
                if let Some(h) = Held::from_record(session, &rec.msg)
                    && !recorded.contains(&h.prompt_id)
                {
                    let list = held.entry(h.from.clone()).or_default();
                    if !list.iter().any(|x| x.prompt_id == h.prompt_id) {
                        list.push(h);
                    }
                }
            }
            "agent_pair_dropped" => {
                if let Some(id) = rec.msg.get("promptId").and_then(Value::as_str) {
                    held.values_mut().for_each(|list| list.retain(|h| h.prompt_id != id));
                }
            }
            _ => {}
        }
    }
    held.retain(|_, list| !list.is_empty());
    held
}

/// Whether a log record shows the session doing work: a tool call that is not a messaging
/// call, or a file the agent wrote.
fn progress_record(rec: &EventRecord) -> bool {
    match rec.kind.as_str() {
        "fs/write_text_file" => rec.dir == "in",
        "tool_call" => !messaging_call(rec.msg.pointer("/params/update").unwrap_or(&rec.msg)),
        _ => false,
    }
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

    /// The sending session of an agent message (`agent_message`) or of a cmux-subsessions
    /// `send_message` or `start_session` (`subsession_message`): a session of this daemon, by
    /// its exact id (the cmux daemon writes it `acp:<id>`). `None` for any other prompt, for a
    /// sender that is no session here (the person's `cli`, a terminal, another actor), and for
    /// acpmux's own withdraw notices.
    fn agent_message_sender(&self, provenance: Option<&Value>) -> Option<Arc<Session>> {
        let p = provenance?;
        let kind = p.get("kind").and_then(Value::as_str);
        if !matches!(kind, Some("agent_message" | super::subsessions::PROVENANCE_KIND)) {
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

    /// Whether `session` did work after log sequence `mark`.
    fn progressed_since(&self, session: &str, mark: u64) -> bool {
        let mut progressed = false;
        let _ = self.store.scan(session, mark, &mut |rec| {
            progressed = progress_record(&rec);
            !progressed
        });
        progressed
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
        let prompt_id =
            opts.prompt_id.get_or_insert_with(|| uuid::Uuid::now_v7().to_string()).clone();
        let text = prompt_text(blocks);
        let said = words(message_body(&text));
        let key = pair_key(&from, &to);
        let last = self.pairs_state().pairs.get(&key).and_then(|p| p.last.clone());
        // Read outside the lock: store scans. Work in either session since the last exchange.
        let progressed = last.as_ref().is_some_and(|l| {
            self.progressed_since(&l.to, l.to_mark) || self.progressed_since(&l.from, l.from_mark)
        });
        let held = Held {
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
        };
        let hold =
            {
                let mut state = self.pairs_state();
                let pair = state.pairs.entry(key.clone()).or_default();
                if let Some(paused) = pair.paused.as_mut() {
                    if paused.held.iter().any(|h| h.prompt_id == prompt_id) {
                        // A resend of a message held already.
                    } else if paused.held.len() >= MAX_HELD {
                        return Err(RpcError::new(
                        -32000,
                        format!(
                            "{FULL_REASON}: this message to session {to} was NOT delivered and is \
                             not held: the paused pair already holds {MAX_HELD} messages. Stop \
                             messaging {to}; tell the user what you need."
                        ),
                    )
                    .with_data(json!({"reason": FULL_REASON, "held": false, "promptId": prompt_id,
                                      "sessions": [from, to], "limit": MAX_HELD})));
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
                    let trip = if alternating >= guard.alternations {
                        Some(Trip::Alternating(alternating))
                    } else if repeats >= guard.repeats {
                        Some(Trip::Repeating(repeats))
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
                       "resume": method::MUX_AGENT_PAIR_RESUME})
            };
            self.append(session, "mux", "agent_pair_paused", note(&from, &sender_name));
            self.mark_unread(session);
            self.append(&sender, "mux", "agent_pair_paused", note(&to, &receiver_name));
            self.mark_unread(&sender);
        }
        self.append(session, "mux", "agent_pair_held", held.record(&sender_name));
        let (why, then) = match hold {
            Hold::Tripped(Trip::Repeating(n)) => (
                format!("it sent {n} near-identical messages in a row"),
                "The user resumes the pair; held messages are then delivered in order.",
            ),
            Hold::Tripped(Trip::Alternating(n)) => (
                format!(
                    "the two sessions exchanged {n} messages with no tool call or file change \
                     in between"
                ),
                "The user resumes the pair; held messages are then delivered in order.",
            ),
            Hold::Paused => (
                "the pair is paused".to_owned(),
                "The user resumes the pair; held messages are then delivered in order.",
            ),
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
            "promptId": prompt_id,
            "sessions": [from, to],
            "trip": trip,
        })))
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
        pair.last = Some(Exchange {
            from: p.from.id.clone(),
            to: p.to.id.clone(),
            from_mark: p.from.seq.load(Ordering::SeqCst),
            to_mark: p.to.seq.load(Ordering::SeqCst),
        });
    }

    /// Rebuilds the pauses `session`'s log shows (`queue.rs` `restore_queue`, at load and for a
    /// chat moved here): every message held for it that never reached it (`recorded`: the prompt
    /// ids of its `queued` and `user_message` records) and was not dropped. A resume that a
    /// restart cut short leaves its undelivered messages held, for the person to resume again.
    pub(super) fn restore_agent_pairs(
        &self,
        session: &str,
        records: Vec<EventRecord>,
        recorded: &HashSet<String>,
    ) {
        let held = still_held(session, records, recorded);
        let mut state = self.pairs_state();
        for (from, list) in held {
            let pair = state.pairs.entry(pair_key(&from, session)).or_default();
            let paused = pair
                .paused
                .get_or_insert_with(|| Paused { held: VecDeque::new(), draining: false });
            for h in list {
                if !paused.held.iter().any(|x| x.prompt_id == h.prompt_id) {
                    paused.held.push_back(h);
                }
            }
        }
    }

    /// The person prompted `session`: every pair it is in starts over, and a paused one is
    /// resumed.
    pub fn agent_pair_person_prompt(self: &Arc<Self>, session: &Session) {
        self.agent_pair_resume_inner(&session.id, None, "person");
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

    /// Delivers what a resumed pair holds, oldest first, each recorded (queued or started)
    /// before the next; messages held meanwhile follow. Once it is empty the pair starts over.
    async fn drain_pair(self: Arc<Self>, key: PairKey) {
        loop {
            let next = {
                let mut state = self.pairs_state();
                let next = state
                    .pairs
                    .get_mut(&key)
                    .and_then(|p| p.paused.as_mut())
                    .and_then(|p| p.held.pop_front());
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
                self.pairs_state().releasing.remove(&h.prompt_id);
                continue;
            };
            let (tx, rx) = oneshot::channel::<()>();
            let accepted = Arc::new(AtomicBool::new(false));
            let accept = accepted.clone();
            let opts = PromptOptions {
                prompt_id: Some(h.prompt_id.clone()),
                on_accepted: Some(Box::new(move |_| {
                    accept.store(true, Ordering::SeqCst);
                    let _ = tx.send(());
                })),
                // A message a restart rebuilt may have run before: the log answers it.
                resend: true,
                control: h.control,
                trust_gate: h.trust_gate,
                steer_only: h.steer_only,
                interrupt: h.interrupt,
                provenance: Some(h.provenance),
                ..PromptOptions::default()
            };
            let hub = self.clone();
            let (blocks, client, steer) = (h.blocks, h.client, h.steer);
            let prompt_id = h.prompt_id;
            let from = h.from;
            tokio::spawn(async move {
                // A refusal before the session recorded it (no live agent, a steer with no turn
                // to steer): it is dropped, and a restart does not hold it again.
                if let Err(e) = hub.prompt_with(&session, blocks, &client, steer, opts).await
                    && !accepted.load(Ordering::SeqCst)
                {
                    hub.pairs_state().releasing.remove(&prompt_id);
                    tracing::warn!(session = %session.id, "held agent message: {}", e.message);
                    hub.append(
                        &session,
                        "mux",
                        "agent_pair_dropped",
                        json!({"peer": from, "promptId": prompt_id, "error": e.message}),
                    );
                }
            });
            let _ = tokio::time::timeout(RELEASE_WAIT, rx).await;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_rendered_message_compares_by_its_body() {
        let text = "[cmux agent message] from builder (acp:a)\nMessage id: m-1\nNote\n---\nPlease check the build\n--- end of message m-1 ---";
        assert_eq!(message_body(text), "Please check the build");
        assert_eq!(message_body("plain text"), "plain text");
    }

    #[test]
    fn near_identical_ignores_case_digits_and_spacing() {
        let a = words("Please  check the BUILD, run 1");
        let b = words("please check the build run 22");
        assert!(similarity(&a, &b) >= 0.9);
        let c = words("the build is green, merging now");
        assert!(similarity(&a, &c) < 0.9);
    }

    #[test]
    fn settings_come_from_the_environment() {
        let env = |pairs: &'static [(&'static str, &'static str)]| {
            move |k: &str| pairs.iter().find(|(key, _)| *key == k).map(|(_, v)| (*v).to_owned())
        };
        assert_eq!(PairGuard::from_env(env(&[])), PairGuard::default());
        let off = PairGuard::from_env(env(&[(GUARD_ENV, "0")]));
        assert!(!off.enabled);
        let tuned = PairGuard::from_env(env(&[
            (ALTERNATIONS_ENV, "10"),
            (REPEATS_ENV, "1"),
            (SIMILARITY_ENV, "80"),
        ]));
        assert_eq!((tuned.alternations, tuned.repeats), (10, 3));
        assert!((tuned.similarity - 0.8).abs() < f64::EPSILON);
    }

    #[test]
    fn messaging_calls_are_not_progress() {
        let rec = |update: Value| EventRecord {
            seq: 1,
            at: 0,
            dir: "in".into(),
            kind: "tool_call".into(),
            msg: json!({"params": {"update": update}}),
            host_seq: None,
        };
        assert!(!progress_record(&rec(json!({"title": "mcp__cmux-subsessions__send_message"}))));
        assert!(!progress_record(&rec(
            json!({"title": "Bash", "rawInput": {"command": "cmux agent message acp:b hi"}})
        )));
        assert!(progress_record(&rec(json!({"title": "Edit notes.md", "kind": "edit"}))));
        assert!(!progress_record(&rec(json!({"title": "Tool: cmux-subsessions/send_message"}))));
        assert!(!progress_record(&rec(
            json!({"title": "Shell", "rawInput": {"command": ["bash", "-lc", "cmux agent inbox"]}})
        )));
    }

    #[test]
    fn subsession_and_chat_tools_are_not_progress_but_starting_one_is() {
        let rec = |title: &str| EventRecord {
            seq: 1,
            at: 0,
            dir: "in".into(),
            kind: "tool_call".into(),
            msg: json!({"params": {"update": {"title": title}}}),
            host_seq: None,
        };
        for title in [
            "mcp__cmux-subsessions__send_message",
            "mcp__cmux-subsessions__wait_for_sessions",
            "mcp__cmux-subsessions__get_session",
            "mcp__cmux-subsessions__list_sessions",
            "mcp__cmux-subsessions__stop_session",
            "mcp__cmux-subsessions__set_session_limits",
            "cmux-subsessions.send_message",
            "send_message",
            "wait_for_sessions",
            "mcp__cmux__agents_chat_send",
            "agents_chat_read",
        ] {
            assert!(!progress_record(&rec(title)), "{title} is messaging, not progress");
        }
        // Starting a sub-session hands work off; another server's tool of the same name is work.
        for title in [
            "mcp__cmux-subsessions__start_session",
            "mcp__slack__send_message",
            "github.list_sessions",
        ] {
            assert!(progress_record(&rec(title)), "{title} is progress");
        }
    }

    /// A restart rebuilds what is still owed: a held message a cut-short resume never delivered
    /// stays held; one that reached the session, or was dropped, does not.
    #[test]
    fn a_restart_holds_only_what_never_reached_the_session() {
        let rec = |kind: &str, msg: Value| EventRecord {
            seq: 1,
            at: 0,
            dir: "mux".into(),
            kind: kind.into(),
            msg,
            host_seq: None,
        };
        let held = |id: &str| {
            rec(
                "agent_pair_held",
                json!({"from": "a", "to": "b", "promptId": id, "client": "acpmux",
                       "prompt": [{"type": "text", "text": id}],
                       "provenance": {"kind": "subsession_message", "from": "a", "to": "b"},
                       "interrupt": id == "h3"}),
            )
        };
        let records = vec![
            held("h1"),
            held("h2"),
            held("h3"),
            held("h4"),
            rec("agent_pair_dropped", json!({"peer": "a", "promptId": "h2"})),
        ];
        let recorded: HashSet<String> = ["h1".to_owned()].into();
        let owed = still_held("b", records, &recorded);
        let ids: Vec<&str> = owed["a"].iter().map(|h| h.prompt_id.as_str()).collect();
        assert_eq!(ids, ["h3", "h4"]);
        assert!(owed["a"][0].interrupt, "the flags come back as sent");
        assert!(still_held("b", vec![held("h1")], &recorded).is_empty());
    }

    #[test]
    fn only_a_whole_messaging_call_is_not_progress() {
        let rec = |update: Value| EventRecord {
            seq: 1,
            at: 0,
            dir: "in".into(),
            kind: "tool_call".into(),
            msg: json!({"params": {"update": update}}),
            host_seq: None,
        };
        // An edit of a file that mentions a messaging tool is an edit.
        assert!(progress_record(&rec(json!({"title": "Edit send_message.rs", "kind": "edit"}))));
        // A command that also runs something else is work.
        assert!(progress_record(&rec(json!({"title": "Bash",
            "rawInput": {"command": "cargo test && cmux agent message acp:b done"}}))));
        assert!(progress_record(&rec(json!({"title": "Bash",
            "rawInput": {"command": "grep -r 'cmux agent message' docs"}}))));
    }
}
