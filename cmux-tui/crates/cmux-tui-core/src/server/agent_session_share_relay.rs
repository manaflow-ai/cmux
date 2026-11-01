//! The relay of one guest of a bridged link share (design chat-multiplayer.md 4.3). For each guest
//! whose browser is in the room, the bridge opens a same-user connection to this daemon, served by
//! the real connection path, binds it with `agent-session-proxy-bind {link_guest}` on its first
//! line, and attaches. So every frame is the bound guest's and passes the daemon's per-frame
//! checks (its share and guest live, the guest verbs only, every prompt held for the owner), and
//! revoke, kick and expiry end the connection at the daemon first.
//!
//! What the relay sends the room names this guest only: a `snapshot` first (the newest records
//! that fit in 512 KiB, `has_more` when older ones remain), then each live record, `page` for
//! `older`, and `prompt_state` for the guest's prompts, read from acpmux's records (`queued`
//! awaiting the owner, `queue_approved`, `queue_declined`, `queue_removed`). A record over
//! 256 KiB goes cut: its seq and kind with `truncated: true, full_bytes`. Records the daemon sends
//! before the attach answer wait for the snapshot. A prompt's state only moves forward (a
//! decision is final; held replaces refused), kept in the guest's [`Ledger`].

use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::{Arc, Mutex, MutexGuard};

use cmux_json::JsonSet as _;
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt as _, AsyncWriteExt as _, BufReader};
use tokio::net::unix::OwnedWriteHalf;
use tokio::sync::mpsc;

use super::super::guest_prompt_id;
use crate::mux::Mux;
use crate::server::{RenderService, claim_connection, handle_connection_with_permit, transport};

/// A whole `snapshot` or `page` frame.
const MAX_FRAME: usize = 512 * 1024;
/// A record bigger than this is sent cut.
const MAX_RECORD: usize = 256 * 1024;
/// Records one attach or history page asks for.
const PAGE: u64 = 200;
/// A guest's prompts held at once, and the decided ones a snapshot names.
const MAX_HELD: usize = 16;
const MAX_DECIDED: usize = 16;
/// Prompt states and client ids one guest's ledger remembers.
const MAX_STATES: usize = 512;
const MAX_CLIENTS: usize = 64;
/// The room's asks a relay keeps until its attachment answers.
const MAX_WAITING: usize = 64;
/// The room's asks queued for a relay, its calls awaiting the daemon's answer, and its history
/// pages among them: past these an ask is refused at once (`share.busy`, an empty page).
pub(super) const MAX_ASKS: usize = 64;
const MAX_PENDING: usize = 32;
const MAX_PAGES: usize = 2;
/// The records the daemon sends before the attach answer, kept for after the snapshot (each
/// cut first), by count and by bytes.
const MAX_EARLY: usize = 256;
const MAX_EARLY_BYTES: usize = 4 * 1024 * 1024;

/// The prompt states that never change again.
fn decided(state: &str) -> bool {
    matches!(state, "approved" | "declined" | "removed")
}

/// Whether a prompt's state may go from `from` to `to`: forward only. A decision is final;
/// `held` (acpmux took it) is never undone by a refused retry, and replaces an earlier refusal.
fn advance(from: Option<&str>, to: &str) -> bool {
    match from {
        Some(from) if decided(from) => false,
        Some("held") => to != "refused",
        _ => true,
    }
}

struct State {
    state: &'static str,
    reason: Option<String>,
    at: u64,
}

/// One guest's prompts: their states, their client ids, and which count against [`MAX_HELD`].
/// The bridge keeps one per guest of each share, so the guest's successive relays and the
/// share's successive host sockets share it (a reconnect of either keeps it). Keyed by prompt
/// id: a retry, a decision said again (live, in a snapshot, in a history page) changes nothing.
/// The count is the guest's prompts sent and neither refused nor decided, filled only from what
/// the guest sent (never from `prompt_status`), so the cap counts every one. A prompt the daemon
/// has not answered yet stays here with its text, and every relay of the guest sends it again
/// once attached (acpmux runs a prompt id once), so neither a guest nor a host reconnect loses
/// it unsaid.
#[derive(Default)]
pub(super) struct Ledger {
    open: HashSet<String>,
    /// Prompts taken and not answered yet (prompt id, client id, text), oldest first; at most
    /// [`MAX_HELD`], as each is in `open`.
    unanswered: VecDeque<(String, String, String)>,
    /// Prompt id to its state (the chat's guest prompts the relays saw), oldest first in `order`.
    states: HashMap<String, State>,
    order: VecDeque<String>,
    /// Prompt id to this guest's `client_id`.
    clients: HashMap<String, String>,
    tick: u64,
}

