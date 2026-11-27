//! The default-off ask-ledger experiment (RFD 0010). A prompt opts in at the client, but only the
//! daemon's proven human-send boundary may capture it.
//!
//! An ask is a list of events, never a row someone edits: `captured` (with the ask's words and
//! source), then whatever follows (`routed`, `picked`, `prOpened`, `prMerged`, `answered`,
//! `reopened`, `dropped`), each naming who caused it and when. An ask's `status` and its `owner`
//! are folded from those events on every read, so "ask to owner" and "ask to PR" are queries,
//! not reconstructions of a result string.
//!
//! Persisted append-only to `<home>/ask-ledger/events.jsonl` by a writer thread started at the
//! first event, so a machine that never opts in has no file, folder or thread; folded once when
//! the hub is built. A purge drops the chat's asks and rewrites the file without them, so the
//! words leave the disk with the chat. A memory store keeps the events in memory only.

mod store;

use super::{Hub, Session};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::Sender;
use std::sync::{Arc, Mutex, PoisonError};

pub(crate) const METHOD: &str = "_acpmux/ask_ledger";
/// `<home>/ask-ledger`.
pub(crate) const DIR: &str = "ask-ledger";
/// The newest asks one read returns.
const LIMIT: usize = 200;
const TEXT_CHARS: usize = 16_384;

/// What happened to an ask. `captured` carries the ask itself; the rest name their target.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub(crate) enum Kind {
    Captured { row: Value },
    Routed { to: String },
    Picked,
    PrOpened { repo: String, number: u64 },
    PrMerged { repo: String, number: u64 },
    Answered,
    Reopened,
    Dropped { reason: String },
}

/// One line of the file: an event on an ask, or a purged chat's asks leaving.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "t", rename_all = "camelCase")]
pub(crate) enum Line {
    Event {
        ask: String,
        /// The chat the ask was typed in: what a purge removes by.
        sid: String,
        ts: u64,
        /// Who caused it: the person for a capture, else a session, lane or tool.
        by: String,
        #[serde(flatten)]
        kind: Kind,
    },
    Purge {
        sid: String,
    },
}

/// One ask's events, oldest first; the first is its `captured`.
struct Ask {
    sid: String,
    events: Vec<(u64, String, Kind)>,
}

impl Ask {
    /// The ask's status, folded from its events: never set by hand.
    fn status(&self) -> &'static str {
        let mut status = "open";
        for (_, _, kind) in &self.events {
            status = match kind {
                Kind::Captured { .. } | Kind::Reopened => "open",
                Kind::Routed { .. } => "routed",
                Kind::Picked | Kind::PrOpened { .. } => "inProgress",
                Kind::PrMerged { .. } => "landed",
                Kind::Answered => "answered",
                Kind::Dropped { .. } => "dropped",
            };
        }
        status
    }

    /// Who took it: the newest `routed` target or `picked` actor since it was last reopened.
    fn owner(&self) -> Option<(&str, u64)> {
        let mut owner = None;
        for (ts, by, kind) in &self.events {
            match kind {
                Kind::Routed { to } => owner = Some((to.as_str(), *ts)),
                Kind::Picked => owner = Some((by.as_str(), *ts)),
                Kind::Reopened => owner = None,
                _ => {}
            }
        }
        owner
    }

    fn row(&self) -> Value {
        let mut row = match self.events.first() {
            Some((_, _, Kind::Captured { row: Value::Object(row) })) => row.clone(),
            _ => serde_json::Map::new(),
        };
        let created = self.events.first().map(|(ts, ..)| *ts).unwrap_or_default();
        row.insert("status".into(), json!(self.status()));
        if let Some((owner, at)) = self.owner() {
            row.insert("owner".into(), json!(owner));
            row.insert("ownedAfterMs".into(), json!(at.saturating_sub(created)));
        }
        let events = self
            .events
            .iter()
            .skip(1)
            .map(|(ts, by, kind)| {
                let mut event = match serde_json::to_value(kind) {
                    Ok(Value::Object(event)) => event,
                    _ => serde_json::Map::new(),
                };
                event.insert("ts".into(), json!(ts));
                event.insert("by".into(), json!(by));
                Value::Object(event)
            })
            .collect();
        row.insert("events".into(), Value::Array(events));
        Value::Object(row)
    }
}

#[derive(Default)]
struct State {
    asks: HashMap<String, Ask>,
    /// Capture order, oldest first: a read takes the newest from the end.
    order: Vec<String>,
    /// A purge was folded, so the file still holds that chat's words until it is rewritten.
    stale: bool,
}

