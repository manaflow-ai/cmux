//! Part of `Hub`; see `hub/mod.rs`. A durable local copy of each peer session's events, so a
//! client paints a paused or offline peer's chat at once, marked possibly stale (cmuxterm-hq#4381).
//! The peer's journal stays the authority. The files are `disk.rs`'s.
//!
//! One thread owns every copy and every file (`Store`); the hub only sends it ops, in order.
//! This part is the thread and what it does with the copies it holds: their bounds, writes and
//! removal. What starts or grows a copy, and the hub's taps, come next.
//!
//! Bounds: [`SESSION_EVENTS`] and [`SESSION_BYTES`] per copy (its oldest records go), and
//! [`FILE_BYTES`] per file; [`TOTAL_BYTES`] on disk, refused removals counted (the least recently
//! used copy goes; with nothing left to evict a write waits); [`MEMORY_BYTES`] in memory (written
//! copies unload first). A failed write, a refused removal and a disk that cannot be read are
//! tried again, 1 s doubling to 60 s (`daemon/persist_retry.rs`), never an exit. Nothing is
//! written or removed until the directory reads as this user's own (no symlink).

use super::*;
use std::collections::{BTreeMap, HashSet};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex as StdMutex, mpsc};
use std::time::{Duration, Instant};

mod disk;
use disk::{Head, Key, Writer, record_bytes, seq_of};

/// Records and bytes one peer session keeps; more than an attach page (400).
pub(crate) const SESSION_EVENTS: usize = if cfg!(test) { 40 } else { 1000 };
pub(crate) const SESSION_BYTES: u64 = if cfg!(test) { 16 << 10 } else { 2 << 20 };
/// Bytes of a copy's head line (its row, mostly); a copy whose head is past it is not kept.
pub(crate) const HEAD_BYTES: u64 = if cfg!(test) { 4 << 10 } else { 256 << 10 };
/// Bytes of one copy's file, written or read: its records and its head. One past it is not a copy.
pub(crate) const FILE_BYTES: u64 = SESSION_BYTES + HEAD_BYTES;
/// Bytes every copy's file keeps together, refused removals included.
pub(crate) const TOTAL_BYTES: u64 = if cfg!(test) { 40 << 10 } else { 64 << 20 };
/// Bytes held in memory, every copy together: their records, and each copy's own cost.
const MEMORY_BYTES: u64 = if cfg!(test) { 24 << 10 } else { 16 << 20 };
/// How long new records wait before their write, so a streaming turn writes every few seconds,
/// not on every token.
const FLUSH_AFTER: Duration = Duration::from_millis(if cfg!(test) { 10 } else { 2000 });
const RETRY_FIRST: Duration = Duration::from_millis(if cfg!(test) { 10 } else { 1000 });
const RETRY_MAX: Duration = Duration::from_secs(60);
/// The longest a read or a flush waits for the store's thread.
const ANSWER_WITHIN: Duration = Duration::from_secs(5);
/// What every op costs in the queue on top of its records, so empty ones are bounded too.
const OP_BYTES: u64 = 256;
/// What every copy costs in memory on top of its records and its head (its key, its retry
/// state), so empty copies and copies only on disk are bounded too.
const KEPT_BYTES: u64 = 256;

enum Op {
    Flush { peer: Option<String>, done: Option<mpsc::SyncSender<()>> },
}

/// The flushes sent and not yet taken: each is sent once until the thread takes it.
#[derive(Default)]
struct Dropped {
    flushes: HashSet<Option<String>>,
}

/// The hub's handle on the store's thread, started at the first op.
pub struct PeerSnapshots {
    dir: Option<PathBuf>,
    /// Set once the thread runs: a spawn that failed is tried again at the next op.
    tx: StdMutex<Option<mpsc::Sender<(u64, Op)>>>,
    /// Bytes of ops sent and not yet taken.
    queued: Arc<AtomicU64>,
    dropped: Arc<StdMutex<Dropped>>,
}

impl PeerSnapshots {
    /// The store under `peers` (`store.peer_cache_dir()`); None keeps nothing.
    pub fn open(peers: Option<PathBuf>) -> Self {
        Self {
            dir: peers.map(|p| disk::root(&p)),
            tx: StdMutex::new(None),
            queued: Arc::default(),
            dropped: Arc::default(),
        }
    }

