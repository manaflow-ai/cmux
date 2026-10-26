//! Part of `Hub`; see `hub/mod.rs`. A durable local copy of each peer session's events, so a
//! client paints a paused or offline peer's chat at once, marked possibly stale, then catches up
//! from the peer with `afterSeq` (cmuxterm-hq#4381; Lawrence: "decouple persistence of acp
//! trajectories from the VM itself, in case the VM is resuming"). The peer's journal stays the
//! authority: this is what this daemon saw of it (its clients' pages, the peer's live records),
//! never a write lease, an execution checkpoint or a backup. The files are `disk.rs`'s.
//!
//! Bounds: past [`SESSION_EVENTS`] or [`SESSION_BYTES`] the segment of a session's oldest records
//! goes; past [`TOTAL_BYTES`] (disk and memory) the least recently captured session goes;
//! unwritten records keep one session's bound each and [`PENDING_BYTES`] in all. A failed write
//! stays in memory and is tried again, 1 s doubling to 60 s (`daemon/persist_retry.rs`), never an
//! exit. A removal queues its path (`State::doom`) and does the file work at once under the `disk`
//! lock (`sweep`), unlinking `meta.json` first; one the filesystem refuses stays queued and is
//! tried again before every write; no copy is written under a path still queued, and while
//! [`DOOMED_KEPT`] wait no new copy is started. A peer's full session list drops the copies of
//! sessions it does not list (`retain_peer`), so what a crash left before its removal goes too.
//!
//! The generation is the session's `createdAt`. A row naming another one, or a page whose
//! `lastSeq` is below this copy's from any link but the one that last paged it (a recreated
//! session, a VM back on an older disk, this daemon restarted), drops the copy instead of merging
//! two journals; a live record on a link no page has checked yet is not kept. The link is the one
//! the record or page came on (`PeerNotice::Notification`'s `link`, an epoch read before the
//! forwarded request), never one read later. A purged session is not captured again in this run. A leased peer (a Cloud VM) is kept too: what a lease must not
//! leave behind is its URL, port and tokens, none of which is here.

use super::*;
use std::collections::{BTreeMap, VecDeque};
use std::sync::Arc;
use std::sync::Mutex as StdMutex;
use std::time::Duration;

mod disk;
use disk::{Kept, Key, Meta, SEGMENT_BYTES, Segment, Writer, blocking, record_bytes, seq_of};
pub(crate) use disk::{SESSION_BYTES, SESSION_EVENTS};

/// Bytes every peer session keeps together, on disk and in memory.
pub(crate) const TOTAL_BYTES: u64 = if cfg!(test) { 40 << 10 } else { 64 << 20 };
/// Bytes of records not yet written, every session together (a full disk).
const PENDING_BYTES: u64 = if cfg!(test) { 24 << 10 } else { 16 << 20 };
/// How long new records wait before their write, so a streaming turn
/// writes every few seconds, not on every token.
const FLUSH_AFTER: Duration = Duration::from_millis(if cfg!(test) { 10 } else { 2000 });
const RETRY_FIRST: Duration = Duration::from_millis(if cfg!(test) { 10 } else { 1000 });
const RETRY_MAX: Duration = Duration::from_secs(60);
/// Purged sessions this run remembers, so a capture already under way never brings one back. A
/// later one cannot: every capture needs the session listed (`resolve_remote`, a live record's
/// row), and a purge unlists it first; so a key that ages out of this list loses nothing. And how
/// many refused removals stop new copies.
const GONE_KEPT: usize = 4096;
const DOOMED_KEPT: usize = 256;
/// Row fields a snapshot never repeats: a countdown (`retry.nextAt`) from a
/// peer that is not answering may already have fired.
const VOLATILE_ROW_FIELDS: &[&str] = &["retry"];

#[derive(Default)]
struct Snap {
    /// Which copy this is: a write that finds another under its key (this
    /// one was dropped meanwhile) keeps nothing.
    id: u64,
    meta: Meta,
    /// `meta.json`'s size as last written or read, and the row's in memory.
    meta_bytes: u64,
    row_bytes: u64,
    /// `meta` changed since it was last written.
    dirty: bool,
    segments: Vec<Segment>,
    loaded: bool,
    pending: BTreeMap<u64, Value>,
    pending_bytes: u64,
    /// A write task is pending; `ticket` names the one that may run (`schedule`).
    scheduled: bool,
    ticket: u64,
    /// The peer link's epoch (`Peer::link_epoch`) a page last came on, None before any in this
    /// run: on it, a page naming an older `lastSeq` only raced a live record.
    epoch: Option<u64>,
    retry: Option<Duration>,
    failures: u64,
    /// Segments past the bound, removed once `meta.json` is written without them.
    gone: Vec<(PathBuf, u64)>,
}