pub(super) type Held = Arc<Mutex<Ledger>>;

impl Ledger {
    fn state(&self, prompt: &str) -> Option<&'static str> {
        self.states.get(prompt).map(|s| s.state)
    }

    /// Whether `prompt` may go to the daemon: it counts already (sent, or decided), or there is
    /// room for it under the cap, which it then takes.
    fn admit(&mut self, prompt: &str) -> bool {
        if self.open.contains(prompt) || self.state(prompt).is_some_and(decided) {
            return true;
        }
        if self.open.len() >= MAX_HELD {
            return false;
        }
        self.open.insert(prompt.to_owned());
        true
    }

    /// Takes the guest's `prompt` to send: false at the cap. Kept until the daemon answers it.
    fn take(&mut self, prompt: &str, client_id: String, text: String) -> bool {
        self.remember(prompt, client_id.clone());
        if !self.admit(prompt) {
            return false;
        }
        if !self.unanswered.iter().any(|(p, _, _)| p == prompt) {
            self.unanswered.push_back((prompt.to_owned(), client_id, text));
        }
        true
    }

    /// Records a prompt's state, forward only; whether it changed. Any state answers it.
    fn note(&mut self, prompt: &str, state: &'static str, reason: Option<String>) -> bool {
        if !prompt.starts_with("g-") {
            return false;
        }
        self.unanswered.retain(|(p, _, _)| p != prompt);
        let from = self.state(prompt);
        if !advance(from, state) {
            return false;
        }
        match state {
            // Counted when it is this guest's (its client id is known).
            "held" if self.clients.contains_key(prompt) => {
                self.open.insert(prompt.to_owned());
            }
            "held" => {}
            _ => {
                self.open.remove(prompt);
            }
        }
        let same = self.states.get(prompt).is_some_and(|s| s.state == state && s.reason == reason);
        self.tick = self.tick.wrapping_add(1);
        if !self.states.contains_key(prompt) {
            if self.order.len() >= MAX_STATES
                && let Some(oldest) = self.order.pop_front()
            {
                self.states.remove(&oldest);
            }
            self.order.push_back(prompt.to_owned());
        }
        self.states.insert(prompt.to_owned(), State { state, reason, at: self.tick });
        !same
    }

    fn remember(&mut self, prompt: &str, client_id: String) {
        if !self.clients.contains_key(prompt) && self.clients.len() >= MAX_CLIENTS {
            // Never a prompt still counted (held, or sent and unanswered: at most MAX_HELD of
            // MAX_CLIENTS), whose later state the guest must hear.
            let oldest = (self.clients.keys())
                .filter(|p| !self.open.contains(*p))
                .min_by_key(|p| self.states.get(*p).map_or(0, |s| s.at));
            if let Some(oldest) = oldest.cloned() {
                self.clients.remove(&oldest);
            }
        }
        self.clients.insert(prompt.to_owned(), client_id);
    }

    /// The `prompt_state` of this guest's `prompt`, when its client id and state are known.
    fn frame(&self, guest_id: &str, prompt: &str) -> Option<Value> {
        let (client_id, state) = (self.clients.get(prompt)?, self.states.get(prompt)?);
        let mut frame = json!({"v": 1, "t": "prompt_state", "guest_id": guest_id,
            "client_id": client_id, "prompt_id": prompt, "state": state.state});
        if let Some(reason) = &state.reason {
            frame.set("reason", json!(reason));
        }
        Some(frame)
    }

    /// This guest's held prompts and its most recently decided ones.
    fn prompts(&self) -> Vec<Value> {
        let mut known: Vec<(&String, &String, &State)> = (self.clients.iter())
            .filter_map(|(prompt, client)| Some((prompt, client, self.states.get(prompt)?)))
            .collect();
        known.sort_by_key(|(_, _, state)| std::cmp::Reverse(state.at));
        let (held, decided): (Vec<_>, Vec<_>) =
            known.into_iter().partition(|(_, _, s)| s.state == "held");
        let entry = |(prompt, client, state): (&String, &String, &State)| json!({"client_id": client, "prompt_id": prompt, "state": state.state});
        let held = held.into_iter().take(MAX_HELD).map(&entry);
        held.chain(decided.into_iter().take(MAX_DECIDED).map(&entry)).collect()
    }
}