    /// Sends `op` costing `cost` (a flush: bounded by `Dropped`).
    fn send(&self, cost: u64, op: Op) -> bool {
        self.queued.fetch_add(cost, Ordering::AcqRel);
        self.enqueue(cost, op)
    }

    /// Sends `op` whose `cost` is already counted in `queued`; uncounts it when it is not sent.
    fn enqueue(&self, cost: u64, op: Op) -> bool {
        let Some(root) = &self.dir else {
            self.queued.fetch_sub(cost, Ordering::AcqRel);
            return false;
        };
        let mut tx = self.tx.lock().unwrap_or_else(|e| e.into_inner());
        if tx.is_none() {
            let (sender, rx) = mpsc::channel();
            let store = Store::new(root.clone(), self.queued.clone(), self.dropped.clone());
            let spawned = std::thread::Builder::new()
                .name("acpmux-peer-snapshots".into())
                .spawn(move || store.run(&rx));
            match spawned {
                Ok(_) => *tx = Some(sender),
                Err(e) => tracing::warn!("peer snapshots: could not start their thread: {e}"),
            }
        }
        let sent = tx.as_ref().is_some_and(|tx| tx.send((cost, op)).is_ok());
        if !sent {
            self.queued.fetch_sub(cost, Ordering::AcqRel);
        }
        sent
    }

    fn dropped(&self) -> std::sync::MutexGuard<'_, Dropped> {
        self.dropped.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Writes what is not written yet, of peer `peer` (None: every peer), without waiting.
    pub(crate) fn flush(&self, peer: Option<&str>) {
        let peer = peer.map(str::to_owned);
        if self.dir.is_some()
            && self.dropped().flushes.insert(peer.clone())
            && !self.send(OP_BYTES, Op::Flush { peer: peer.clone(), done: None })
        {
            // Not queued (no thread): the next flush tries again.
            self.dropped().flushes.remove(&peer);
        }
    }

    /// Writes what is not written yet and waits for it, at most [`ANSWER_WITHIN`] (shutdown).
    pub(crate) fn flush_now(&self) {
        let (done, rx) = mpsc::sync_channel(1);
        if self.send(OP_BYTES, Op::Flush { peer: None, done: Some(done) }) {
            let _ = blocking(|| rx.recv_timeout(ANSWER_WITHIN));
        }
    }
}

/// Runs a wait called from async code without holding up the runtime's other tasks: on a worker
/// of a multi-thread runtime (the daemon's) it tells the runtime first, as `persist_retry.rs`
/// does. A current-thread runtime (a test, a one-shot CLI) has no other worker to hold up.
fn blocking<T>(f: impl FnOnce() -> T) -> T {
    let multi = tokio::runtime::Handle::try_current()
        .is_ok_and(|h| h.runtime_flavor() == tokio::runtime::RuntimeFlavor::MultiThread);
    if multi { tokio::task::block_in_place(f) } else { f() }
}

/// Whether `record` is of session `key` (its `sessionId`): a page or a file holding another
/// session's record is not this copy.
fn of_session(record: &Value, key: &Key) -> bool {
    record.get("sessionId").and_then(Value::as_str) == Some(key.1.as_str())
}

struct Kept {
    head: Head,
    /// Its records once read (`Store::load`); None while they are only on disk.
    records: Option<BTreeMap<u64, Value>>,
    /// Bytes of `records`, and of its file on disk (0: none).
    memory: u64,
    disk: u64,
    /// What the copy itself costs in memory, loaded or not: [`KEPT_BYTES`], its key, its head.
    own: u64,
    /// Not written yet: when the write is due, and the retry delay after a failed one.
    due: Option<Instant>,
    retry: Option<Duration>,
    failures: u64,
    /// When it was last captured or read (ms), for eviction; a restart keeps its `capturedAt`.
    used: u64,
}

impl Kept {
    fn new(head: Head, disk: u64) -> Self {
        let used = head.captured_at;
        let (memory, due, retry, failures, own) = (0, None, None, 0, 0);
        Self { head, records: None, memory, disk, own, due, retry, failures, used }
    }
}