impl Snap {
    /// A new copy, with an id of its own.
    fn fresh() -> Self {
        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);
        Self { id: NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed), ..Self::default() }
    }
    fn kept(k: Kept) -> Self {
        let Kept { meta, meta_bytes, segments } = k;
        Self { meta, meta_bytes, segments, ..Self::fresh() }
    }
    /// What the copy's live segments and `meta.json` hold: its own bound.
    fn live_bytes(&self) -> u64 {
        self.segments.iter().map(|s| s.bytes).sum::<u64>() + self.meta_bytes.max(self.row_bytes)
    }
    /// What it holds on disk, segments pruned but not removed yet included.
    fn disk_bytes(&self) -> u64 {
        self.live_bytes() + self.gone.iter().map(|(_, b)| b).sum::<u64>()
    }
    /// What it holds, on disk and in memory.
    fn held_bytes(&self) -> u64 {
        self.disk_bytes() + self.pending_bytes
    }
    fn count(&self) -> usize {
        self.segments.iter().map(|s| s.seqs.len()).sum()
    }
    fn has(&self, seq: u64) -> bool {
        self.pending.contains_key(&seq) || self.segments.iter().any(|s| s.seqs.contains(&seq))
    }
    fn newest(&self) -> u64 {
        let pending = self.pending.keys().next_back().copied().unwrap_or(0);
        let disk = self.segments.iter().map(Segment::last).max().unwrap_or(0);
        self.meta.last_seq.max(pending).max(disk)
    }
    fn is_empty(&self) -> bool {
        self.segments.is_empty() && self.pending.is_empty()
    }
    /// The session's own bound: the segments of its oldest records go (once `meta.json` is
    /// written without them). Answers whether any went.
    fn prune(&mut self) -> bool {
        let mut pruned = false;
        while self.segments.len() > 1
            && (self.count() > SESSION_EVENTS || self.live_bytes() > SESSION_BYTES)
        {
            let at = (0..self.segments.len()).min_by_key(|i| self.segments[*i].last());
            let old = self.segments.remove(at.unwrap_or(0));
            self.gone.push((old.path, old.bytes));
            self.meta.from_start = false;
            pruned = true;
        }
        pruned
    }
}

#[derive(Default)]
struct State {
    scanned: bool,
    sessions: HashMap<Key, Snap>,
    /// Bytes of every session's unwritten records.
    pending_bytes: u64,
    /// Sessions purged or replaced in this run, oldest first, with the generation that went (None:
    /// not known): no capture of it, or of an older or unknown one, is kept again (`barred`).
    gone: VecDeque<Key>,
    buried: HashMap<Key, Option<u64>>,
    /// Paths waiting for their removal, with the bytes each holds.
    doomed: Vec<(PathBuf, u64)>,
    /// Of those, the bytes of the ones the filesystem already refused once: still on disk.
    refused_bytes: u64,
}

impl State {
    fn bury(&mut self, key: Key, generation: Option<u64>) {
        let was = self.buried.insert(key.clone(), generation);
        match (was, generation) {
            (None, _) => self.gone.push_back(key),
            (Some(Some(a)), Some(b)) => drop(self.buried.insert(key, Some(a.max(b)))),
            _ => {}
        }
        while self.gone.len() > GONE_KEPT {
            if let Some(old) = self.gone.pop_front() {
                self.buried.remove(&old);
            }
        }
    }
    /// A capture of `key` naming `generation` is of a session that went: the one buried, an older
    /// one, or one it cannot tell (a tombstone of an unknown generation bars all until a list).
    fn barred(&self, key: &Key, generation: Option<u64>) -> bool {
        match self.buried.get(key) {
            None => false,
            Some(None) => true,
            Some(Some(gone)) => generation.is_none_or(|g| g <= *gone),
        }
    }
    fn take(&mut self, key: &Key) -> Option<Snap> {
        let snap = self.sessions.remove(key)?;
        self.pending_bytes = self.pending_bytes.saturating_sub(snap.pending_bytes);
        Some(snap)
    }
    /// Queues `path` for removal (`PeerSnapshots::sweep`); no file work here. Never dropped: past
    /// [`DOOMED_KEPT`] no new copy starts (`capture`), so the queue only holds what is on disk.
    fn doom(&mut self, path: PathBuf, bytes: u64) {
        if !self.doomed.iter().any(|(p, _)| *p == path) {
            self.doomed.push((path, bytes));
        }
    }
    /// The removal of `path` was refused: queued again, its bytes counted until it goes.
    fn refuse(&mut self, path: PathBuf, bytes: u64) {
        self.refused_bytes += bytes;
        self.doom(path, bytes);
    }
    /// Whether a path under `dir` (or `dir` itself, or a parent) waits for its removal.
    fn blocks(&self, dir: &Path) -> bool {
        self.doomed.iter().any(|(p, _)| dir.starts_with(p) || p.starts_with(dir))
    }
    /// What every copy holds, and what refused removals still hold on disk.
    fn total_bytes(&self) -> u64 {
        self.sessions.values().map(Snap::held_bytes).sum::<u64>() + self.refused_bytes
    }
}

