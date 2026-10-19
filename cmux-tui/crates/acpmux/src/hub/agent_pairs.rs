//! The runaway guard for agent-to-agent messages: two sessions that keep messaging each other
//! without progress are paused as a pair until the person resumes them. There is no cap on how
//! many messages a turn may send; only a loop is stopped.
//!
//! Every agent message reaches a session here: a `session/prompt` whose provenance is
//! `agent_message` (`prompt_provenance.rs`), checked in `Hub::prompt_with` before the prompt is
//! recorded. That covers `cmux agent message` and every tool built on it (the cmux daemon's
//! delivery pump) and acpmux's own session tools (`deliver.rs`).
//!
//! A pair is the unordered pair of sender and receiver sessions. Each delivered message is an
//! exchange. Progress resets the pair: since the pair's last exchange, the session it reached
//! made a tool call that is not itself a messaging call (`send_to_session`, `cmux agent
//! message`, ...), or wrote a file. Without progress the pair trips when either
//!
//! - `alternations` exchanges in a row go back and forth (default 6), or
//! - one sender sends the receiver `repeats` near-identical messages in a row (default 3): the
//!   same words once case, digits and punctuation are dropped, token Jaccard at least
//!   `similarity` (default 0.9).
//!
//! The message that trips the pair, and every later one between the two, is held, not delivered:
//! the sender's `session/prompt` is refused with `agent_pair.paused` (data `held: true`), whose
//! text tells the agent the user resumes the pair, so it stops retrying. Both transcripts record
//! `agent_pair_paused`, the receiver's records each `agent_pair_held`, and both chats are marked
//! unread (the daemon's `notify_command` also fires). `_acpmux/agent_pair_resume`, or a prompt the
//! person sends into either session, clears the pause and delivers the held messages in order
//! (`agent_pair_resumed`, `by: request | person`).
//!
//! The pairs live in memory: a daemon restart forgets the counts, the pause and what it held.
//! The guard and its thresholds are read at daemon start (`PairGuard::from_env`); the app's
//! Debug Settings toggle `agent.pairGuard` turns it off (`ACPMUX_AGENT_PAIR_GUARD=0`).

use super::*;
use std::collections::{BTreeSet, HashSet};

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

/// Tool calls that only message or read another session: never progress.
const MESSAGING_TOOLS: &[&str] = &[
    "send_to_session",
    "read_session",
    "list_sessions",
    "agents_chat_send",
    "agents_chat_read",
    "cmux agent message",
    "cmux agent inbox",
];

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
        Self { enabled: true, alternations: 6, repeats: 3, similarity: 0.9 }
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

#[derive(Default)]
struct PairsState {
    pairs: HashMap<(String, String), Pair>,
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
    /// The receiver's last log sequence when it was delivered: progress is looked for after it.
    mark: u64,
}

struct Paused {
    held: Vec<Held>,
}