struct Store {
    root: PathBuf,
    write: Writer,
    scanned: bool,
    scan_retry: Option<(Instant, Duration)>,
    copies: HashMap<Key, Kept>,
    /// Removals the filesystem refused, with their bytes, and when they are tried again.
    dead: HashMap<PathBuf, u64>,
    dead_retry: Option<(Instant, Duration)>,
    /// When something is next due (a write, a retry, a scan); kept as a running minimum so taking
    /// a record costs no walk of the copies, and recomputed after the work it wakes for.
    wake: Option<Instant>,
    /// Bytes of every loaded copy's records, and every copy's own cost.
    memory: u64,
    queued: Arc<AtomicU64>,
    dropped: Arc<StdMutex<Dropped>>,
}

/// Which work `Store::write_due` does.
#[derive(Clone, Copy, PartialEq, Eq)]
enum When {
    /// What is due by now.
    Due,
    /// And every write not tried yet (a flush); what failed keeps its backoff.
    Pending,
    /// Everything once more, backoff or not (shutdown).
    Last,
}

/// The next delay after `before` (none: the first).
fn backoff(before: Option<Duration>) -> Duration {
    before.map_or(RETRY_FIRST, |d| (d * 2).min(RETRY_MAX))
}

impl Store {
    fn new(root: PathBuf, queued: Arc<AtomicU64>, dropped: Arc<StdMutex<Dropped>>) -> Self {
        Self {
            root,
            write: crate::config::write_atomic,
            scanned: false,
            scan_retry: None,
            copies: HashMap::new(),
            dead: HashMap::new(),
            dead_retry: None,
            wake: None,
            memory: 0,
            queued,
            dropped,
        }
    }

    /// The thread: does what is due, then takes the next op, in order. It ends, after a last
    /// write, when the hub's handle is gone.
    fn run(mut self, rx: &mpsc::Receiver<(u64, Op)>) {
        self.scan();
        loop {
            // Before every op, not only when none is waiting: a steady stream never holds up a
            // write that is due.
            if self.wake.is_some_and(|at| at <= Instant::now()) {
                self.write_due(None, When::Due);
            }
            let next = match self.wake {
                Some(at) => rx.recv_timeout(at.saturating_duration_since(Instant::now())),
                None => rx.recv().map_err(|_| mpsc::RecvTimeoutError::Disconnected),
            };
            match next {
                Ok((cost, op)) => {
                    self.queued.fetch_sub(cost, Ordering::AcqRel);
                    self.take(op);
                }
                Err(mpsc::RecvTimeoutError::Timeout) => {}
                Err(mpsc::RecvTimeoutError::Disconnected) => {
                    self.write_due(None, When::Last);
                    return;
                }
            }
        }
    }

    fn wake_by(&mut self, at: Instant) {
        self.wake = Some(self.wake.map_or(at, |w| w.min(at)));
    }

    fn take(&mut self, op: Op) {
        match op {
            Op::Flush { peer, done } => {
                if done.is_none() {
                    self.dropped.lock().unwrap_or_else(|e| e.into_inner()).flushes.remove(&peer);
                }
                // A flush (a link dropped) keeps every retry's backoff, however often it comes;
                // only the shutdown's (`done`) tries everything once more.
                let when = if done.is_some() { When::Last } else { When::Pending };
                self.write_due(peer.as_deref(), when);
                if let Some(done) = done {
                    let _ = done.send(());
                }
            }
        }
    }

    /// Adds `records` to `key`'s loaded copy, keeps it within its bounds and the memory bound,
    /// and makes its write due.
    fn add(&mut self, key: &Key, records: Vec<Value>) {
        let Store { copies, memory, .. } = self;
        let Some(c) = copies.get_mut(key) else { return };
        let Some(held) = c.records.as_mut() else { return };
        for r in records {
            let Some(seq) = seq_of(&r) else { continue };
            let bytes = record_bytes(&r);
            if let Some(old) = held.insert(seq, r) {
                c.memory -= record_bytes(&old);
                *memory -= record_bytes(&old);
            }
            c.memory += bytes;
            *memory += bytes;
        }
        self.bound(key);
        let Some(c) = self.copies.get_mut(key) else { return };
        c.head.captured_at = now_ms();
        c.used = c.head.captured_at;
        let due = *c.due.get_or_insert_with(|| Instant::now() + FLUSH_AFTER);
        self.wake_by(due);
        self.trim_memory(Some(key));
    }

