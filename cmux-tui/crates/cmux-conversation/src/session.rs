//! One open conversation in the app: the confirmed mirror (written only by
//! the owner's committed changes) and the intent log of the user's sends the
//! owner has not confirmed (OWNERSHIP-PRINCIPLES.md "Clients are
//! projections"). The visible transcript is the mirror's tail followed by the
//! log's entries; older history is paged from the owner on demand and never
//! kept here. The C handle is [`crate::ffi`]'s `CmuxConversationSession`;
//! golden vectors: `tests/cases/session.json`.
//!
//! Messages, heads and parts stay the owner's JSON: the session reads only
//! the fields its rules need (`rev`, `seq`, `id`, `client_msg_id`,
//! `created_at`, `last_seq`, `last_message`, `read_cursors`), so a field this
//! build does not know passes through to the view unchanged.

use serde_json::{Map, Value, json};
use std::collections::{BTreeSet, VecDeque};

/// The newest confirmed messages a mirror keeps by default.
pub const DEFAULT_TAIL_LIMIT: usize = 400;
/// The most events kept while a snapshot loads.
pub const MAX_BUFFERED: usize = 1024;

fn u64_at(value: &Value, key: &str) -> u64 {
    value.get(key).and_then(Value::as_u64).unwrap_or(0)
}

fn str_at<'a>(value: &'a Value, key: &str) -> Option<&'a str> {
    value.get(key).and_then(Value::as_str)
}

/// The confirmed projection of one conversation: its head and a bounded
/// tail of the newest messages, ascending and contiguous by seq.
#[derive(Debug, Clone, PartialEq)]
pub struct Mirror {
    summary: Map<String, Value>,
    tail: VecDeque<Value>,
    tail_limit: usize,
}

/// What one committed change did to a mirror.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Outcome {
    Applied,
    /// Already applied (a duplicate or a change older than the mirror).
    Stale,
    /// A revision was skipped: refetch the snapshot.
    Gap,
}

impl Outcome {
    pub fn code(self) -> &'static str {
        match self {
            Self::Applied => "applied",
            Self::Stale => "stale",
            Self::Gap => "gap",
        }
    }
}

impl Mirror {
    /// A mirror of `snapshot` (`{conversation, messages}`), keeping its
    /// newest `tail_limit` messages (at least 1). None when the snapshot has
    /// no head object.
    pub fn new(snapshot: &Value, tail_limit: usize) -> Option<Self> {
        let summary = snapshot.get("conversation")?.as_object()?.clone();
        let tail_limit = tail_limit.max(1);
        let messages =
            snapshot.get("messages").and_then(Value::as_array).map_or(&[][..], Vec::as_slice);
        let tail = messages[messages.len().saturating_sub(tail_limit)..].iter().cloned().collect();
        Some(Self { summary, tail, tail_limit })
    }

    pub fn rev(&self) -> u64 {
        self.summary.get("rev").and_then(Value::as_u64).unwrap_or(0)
    }

    pub fn summary(&self) -> &Map<String, Value> {
        &self.summary
    }

    pub fn tail(&self) -> &VecDeque<Value> {
        &self.tail
    }