struct Inner {
    dir: Option<PathBuf>,
    state: StdMutex<State>,
    /// Held across every disk change (a write, an eviction, a removal); taken
    /// before `state`, never after.
    disk: StdMutex<()>,
    write: Writer,
}

/// The store; a clone shares it.
#[derive(Clone)]
pub struct PeerSnapshots(Arc<Inner>);

/// What one page or live record says of a peer session.
pub(crate) struct Capture<'a> {
    /// The peer link's epoch (`Peer::link_epoch`).
    pub epoch: u64,
    /// The session's `createdAt`, when known.
    pub generation: Option<u64>,
    /// The peer's own last seq: a page names it, a live record does not.
    pub host_last_seq: Option<u64>,
    /// Nothing older of the page's kinds exists.
    pub from_start: bool,
    /// The session's row, from a page (a live record copies none).
    pub row: Option<Value>,
    pub records: &'a [Value],
}

/// What a flush leaves to do.
#[derive(Debug, PartialEq)]
enum Next {
    Done,
    /// More than one segment holds, or a change that came meanwhile: the next write goes at once.
    More,
    /// The write failed: try again after this.
    Retry(Duration),
}

/// A row as a snapshot repeats it: last-known, never a countdown.
fn snapshot_row(mut row: Value) -> Value {
    if let Some(obj) = row.as_object_mut() {
        for f in VOLATILE_ROW_FIELDS {
            obj.remove(*f);
        }
        obj.insert("stale".into(), Value::Bool(true));
    }
    row
}