    /// Keeps `key`'s loaded copy within [`SESSION_EVENTS`] and [`SESSION_BYTES`]: its oldest
    /// records go, and the copy then covers only what follows them (a record larger than the
    /// bound on its own goes too). Answers whether any went.
    fn bound(&mut self, key: &Key) -> bool {
        let Store { copies, memory, .. } = self;
        let Some(c) = copies.get_mut(key) else { return false };
        let Some(held) = c.records.as_mut() else { return false };
        let mut cut = false;
        while held.len() > SESSION_EVENTS || c.memory > SESSION_BYTES {
            let Some((seq, old)) = held.pop_first() else { break };
            c.memory -= record_bytes(&old);
            *memory -= record_bytes(&old);
            c.head.first_seq = c.head.first_seq.max(seq + 1);
            c.head.last_seq = c.head.last_seq.max(c.head.first_seq - 1);
            c.head.from_start = false;
            cut = true;
        }
        cut
    }

    /// Within [`MEMORY_BYTES`]: written copies' records are unloaded, least recently used first;
    /// then the least recently used copy not written yet goes; then (only what copies cost
    /// themselves is left) the least recently used copy goes, file and all.
    fn trim_memory(&mut self, keep: Option<&Key>) {
        while self.memory > MEMORY_BYTES {
            let others = self.copies.iter().filter(|(k, _)| Some(*k) != keep);
            let loaded = others.clone().filter(|(_, c)| c.records.is_some());
            let lru = |(k, c): (&Key, &Kept)| (c.used, k.clone());
            let unload = loaded.clone().filter(|(_, c)| c.due.is_none()).map(lru).min();
            if let Some((_, key)) = unload {
                if let Some(c) = self.copies.get_mut(&key) {
                    c.records = None;
                    self.memory -= std::mem::take(&mut c.memory);
                }
                continue;
            }
            let unwritten = loaded.map(lru).min();
            let Some((_, key)) = unwritten.clone().or_else(|| others.map(lru).min()) else { break };
            if unwritten.is_some() {
                tracing::warn!(peer = %key.0, session = %key.1, "peer snapshot: unwritten copies past their memory bound; this one goes");
            }
            self.remove(&key);
        }
    }

    /// Starts `key`'s copy (one already there goes), counting what it costs itself.
    fn insert(&mut self, key: Key, copy: Kept) {
        self.remove(&key);
        self.copies.insert(key.clone(), copy);
        self.charge(&key);
    }

    /// Counts again what `key`'s copy costs itself, after its head changed.
    fn charge(&mut self, key: &Key) {
        let Some(c) = self.copies.get_mut(key) else { return };
        let own = KEPT_BYTES + (key.0.len() + key.1.len()) as u64 + record_bytes(&c.head.summary);
        self.memory = self.memory - std::mem::replace(&mut c.own, own) + own;
    }

    /// Reads `key`'s records in when they are only on disk; a copy that does not read goes.
    /// Answers whether its records are loaded.
    fn load(&mut self, key: &Key) -> bool {
        let Some(c) = self.copies.get(key) else { return false };
        if c.records.is_some() {
            return true;
        }
        let read = match disk::path(&self.root, key) {
            Some(_) if c.disk > FILE_BYTES => Err(anyhow::anyhow!("past its bound")),
            Some(path) => disk::read(&path, key),
            None => Err(anyhow::anyhow!("a name that cannot be kept")),
        };
        match read {
            Ok(Some((mut head, records))) => {
                let bytes: u64 = records.values().map(record_bytes).sum();
                // What it covers holds every record it has, whatever an earlier run wrote.
                let (lo, hi) =
                    (records.keys().next().copied(), records.keys().next_back().copied());
                head.last_seq = head.last_seq.max(hi.unwrap_or(0));
                if head.first_seq == 0 || lo.is_some_and(|lo| lo < head.first_seq) {
                    head.first_seq = if head.from_start { 1 } else { lo.unwrap_or(1) };
                }
                head.from_start = head.first_seq <= 1;
                if let Some(c) = self.copies.get_mut(key) {
                    c.head = head;
                    c.records = Some(records);
                    c.memory = bytes;
                }
                self.memory += bytes;
                self.charge(key);
                // Within this run's bounds (an earlier run's may have been larger), written so.
                if self.bound(key)
                    && let Some(c) = self.copies.get_mut(key)
                {
                    let due = *c.due.get_or_insert_with(|| Instant::now() + FLUSH_AFTER);
                    self.wake_by(due);
                }
                self.trim_memory(Some(key));
                true
            }
            other => {
                if let Err(e) = other {
                    tracing::warn!(peer = %key.0, session = %key.1, "peer snapshot: a copy that does not read goes: {e:#}");
                }
                self.remove(key);
                false
            }
        }
    }

