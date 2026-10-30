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
//! 256 KiB goes cut: its seq and kind with `truncated: true, full_bytes`.

use std::collections::{HashMap, VecDeque};
use std::sync::Arc;

use cmux_json::JsonSet as _;
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt as _, AsyncWriteExt as _, BufReader};
use tokio::net::unix::OwnedWriteHalf;
use tokio::sync::mpsc;

use super::super::guest_prompt_id;
use crate::mux::Mux;
use crate::server::{RenderService, handle_connection_with_permit, transport};

/// A whole `snapshot` or `page` frame.
const MAX_FRAME: usize = 512 * 1024;
/// A record bigger than this is sent cut.
const MAX_RECORD: usize = 256 * 1024;
/// Records one attach or history page asks for.
const PAGE: u64 = 200;
/// A guest's prompts held at once, and the decided ones a snapshot names.
const MAX_HELD: usize = 16;
const MAX_DECIDED: usize = 16;
/// Prompt states and client ids one relay remembers.
const MAX_STATES: usize = 512;
const MAX_CLIENTS: usize = 64;
/// The room's asks a relay keeps until its attachment answers.
const MAX_WAITING: usize = 64;

/// What the room asked of one guest.
pub(super) enum Ask {
    Prompt { client_id: String, text: String },
    Typing(bool),
    Older(u64),
    Status(Vec<String>),
}

/// What a relay hands the host socket.
pub(super) enum Out {
    /// A frame of this guest's relay of this generation.
    Frame(String, u64, Value),
    /// The relay of this guest and generation ended.
    Ended(String, u64),
}

/// One running relay, as the host socket keeps it. Dropping it ends the relay.
pub(super) struct Relay {
    pub(super) asks: mpsc::UnboundedSender<Ask>,
    pub(super) generation: u64,
    /// The guest's browser sockets the room said are open; `None` once their count is unknown
    /// (a host `hello` names each guest once).
    pub(super) sockets: Option<usize>,
}

/// Starts the relay of `guest_id` (on the bridge's runtime: the caller is one of its tasks).
pub(super) fn start(
    mux: &Arc<Mux>,
    render: Arc<RenderService>,
    ids: (&str, &str),
    generation: u64,
    out: mpsc::UnboundedSender<Out>,
) -> Option<Relay> {
    let (ours, daemons) = std::os::unix::net::UnixStream::pair().ok()?;
    ours.set_nonblocking(true).ok()?;
    let ours = tokio::net::UnixStream::from_std(ours).ok()?;
    let mux = mux.clone();
    let serve = move || {
        let stream: Box<dyn transport::Stream> = Box::new(daemons);
        handle_connection_with_permit(mux, stream, render, None);
    };
    std::thread::Builder::new().name("mux-share-guest".into()).spawn(serve).ok()?;
    let (asks, receiver) = mpsc::unbounded_channel();
    let (read, write) = ours.into_split();
    let link = Link {
        share_id: ids.0.to_owned(),
        guest_id: ids.1.to_owned(),
        generation,
        out,
        write,
        next_id: 1,
        pending: HashMap::new(),
        states: HashMap::new(),
        order: VecDeque::new(),
        clients: HashMap::new(),
        tick: 0,
        attached: false,
        waiting: VecDeque::new(),
    };
    tokio::spawn(run(BufReader::new(read), link, receiver));
    Some(Relay { asks, generation, sockets: Some(1) })
}