fn lock<T>(m: &StdMutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

impl PeerSnapshots {
    /// A store under `dir` (`peers/` beside `sessions/`); None keeps nothing.
    pub fn open(dir: Option<PathBuf>) -> Self {
        Self::with_writer(dir, crate::config::write_atomic)
    }

    fn with_writer(dir: Option<PathBuf>, write: Writer) -> Self {
        let state = StdMutex::new(State::default());
        Self(Arc::new(Inner { dir, state, disk: StdMutex::new(()), write }))
    }

    fn session_dir(&self, key: &Key) -> Option<PathBuf> {
        let dir = self.0.dir.as_ref()?;
        crate::session_name::validate(&key.0).ok()?;
        disk::valid_mux_id(&key.1).then(|| dir.join(&key.0).join(&key.1))
    }

    /// Lists what an earlier run kept, once, under the `disk` lock; removes what is not a copy;
    /// keeps the total bound.
    fn scan(&self) {
        if lock(&self.0.state).scanned {
            return;
        }
        let _disk = lock(&self.0.disk);
        if lock(&self.0.state).scanned {
            return;
        }
        let found = self.0.dir.as_ref().map(|dir| blocking(|| disk::scan(dir)));
        let mut state = lock(&self.0.state);
        state.scanned = true;
        let (kept, stray) = found.unwrap_or_default();
        for (path, bytes) in stray {
            state.doom(path, bytes);
        }
        for (key, k) in kept {
            state.sessions.entry(key).or_insert_with(|| Snap::kept(k));
        }
        self.evict_total(&mut state, None);
        drop(state);
        self.sweep_locked();
    }

    /// Drops `key`'s copy and queues its files' removal; the caller sweeps after.
    fn discard(&self, state: &mut State, key: &Key) {
        let bytes = state.take(key).map_or(0, |s| s.disk_bytes());
        if let Some(dir) = self.session_dir(key) {
            state.doom(dir, bytes);
        }
    }

    /// Removes the paths queued for removal; `disk` is held. One the filesystem refuses is logged
    /// and stays queued for the next sweep.
    fn sweep_locked(&self) {
        let doomed = {
            let mut state = lock(&self.0.state);
            state.refused_bytes = 0;
            std::mem::take(&mut state.doomed)
        };
        if doomed.is_empty() {
            return;
        }
        let Some(root) = self.0.dir.as_ref() else { return };
        let refused: Vec<(PathBuf, u64)> = blocking(|| {
            let refused = doomed.into_iter().filter_map(|(path, bytes)| {
                let (left, e) = disk::remove(root, &path).err()?;
                tracing::warn!(path = %left.display(), "could not remove a peer snapshot (tried again at the next write or removal): {e}");
                Some((left, bytes))
            });
            refused.collect()
        });
        let mut state = lock(&self.0.state);
        for (path, bytes) in refused {
            state.refuse(path, bytes);
        }
    }

    /// Sweeps now, before the caller goes on (`blocking`); never with `state` held.
    fn sweep(&self) {
        let _disk = lock(&self.0.disk);
        self.sweep_locked();
    }

    /// Keeps `c.records` (`_acpmux/event` values) of peer `peer`'s session `mux`.
    pub(crate) fn capture(&self, peer: &str, mux: &str, c: Capture<'_>) {
        let key = (peer.to_owned(), mux.to_owned());
        if self.session_dir(&key).is_none() {
            return;
        }
        self.scan();
        let mut state = lock(&self.0.state);
        // A copy this capture does not continue is removed from disk before this one is kept;
        // each pass rechecks from the top, as a purge or another capture may land meanwhile.
        for pass in 0.. {
            if pass == 3 || state.barred(&key, c.generation) {
                return;
            }
            if !state.sessions.contains_key(&key) && state.doomed.len() >= DOOMED_KEPT {
                tracing::debug!(
                    peer,
                    session = mux,
                    "peer snapshot removals are refused: no new copy"
                );
                return;
            }
            let snap = state.sessions.entry(key.clone()).or_insert_with(Snap::fresh);
            if !snap.loaded {
                // A read under `state`: a write renames whole files in, so it sees one or the
                // other.
                if let Err(e) = blocking(|| disk::load(&mut snap.segments)) {
                    tracing::warn!(
                        peer,
                        session = mux,
                        "could not read a peer snapshot, so it is dropped: {e:#}"
                    );
                    self.discard(&mut state, &key);
                    drop(state);
                    return self.sweep();
                }
                snap.loaded = true;
                // A copy past its bound (another build's): its oldest segments go at the next
                // write.
                snap.dirty |= snap.prune();
            }
            // A copy is only ever continued by its own generation: a capture of an older one (a
            // reply that was slow to come) or of none it can tell is not kept; a newer one, or a
            // known one over a copy of an unknown one, replaces it.
            let newer = match (snap.meta.generation, c.generation) {
                (Some(a), Some(b)) if b < a => return,
                (Some(_), None) => return,
                (Some(a), Some(b)) => b > a,
                (None, Some(_)) => !snap.is_empty(),
                (None, None) => false,
            };
            // From any link but the one that last paged it (another one, or none: this daemon
            // restarted), a journal behind the copy is not the copy's journal.
            let journal_behind =
                c.host_last_seq.is_some_and(|h| h < snap.newest()) && snap.epoch != Some(c.epoch);
            if !newer && !journal_behind {
                break;
            }
            if newer && let Some(old) = snap.meta.generation {
                state.bury(key.clone(), Some(old));
            }
            tracing::info!(
                peer,
                session = mux,
                "the peer's session was recreated or restored: its local snapshot is dropped"
            );
            self.discard(&mut state, &key);
            drop(state);
            self.sweep();
            state = lock(&self.0.state);
        }
        let schedule = Self::keep(&mut state, &key, c);
        let empty = state.sessions.get(&key).is_some_and(Snap::is_empty);
        if empty {
            state.take(&key);
        }
        drop(state);
        if schedule && !empty {
            self.schedule(key, FLUSH_AFTER);
        }
    }

    /// `capture`'s part under the state lock: answers whether a write is to be scheduled.
    fn keep(state: &mut State, key: &Key, c: Capture<'_>) -> bool {
        let snap = state
            .sessions
            .entry(key.clone())
            .or_insert_with(|| Snap { loaded: true, ..Snap::fresh() });
        let newest = snap.newest();
        if c.host_last_seq.is_some() || newest == 0 {
            snap.epoch = Some(c.epoch);
        } else if snap.epoch != Some(c.epoch) {
            // A live record on a link no page has checked: its journal may not be the copy's.
            return false;
        }
        let was = (snap.meta.generation, snap.meta.host_last_seq, snap.meta.from_start);
        snap.meta.generation = c.generation.or(snap.meta.generation);
        snap.meta.host_last_seq = snap.meta.host_last_seq.max(c.host_last_seq.unwrap_or(0));
        // A row too big for a segment is not repeated.
        if let Some(row) = c.row.map(snapshot_row).filter(|r| record_bytes(r) <= SEGMENT_BYTES)
            && row != snap.meta.summary
        {
            snap.row_bytes = record_bytes(&row);
            snap.meta.summary = row;
            snap.dirty = true;
        }
        let mut added = false;
        for r in c.records {
            let Some(seq) = seq_of(r) else { continue };
            if snap.has(seq) {
                continue;
            }
            // A record no segment holds is not kept: the peer still serves it.
            let b = record_bytes(r);
            if b > SEGMENT_BYTES || state.pending_bytes + b > PENDING_BYTES {
                snap.meta.from_start = false;
                continue;
            }
            snap.pending_bytes += b;
            state.pending_bytes += b;
            snap.pending.insert(seq, r.clone());
            added = true;
        }
        // A page from the first record that reaches as far as this copy did.
        let page_high = c.records.iter().filter_map(seq_of).max().unwrap_or(0);
        if c.from_start && (newest == 0 || page_high >= newest) {
            snap.meta.from_start = true;
        }
        // While the disk refuses, memory keeps one session's bound at most.
        while snap.pending_bytes > SESSION_BYTES || snap.pending.len() > SESSION_EVENTS {
            let Some((_, v)) = snap.pending.pop_first() else { break };
            let b = record_bytes(&v);
            snap.pending_bytes = snap.pending_bytes.saturating_sub(b);
            state.pending_bytes = state.pending_bytes.saturating_sub(b);
            snap.meta.from_start = false;
        }
        if added {
            snap.meta.captured_at = now_ms();
        }
        let now = (snap.meta.generation, snap.meta.host_last_seq, snap.meta.from_start);
        snap.dirty |= added || was != now;
        snap.dirty && !snap.scheduled
    }

    /// Writes `key`'s copy after `delay`, superseding a write already scheduled (each call takes a
    /// new `ticket`; a task that wakes holding an older one ends), so a session has one write task
    /// at most. Stop condition: the write; one that leaves more (a failure, a batch past a
    /// segment, a change that came meanwhile) schedules one more, after a failure with a doubled
    /// delay of at most a minute; a session dropped meanwhile ends it, and the runtime ends it
    /// with the daemon (`Hub::shutdown_all` writes what is left first). Without a runtime (a
    /// synchronous caller, a test) it writes now; a refused write waits for the next change.
    fn schedule(&self, key: Key, delay: Duration) {
        // The copy and the write: a task of a copy replaced meanwhile, or superseded, ends.
        let ticket = {
            let mut state = lock(&self.0.state);
            let Some(snap) = state.sessions.get_mut(&key) else { return };
            snap.scheduled = true;
            snap.ticket += 1;
            (snap.id, snap.ticket)
        };
        let Ok(rt) = tokio::runtime::Handle::try_current() else {
            self.drain(&key);
            return;
        };
        let me = self.clone();
        rt.spawn(async move {
            tokio::time::sleep(delay).await;
            let current =
                lock(&me.0.state).sessions.get(&key).is_some_and(|s| (s.id, s.ticket) == ticket);
            if !current {
                return;
            }
            let (me2, key2) = (me.clone(), key.clone());
            match tokio::task::spawn_blocking(move || me2.flush(&key2)).await {
                Ok(Next::More) => me.schedule(key, Duration::ZERO),
                Ok(Next::Retry(delay)) => me.schedule(key, delay),
                Ok(Next::Done) | Err(_) => {}
            }
        });
    }

    /// Writes `key`'s copy now, as many segments as it fills. Answers the retry a refused write
    /// left, which it does not wait for.
    fn drain(&self, key: &Key) -> Option<Duration> {
        loop {
            match self.flush(key) {
                Next::More => continue,
                Next::Done => return None,
                Next::Retry(delay) => {
                    if let Some(snap) = lock(&self.0.state).sessions.get_mut(key) {
                        snap.scheduled = false;
                    }
                    return Some(delay);
                }
            }
        }
    }

    /// Writes what fits of `key`'s pending records into its newest open segment, then its
    /// `meta.json`; the segments past the session's bound go after that.
    fn flush(&self, key: &Key) -> Next {
        let _disk = lock(&self.0.disk);
        let Some(dir) = self.session_dir(key) else { return Next::Done };
        self.sweep_locked();
        let (id, batch) = {
            let mut state = lock(&self.0.state);
            let state = &mut *state;
            let blocked = state.blocks(&dir);
            let Some(snap) = state.sessions.get_mut(key) else { return Next::Done };
            if blocked {
                let e = anyhow::anyhow!("an earlier copy at {} is not removed yet", dir.display());
                return Self::failed(snap, key, &e);
            }
            if !snap.dirty && snap.pending.is_empty() {
                snap.scheduled = false;
                return Next::Done;
            }
            // Segments pruned but still counted in `meta.json` go first: no new segment until a
            // `meta.json` without them is written, so a refused one never lets segments pile up.
            let first = snap.pending.values().next().filter(|_| snap.gone.is_empty());
            let batch = first.map(|first| {
                let seg = disk::open_segment(&snap.segments, &dir, record_bytes(first));
                let records = disk::batch(&seg, snap.pending.values());
                (seg, records)
            });
            (snap.id, batch)
        };
        if let Some((seg, records)) = batch {
            let written = disk::write_segment(self.0.write, &dir, &seg, &records);
            let mut state = lock(&self.0.state);
            let state = &mut *state;
            // Dropped (or replaced) while writing: whoever dropped it removes its files.
            let Some(snap) = state.sessions.get_mut(key).filter(|s| s.id == id) else {
                return Next::Done;
            };
            let (bytes, seqs) = match written {
                Ok(done) => done,
                Err(e) => return Self::failed(snap, key, &e),
            };
            for seq in records.iter().filter_map(seq_of) {
                if let Some(v) = snap.pending.remove(&seq) {
                    let b = record_bytes(&v);
                    snap.pending_bytes = snap.pending_bytes.saturating_sub(b);
                    state.pending_bytes = state.pending_bytes.saturating_sub(b);
                }
            }
            let seg = Segment { bytes, seqs, ..seg };
            match snap.segments.iter_mut().find(|s| s.n == seg.n) {
                Some(same) => *same = seg,
                None => snap.segments.push(seg),
            }
            snap.prune();
            snap.dirty = true;
        }
        let meta = {
            let mut state = lock(&self.0.state);
            let Some(snap) = state.sessions.get_mut(key).filter(|s| s.id == id) else {
                return Next::Done;
            };
            snap.dirty = false;
            snap.meta.last_seq = snap.newest();
            serde_json::to_vec(&snap.meta).unwrap_or_default()
        };
        let written = disk::write_meta(self.0.write, &dir, &meta);
        let mut guard = lock(&self.0.state);
        let state = &mut *guard;
        let Some(snap) = state.sessions.get_mut(key).filter(|s| s.id == id) else {
            return Next::Done;
        };
        if let Err(e) = written {
            snap.dirty = true;
            return Self::failed(snap, key, &e);
        }
        if snap.failures > 0 {
            tracing::info!(peer = %key.0, session = %key.1, "wrote the peer session's snapshot after {} failed write(s)", snap.failures);
        }
        (snap.failures, snap.retry, snap.meta_bytes) = (0, None, meta.len() as u64);
        let more = snap.dirty || !snap.pending.is_empty();
        snap.scheduled = more;
        // Removed once `meta.json` no longer counts them.
        for (path, bytes) in std::mem::take(&mut snap.gone) {
            state.doom(path, bytes);
        }
        self.evict_total(state, Some(key));
        drop(guard);
        self.sweep_locked();
        if more { Next::More } else { Next::Done }
    }

    /// A refused write: kept in memory, tried again after a doubled delay; logged on the first
    /// failure, each power of two after it, and every minute.
    fn failed(snap: &mut Snap, key: &Key, e: &anyhow::Error) -> Next {
        snap.failures += 1;
        let delay = snap.retry.map_or(RETRY_FIRST, |d| (d * 2).min(RETRY_MAX));
        snap.retry = Some(delay);
        if snap.failures.is_power_of_two() || delay >= RETRY_MAX {
            tracing::warn!(peer = %key.0, session = %key.1, failures = snap.failures, "could not write the peer session's snapshot ({e:#}); keeping it in memory and trying again");
        }
        Next::Retry(delay)
    }

    /// Drops the least recently captured sessions while all of them, and what refused removals
    /// still hold, come to more than [`TOTAL_BYTES`], on disk and in memory; never `keep`, which
    /// is within its own bound. Queues the removals; the caller sweeps.
    fn evict_total(&self, state: &mut State, keep: Option<&Key>) {
        while state.total_bytes() > TOTAL_BYTES {
            let oldest = state
                .sessions
                .iter()
                .filter(|(k, _)| Some(*k) != keep)
                .min_by_key(|(_, s)| s.meta.captured_at)
                .map(|(k, _)| k.clone());
            let Some(oldest) = oldest else { return };
            tracing::info!(peer = %oldest.0, session = %oldest.1, "peer snapshots are over their total bound: the least recently captured one is dropped");
            self.discard(state, &oldest);
        }
    }

    /// Drops peer `peer`'s session `mux` (purged; `generation`, its row's `createdAt`, if known):
    /// its copy goes, and nothing of that generation or an older one is captured again in this
    /// run. A session the peer lists again with a newer one is captured (`retain_peer`, `barred`).
    pub(crate) fn forget(&self, peer: &str, mux: &str, generation: Option<u64>) {
        let key = (peer.to_owned(), mux.to_owned());
        self.scan();
        {
            let mut state = lock(&self.0.state);
            let kept = state.sessions.get(&key).and_then(|s| s.meta.generation);
            self.discard(&mut state, &key);
            state.bury(key, kept.max(generation));
        }
        self.sweep();
    }

    /// Drops every session of peer `peer` (the peer was removed). The caller holds the hub's
    /// `peer_leases` lock, as each capture does, so no capture of the removed peer lands after.
    pub(crate) fn forget_peer(&self, peer: &str) {
        // Every copy of it is known, so its bytes are counted until its directory goes.
        self.scan();
        {
            let mut state = lock(&self.0.state);
            let keys: Vec<Key> = state.sessions.keys().filter(|k| k.0 == peer).cloned().collect();
            let bytes: u64 =
                keys.iter().filter_map(|k| state.take(k)).map(|s| s.disk_bytes()).sum();
            // A peer added again under the name starts with no tombstones of this one.
            state.gone.retain(|k| k.0 != peer);
            state.buried.retain(|k, _| k.0 != peer);
            if let Some(dir) = self.0.dir.as_ref()
                && crate::session_name::validate(peer).is_ok()
            {
                state.doom(dir.join(peer), bytes);
            }
        }
        self.sweep();
    }

    /// Keeps only the copies of peer `peer`'s sessions that its full session list (`listed`: mux
    /// id to `createdAt`) names with the copy's own `createdAt`: a session purged or recreated
    /// while this daemon was down goes, as does one whose removal a crash cut, and one either side
    /// cannot name a generation for. A session the list names lifts the tombstone of an older one.
    pub(crate) fn retain_peer(&self, peer: &str, listed: &HashMap<&str, Option<u64>>) {
        self.scan();
        let dropped = {
            let mut state = lock(&self.0.state);
            for (mux, g) in listed {
                let key = (peer.to_owned(), (*mux).to_owned());
                let lifts = match (state.buried.get(&key), g) {
                    (Some(None), _) => true,
                    (Some(Some(gone)), Some(g)) => g >= gone,
                    _ => false,
                };
                if lifts {
                    state.buried.remove(&key);
                    state.gone.retain(|k| *k != key);
                }
            }
            let stale = |k: &Key, s: &Snap| {
                k.0 == peer && listed.get(k.1.as_str()) != Some(&s.meta.generation)
            };
            let keys: Vec<Key> = state
                .sessions
                .iter()
                .filter(|(k, s)| stale(k, s))
                .map(|(k, _)| k.clone())
                .collect();
            for k in &keys {
                let gone = state.sessions.get(k).and_then(|s| s.meta.generation);
                self.discard(&mut state, k);
                if gone.is_some() {
                    state.bury(k.clone(), gone);
                }
            }
            !keys.is_empty()
        };
        if dropped {
            self.sweep();
        }
    }

    /// Writes every session's copy now: peer `peer`'s (it went down), or every peer's (`None`,
    /// at shutdown). A write the disk refuses is tried again later, as any flush's is; at
    /// shutdown that try may not come, which loses the last seconds of a copy, never the chat.
    pub(crate) fn flush_now(&self, peer: Option<&str>) {
        let keys: Vec<Key> = lock(&self.0.state)
            .sessions
            .iter()
            .filter(|(k, s)| (s.dirty || !s.pending.is_empty()) && peer.is_none_or(|p| k.0 == p))
            .map(|(k, _)| k.clone())
            .collect();
        for key in keys {
            if let Some(delay) = blocking(|| self.drain(&key))
                && tokio::runtime::Handle::try_current().is_ok()
            {
                self.schedule(key, delay);
            }
        }
    }
}

/// `createdAt` of a session row or detail.
fn created_at(row: &Value) -> Option<u64> {
    row.get("createdAt").and_then(Value::as_u64)
}

impl Hub {
    /// The epoch of peer `peer`'s link while `generation` (None: any) is the instance registered
    /// under the name; None when it is not. Read under `peer_leases`, as `remove_peer` changes it.
    fn capturing_epoch(&self, peer: &str, generation: Option<u64>) -> Option<u64> {
        self.peer(peer)
            .filter(|p| generation.is_none_or(|g| p.generation == g))
            .map(|p| p.link_epoch())
    }

    /// Keeps a live record of peer `peer`'s session `mux` (`apply_peer_notice`); `row` is the
    /// row the caller already found (Null: none, so nothing is kept), so a token costs no second
    /// walk of the rows and copies no row.
    /// `link` is the link the record came on (`PeerNotice::Notification`).
    pub(super) fn capture_peer_record(
        &self,
        (peer, generation, link): (&str, u64, u64),
        mux: &str,
        row: &Value,
        r: &EventRecord,
    ) {
        if r.seq == 0 || r.dir == "peer" || row.is_null() || self.store.peer_cache_dir().is_none() {
            return;
        }
        let value = json!({"sessionId": mux, "seq": r.seq, "at": r.at, "dir": r.dir, "kind": r.kind, "msg": r.msg});
        // Held to the end, so a removal of the peer (`remove_peer`) never lands in between.
        let _leases = self.peer_leases.lock().unwrap_or_else(|e| e.into_inner());
        // A record of a link that has ended since is not kept: a page on the new one is read. One
        // whose link ends just after this check is still kept as that link's (`Capture::epoch` is
        // the link it came on), so the next page on the new link checks it as any other.
        if self.capturing_epoch(peer, Some(generation)) != Some(link) {
            return;
        }
        let c = Capture {
            epoch: link,
            generation: created_at(row),
            host_last_seq: None,
            from_start: false,
            row: None,
            records: std::slice::from_ref(&value),
        };
        self.peer_snapshots.capture(peer, mux, c);
    }

    /// Keeps a page of peer `peer`'s session `mux` this daemon forwarded (`_acpmux/attach`,
    /// `_acpmux/events`; `server/peer_forward.rs`): only of a session it still lists, and only
    /// while the link it was asked on (`link`, read before the request) is the peer's.
    pub fn capture_peer_page(
        &self,
        (peer, generation, link): (&str, u64, u64),
        mux: &str,
        params: &Value,
        result: &Value,
    ) {
        if self.store.peer_cache_dir().is_none() {
            return;
        }
        let Some(records) = result.get("events").and_then(Value::as_array) else { return };
        let _leases = self.peer_leases.lock().unwrap_or_else(|e| e.into_inner());
        if self.capturing_epoch(peer, Some(generation)) != Some(link) {
            return;
        }
        let Some((_, _, row)) = self.resolve_remote(&format!("{peer}/{mux}")) else { return };
        // A page of a session the peer has recreated since (a reply that was slow to come) is not
        // the listed session's.
        let (page, listed) = (result.get("session").and_then(created_at), created_at(&row));
        if matches!((page, listed), (Some(a), Some(b)) if a != b) {
            return;
        }
        let c = Capture {
            epoch: link,
            generation: listed.or(page),
            host_last_seq: result.get("lastSeq").and_then(Value::as_u64),
            from_start: result.get("hasMore") == Some(&Value::Bool(false))
                && params.get("afterSeq").and_then(Value::as_u64).unwrap_or(0) == 0,
            row: Some(row),
            records,
        };
        self.peer_snapshots.capture(peer, mux, c);
    }
}

#[cfg(test)]
#[path = "peer_snapshot_tests.rs"]
mod tests;