    /// Every copy on disk, by its head; anything else there goes. Until it reads, nothing is
    /// written or removed (what the disk holds is not known), and it is tried again with backoff.
    fn scan(&mut self) -> bool {
        let found = match disk::scan(&self.root) {
            Ok(found) => found,
            Err(e) => {
                let wait = backoff(self.scan_retry.map(|(_, d)| d));
                if self.scan_retry.is_none() {
                    tracing::warn!("peer snapshots: could not read {}: {e:#}", self.root.display());
                }
                self.scan_retry = Some((Instant::now() + wait, wait));
                self.wake_by(Instant::now() + wait);
                return false;
            }
        };
        self.scanned = true;
        self.scan_retry = None;
        for (path, bytes) in found.stray {
            self.unlink(path, bytes);
        }
        for dir in found.empty {
            // Only while empty: a copy written in it meanwhile stays (a removed peer added again).
            let _ = std::fs::remove_dir(dir);
        }
        for (key, path, bytes) in found.copies {
            match disk::read_head(&path, &key) {
                Ok(Some(head)) if bytes <= FILE_BYTES && !self.copies.contains_key(&key) => {
                    self.insert(key, Kept::new(head, bytes));
                }
                _ => self.unlink(path, bytes),
            }
        }
        self.evict_disk(None, 0);
        true
    }

    /// Removes `key`'s copy and its file.
    fn remove(&mut self, key: &Key) {
        let Some(c) = self.copies.remove(key) else { return };
        self.memory -= c.memory + c.own;
        if c.disk > 0
            && let Some(path) = disk::path(&self.root, key)
        {
            self.unlink(path, c.disk);
        }
    }

    /// Removes `path`; one the filesystem refuses stays counted and is tried again.
    fn unlink(&mut self, path: PathBuf, bytes: u64) {
        if let Err(e) = disk::remove(&path) {
            tracing::warn!("peer snapshot: could not remove {}: {e}; trying again", path.display());
            *self.dead.entry(path).or_default() += bytes;
            let (at, _) =
                *self.dead_retry.get_or_insert((Instant::now() + RETRY_FIRST, RETRY_FIRST));
            self.wake_by(at);
        } else {
            self.emptied(&path);
        }
    }

    /// After `path` went: its peer directory goes too once it is empty (one still in use is not
    /// empty, and a write makes it again). Never recursive.
    fn emptied(&self, path: &Path) {
        if let Some(dir) = path.parent().filter(|d| *d != self.root) {
            let _ = std::fs::remove_dir(dir);
        }
    }

    fn sweep(&mut self) {
        let dead: Vec<(PathBuf, u64)> = self.dead.drain().collect();
        let before = self.dead_retry.take();
        for (path, bytes) in dead {
            if disk::remove(&path).is_err() {
                self.dead.insert(path, bytes);
            } else {
                self.emptied(&path);
            }
        }
        if !self.dead.is_empty() {
            let wait = backoff(before.map(|(_, d)| d));
            self.dead_retry = Some((Instant::now() + wait, wait));
        }
    }

    /// Bytes on disk with `size` for `key`'s file instead of its own: every other copy's file and
    /// every refused removal.
    fn disk_with(&self, key: Option<&Key>, size: u64) -> u64 {
        let others = self.copies.iter().filter(|(k, _)| Some(*k) != key).map(|(_, c)| c.disk);
        others.sum::<u64>() + self.dead.values().sum::<u64>() + size
    }