fn lock(held: &Held) -> MutexGuard<'_, Ledger> {
    held.lock().unwrap_or_else(|e| e.into_inner())
}

/// What the room asked of one guest.
pub(super) enum Ask {
    Prompt { client_id: String, text: String },
    Typing(bool),
    Older(u64),
    Status(Vec<String>),
}

/// The answer to an ask no relay can take now: a prompt is refused with `reason` (its state
/// said; a prompt acpmux took already stays held), `older` gets an empty page that still has
/// more; the rest the guest's page asks again.
pub(super) fn refuse(held: &Held, ids: (&str, &str), ask: Ask, reason: &str) -> Option<Value> {
    match ask {
        Ask::Prompt { client_id, .. } if (1..=128).contains(&client_id.len()) => {
            let prompt = guest_prompt_id(ids.0, ids.1, &client_id);
            let mut ledger = lock(held);
            ledger.remember(&prompt, client_id);
            ledger.note(&prompt, "refused", Some(reason.to_owned()));
            ledger.frame(ids.1, &prompt)
        }
        Ask::Older(_) => Some(bounded(json!({"v": 1, "t": "page", "to": ids.1}), Vec::new(), true)),
        Ask::Prompt { .. } | Ask::Typing(_) | Ask::Status(_) => None,
    }
}

/// What a relay hands the host socket.
pub(super) enum Out {
    /// A frame of this guest's relay of this generation.
    Frame(String, u64, Value),
    /// The relay of this guest and generation ended.
    Ended(String, u64),
    /// Try again to start the relay of this connected guest (no connection permit was free, or
    /// its last relay ended while the guest stayed connected).
    Retry(String),
}

/// One running relay, as the host socket keeps it. Dropping it ends the relay.
pub(super) struct Relay {
    /// Bounded ([`MAX_ASKS`]): a full queue refuses the ask.
    pub(super) asks: mpsc::Sender<Ask>,
    pub(super) generation: u64,
    /// The guest's browser sockets the room said are open; `None` once their count is unknown
    /// (a host `hello` names each guest once).
    pub(super) sockets: Option<usize>,
    /// The starts in a row this guest's relay took (its backoff when it ends again).
    pub(super) tries: u32,
}

/// Starts the relay of `guest_id` (on the bridge's runtime: the caller is one of its tasks). Its
/// connection takes one of the daemon's connection permits like any client's; with none free no
/// relay starts (the guest's next `guest_joined` asks again).
pub(super) fn start(
    mux: &Arc<Mux>,
    render: Arc<RenderService>,
    ids: (&str, &str),
    generation: u64,
    out: mpsc::UnboundedSender<Out>,
    held: Held,
) -> Option<Relay> {
    let permit = claim_connection(mux.connection_stats())?;
    let (ours, daemons) = std::os::unix::net::UnixStream::pair().ok()?;
    ours.set_nonblocking(true).ok()?;
    let ours = tokio::net::UnixStream::from_std(ours).ok()?;
    let mux = mux.clone();
    let serve = move || {
        let stream: Box<dyn transport::Stream> = Box::new(daemons);
        handle_connection_with_permit(mux, stream, render, Some(permit));
    };
    std::thread::Builder::new().name("mux-share-guest".into()).spawn(serve).ok()?;
    let (asks, receiver) = mpsc::channel(MAX_ASKS);
    let (read, write) = ours.into_split();
    let link = Link::new(ids, generation, out, write, held);
    tokio::spawn(run(BufReader::new(read), link, receiver));
    Some(Relay { asks, generation, sockets: Some(1), tries: 0 })
}