    /// Applies one committed `change` at `rev`.
    pub fn apply(&mut self, rev: u64, change: &Value) -> Outcome {
        let current = self.rev();
        if rev <= current {
            return Outcome::Stale;
        }
        if rev != current + 1 {
            return Outcome::Gap;
        }
        self.summary.insert("rev".into(), json!(rev));
        let message = change.get("message").filter(|m| m.is_object());
        match (str_at(change, "kind"), message) {
            (Some("message"), Some(message)) => {
                let seq = u64_at(message, "seq");
                let last_seq = self.summary.get("last_seq").and_then(Value::as_u64).unwrap_or(0);
                self.summary.insert("last_seq".into(), json!(last_seq.max(seq)));
                self.summary.insert("last_message".into(), message.clone());
                if let Some(at) = message.get("created_at") {
                    self.summary.insert("updated_at".into(), at.clone());
                }
                match self.tail.back() {
                    // A new message the tail cannot join contiguously: restart the tail there.
                    Some(last) if seq != u64_at(last, "seq") + 1 => {
                        self.tail.clear();
                        self.tail.push_back(message.clone());
                    }
                    _ => {
                        self.tail.push_back(message.clone());
                        while self.tail.len() > self.tail_limit {
                            self.tail.pop_front();
                        }
                    }
                }
            }
            (Some("message-updated"), Some(message)) => {
                let id = str_at(message, "id");
                if let Some(slot) = self.tail.iter_mut().find(|m| str_at(m, "id") == id) {
                    *slot = message.clone();
                }
                if self.summary.get("last_message").and_then(|m| str_at(m, "id")) == id {
                    self.summary.insert("last_message".into(), message.clone());
                }
            }
            (Some("read-cursor"), _) => {
                if let Some(participant) = str_at(change, "participant") {
                    let seq = u64_at(change, "seq");
                    let cursors = self
                        .summary
                        .entry("read_cursors")
                        .or_insert_with(|| Value::Object(Map::new()));
                    if !cursors.is_object() {
                        *cursors = Value::Object(Map::new());
                    }
                    if let Some(cursors) = cursors.as_object_mut() {
                        let before = cursors.get(participant).and_then(Value::as_u64).unwrap_or(0);
                        cursors.insert(participant.into(), json!(before.max(seq)));
                    }
                }
            }
            (Some("conversation"), _) => {
                if let Some(head) = change.get("conversation").and_then(Value::as_object) {
                    let last_message = self.summary.remove("last_message");
                    self.summary = head.clone();
                    self.summary.insert("rev".into(), json!(rev));
                    let has_last = self.summary.get("last_message").is_some_and(|m| !m.is_null());
                    if let (false, Some(last)) = (has_last, last_message) {
                        self.summary.insert("last_message".into(), last);
                    }
                }
            }
            // A change kind this build does not know moves the revision only.
            _ => {}
        }
        Outcome::Applied
    }

    /// The confirmed message with this client id, when it is in the tail.
    pub fn message(&self, client_msg_id: &str) -> Option<&Value> {
        self.tail.iter().rev().find(|m| str_at(m, "client_msg_id") == Some(client_msg_id))
    }
}

/// Where one unconfirmed send stands.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SendState {
    /// Sent (or waiting to be resent after a reconnect).
    Sending,
    /// The owner answered; it leaves the log once the mirror reaches `rev`.
    Acknowledged(u64),
    /// The owner rejected it, or it could not be sent: a failed draft the
    /// user can retry (same key) or discard.
    Failed(String),
}

/// One `message.send` the user made that the owner has not confirmed.
#[derive(Debug, Clone, PartialEq)]
pub struct PendingSend {
    /// Also the op's idempotency key.
    pub client_msg_id: String,
    /// The rest of the entry as the app gave it (`conversation`, `parts`,
    /// `reply_to`, `thread_root`, `created_at`), passed through.
    pub fields: Map<String, Value>,
    pub state: SendState,
}

impl PendingSend {
    /// The entry from the app's JSON (`client_msg_id` required).
    pub fn from_json(value: &Value) -> Option<Self> {
        let mut fields = value.as_object()?.clone();
        let client_msg_id = fields.remove("client_msg_id")?.as_str()?.to_owned();
        fields.remove("state");
        Some(Self { client_msg_id, fields, state: SendState::Sending })
    }

    pub fn to_json(&self) -> Value {
        let mut out = self.fields.clone();
        out.insert("client_msg_id".into(), json!(self.client_msg_id));
        out.insert(
            "state".into(),
            match &self.state {
                SendState::Sending => json!({"kind": "sending"}),
                SendState::Acknowledged(rev) => json!({"kind": "acknowledged", "rev": rev}),
                SendState::Failed(reason) => json!({"kind": "failed", "reason": reason}),
            },
        );
        out.insert("op".into(), self.op());
        Value::Object(out)
    }

    /// The `message.send` op this entry sends (the idempotency key is the
    /// client id).
    pub fn op(&self) -> Value {
        let mut op = Map::new();
        op.insert("kind".into(), json!("message.send"));
        op.insert("client_msg_id".into(), json!(self.client_msg_id));
        op.insert("parts".into(), self.fields.get("parts").cloned().unwrap_or_else(|| json!([])));
        for key in ["reply_to", "thread_root"] {
            if let Some(value) = self.fields.get(key).filter(|v| !v.is_null()) {
                op.insert(key.into(), value.clone());
            }
        }
        Value::Object(op)
    }
}

/// The ordered log of unconfirmed sends. An entry leaves on its echo (the
/// mirror holds a message with its client id) or once the mirror reaches
/// the revision the owner acknowledged it at; a reject turns it into a
/// failed draft.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct IntentLog {
    entries: Vec<PendingSend>,
}

impl IntentLog {
    pub fn entries(&self) -> &[PendingSend] {
        &self.entries
    }

