//! The client side of the `cmux.wire/1` ownership protocol, sans-I/O: one
//! stream's confirmed mirror plus the client's intent log
//! (`ProjectionClient` in backend/packages/ownership/src/client.ts, checked
//! by plans/cmux-next/formal/OwnershipConvergence.tla).
//!
//! Frames go in through [`StreamMirror::receive`]; frames to send come out as
//! [`ClientOut`]. There is no clock, socket or thread here: the caller passes
//! `now` (milliseconds) and owns the transport. The same engine serves the
//! Mac daemon, the iOS app and the Android app (plans/cmux-next/object-sync
//! DESIGN.md, phase 1).
//!
//! Rules (each one matches the TypeScript client):
//! - An event at `seq + 1` applies; a later one is a gap: buffer it and ask
//!   for a snapshot that reports the pending keys.
//! - Row-mode owners send each event's effects, which apply without a
//!   reducer. An event without effects goes to the [`Reducer`]; when it has
//!   no answer the mirror counts a desync and asks for a snapshot.
//! - An ok settle leaves the log only once the mirror reached its sequence
//!   (held until then), so the UI never shows the op undone.
//! - Offline, a new op is refused (U5). Reconnect resends every pending
//!   intent with its own key, then asks for a snapshot.
//! - An intent older than [`INTENT_TTL_MS`] is never resent; it moves to
//!   `expired` and is reported to the user.

use crate::Origin;
use crate::frames::{
    ClientOut, EventFrame, OpFrame, OwnerFrame, RowWrite, SettledFrame, SnapshotFrame, StoredRow,
};
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet, HashMap};

/// Longest a client keeps a pending intent (24 h). Owners forget decided
/// keys after 7 days, so a resend can never reach an owner that pruned it.
pub const INTENT_TTL_MS: i64 = 24 * 3600 * 1000;

/// A new op while the owner is unreachable: refused, nothing queues (U5).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct OwnerUnreachable;

impl OwnerUnreachable {
    pub const CODE: &'static str = "owner_unreachable";
}

impl std::fmt::Display for OwnerUnreachable {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("owner unreachable: changes are refused while offline (U5)")
    }
}

impl std::error::Error for OwnerUnreachable {}

/// One typed intent the user issued, keyed for its whole life.
#[derive(Debug, Clone, PartialEq)]
pub struct Intent {
    pub idempotency_key: String,
    pub op: String,
    pub params: Value,
    pub origin: Origin,
}

impl Intent {
    fn frame(&self) -> ClientOut {
        ClientOut::Op(OpFrame {
            op: self.op.clone(),
            params: self.params.clone(),
            idempotency_key: self.idempotency_key.clone(),
            origin: self.origin,
        })
    }
}

/// The rows a mirror holds: the loaded pages of a row-backed owner. Applying
/// committed writes keeps it equal to the owner on the keys it has.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Rows {
    tables: BTreeMap<String, BTreeMap<String, StoredRow>>,
}

impl Rows {
    pub fn get(&self, table: &str, key: &str) -> Option<&StoredRow> {
        self.tables.get(table)?.get(key)
    }

    /// Every row of a table in key order.
    pub fn table(&self, table: &str) -> impl Iterator<Item = &StoredRow> {
        self.tables.get(table).into_iter().flat_map(BTreeMap::values)
    }

    /// Rows of a table ordered by `n` (unordered rows left out).
    pub fn ordered(&self, table: &str) -> Vec<&StoredRow> {
        let mut rows: Vec<&StoredRow> = self.table(table).filter(|r| r.n.is_some()).collect();
        rows.sort_by_key(|r| r.n);
        rows
    }

    /// `{table: {key: {key, n, row}}}`, the shape of the TypeScript `MemoryRows.dump`.
    pub fn dump(&self) -> Value {
        let tables = self.tables.iter().map(|(t, rows)| {
            let rows = rows.iter().map(|(k, r)| (k.clone(), serde_json::json!(r)));
            (t.clone(), Value::Object(rows.collect()))
        });
        Value::Object(tables.collect())
    }

    pub fn apply(&mut self, writes: &[RowWrite]) {
        for w in writes {
            match w {
                RowWrite::Upsert { table, key, n, row } => {
                    let t = self.tables.entry(table.clone()).or_default();
                    let stored = StoredRow { key: key.clone(), n: *n, row: row.clone() };
                    t.insert(key.clone(), stored);
                }
                RowWrite::Delete { table, key } => {
                    // The TypeScript mirror keeps an emptied table; so does this one.
                    self.tables.entry(table.clone()).or_default().remove(key);
                }
            }
        }
    }

