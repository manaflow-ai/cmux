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
//! - A snapshot that does not decode keeps the mirror waiting (events stay
//!   buffered) and is asked for again after a backoff ([`SnapshotBackoff`]).
//!   After the last attempt the caller drops the connection; the next one
//!   resumes, so a stream is never stuck on a snapshot it cannot read.
//!
//! A relay (the daemon proxy) keeps no rows ([`StreamMirror::without_rows`]),
//! moves its position on events without effects ([`PositionOnly`]), resumes
//! a new connection with [`StreamMirror::resume`] and translates what
//! [`StreamMirror::receive_applied`] reports.

use crate::Origin;
use crate::frames::{
    ClientOut, EventFrame, OpFrame, OwnerFrame, RowWrite, SettledFrame, SnapshotFrame, StoredRow,
};
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet, HashMap};

/// Longest a client keeps a pending intent (24 h). Owners forget decided
/// keys after 7 days, so a resend can never reach an owner that pruned it.
pub const INTENT_TTL_MS: i64 = 24 * 3600 * 1000;

/// Most events a mirror buffers while it waits for a snapshot. Past it the
/// buffer is dropped: the snapshot, or the gap the next event opens, covers
/// them, and a snapshot that never comes cannot grow the buffer forever.
pub const MAX_BUFFERED_EVENTS: usize = 1024;

/// How a mirror asks again for a snapshot that did not decode: after
/// `first_ms`, then twice as long each time up to `max_ms`, at most
/// `attempts` times before it gives the connection up
/// ([`SnapshotRetry::Exhausted`]).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SnapshotBackoff {
    pub first_ms: i64,
    pub max_ms: i64,
    pub attempts: u32,
}

impl Default for SnapshotBackoff {
    fn default() -> Self {
        Self { first_ms: 250, max_ms: 30_000, attempts: 6 }
    }
}

impl SnapshotBackoff {
    /// The wait before attempt `n` (1-based).
    fn delay(&self, n: u32) -> i64 {
        let doublings = n.saturating_sub(1).min(32);
        self.first_ms.max(0).saturating_mul(1_i64 << doublings).min(self.max_ms.max(0))
    }
}

/// What the mirror does about a snapshot that did not decode.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SnapshotRetry {
    /// It asks again at this time (ms): call
    /// [`StreamMirror::snapshot_retry_due`] then and send its frames.
    At(i64),
    /// Every attempt failed: drop the connection. The next connection
    /// resumes ([`StreamMirror::resume`]); the failures count on, so each
    /// later connection that still gets an unreadable snapshot gives up at
    /// once and the transport's own reconnect backoff paces it.
    Exhausted,
}

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
                // Callers check `known_writes` first; an unknown write never applies.
                RowWrite::Unknown => {}
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
/// answers nothing, which makes the mirror resync from a snapshot. A real
/// reducer must build the owner's context from the event exactly as the
/// owner did: `now = at`, `principal = actor`, ids from the TypeScript
/// `idFactory(tx)`; new owners use effects mode so mirrors need none.
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

/// The reducer of a relay that keeps only the head and the position: an
/// event without effects (an ack the owner wrote no rows for) moves the
/// position and keeps the head. The relay's clients interpret the frames.
#[derive(Debug, Clone, Copy, Default)]
pub struct PositionOnly;

impl Reducer for PositionOnly {
    fn apply(&self, state: &Value, _: &Rows, _: &EventFrame) -> Option<(Value, Vec<RowWrite>)> {
        Some((state.clone(), Vec::new()))
    }
}

/// A frame the mirror applied, in apply order (buffered events replay after
/// their snapshot). A relay turns these into its own events; a view reads
/// the mirror instead.
#[derive(Debug, Clone, PartialEq)]
pub enum Applied {
    Snapshot(Box<SnapshotFrame>),
    Event(Box<EventFrame>),
}

/// What one owner frame did: frames to send, frames applied and, for a
/// snapshot that did not decode, when it is asked for again.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Received {
    pub send: Vec<ClientOut>,
    pub applied: Vec<Applied>,
    pub snapshot_retry: Option<SnapshotRetry>,
}