impl State {
    fn apply(&mut self, line: Line) {
        match line {
            Line::Event { ask, sid, ts, by, kind } => {
                if let Some(known) = self.asks.get_mut(&ask) {
                    // A second capture of a known id (a retry, a second path) adds nothing.
                    if !matches!(kind, Kind::Captured { .. }) {
                        known.events.push((ts, by, kind));
                    }
                } else if matches!(kind, Kind::Captured { .. }) {
                    self.order.push(ask.clone());
                    self.asks.insert(ask, Ask { sid, events: vec![(ts, by, kind)] });
                }
            }
            Line::Purge { sid } => {
                self.remove_session(&sid);
                self.stale = true;
            }
        }
    }

    fn remove_session(&mut self, sid: &str) -> bool {
        let before = self.asks.len();
        self.asks.retain(|_, ask| ask.sid != sid);
        if self.asks.len() == before {
            return false;
        }
        let asks = &self.asks;
        self.order.retain(|id| asks.contains_key(id));
        true
    }

    /// Every line that rebuilds this state, in capture order.
    fn lines(&self) -> Vec<Line> {
        let mut lines = Vec::new();
        for id in &self.order {
            let Some(ask) = self.asks.get(id) else { continue };
            for (ts, by, kind) in &ask.events {
                lines.push(Line::Event {
                    ask: id.clone(),
                    sid: ask.sid.clone(),
                    ts: *ts,
                    by: by.clone(),
                    kind: kind.clone(),
                });
            }
        }
        lines
    }
}

pub(crate) struct AskLedger {
    state: Mutex<State>,
    dir: Option<PathBuf>,
    writer: Mutex<Option<Sender<store::Work>>>,
    thread: Mutex<Option<store::WriterThread>>,
    /// Set by [`AskLedger::close`]: later events stay in memory, and no second writer starts.
    closed: AtomicBool,
}

impl Default for AskLedger {
    /// In memory only (a memory store, tests).
    fn default() -> Self {
        Self::open(None)
    }
}