    /// Appends a send; false when the client id is already in the log.
    pub fn add(&mut self, send: PendingSend) -> bool {
        if self.entries.iter().any(|e| e.client_msg_id == send.client_msg_id) {
            return false;
        }
        self.entries.push(send);
        true
    }

    fn entry(&mut self, client_msg_id: &str) -> Option<&mut PendingSend> {
        self.entries.iter_mut().find(|e| e.client_msg_id == client_msg_id)
    }

    /// The owner committed (or replayed) the send at `rev`.
    pub fn acknowledge(&mut self, client_msg_id: &str, rev: u64) {
        if let Some(entry) = self.entry(client_msg_id) {
            entry.state = SendState::Acknowledged(rev);
        }
    }

    pub fn reject(&mut self, client_msg_id: &str, reason: &str) {
        if let Some(entry) = self.entry(client_msg_id) {
            entry.state = SendState::Failed(reason.to_owned());
        }
    }

    /// A send goes back to sending (retry with the same key).
    pub fn retry(&mut self, client_msg_id: &str) -> Option<&PendingSend> {
        let entry = self.entry(client_msg_id)?;
        entry.state = SendState::Sending;
        Some(entry)
    }

    pub fn discard(&mut self, client_msg_id: &str) {
        self.entries.retain(|e| e.client_msg_id != client_msg_id);
    }

    /// Drops every entry the mirror now confirms; the client ids that left.
    pub fn settle(&mut self, mirror: &Mirror) -> Vec<String> {
        let mut settled = Vec::new();
        self.entries.retain(|entry| {
            let echoed = mirror.message(&entry.client_msg_id).is_some();
            let reached =
                matches!(entry.state, SendState::Acknowledged(rev) if mirror.rev() >= rev);
            if echoed || reached {
                settled.push(entry.client_msg_id.clone());
            }
            !(echoed || reached)
        });
        settled
    }

    /// Sends to repeat after a reconnect: everything still sending, in
    /// order. The owner applies a repeated key once.
    pub fn resendable(&self) -> impl Iterator<Item = &PendingSend> {
        self.entries.iter().filter(|e| e.state == SendState::Sending)
    }
}

/// One open conversation: the mirror, the intent log, the events that came
/// while a snapshot loaded, and who is typing (ephemeral).
#[derive(Debug, Clone, Default)]
pub struct Session {
    mirror: Option<Mirror>,
    log: IntentLog,
    buffered: Vec<Value>,
    loading: bool,
    typing: BTreeSet<String>,
    tail_limit: Option<usize>,
}

/// Why a session op refused its input.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Invalid;

fn ids(list: Vec<String>) -> Value {
    json!(list)
}

impl Session {
    pub fn new(tail_limit: Option<usize>) -> Self {
        Self { tail_limit, ..Self::default() }
    }

    pub fn mirror(&self) -> Option<&Mirror> {
        self.mirror.as_ref()
    }

    pub fn log(&self) -> &IntentLog {
        &self.log
    }

    fn settle(&mut self) -> Vec<String> {
        match &self.mirror {
            Some(mirror) => self.log.settle(mirror),
            None => Vec::new(),
        }
    }

    /// One owner event (`{rev, change}`). While a snapshot loads (or before
    /// the first one) it is kept, up to [`MAX_BUFFERED`], and replayed after
    /// the snapshot when newer than it.
    pub fn apply(&mut self, event: &Value) -> Value {
        if self.loading || self.mirror.is_none() {
            if self.buffered.len() < MAX_BUFFERED {
                self.buffered.push(event.clone());
            }
            return json!({"outcome": "buffered", "settled": []});
        }
        let Some(mirror) = self.mirror.as_mut() else { return json!({"outcome": "buffered"}) };
        let change = event.get("change").cloned().unwrap_or(Value::Null);
        let outcome = mirror.apply(u64_at(event, "rev"), &change);
        if outcome != Outcome::Applied {
            return json!({"outcome": outcome.code(), "settled": []});
        }
        let settled = self.settle();
        json!({"outcome": "applied", "change": change, "settled": ids(settled)})
    }

    /// A snapshot read starts (first open, a gap, a reconnect).
    pub fn load_started(&mut self) {
        self.loading = true;
    }

    /// The snapshot read failed: the events kept for it are dropped.
    pub fn load_failed(&mut self) {
        self.loading = false;
        self.buffered.clear();
    }