/// How to subscribe on a new connection (see [`StreamMirror::resume`]).
#[derive(Debug, Clone, PartialEq)]
pub struct Resume {
    /// `subscribe {after_seq}` when the mirror holds a confirmed position;
    /// `None`: subscribe fresh, the owner answers a snapshot.
    pub after_seq: Option<u64>,
    /// The keys to report in the subscribe's `pending` (pending and expired
    /// intents). When it is not empty the owner answers with a snapshot whose
    /// `decided` settles them instead of replaying the gap.
    pub pending: Vec<String>,
    /// Pending intents to resend with their keys (after the subscribe).
    pub send: Vec<ClientOut>,
}

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
    /// A snapshot or an event was applied since creation or [`StreamMirror::reset`].
    positioned: bool,
    /// A resume went out and nothing answered it yet: the owner's answer may
    /// be a snapshot behind the position (a reset or recreated owner), which
    /// then replaces it.
    resumed: bool,
    /// False for a relay that keeps only the head and the position.
    track_rows: bool,
    applied: Vec<Applied>,
    backoff: SnapshotBackoff,
    /// Snapshots in a row that did not decode; 0 after one that did.
    snapshot_failures: u32,
    /// When the next snapshot request goes out after a failed snapshot.
    snapshot_retry_at: Option<i64>,
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
            positioned: false,
            resumed: false,
            track_rows: true,
            applied: Vec::new(),
            backoff: SnapshotBackoff::default(),
            snapshot_failures: 0,
            snapshot_retry_at: None,
        }
    }

    /// Replaces the default [`SnapshotBackoff`].
    pub fn with_snapshot_backoff(mut self, backoff: SnapshotBackoff) -> Self {
        self.backoff = backoff;
        self
    }

    /// Keeps no rows (a relay such as the daemon proxy, whose clients hold the
    /// rows): the head state, the position and the intent log only, so memory
    /// does not grow with the stream.
    pub fn without_rows(mut self) -> Self {
        self.track_rows = false;
        self.rows.clear();
        self
    }

    /// The seq to resume from, when the mirror holds a confirmed position.
    pub fn resume_seq(&self) -> Option<u64> {
        self.positioned.then_some(self.seq)
    }

    /// Forgets everything, intents included: the connection now belongs to
    /// another principal, whose stream must start from a snapshot.
    /// The key counter survives, so no key is ever issued twice.
    pub fn reset(&mut self, initial: Value) {
        self.state = initial;
        self.seq = 0;
        self.rows.clear();
        self.pending.clear();
        self.expired.clear();
        self.held.clear();
        self.buffered.clear();
        self.settled_ok.clear();
        self.issued_at.clear();
        self.awaiting = false;
        self.positioned = false;
        self.resumed = false;
        self.applied.clear();
        self.snapshot_failures = 0;
        self.snapshot_retry_at = None;
    }

    /// A new connection is open and subscribes (the daemon proxy's path; a
    /// client with an open position may use [`StreamMirror::reconnect`]
    /// instead). With a position the subscribe resumes after it and the
    /// owner replays the events after it. Without one the owner answers
    /// with a snapshot: events buffer until it comes, so none is lost.
    pub fn resume(&mut self, now: i64) -> Resume {
        self.connected = true;
        self.buffered.clear();
        self.expire_stale(now);
        let after_seq = self.resume_seq();
        self.awaiting = after_seq.is_none();
        self.resumed = after_seq.is_some();
        // The subscribe is the new ask: the owner answers it.
        self.snapshot_retry_at = None;
        Resume {
            after_seq,
            pending: self.reported_keys(),
            send: self.pending.iter().map(Intent::frame).collect(),
        }
    }

    /// Asks for a snapshot unless one is already asked for: the caller could
    /// not use an applied frame (a relay whose translation failed).
    pub fn resync(&mut self) -> Vec<ClientOut> {
        let mut out = Vec::new();
        if !self.awaiting {
            self.desyncs += 1;
            self.request_snapshot(&mut out);
        }
        out
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
    /// Keys settled ok since the last [`StreamMirror::take_settled_ok`].
    pub fn settled_ok(&self) -> &BTreeSet<String> {
        &self.settled_ok
    }
    /// Hands the settled keys to the caller and forgets them, so a long-lived
    /// mirror does not grow (the TypeScript client keeps them for invariant checks).
    pub fn take_settled_ok(&mut self) -> BTreeSet<String> {
        std::mem::take(&mut self.settled_ok)
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
    /// Snapshots in a row that did not decode (0: the last one did).
    pub fn snapshot_failures(&self) -> u32 {
        self.snapshot_failures
    }
    /// When the next snapshot request is due after a failed snapshot (ms).
    pub fn snapshot_retry_at(&self) -> Option<i64> {
        self.snapshot_retry_at
    }

    /// A snapshot of this stream did not decode (or the caller could not
    /// use it). The mirror keeps waiting, so events stay buffered, and says
    /// when it asks again.
    pub fn snapshot_failed(&mut self, now: i64) -> SnapshotRetry {
        self.desyncs += 1;
        self.awaiting = true;
        self.snapshot_failures = self.snapshot_failures.saturating_add(1);
        if self.snapshot_failures > self.backoff.attempts {
            self.snapshot_retry_at = None;
            return SnapshotRetry::Exhausted;
        }
        let at = now.saturating_add(self.backoff.delay(self.snapshot_failures));
        self.snapshot_retry_at = Some(at);
        SnapshotRetry::At(at)
    }

    /// The snapshot request of a failed snapshot, once its time came.
    pub fn snapshot_retry_due(&mut self, now: i64) -> Vec<ClientOut> {
        let mut out = Vec::new();
        if self.connected && self.snapshot_retry_at.is_some_and(|at| now >= at) {
            self.snapshot_retry_at = None;
            self.request_snapshot(&mut out);
        }
        out
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

    /// Applies one owner frame. The caller routes frames by `stream`: one
    /// mirror per stream, and only that stream's frames reach it.
    pub fn receive(&mut self, frame: OwnerFrame) -> Vec<ClientOut> {
        self.receive_applied(frame).send
    }

    /// One owner frame as JSON, as the socket carries it. A known frame that
    /// does not decode is handled here: an event asks for a snapshot, a
    /// snapshot is asked for again after the backoff
    /// ([`Received::snapshot_retry`]). Any other frame that does not decode
    /// is ignored.
    pub fn receive_value(&mut self, frame: Value, now: i64) -> Received {
        let kind = frame.get("t").and_then(Value::as_str).unwrap_or_default().to_owned();
        match OwnerFrame::from_value(frame) {
            Ok(frame) => self.receive_applied(frame),
            Err(_) if !self.connected => Received::default(),
            Err(_) if kind == "event" => Received { send: self.resync(), ..Received::default() },
            Err(_) if kind == "snapshot" => {
                Received { snapshot_retry: Some(self.snapshot_failed(now)), ..Received::default() }
            }
            Err(_) => Received::default(),
        }
    }

    /// [`StreamMirror::receive`], also returning the frames it applied in
    /// order: a gap's buffered events come after the snapshot that closed it.
    pub fn receive_applied(&mut self, frame: OwnerFrame) -> Received {
        let mut out = Vec::new();
        self.applied.clear();
        if self.connected {
            match frame {
                OwnerFrame::Event(e) => self.on_event(*e, &mut out),
                OwnerFrame::Settled(s) => self.on_settled(s),
                OwnerFrame::Snapshot(s) => self.on_snapshot(s, &mut out),
                // Result and reject carry the value; the settle decides the log.
                OwnerFrame::Result(_) | OwnerFrame::Reject(_) | OwnerFrame::Other(_) => {}
            }
        }
        Received { send: out, applied: std::mem::take(&mut self.applied), snapshot_retry: None }
    }

    pub fn disconnect(&mut self) {
        self.connected = false;
        self.awaiting = false;
        self.buffered.clear();
        self.snapshot_retry_at = None;
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

    /// Pending and expired keys: expired ones are asked about (a query, never
    /// a resend) so a decided one leaves `expired`.
    fn reported_keys(&self) -> Vec<String> {
        self.pending.iter().chain(&self.expired).map(|i| i.idempotency_key.clone()).collect()
    }

    fn request_snapshot(&mut self, out: &mut Vec<ClientOut>) {
        self.awaiting = true;
        let pending = self.reported_keys();
        out.push(ClientOut::SnapshotRequest { pending });
    }

    fn buffer(&mut self, e: EventFrame) {
        if self.buffered.len() >= MAX_BUFFERED_EVENTS {
            self.buffered.clear();
        }
        self.buffered.push(e);
    }

    fn on_event(&mut self, e: EventFrame, out: &mut Vec<ClientOut>) {
        if self.awaiting {
            self.buffer(e);
            return;
        }
        if e.seq == self.seq + 1 {
            self.apply_event(e, out);
            if !self.awaiting {
                self.flush_held();
            }
        } else if e.seq > self.seq + 1 {
            self.buffer(e);
            self.request_snapshot(out);
        }
    }

    fn apply_event(&mut self, e: EventFrame, out: &mut Vec<ClientOut>) {
        if let Some(effects) = &e.effects {
            // A write kind from a newer owner: never apply part of an op; resync instead.
            if effects.writes.iter().any(|w| matches!(w, RowWrite::Unknown)) {
                self.desyncs += 1;
                self.request_snapshot(out);
                return;
            }
            if self.track_rows {
                self.rows.apply(&effects.writes);
            }
            self.state = effects.state.clone();
            self.applied_event(e);
            return;
        }
        match self.reducer.apply(&self.state, &self.rows, &e) {
            Some((state, writes)) => {
                if self.track_rows {
                    self.rows.apply(&writes);
                }
                self.state = state;
                self.applied_event(e);
            }
            // Version skew or no reducer for this domain: resync instead of diverging.
            None => {
                self.desyncs += 1;
                self.request_snapshot(out);
            }
        }
    }

    fn applied_event(&mut self, e: EventFrame) {
        self.seq = e.seq;
        self.positioned = true;
        self.resumed = false;
        self.applied.push(Applied::Event(Box::new(e)));
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
        self.snapshot_failures = 0;
        self.snapshot_retry_at = None;
        let behind = snap.seq < self.seq;
        // A snapshot behind the position answers only a resume (the owner
        // lost its tail): it replaces the position. Any other one is stale.
        if !behind || std::mem::take(&mut self.resumed) {
            self.resumed = false;
            self.state = snap.state.clone();
            self.seq = snap.seq;
            self.positioned = true;
            // Rows held from before may be stale; keep only what the snapshot sends.
            if self.track_rows && (behind || snap.rows.is_some()) {
                self.rows.clear();
            }
            if let (Some(rows), true) = (&snap.rows, self.track_rows) {
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
            self.applied.push(Applied::Snapshot(Box::new(snap)));
        }
        let mut later = std::mem::take(&mut self.buffered);
        later.sort_by_key(|e| e.seq);
        for e in later {
            self.on_event(e, out);
        }
        self.flush_held();
    }
}