impl AskLedger {
    /// The ledger kept in `dir` (`<home>/ask-ledger`), folded from its file now. A fold that saw a
    /// purge rewrites the file at once, so a purged chat's words never outlive one restart.
    pub(crate) fn open(dir: Option<PathBuf>) -> Self {
        let mut state = State::default();
        if let Some(dir) = &dir {
            store::fold(&dir.join(store::FILE), &mut state);
        }
        let stale = std::mem::take(&mut state.stale);
        let lines = stale.then(|| state.lines());
        let ledger = Self {
            state: Mutex::new(state),
            dir,
            writer: Mutex::new(None),
            thread: Mutex::new(None),
            closed: AtomicBool::new(false),
        };
        if let Some(lines) = lines {
            ledger.send(store::Work::Rewrite(lines));
        }
        ledger
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Hands `work` to the writer, starting it on first use. Called under the state lock, so
    /// the file's order is the state's.
    fn send(&self, work: store::Work) {
        let Some(dir) = &self.dir else { return };
        let mut writer = self.writer.lock().unwrap_or_else(PoisonError::into_inner);
        if self.closed.load(Ordering::SeqCst) {
            return;
        }
        if writer.is_none() {
            let mut thread = self.thread.lock().unwrap_or_else(PoisonError::into_inner);
            let Some((tx, handle)) = store::spawn_writer(dir.clone()) else { return };
            *writer = Some(tx);
            *thread = Some(handle);
        }
        if let Some(tx) = writer.as_ref() {
            let _ = tx.send(work);
        }
    }

    /// Records one event. `captured` of a purged chat (`purged` set) writes nothing: checked
    /// under the lock a purge takes after setting the flag, so a late callback cannot outlive it.
    pub(crate) fn record(&self, line: Line, purged: Option<&AtomicBool>) -> bool {
        let mut state = self.lock();
        if purged.is_some_and(|gone| gone.load(Ordering::SeqCst)) {
            return false;
        }
        let Line::Event { ask, kind, .. } = &line else { return false };
        let known = state.asks.contains_key(ask);
        let captured = matches!(kind, Kind::Captured { .. });
        if known == captured {
            // A repeated capture, or an event on an ask this ledger never saw.
            return false;
        }
        state.apply(line.clone());
        self.send(store::Work::Line(Box::new(line)));
        true
    }

    /// The chat's asks leave memory and the file.
    pub(crate) fn purge(&self, sid: &str) {
        let mut state = self.lock();
        if state.remove_session(sid) {
            let lines = state.lines();
            self.send(store::Work::Rewrite(lines));
        }
    }

    /// The newest asks, each with its folded status, owner and later events. Never a scan of
    /// chats or their journals.
    pub(crate) fn page(&self) -> Value {
        let state = self.lock();
        let entries: Vec<Value> = state
            .order
            .iter()
            .rev()
            .take(LIMIT)
            .filter_map(|id| state.asks.get(id).map(Ask::row))
            .collect();
        json!({"entries": entries})
    }

    /// Shutdown: closes the writer's queue and waits up to `within` for it to write what it
    /// holds. True when it ended (or never started).
    pub(crate) fn close(&self, within: std::time::Duration) -> bool {
        {
            let mut writer = self.writer.lock().unwrap_or_else(PoisonError::into_inner);
            self.closed.store(true, Ordering::SeqCst);
            drop(writer.take());
        }
        let thread = self.thread.lock().unwrap_or_else(PoisonError::into_inner).take();
        let Some(thread) = thread else { return true };
        match thread.join_within(within) {
            Ok(()) => true,
            Err(thread) => {
                *self.thread.lock().unwrap_or_else(PoisonError::into_inner) = Some(thread);
                false
            }
        }
    }

    /// Waits for a writer [`AskLedger::close`] left running, however long it takes.
    pub(crate) fn wait_closed(&self) {
        {
            let mut writer = self.writer.lock().unwrap_or_else(PoisonError::into_inner);
            self.closed.store(true, Ordering::SeqCst);
            drop(writer.take());
        }
        let thread = self.thread.lock().unwrap_or_else(PoisonError::into_inner).take();
        if let Some(thread) = thread {
            thread.join();
        }
    }

    #[cfg(test)]
    fn flush(&self) {
        let (tx, rx) = std::sync::mpsc::sync_channel(1);
        self.send(store::Work::Flush(tx));
        let _ = rx.recv_timeout(std::time::Duration::from_secs(5));
    }
}

/// Full digest of a length-delimited tuple: stable across retries; neither text nor time is an id.
fn identity(harness: &str, session: &str, message: &str) -> String {
    let mut hash = Sha256::new();
    for part in [harness, session, message] {
        hash.update((part.len() as u64).to_be_bytes());
        hash.update(part.as_bytes());
    }
    format!("ask-{:x}", hash.finalize())
}

/// The person at this machine, as an event's `by`.
fn person() -> String {
    let user = std::env::var("USER")
        .or_else(|_| std::env::var("USERNAME"))
        .ok()
        .filter(|u| !u.is_empty())
        .unwrap_or_else(|| "person".into());
    format!("{user}@{}", crate::host_pressure::host_name())
}

impl Hub {
    /// Adds capture to acceptance, never to a successful turn's eventual result. An unaccepted
    /// send writes nothing; a duplicate/withdrawn/resend receipt writes nothing. The original
    /// callback always runs, so this view cannot change the composer's accepted-send behavior.
    pub(crate) fn capture_ask_on_accept(
        self: &Arc<Self>,
        session: &Arc<Session>,
        text: &str,
        next: Option<Box<dyn FnOnce(Value) + Send>>,
    ) -> Option<Box<dyn FnOnce(Value) + Send>> {
        let hub = Arc::downgrade(self);
        let session_id = session.id.clone();
        let harness = session.read_meta(|m| m.harness.clone());
        let gone = session.purged.clone();
        let body: String = text.chars().take(TEXT_CHARS).collect();
        let truncated = body.len() < text.len();
        Some(Box::new(move |accepted| {
            let ignored = ["duplicate", "withdrawn", "resent"]
                .iter()
                .any(|key| accepted.get(key).and_then(Value::as_bool) == Some(true));
            if !ignored
                && !body.trim().is_empty()
                && let Some(message_id) = accepted.get("promptId").and_then(Value::as_str)
                && let Some(hub) = hub.upgrade()
            {
                let id = identity(&harness, &session_id, message_id);
                let now = crate::store::now_ms();
                let row = json!({
                    "id": id,
                    "messageId": message_id,
                    "sessionId": session_id,
                    "harness": harness,
                    "host": crate::host_pressure::host_name(),
                    "text": body,
                    "truncated": truncated,
                    "createdAt": now,
                });
                let line = Line::Event {
                    ask: id,
                    sid: session_id.to_string(),
                    ts: now,
                    by: person(),
                    kind: Kind::Captured { row },
                };
                hub.ask_ledger.record(line, Some(&gone));
            }
            if let Some(next) = next {
                next(accepted);
            }
        }))
    }
}

#[cfg(test)]
mod tests;