    fn load(&mut self, table: &str, rows: &[StoredRow]) {
        // Like the TypeScript mirror, an empty page creates no table.
        for r in rows {
            self.tables.entry(table.to_owned()).or_default().insert(r.key.clone(), r.clone());
        }
    }

    fn clear(&mut self) {
        self.tables.clear();
    }
}

/// Replays an op that came without effects (JSON-mode owners). The default
/// answers nothing, which makes the mirror resync from a snapshot.
pub trait Reducer {
    fn apply(
        &self,
        _state: &Value,
        _rows: &Rows,
        _event: &EventFrame,
    ) -> Option<(Value, Vec<RowWrite>)> {
        None
    }
}

/// The reducer of an effects-only mirror.
#[derive(Debug, Clone, Copy, Default)]
pub struct EffectsOnly;

impl Reducer for EffectsOnly {}

/// One stream's mirror and intent log.
#[derive(Debug, Clone)]
pub struct StreamMirror<R: Reducer = EffectsOnly> {
    reducer: R,
    key_prefix: String,
    counter: u64,
    state: Value,
    seq: u64,
    rows: Rows,
    pending: Vec<Intent>,
    expired: Vec<Intent>,
    held: Vec<SettledFrame>,
    buffered: Vec<EventFrame>,
    settled_ok: BTreeSet<String>,
    issued_at: HashMap<String, i64>,
    connected: bool,
    awaiting: bool,
    desyncs: u64,
}

impl StreamMirror<EffectsOnly> {
    /// An effects-only mirror. `key_prefix` must be unique per client and
    /// stable across restarts of the intent log (install id + a random part).
    pub fn new(key_prefix: impl Into<String>, initial: Value) -> Self {
        Self::with_reducer(EffectsOnly, key_prefix, initial)
    }
}

impl<R: Reducer> StreamMirror<R> {
    pub fn with_reducer(reducer: R, key_prefix: impl Into<String>, initial: Value) -> Self {
        Self {
            reducer,
            key_prefix: key_prefix.into(),
            counter: 0,
            state: initial,
            seq: 0,
            rows: Rows::default(),
            pending: Vec::new(),
            expired: Vec::new(),
            held: Vec::new(),
            buffered: Vec::new(),
            settled_ok: BTreeSet::new(),
            issued_at: HashMap::new(),
            connected: true,
            awaiting: false,
            desyncs: 0,
        }
    }

    pub fn state(&self) -> &Value {
        &self.state
    }
    pub fn seq(&self) -> u64 {
        self.seq
    }
    pub fn rows(&self) -> &Rows {
        &self.rows
    }
    /// Intents not decided yet, in issue order: render them as pending.
    pub fn pending(&self) -> &[Intent] {
        &self.pending
    }
    /// Intents that outlived the TTL undecided: show them as not sent.
    pub fn expired(&self) -> &[Intent] {
        &self.expired
    }
    /// Keys of ok settles waiting for the mirror to reach their sequence.
    pub fn held_keys(&self) -> impl Iterator<Item = &str> {
        self.held.iter().map(|h| h.idempotency_key.as_str())
    }
    pub fn settled_ok(&self) -> &BTreeSet<String> {
        &self.settled_ok
    }
    pub fn is_connected(&self) -> bool {
        self.connected
    }
    /// True while a snapshot is requested and events are buffered.
    pub fn is_awaiting_snapshot(&self) -> bool {
        self.awaiting
    }
    pub fn desyncs(&self) -> u64 {
        self.desyncs
    }

    /// Issues a typed intent with the next key of this client. Offline: refused.
    pub fn issue(
        &mut self,
        op: &str,
        params: Value,
        origin: Origin,
        now: i64,
    ) -> Result<(String, Vec<ClientOut>), OwnerUnreachable> {
        if !self.connected {
            return Err(OwnerUnreachable);
        }
        self.counter += 1;
        let key = format!("{}:{}", self.key_prefix, self.counter);
        let intent = Intent { idempotency_key: key.clone(), op: op.to_owned(), params, origin };
        let out = vec![intent.frame()];
        self.pending.push(intent);
        self.issued_at.insert(key.clone(), now);
        Ok((key, out))
    }

    /// Timeout resend of one pending intent with the same key.
    pub fn retry(&mut self, key: &str, now: i64) -> Vec<ClientOut> {
        self.expire_stale(now);
        match self.pending.iter().find(|i| i.idempotency_key == key) {
            Some(i) if self.connected => vec![i.frame()],
            _ => Vec::new(),
        }
    }

    pub fn receive(&mut self, frame: OwnerFrame) -> Vec<ClientOut> {
        let mut out = Vec::new();
        if !self.connected {
            return out;
        }
        match frame {
            OwnerFrame::Event(e) => self.on_event(*e, &mut out),
            OwnerFrame::Settled(s) => self.on_settled(s),
            OwnerFrame::Snapshot(s) => self.on_snapshot(s, &mut out),
            // Result and reject carry the value; the settle decides the log.
            OwnerFrame::Result(_) | OwnerFrame::Reject(_) | OwnerFrame::Other(_) => {}
        }
        out
    }