    /// Evicts the least recently used other copies until `size` for `key` fits [`TOTAL_BYTES`]:
    /// written ones first, then (none left) one not written yet, which goes whole, records and
    /// file, so no later record joins it with a gap. Answers whether it fits.
    fn evict_disk(&mut self, key: Option<&Key>, size: u64) -> bool {
        while self.disk_with(key, size) > TOTAL_BYTES {
            let others = self.copies.iter().filter(|(k, c)| Some(*k) != key && c.disk > 0);
            let victim = others
                .clone()
                .filter(|(_, c)| c.due.is_none())
                .min_by_key(|(_, c)| c.used)
                .or_else(|| others.min_by_key(|(_, c)| c.used))
                .map(|(k, c)| (k.clone(), c.due.is_some()));
            let Some((victim, unwritten)) = victim else { return false };
            if unwritten {
                tracing::warn!(peer = %victim.0, session = %victim.1, "peer snapshot: unwritten copies past the disk bound; this one goes");
            }
            self.remove(&victim);
        }
        true
    }

    /// Does what is due: a refused removal tried again, a scan that failed, and the writes due
    /// of `peer` (None: all); `when` says which are due.
    fn write_due(&mut self, peer: Option<&str>, when: When) {
        let now = Instant::now();
        let last = when == When::Last;
        if self.dead_retry.is_some_and(|(at, _)| last || at <= now) {
            self.sweep();
        }
        if !self.scanned && self.scan_retry.is_some_and(|(at, _)| last || at <= now) {
            self.scan();
        }
        // Until the disk reads, nothing is written: its retry wakes the thread, once.
        let due: Vec<Key> = if !self.scanned {
            Vec::new()
        } else {
            self.copies
                .iter()
                .filter(|(k, c)| {
                    let early = last || (when == When::Pending && c.failures == 0);
                    c.due.is_some_and(|d| early || d <= now) && peer.is_none_or(|p| k.0 == p)
                })
                .map(|(k, _)| k.clone())
                .collect()
        };
        for key in due {
            if let Err(e) = self.write_one(&key) {
                self.failed(&key, &e);
            }
        }
        // Writes wait for the scan, so only its retry wakes the thread until then (never a spin
        // on writes that are due and cannot run).
        let due = self.copies.values().filter_map(|c| c.due).min().filter(|_| self.scanned);
        let retries = [self.dead_retry, self.scan_retry.filter(|_| !self.scanned)];
        self.wake = due.into_iter().chain(retries.into_iter().flatten().map(|(at, _)| at)).min();
    }

    fn write_one(&mut self, key: &Key) -> anyhow::Result<()> {
        if !self.scanned {
            anyhow::bail!("the snapshot directory does not read");
        }
        if disk::path(&self.root, key).is_none() {
            // An id with no file name never writes: not kept, never retried.
            self.remove(key);
            return Ok(());
        }
        let Some(c) = self.copies.get(key) else { return Ok(()) };
        let Some(records) = &c.records else { return Ok(()) };
        let bytes = disk::encode(&c.head, records);
        let head = serde_json::to_vec(&c.head).map_or(u64::MAX, |h| h.len() as u64);
        if !disk::head_fits(head) || bytes.len() as u64 > FILE_BYTES {
            // Its head (its row) is past what a copy may hold, as a restart reads it: not kept.
            tracing::warn!(peer = %key.0, session = %key.1, "peer snapshot past its bound; not kept");
            self.remove(key);
            return Ok(());
        }
        if !self.evict_disk(Some(key), bytes.len() as u64) {
            anyhow::bail!("no room within the peer snapshots' total bound");
        }
        let written = disk::write(self.write, &self.root, key, &bytes)?;
        if let Some(path) = disk::path(&self.root, key) {
            // The write took the place of a file whose removal was refused.
            self.dead.remove(&path);
        }
        if let Some(c) = self.copies.get_mut(key) {
            c.disk = written;
            (c.due, c.retry, c.failures) = (None, None, 0);
        }
        self.trim_memory(None);
        Ok(())
    }

    fn failed(&mut self, key: &Key, e: &anyhow::Error) {
        let Some(c) = self.copies.get_mut(key) else { return };
        c.failures += 1;
        if c.failures == 1 || c.failures % 20 == 0 {
            tracing::warn!(peer = %key.0, session = %key.1, failures = c.failures, "peer snapshot not written; trying again: {e:#}");
        }
        let wait = backoff(c.retry);
        c.retry = Some(wait);
        let due = Instant::now() + wait;
        c.due = Some(due);
        self.wake_by(due);
    }
}

#[cfg(test)]
#[path = "peer_snapshot_tests.rs"]
mod tests;