    /// The snapshot (`{conversation, messages}`) arrived. The mirror never
    /// moves back to an older revision than it has; the events kept meanwhile
    /// that are newer than the mirror are applied, then the log settles.
    pub fn loaded(&mut self, snapshot: &Value) -> Result<Value, Invalid> {
        let limit = self.tail_limit.unwrap_or(DEFAULT_TAIL_LIMIT);
        let fresh = Mirror::new(snapshot, limit).ok_or(Invalid)?;
        self.loading = false;
        let replaced = self.mirror.as_ref().is_none_or(|m| m.rev() <= fresh.rev());
        if replaced {
            self.mirror = Some(fresh);
            self.typing.clear();
        }
        let mut settled = Vec::new();
        for event in std::mem::take(&mut self.buffered) {
            let rev = self.mirror.as_ref().map_or(0, Mirror::rev);
            if u64_at(&event, "rev") > rev
                && let Some(mirror) = self.mirror.as_mut()
                && mirror.apply(u64_at(&event, "rev"), event.get("change").unwrap_or(&Value::Null))
                    == Outcome::Applied
            {
                settled.extend(self.settle());
            }
        }
        settled.extend(self.settle());
        Ok(json!({"replaced": replaced, "settled": ids(settled)}))
    }

    /// Who is typing; `changed` when the set moved.
    pub fn set_typing(&mut self, participant: &str, on: bool) -> Value {
        let changed = if on {
            self.typing.insert(participant.to_owned())
        } else {
            self.typing.remove(participant)
        };
        json!({"changed": changed, "typing": self.typing})
    }

    /// The owner's reply settles the intent only; the mirror is written by
    /// the owner's events alone, so a pending bubble stays until the mirror
    /// reaches the acknowledged revision and never blinks out or shows twice.
    pub fn acknowledge(&mut self, client_msg_id: &str, rev: u64) -> Value {
        self.log.acknowledge(client_msg_id, rev);
        json!({"settled": ids(self.settle())})
    }

    /// The session's state for the view and the debug page.
    pub fn state(&self, tail: Option<usize>) -> Value {
        let mirror = self.mirror.as_ref().map(|m| {
            let keep = tail.unwrap_or(m.tail.len()).min(m.tail.len());
            let shown: Vec<&Value> = m.tail.iter().skip(m.tail.len() - keep).collect();
            json!({"rev": m.rev(), "summary": m.summary, "tail": shown})
        });
        json!({
            "mirror": mirror,
            "pending": self.log.entries.iter().map(PendingSend::to_json).collect::<Vec<_>>(),
            "typing": self.typing,
            "loading": self.loading,
            "buffered": self.buffered.len(),
        })
    }

    /// One JSON op on this session; None for an op this build does not know.
    pub fn call(&mut self, op: &str, request: &Value) -> Option<Result<Value, Invalid>> {
        let text = |key: &str| str_at(request, key).ok_or(Invalid);
        let reply = match op {
            "load_started" => {
                self.load_started();
                Ok(json!({}))
            }
            "load_failed" => {
                self.load_failed();
                Ok(json!({}))
            }
            "loaded" => self.loaded(request.get("snapshot").unwrap_or(&Value::Null)),
            "apply" => {
                request.get("event").filter(|e| e.is_object()).map(|e| self.apply(e)).ok_or(Invalid)
            }
            "typing" => (|| {
                let on = request.get("on").and_then(Value::as_bool).ok_or(Invalid)?;
                Ok(self.set_typing(text("participant")?, on))
            })(),
            "add" => request
                .get("send")
                .and_then(PendingSend::from_json)
                .map(|send| json!({"added": self.log.add(send)}))
                .ok_or(Invalid),
            "acknowledge" => (|| {
                let rev = request.get("rev").and_then(Value::as_u64).ok_or(Invalid)?;
                Ok(self.acknowledge(text("client_msg_id")?, rev))
            })(),
            "reject" => (|| {
                self.log.reject(text("client_msg_id")?, text("reason")?);
                Ok(json!({}))
            })(),
            "retry" => text("client_msg_id")
                .map(|id| json!({"send": self.log.retry(id).map(PendingSend::to_json)})),
            "discard" => text("client_msg_id").map(|id| {
                self.log.discard(id);
                json!({})
            }),
            "resendable" => Ok(
                json!({"sends": self.log.resendable().map(PendingSend::to_json).collect::<Vec<_>>()}),
            ),
            "state" => {
                Ok(self.state(request.get("tail").and_then(Value::as_u64).map(|n| n as usize)))
            }
            _ => return None,
        };
        Some(reply)
    }
}