/// A message a paused pair holds, with what `prompt_with` needs to deliver it later.
struct Held {
    to: String,
    blocks: Vec<Value>,
    client: String,
    steer: bool,
    prompt_id: String,
    provenance: Value,
    control: Control,
    trust_gate: bool,
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

fn pair_key(a: &str, b: &str) -> (String, String) {
    if a <= b { (a.to_owned(), b.to_owned()) } else { (b.to_owned(), a.to_owned()) }
}

/// The sending session of an agent message, without the `acp:` prefix the cmux daemon writes;
/// `None` for any other prompt and for acpmux's own withdraw notices.
fn agent_message_sender(provenance: Option<&Value>) -> Option<String> {
    let p = provenance?;
    if p.get("kind").and_then(Value::as_str) != Some("agent_message") {
        return None;
    }
    if p.get("msgId").and_then(Value::as_str).is_some_and(|id| id.ends_with(".withdrawn")) {
        return None;
    }
    let from = p.get("from").and_then(Value::as_str)?;
    Some(from.strip_prefix("acp:").unwrap_or(from).to_owned())
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

/// Whether a log record shows the session doing work: a tool call that is not a messaging
/// call, or a file the agent wrote.
fn progress_record(rec: &EventRecord) -> bool {
    match rec.kind.as_str() {
        "fs/write_text_file" => rec.dir == "in",
        "tool_call" => {
            let update = rec.msg.pointer("/params/update").unwrap_or(&rec.msg);
            let said = |key: &str| update.get(key).map(Value::to_string).unwrap_or_default();
            let call = format!("{} {}", said("title"), said("rawInput"));
            !MESSAGING_TOOLS.iter().any(|tool| call.contains(tool))
        }
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

    /// Whether `session` did work after log sequence `mark`.
    fn progressed_since(&self, session: &str, mark: u64) -> bool {
        let mut progressed = false;
        let _ = self.store.scan(session, mark, &mut |rec| {
            progressed = progress_record(&rec);
            !progressed
        });
        progressed
    }

    /// The guard for one prompt into `session`: Ok to deliver it, else the refusal of a held
    /// message (it is kept for the resume).
    pub(super) fn agent_pair_check(
        self: &Arc<Self>,
        session: &Arc<Session>,
        blocks: &[Value],
        client: &str,
        steer: bool,
        opts: &mut PromptOptions,
    ) -> Result<(), RpcError> {
        let Some(from) = agent_message_sender(opts.provenance.as_ref()) else { return Ok(()) };
        let to = session.id.clone();
        let guard = self.agent_pair_guard();
        if from == to || !guard.enabled {
            return Ok(());
        }
        if let Some(id) = &opts.prompt_id
            && self.agent_pairs.state.lock().unwrap_or_else(|e| e.into_inner()).releasing.remove(id)
        {
            return Ok(());
        }
        let prompt_id =
            opts.prompt_id.get_or_insert_with(|| uuid::Uuid::now_v7().to_string()).clone();
        let text = prompt_text(blocks);
        let said = words(message_body(&text));
        let key = pair_key(&from, &to);
        let last = {
            let state = self.agent_pairs.state.lock().unwrap_or_else(|e| e.into_inner());
            state.pairs.get(&key).and_then(|p| p.last.clone())
        };
        // Read outside the lock: a store scan.
        let progressed = last.as_ref().is_some_and(|l| self.progressed_since(&l.to, l.mark));
        let held = Held {
            to: to.clone(),
            blocks: blocks.to_vec(),
            client: client.to_owned(),
            steer,
            prompt_id: prompt_id.clone(),
            provenance: opts.provenance.clone().unwrap_or(Value::Null),
            control: opts.control,
            trust_gate: opts.trust_gate,
        };
        let tripped = {
            let mut state = self.agent_pairs.state.lock().unwrap_or_else(|e| e.into_inner());
            let pair = state.pairs.entry(key).or_default();
            if let Some(paused) = pair.paused.as_mut() {
                if !paused.held.iter().any(|h| h.prompt_id == prompt_id) {
                    paused.held.push(held);
                }
                None
            } else {
                if progressed {
                    pair.alternating = 0;
                    pair.repeats.clear();
                }
                let back = pair.last.as_ref().is_some_and(|l| l.from == to && l.to == from);
                pair.alternating = if back { pair.alternating + 1 } else { 1 };
                let repeats = match pair.repeats.get(&from) {
                    Some((n, before)) if similarity(before, &said) >= guard.similarity => n + 1,
                    _ => 1,
                };
                pair.repeats.insert(from.clone(), (repeats, said));
                let trip = if pair.alternating >= guard.alternations {
                    Some(Trip::Alternating(pair.alternating))
                } else if repeats >= guard.repeats {
                    Some(Trip::Repeating(repeats))
                } else {
                    None
                };
                match trip {
                    Some(trip) => {
                        pair.paused = Some(Paused { held: vec![held] });
                        Some(trip)
                    }
                    None => {
                        let mark = session.seq.load(Ordering::SeqCst);
                        pair.last = Some(Exchange { from: from.clone(), to: to.clone(), mark });
                        return Ok(());
                    }
                }
            }
        };
        let sender = self.resolve(&from).ok();
        let sender_name = sender.as_ref().map_or_else(|| from.clone(), |s| s.meta().name);
        if let Some(trip) = tripped {
            let receiver_name = session.meta().name;
            let note = |peer: &str, peer_name: &str| {
                json!({"peer": peer, "peerName": peer_name, "reason": trip.reason(),
                       "count": trip.count(), "promptId": prompt_id,
                       "resume": method::MUX_AGENT_PAIR_RESUME})
            };
            self.append(session, "mux", "agent_pair_paused", note(&from, &sender_name));
            self.mark_unread(session);
            if let Some(sender) = &sender {
                self.append(sender, "mux", "agent_pair_paused", note(&to, &receiver_name));
                self.mark_unread(sender);
            }
        }
        self.append(
            session,
            "mux",
            "agent_pair_held",
            json!({"from": from, "fromName": sender_name, "promptId": prompt_id,
                   "text": short_text(message_body(&text), 200), "provenance": opts.provenance}),
        );
        let why = match tripped {
            Some(Trip::Repeating(n)) => format!("it sent {n} near-identical messages in a row"),
            Some(Trip::Alternating(n)) => format!(
                "the two sessions exchanged {n} messages with no tool call or file change in between"
            ),
            None => "the pair was already paused".to_owned(),
        };
        let message = format!(
            "{PAUSED_REASON}: this message to session {to} is held, not delivered: cmux paused \
             this session and {to} because {why}. The user resumes the pair, and held messages \
             are then delivered in order. Do not send it again; tell the user what you need."
        );
        Err(RpcError::new(-32000, message).with_data(json!({
            "reason": PAUSED_REASON,
            "held": true,
            "promptId": prompt_id,
            "sessions": [from, to],
            "trip": tripped.map(Trip::reason),
        })))
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

    /// Resumes and resets the pairs; how many were paused, and how many messages they held.
    fn agent_pair_resume_inner(
        self: &Arc<Self>,
        session: &str,
        peer: Option<&str>,
        by: &str,
    ) -> (usize, usize) {
        let mut released: Vec<((String, String), Vec<Held>)> = Vec::new();
        {
            let mut state = self.agent_pairs.state.lock().unwrap_or_else(|e| e.into_inner());
            let keys: Vec<(String, String)> = state
                .pairs
                .keys()
                .filter(|(a, b)| {
                    let other = if a == session {
                        b
                    } else if b == session {
                        a
                    } else {
                        return false;
                    };
                    peer.is_none_or(|p| p == other)
                })
                .cloned()
                .collect();
            for key in keys {
                if let Some(pair) = state.pairs.remove(&key)
                    && let Some(paused) = pair.paused
                {
                    released.push((key, paused.held));
                }
            }
            for (_, held) in &released {
                state.releasing.extend(held.iter().map(|h| h.prompt_id.clone()));
            }
        }
        let pairs = released.len();
        let mut queue: Vec<Held> = Vec::new();
        for ((a, b), held) in released {
            let note = |peer: &str, delivered: usize| json!({"peer": peer, "by": by, "delivered": delivered});
            if let Ok(s) = self.resolve(&a) {
                self.append(&s, "mux", "agent_pair_resumed", note(&b, held.len()));
            }
            if let Ok(s) = self.resolve(&b) {
                self.append(&s, "mux", "agent_pair_resumed", note(&a, held.len()));
            }
            queue.extend(held);
        }
        let delivered = queue.len();
        if !queue.is_empty() {
            let hub = self.clone();
            tokio::spawn(async move { hub.release_held(queue).await });
        }
        (pairs, delivered)
    }

    /// Delivers held messages in order: each is recorded (queued or started) before the next.
    async fn release_held(self: Arc<Self>, held: Vec<Held>) {
        for h in held {
            let Ok(session) = self.resolve(&h.to) else {
                self.agent_pairs
                    .state
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .releasing
                    .remove(&h.prompt_id);
                continue;
            };
            let (tx, rx) = oneshot::channel::<()>();
            let opts = PromptOptions {
                prompt_id: Some(h.prompt_id.clone()),
                on_accepted: Some(Box::new(move |_| {
                    let _ = tx.send(());
                })),
                control: h.control,
                trust_gate: h.trust_gate,
                provenance: Some(h.provenance),
                ..PromptOptions::default()
            };
            let hub = self.clone();
            let (blocks, client, steer) = (h.blocks, h.client, h.steer);
            tokio::spawn(async move {
                if let Err(e) = hub.prompt_with(&session, blocks, &client, steer, opts).await {
                    tracing::warn!(session = %session.id, "held agent message: {}", e.message);
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
        assert!(!progress_record(&rec(json!({"title": "mcp__cmux-sessions__send_to_session"}))));
        assert!(!progress_record(&rec(
            json!({"title": "Bash", "rawInput": {"command": "cmux agent message acp:b hi"}})
        )));
        assert!(progress_record(&rec(json!({"title": "Edit notes.md", "kind": "edit"}))));
    }
}