async fn run(
    read: BufReader<tokio::net::unix::OwnedReadHalf>,
    mut link: Link,
    mut asks: mpsc::Receiver<Ask>,
) {
    let mut lines = read.lines();
    let bind = json!({"cmd": "agent-session-proxy-bind",
        "link_guest": {"share_id": link.share_id, "guest_id": link.guest_id}});
    let mut open = link.call(bind, Pending::Bind).await;
    while open {
        open = tokio::select! {
            line = lines.next_line() => match line {
                Ok(Some(line)) => link.inbound(&line).await,
                _ => false,
            },
            // Until the attachment answers, the room's asks wait (one sent before it would be
            // refused as not attached, and lost): a prompt in the guest's ledger, which every
            // relay of the guest sends once attached, the rest here.
            ask = asks.recv() => match ask {
                Some(ask) if link.attached => link.ask(ask).await,
                Some(Ask::Prompt { client_id, text }) => {
                    link.take(client_id, text);
                    true
                }
                Some(ask) if link.waiting.len() < MAX_WAITING => {
                    link.waiting.push_back(ask);
                    true
                }
                // Too many before the attachment: answered as refused, never lost unsaid.
                Some(ask) => {
                    link.busy(ask);
                    true
                }
                None => false,
            },
        };
        while open
            && link.attached
            && let Some(ask) = link.waiting.pop_front()
        {
            open = link.ask(ask).await;
        }
    }
    // The prompts it sent and did not get answered stay in the guest's ledger: its next relay
    // sends them again.
    let _ = link.out.send(Out::Ended(link.guest_id.clone(), link.generation));
}

enum Pending {
    Bind,
    Attach,
    Page,
    /// A prompt sent: its id.
    Prompt(String),
    Ignore,
}