async fn run(
    read: BufReader<tokio::net::unix::OwnedReadHalf>,
    mut link: Link,
    mut asks: mpsc::UnboundedReceiver<Ask>,
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
            // refused as not attached, and lost).
            ask = asks.recv() => match ask {
                Some(ask) if link.attached => link.ask(ask).await,
                Some(ask) => {
                    if link.waiting.len() < MAX_WAITING {
                        link.waiting.push_back(ask);
                    }
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
    let _ = link.out.send(Out::Ended(link.guest_id.clone(), link.generation));
}

enum Pending {
    Bind,
    Attach,
    Page,
    Prompt(String),
    Ignore,
}

struct State {
    state: &'static str,
    reason: Option<String>,
    at: u64,
}

struct Link {
    share_id: String,
    guest_id: String,
    generation: u64,
    out: mpsc::UnboundedSender<Out>,
    write: OwnedWriteHalf,
    next_id: u64,
    pending: HashMap<u64, Pending>,
    /// Prompt id to its state (the chat's guest prompts the relay saw).
    states: HashMap<String, State>,
    order: VecDeque<String>,
    /// Prompt id to this guest's `client_id`.
    clients: HashMap<String, String>,
    tick: u64,
    /// The attachment answered: the room's asks go to the daemon.
    attached: bool,
    /// The room's asks that came before the attachment answered, sent once it does.
    waiting: VecDeque<Ask>,
}

impl Link {
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

    /// One line from the daemon: a reply or an event of the guest's attachment.
    async fn inbound(&mut self, line: &str) -> bool {
        let Ok(frame) = serde_json::from_str::<Value>(line) else { return true };
        match frame.get("event").and_then(Value::as_str) {
            Some("agent-session-record") => {
                self.record(frame.get("record").cloned().unwrap_or(Value::Null));
                return true;
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
                self.snapshot(frame.get("data").unwrap_or(&Value::Null));
                let view = json!({"cmd": "agent-session-view", "surface": 0, "visible": true});
                self.call(view, Pending::Ignore).await
            }
            Pending::Page if ok => {
                let page = json!({"v": 1, "t": "page", "to": self.guest_id});
                let data = frame.get("data").unwrap_or(&Value::Null);
                let more = data.get("hasMore") == Some(&Value::Bool(true));
                self.emit(bounded(page, ordered(data), more));
                true
            }
            Pending::Prompt(prompt) if ok => {
                // Held unless acpmux's records said otherwise first (a retried prompt it ran).
                if !self.states.contains_key(&prompt) {
                    self.note(&prompt, "held", None);
                }
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
            Pending::Page | Pending::Ignore => true,
        }
    }

    async fn ask(&mut self, ask: Ask) -> bool {
        match ask {
            Ask::Prompt { client_id, text } => {
                if !(1..=128).contains(&client_id.len()) {
                    return true;
                }
                let prompt = guest_prompt_id(&self.share_id, &self.guest_id, &client_id);
                self.remember(&prompt, client_id);
                let held = (self.clients.keys())
                    .filter(|p| self.states.get(*p).is_some_and(|s| s.state == "held"))
                    .count();
                if !self.states.contains_key(&prompt) && held >= MAX_HELD {
                    self.note(&prompt, "refused", Some("share.too_many_held".into()));
                    return true;
                }
                let frame = json!({"cmd": "agent-session-prompt", "surface": 0,
                    "client_id": self.clients.get(&prompt), "text": text});
                self.call(frame, Pending::Prompt(prompt)).await
            }
            Ask::Typing(on) => {
                let frame = json!({"cmd": "agent-session-typing", "surface": 0, "on": on});
                self.call(frame, Pending::Ignore).await
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
                        self.remember(&prompt, client_id);
                        if self.states.contains_key(&prompt) {
                            self.announce(&prompt);
                        }
                    }
                }
                true
            }
        }
    }

    fn snapshot(&mut self, data: &Value) {
        let records = ordered(data);
        for record in &records {
            if let Some((prompt, state)) = decision(record) {
                self.set(&prompt, state, None);
            }
        }
        let watermark =
            records.iter().filter_map(|r| r.get("seq").and_then(Value::as_u64)).max().unwrap_or(0);
        let session = data.get("session").unwrap_or(&Value::Null);
        let chat = json!({"title": session.get("title").or_else(|| session.get("name")),
            "harness": session.get("harness"), "status": session.get("status")});
        let snapshot = json!({"v": 1, "t": "snapshot", "to": self.guest_id, "chat": chat,
            "watermark": watermark, "prompts": self.prompts()});
        self.emit(bounded(snapshot, records, data.get("hasMore") == Some(&Value::Bool(true))));
    }

    fn record(&mut self, record: Value) {
        let decided = decision(&record);
        let records =
            json!({"v": 1, "t": "records", "to": [self.guest_id], "records": [cut(record)]});
        self.emit(records);
        if let Some((prompt, state)) = decided {
            self.note(&prompt, state, None);
        }
    }

    /// Records a prompt's state; a change of this guest's prompt goes to the room.
    fn note(&mut self, prompt: &str, state: &'static str, reason: Option<String>) {
        let same = self.states.get(prompt).is_some_and(|s| s.state == state && s.reason == reason);
        self.set(prompt, state, reason);
        if !same && self.clients.contains_key(prompt) {
            self.announce(prompt);
        }
    }

    fn set(&mut self, prompt: &str, state: &'static str, reason: Option<String>) {
        if !prompt.starts_with("g-") {
            return;
        }
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
    }

    fn remember(&mut self, prompt: &str, client_id: String) {
        if !self.clients.contains_key(prompt) && self.clients.len() >= MAX_CLIENTS {
            let oldest =
                self.clients.keys().min_by_key(|p| self.states.get(*p).map_or(0, |s| s.at));
            if let Some(oldest) = oldest.cloned() {
                self.clients.remove(&oldest);
            }
        }
        self.clients.insert(prompt.to_owned(), client_id);
    }

    fn announce(&self, prompt: &str) {
        let (Some(client_id), Some(state)) = (self.clients.get(prompt), self.states.get(prompt))
        else {
            return;
        };
        let mut frame = json!({"v": 1, "t": "prompt_state", "guest_id": self.guest_id,
            "client_id": client_id, "prompt_id": prompt, "state": state.state});
        if let Some(reason) = &state.reason {
            frame.set("reason", json!(reason));
        }
        self.emit(frame);
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