    pub fn disconnect(&mut self) {
        self.connected = false;
        self.awaiting = false;
        self.buffered.clear();
    }

    /// Resends every pending intent with its key, then asks for a snapshot.
    pub fn reconnect(&mut self, now: i64) -> Vec<ClientOut> {
        self.connected = true;
        self.expire_stale(now);
        let mut out: Vec<ClientOut> = self.pending.iter().map(Intent::frame).collect();
        self.request_snapshot(&mut out);
        out
    }

    /// Moves intents older than [`INTENT_TTL_MS`] from `pending` to `expired`.
    pub fn expire_stale(&mut self, now: i64) {
        let cutoff = now - INTENT_TTL_MS;
        let mut keep = Vec::with_capacity(self.pending.len());
        for i in std::mem::take(&mut self.pending) {
            match self.issued_at.get(&i.idempotency_key).copied() {
                None => {
                    self.issued_at.insert(i.idempotency_key.clone(), now);
                    keep.push(i);
                }
                Some(at) if at < cutoff => {
                    self.issued_at.remove(&i.idempotency_key);
                    self.expired.push(i);
                }
                Some(_) => keep.push(i),
            }
        }
        self.pending = keep;
    }

    fn request_snapshot(&mut self, out: &mut Vec<ClientOut>) {
        self.awaiting = true;
        // Expired keys are asked about (a query, never a resend) so a decided one leaves `expired`.
        let pending =
            self.pending.iter().chain(&self.expired).map(|i| i.idempotency_key.clone()).collect();
        out.push(ClientOut::SnapshotRequest { pending });
    }

    fn on_event(&mut self, e: EventFrame, out: &mut Vec<ClientOut>) {
        if self.awaiting {
            self.buffered.push(e);
            return;
        }
        if e.seq == self.seq + 1 {
            self.apply_event(e, out);
            if !self.awaiting {
                self.flush_held();
            }
        } else if e.seq > self.seq + 1 {
            self.buffered.push(e);
            self.request_snapshot(out);
        }
    }

    fn apply_event(&mut self, e: EventFrame, out: &mut Vec<ClientOut>) {
        if let Some(effects) = &e.effects {
            self.rows.apply(&effects.writes);
            self.state = effects.state.clone();
            self.seq = e.seq;
            return;
        }
        match self.reducer.apply(&self.state, &self.rows, &e) {
            Some((state, writes)) => {
                self.rows.apply(&writes);
                self.state = state;
                self.seq = e.seq;
            }
            // Version skew or no reducer for this domain: resync instead of diverging.
            None => {
                self.desyncs += 1;
                self.request_snapshot(out);
            }
        }
    }

    fn on_settled(&mut self, s: SettledFrame) {
        if !s.ok || self.seq >= s.sequence {
            self.settle(&s.idempotency_key, s.ok);
        } else {
            self.held.push(s);
        }
    }

    fn settle(&mut self, key: &str, ok: bool) {
        self.pending.retain(|i| i.idempotency_key != key);
        self.expired.retain(|i| i.idempotency_key != key);
        self.issued_at.remove(key);
        if ok {
            self.settled_ok.insert(key.to_owned());
        }
    }

    fn flush_held(&mut self) {
        let seq = self.seq;
        let (ready, wait): (Vec<_>, Vec<_>) =
            std::mem::take(&mut self.held).into_iter().partition(|h| seq >= h.sequence);
        self.held = wait;
        for h in ready {
            self.settle(&h.idempotency_key, h.ok);
        }
    }

    fn on_snapshot(&mut self, snap: SnapshotFrame, out: &mut Vec<ClientOut>) {
        self.awaiting = false;
        if snap.seq >= self.seq {
            self.state = snap.state;
            self.seq = snap.seq;
            // Rows held from before may be stale; keep only what the snapshot sends.
            if let Some(rows) = &snap.rows {
                self.rows.clear();
                self.rows.load(&rows.table, &rows.rows);
            }
            for d in &snap.decided {
                self.pending.retain(|i| i.idempotency_key != d.idempotency_key);
                self.expired.retain(|i| i.idempotency_key != d.idempotency_key);
                self.issued_at.remove(&d.idempotency_key);
                if d.ok {
                    self.settled_ok.insert(d.idempotency_key.clone());
                }
            }
        }
        let mut later = std::mem::take(&mut self.buffered);
        later.sort_by_key(|e| e.seq);
        for e in later {
            self.on_event(e, out);
        }
        self.flush_held();
    }
}