struct Link {
    share_id: String,
    guest_id: String,
    generation: u64,
    out: mpsc::UnboundedSender<Out>,
    write: OwnedWriteHalf,
    next_id: u64,
    /// The calls awaiting the daemon's answer (at most [`MAX_PENDING`] the room's asks made).
    pending: HashMap<u64, Pending>,
    /// The attachment answered: the room's asks go to the daemon.
    attached: bool,
    /// The room's asks that came before the attachment answered, sent once it does.
    waiting: VecDeque<Ask>,
    /// The records the daemon sent before the attachment answered (cut), each with the prompt
    /// state it said (read before the cut), sent after the snapshot.
    early: VecDeque<(Value, Option<(String, &'static str)>)>,
    /// The bytes of `early` (at most [`MAX_EARLY_BYTES`]).
    early_bytes: usize,
    /// This guest's prompts (kept by the bridge across relays and host sockets).
    held: Held,
}

impl Link {
    fn new(
        ids: (&str, &str),
        generation: u64,
        out: mpsc::UnboundedSender<Out>,
        write: OwnedWriteHalf,
        held: Held,
    ) -> Self {
        Self {
            share_id: ids.0.to_owned(),
            guest_id: ids.1.to_owned(),
            generation,
            out,
            write,
            next_id: 1,
            pending: HashMap::new(),
            attached: false,
            waiting: VecDeque::new(),
            early: VecDeque::new(),
            early_bytes: 0,
            held,
        }
    }

    async fn call(&mut self, mut frame: Value, pending: Pending) -> bool {
        let id = self.next_id;
        self.next_id = self.next_id.wrapping_add(1);
        frame.set("id", json!(id));
        self.pending.insert(id, pending);
        let mut line = frame.to_string();
        line.push('\n');
        self.write.write_all(line.as_bytes()).await.is_ok()
    }

    fn emit(&self, frame: Value) {
        let _ = self.out.send(Out::Frame(self.guest_id.clone(), self.generation, frame));
    }

    fn ledger(&self) -> MutexGuard<'_, Ledger> {
        lock(&self.held)
    }

    /// One line from the daemon: a reply or an event of the guest's attachment.
    async fn inbound(&mut self, line: &str) -> bool {
        let Ok(frame) = serde_json::from_str::<Value>(line) else { return true };
        match frame.get("event").and_then(Value::as_str) {
            Some("agent-session-record") => {
                let record = frame.get("record").cloned().unwrap_or(Value::Null);
                if self.attached {
                    self.record(record);
                    return true;
                }
                // Before the snapshot nothing reaches the room; too many and the relay ends
                // (the guest's next one starts from a fresh snapshot).
                // The prompt state it says is read whole: a cut record no longer names it.
                let decided = decision(&record);
                let record = cut(record);
                self.early_bytes = self.early_bytes.saturating_add(record.to_string().len());
                self.early.push_back((record, decided));
                return self.early.len() <= MAX_EARLY && self.early_bytes <= MAX_EARLY_BYTES;
            }
            // share_ended, detached, overflow: the guest's page reconnects for a fresh snapshot.
            Some("agent-session-closed") => return false,
            Some(_) => return true,
            None => {}
        }
        let Some(pending) =
            frame.get("id").and_then(Value::as_u64).and_then(|id| self.pending.remove(&id))
        else {
            return true;
        };
        let ok = frame.get("ok") == Some(&Value::Bool(true));
        match pending {
            Pending::Bind | Pending::Attach if !ok => false,
            Pending::Bind => {
                let attach = json!({"cmd": "agent-session-attach", "surface": 0, "limit": PAGE,
                    "kinds": ["transcript"]});
                self.call(attach, Pending::Attach).await
            }
            Pending::Attach => {
                self.attached = true;
                let watermark = self.snapshot(frame.get("data").unwrap_or(&Value::Null));
                self.early_bytes = 0;
                for (record, decided) in std::mem::take(&mut self.early) {
                    if record.get("seq").and_then(Value::as_u64).is_none_or(|s| s > watermark) {
                        self.relay(record, decided);
                    }
                }
                let view = json!({"cmd": "agent-session-view", "surface": 0, "visible": true});
                if !self.call(view, Pending::Ignore).await {
                    return false;
                }
                // The guest's prompts no daemon answered yet (taken before this attachment, or
                // by an earlier relay): sent again.
                let unanswered = self.ledger().unanswered.clone();
                for (prompt, client_id, text) in unanswered {
                    if !self.send(prompt, client_id, text).await {
                        return false;
                    }
                }
                true
            }
            Pending::Page if ok => {
                let page = json!({"v": 1, "t": "page", "to": self.guest_id});
                let data = frame.get("data").unwrap_or(&Value::Null);
                let more = data.get("hasMore") == Some(&Value::Bool(true));
                let records = ordered(data);
                // The states it names (older than the snapshot: decided while the guest was
                // away). Forward only, so an older page never undoes a newer state.
                let states: Vec<_> = records.iter().filter_map(decision).collect();
                self.emit(bounded(page, records, more));
                for (prompt, state) in states {
                    self.note(&prompt, state, None);
                }
                true
            }
            Pending::Page => {
                self.busy(Ask::Older(0));
                true
            }
            // Held unless acpmux's records said otherwise first (a retried prompt it ran).
            Pending::Prompt(prompt) if ok => {
                self.note(&prompt, "held", None);
                true
            }
            Pending::Prompt(prompt) => {
                let reason = frame
                    .get("error_code")
                    .and_then(Value::as_str)
                    .unwrap_or("share.refused")
                    .to_owned();
                self.note(&prompt, "refused", Some(reason));
                true
            }
            Pending::Ignore => true,
        }
    }

    /// Takes a prompt of the guest into its ledger (held, plus sent and not answered yet: a
    /// burst cannot pass the cap before the replies come; a retry of one counted or decided
    /// takes no slot again); its id, or `None` when refused at the cap.
    fn take(&mut self, client_id: String, text: String) -> Option<String> {
        if !(1..=128).contains(&client_id.len()) {
            return None;
        }
        let prompt = guest_prompt_id(&self.share_id, &self.guest_id, &client_id);
        if self.ledger().take(&prompt, client_id, text) {
            return Some(prompt);
        }
        self.note(&prompt, "refused", Some("share.too_many_held".into()));
        None
    }

    /// Sends a prompt the ledger took, unless this relay sent it and awaits its answer.
    async fn send(&mut self, prompt: String, client_id: String, text: String) -> bool {
        if self.pending.values().any(|p| matches!(p, Pending::Prompt(p) if *p == prompt)) {
            return true;
        }
        let frame = json!({"cmd": "agent-session-prompt", "surface": 0,
            "client_id": client_id, "text": text});
        self.call(frame, Pending::Prompt(prompt)).await
    }

    /// An ask the relay cannot take now (`share.busy`).
    fn busy(&self, ask: Ask) {
        if let Some(frame) = refuse(&self.held, (&self.share_id, &self.guest_id), ask, "share.busy")
        {
            self.emit(frame);
        }
    }

    async fn ask(&mut self, ask: Ask) -> bool {
        let pages = self.pending.values().filter(|p| matches!(p, Pending::Page)).count();
        let full = self.pending.len() >= MAX_PENDING;
        match ask {
            Ask::Prompt { client_id, text } => {
                if !(1..=128).contains(&client_id.len()) {
                    return true;
                }
                if full {
                    self.busy(Ask::Prompt { client_id, text });
                    return true;
                }
                match self.take(client_id.clone(), text.clone()) {
                    Some(prompt) => self.send(prompt, client_id, text).await,
                    None => true,
                }
            }
            // Dropped when the daemon is behind: the next one says the same.
            Ask::Typing(_) if full => true,
            Ask::Typing(on) => {
                let frame = json!({"cmd": "agent-session-typing", "surface": 0, "on": on});
                self.call(frame, Pending::Ignore).await
            }
            Ask::Older(before) if full || pages >= MAX_PAGES => {
                self.busy(Ask::Older(before));
                true
            }
            Ask::Older(before) => {
                let frame = json!({"cmd": "agent-session-events", "surface": 0,
                    "before_seq": before, "limit": PAGE, "kinds": ["transcript"]});
                self.call(frame, Pending::Page).await
            }
            // One `prompt_state` per prompt the relay knows the state of.
            Ask::Status(client_ids) => {
                for client_id in client_ids.into_iter().take(MAX_HELD) {
                    if (1..=128).contains(&client_id.len()) {
                        let prompt = guest_prompt_id(&self.share_id, &self.guest_id, &client_id);
                        let frame = {
                            let mut ledger = self.ledger();
                            ledger.remember(&prompt, client_id);
                            ledger.frame(&self.guest_id, &prompt)
                        };
                        if let Some(frame) = frame {
                            self.emit(frame);
                        }
                    }
                }
                true
            }
        }
    }

    /// Sends the snapshot of the attach answer; its newest seq.
    fn snapshot(&mut self, data: &Value) -> u64 {
        let records = ordered(data);
        let prompts = {
            let mut ledger = self.ledger();
            for (prompt, state) in records.iter().filter_map(decision) {
                ledger.note(&prompt, state, None);
            }
            ledger.prompts()
        };
        let watermark =
            records.iter().filter_map(|r| r.get("seq").and_then(Value::as_u64)).max().unwrap_or(0);
        let session = data.get("session").unwrap_or(&Value::Null);
        let chat = json!({"title": session.get("title").or_else(|| session.get("name")),
            "harness": session.get("harness"), "status": session.get("status")});
        let snapshot = json!({"v": 1, "t": "snapshot", "to": self.guest_id, "chat": chat,
            "watermark": watermark, "prompts": prompts});
        self.emit(bounded(snapshot, records, data.get("hasMore") == Some(&Value::Bool(true))));
        watermark
    }

    fn record(&mut self, record: Value) {
        let decided = decision(&record);
        self.relay(record, decided);
    }

    /// Sends `record` (cut) to the room, then notes the prompt state it said (read whole).
    fn relay(&mut self, record: Value, decided: Option<(String, &'static str)>) {
        let records =
            json!({"v": 1, "t": "records", "to": [self.guest_id], "records": [cut(record)]});
        self.emit(records);
        if let Some((prompt, state)) = decided {
            self.note(&prompt, state, None);
        }
    }

    /// Records a prompt's state; a change of this guest's prompt goes to the room.
    fn note(&mut self, prompt: &str, state: &'static str, reason: Option<String>) {
        let frame = {
            let mut ledger = self.ledger();
            if ledger.note(prompt, state, reason) {
                ledger.frame(&self.guest_id, prompt)
            } else {
                None
            }
        };
        if let Some(frame) = frame {
            self.emit(frame);
        }
    }
}

/// The page's records, oldest first.
fn ordered(data: &Value) -> Vec<Value> {
    let mut records = data.get("events").and_then(Value::as_array).cloned().unwrap_or_default();
    records.sort_by_key(|record| record.get("seq").and_then(Value::as_u64).unwrap_or(0));
    records
}

/// A guest prompt's state a record says: its prompt id and state.
fn decision(record: &Value) -> Option<(String, &'static str)> {
    let msg = record.get("msg").unwrap_or(record);
    let prompt = msg.get("promptId").and_then(Value::as_str)?;
    let state = match record.get("kind").and_then(Value::as_str)? {
        "queued" if msg.get("awaitingOwner") == Some(&Value::Bool(true)) => "held",
        "queue_approved" => "approved",
        "queue_declined" => "declined",
        "queue_removed" | "prompt_retracted" => "removed",
        _ => return None,
    };
    Some((prompt.to_owned(), state))
}

/// A record over [`MAX_RECORD`] as its seq, dir and kind, `truncated` with its size.
fn cut(record: Value) -> Value {
    let full = record.to_string().len();
    if full <= MAX_RECORD {
        return record;
    }
    let mut short = json!({"truncated": true, "full_bytes": full});
    for key in ["seq", "dir", "kind", "ts", "sessionId"] {
        if let Some(value) = record.get(key) {
            short.set(key, value.clone());
        }
    }
    short
}

/// `frame` with the newest of `records` (oldest first) that fit in [`MAX_FRAME`] with it, each
/// cut; `has_more` when `more` or any older record was left out.
fn bounded(mut frame: Value, records: Vec<Value>, more: bool) -> Value {
    let records: Vec<Value> = records.into_iter().map(cut).collect();
    frame.set("records", json!([]));
    frame.set("has_more", json!(false));
    let mut total = frame.to_string().len();
    let mut from = records.len();
    for (index, record) in records.iter().enumerate().rev() {
        let size = record.to_string().len().saturating_add(1);
        if total.saturating_add(size) > MAX_FRAME {
            break;
        }
        total = total.saturating_add(size);
        from = index;
    }
    frame.set("has_more", json!(more || from > 0));
    frame.set("records", Value::Array(records.into_iter().skip(from).collect()));
    frame
}

#[cfg(test)]
mod tests {
    use super::*;

    fn link(out: mpsc::UnboundedSender<Out>, write: OwnedWriteHalf) -> Link {
        let mut link = Link::new(("s", "g"), 1, out, write, Held::default());
        link.next_id = 2;
        link
    }
    /// A record the daemon sends before the attach answer reaches the room after the snapshot.
    #[test]
    fn records_before_the_attach_answer_follow_the_snapshot() {
        let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
        runtime.block_on(async {
            let (ours, _theirs) = tokio::net::UnixStream::pair().unwrap();
            let (_read, write) = ours.into_split();
            let (out, mut frames) = mpsc::unbounded_channel();
            let mut link = link(out, write);
            link.pending.insert(1, Pending::Attach);
            let record = json!({"event": "agent-session-record",
                "record": {"seq": 5, "kind": "agent_message"}});
            assert!(link.inbound(&record.to_string()).await);
            let reply = json!({"id": 1, "ok": true, "data": {"events": [{"seq": 4}]}});
            assert!(link.inbound(&reply.to_string()).await);
            let mut kinds = Vec::new();
            while let Ok(Out::Frame(_, _, frame)) = frames.try_recv() {
                kinds.push(frame["t"].clone());
            }
            assert_eq!(kinds, vec![json!("snapshot"), json!("records")]);
        });
    }

    /// Records before the attach answer are cut and bounded by bytes: big ones end the relay
    /// (its next one starts from a fresh snapshot) instead of filling memory.
    #[test]
    fn records_before_the_attach_answer_are_bounded_by_bytes() {
        let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
        runtime.block_on(async {
            let (ours, _theirs) = tokio::net::UnixStream::pair().unwrap();
            let (_read, write) = ours.into_split();
            let (out, _frames) = mpsc::unbounded_channel();
            let mut link = link(out, write);
            link.pending.insert(1, Pending::Attach);
            let big = "x".repeat(MAX_RECORD - 1024);
            let mut open = true;
            let mut sent = 0;
            while open && sent < MAX_EARLY {
                let record = json!({"event": "agent-session-record",
                    "record": {"seq": sent, "kind": "agent_message", "text": big}});
                open = link.inbound(&record.to_string()).await;
                sent += 1;
            }
            assert!(!open, "the relay ends past the byte budget");
            assert!(sent < MAX_EARLY, "by bytes, before the count: {sent}");
            assert!(link.early_bytes > MAX_EARLY_BYTES);
            // A huge record is kept cut, never whole.
            let (ours, _theirs) = tokio::net::UnixStream::pair().unwrap();
            let (_read, write) = ours.into_split();
            let (out, _frames) = mpsc::unbounded_channel();
            let mut link = tests::link(out, write);
            let huge = json!({"event": "agent-session-record",
                "record": {"seq": 1, "kind": "agent_message", "text": "y".repeat(2 * MAX_RECORD)}});
            assert!(link.inbound(&huge.to_string()).await);
            assert!(link.early_bytes < 1024);
            assert_eq!(link.early[0].0["truncated"], json!(true));
        });
    }

    /// A prompt the room sends before the attachment, past the cap, is refused and said.
    #[test]
    fn a_prompt_before_the_attachment_past_the_cap_is_refused() {
        let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
        runtime.block_on(async {
            let (ours, _theirs) = tokio::net::UnixStream::pair().unwrap();
            let (_read, write) = ours.into_split();
            let (out, mut frames) = mpsc::unbounded_channel();
            let mut link = link(out, write);
            for n in 0..MAX_HELD {
                assert!(link.take(format!("c{n}"), "hi".into()).is_some());
            }
            assert!(link.take("over".into(), "hi".into()).is_none());
            let mut states = Vec::new();
            while let Ok(Out::Frame(_, _, frame)) = frames.try_recv() {
                states.push((
                    frame["client_id"].clone(),
                    frame["state"].clone(),
                    frame["reason"].clone(),
                ));
            }
            assert_eq!(
                states,
                vec![(json!("over"), json!("refused"), json!("share.too_many_held"))]
            );
        });
    }

    /// The client ids the ledger forgets first are never a prompt still counted (held, or sent
    /// and unanswered), so its later state still reaches the guest.
    #[test]
    fn the_client_id_of_a_counted_prompt_is_kept() {
        let mut ledger = Ledger::default();
        assert!(ledger.take("g-held", "c-held".into(), "hi".into()));
        for n in 0..(MAX_CLIENTS * 2) {
            ledger.remember(&format!("g-asked{n}"), format!("c{n}"));
        }
        assert_eq!(ledger.clients.len(), MAX_CLIENTS);
        assert!(ledger.note("g-held", "approved", None));
        let frame = ledger.frame("g", "g-held").expect("its client id is kept");
        assert_eq!(frame["client_id"], json!("c-held"));
        assert_eq!(frame["state"], json!("approved"));
    }

    /// A guest prompt's queued and decided records that come before the attach answer, too big
    /// and so kept cut, still move its state (held, then approved or declined) and free its slot.
    #[test]
    fn decisions_in_cut_records_before_the_attach_answer_still_count() {
        let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
        runtime.block_on(async {
            let (ours, _theirs) = tokio::net::UnixStream::pair().unwrap();
            let (_read, write) = ours.into_split();
            let (out, mut frames) = mpsc::unbounded_channel();
            let mut link = link(out, write);
            link.pending.insert(1, Pending::Attach);
            let mut prompts = Vec::new();
            for n in 0..MAX_HELD {
                prompts.push(link.take(format!("c{n}"), "hi".into()).expect("under the cap"));
            }
            let big = "z".repeat(2 * MAX_RECORD);
            let records = [
                (5, "queued", &prompts[0]),
                (6, "queue_approved", &prompts[0]),
                (7, "queued", &prompts[1]),
                (8, "queue_declined", &prompts[1]),
            ];
            for (seq, kind, prompt) in records {
                let record = json!({"event": "agent-session-record", "record": {"seq": seq,
                    "kind": kind, "msg": {"promptId": prompt, "awaitingOwner": true, "text": big}}});
                assert!(link.inbound(&record.to_string()).await);
            }
            let reply = json!({"id": 1, "ok": true, "data": {"events": [{"seq": 4}]}});
            assert!(link.inbound(&reply.to_string()).await);
            let mut states = Vec::new();
            while let Ok(Out::Frame(_, _, frame)) = frames.try_recv() {
                if frame["t"] == json!("prompt_state") {
                    states.push((frame["client_id"].clone(), frame["state"].clone()));
                }
            }
            assert_eq!(
                states,
                vec![
                    (json!("c0"), json!("held")),
                    (json!("c0"), json!("approved")),
                    (json!("c1"), json!("held")),
                    (json!("c1"), json!("declined")),
                ]
            );
            // Their two slots are free again, and no more.
            assert!(link.take("over1".into(), "hi".into()).is_some());
            assert!(link.take("over2".into(), "hi".into()).is_some());
            assert!(link.take("over3".into(), "hi".into()).is_none());
        });
    }
}
