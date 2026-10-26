//! Part of `Hub`; see `hub/mod.rs`. A durable local copy of each peer session's events, so a
//! client paints a paused or offline peer's chat at once, marked possibly stale, then catches up
//! from the peer with `afterSeq` (cmuxterm-hq#4381; Lawrence: "decouple persistence of acp
//! trajectories from the VM itself, in case the VM is resuming"). The peer's journal stays the
//! authority: this is what this daemon saw of it (its clients' pages, the peer's live records),
//! never a write lease, an execution checkpoint or a backup. The files are `disk.rs`'s.
//!
//! One thread owns every copy and every file (`Store`); the hub only sends it what it saw, in
//! the order it saw it, so no capture, listing, purge or write ever runs beside another. Sending
//! never waits; a read or a flush waits for its answer at most [`ANSWER_WITHIN`].
//!
//! Which copy may grow (the generation is the session's `createdAt`):
//! - The peer's session list (`listed`, from its full lists and changed rows) says which
//!   generation of each session is current. A copy of another generation, or of a session it no
//!   longer lists, goes. A purged generation (`barred`) is not listed again until a full list
//!   leaves the session out (the peer has done the purge, so no older list can come after).
//! - Each op names the link it came on (`Link`: the peer instance and its link epoch); one of an
//!   older link than the newest the store has seen of that peer is not kept, however late it is.
//! - A copy covers a run of seqs (`first_seq..=last_seq`: every record of them a page held). A page
//!   starts or replaces a copy only when it names the listed generation itself (an attach's
//!   `session.createdAt`) and the row named it when the page was asked (`asked`); a page that
//!   names none (`_acpmux/events`) only continues one. A page joins a copy only next to or inside
//!   what it covers; a newer page that does not replaces it, an older one is left out. A peer whose
//!   `lastSeq` is behind what the copy saw of it, on a link no page joined the copy on (a VM back
//!   on an older disk, this daemon restarted), replaces it too. A journal that went back and then
//!   ran past where the copy was cannot be told by seq; only a new `createdAt` would tell.
//! - A live record continues only a copy a page joined on the link it came on, and only at most
//!   one past what it covers; when the link drops notifications (`_acpmux/lagged`) no record is
//!   taken until a page again.
//!
//! Bounds: [`SESSION_EVENTS`] and [`SESSION_BYTES`] per copy (its oldest records go), and
//! [`FILE_BYTES`] per file (a head past [`HEAD_BYTES`] is not kept, nor read);
//! [`TOTAL_BYTES`] on disk, every file and every refused removal counted (the least recently used
//! copy goes, and with nothing left to evict a write waits); [`MEMORY_BYTES`] of records in memory
//! (written copies are unloaded first, then the least recently used unwritten one goes);
//! [`QUEUED_BYTES`] of ops waiting for the thread, each counted at least [`OP_BYTES`] and reserved
//! before it is sent (past it a capture's copy goes, never a copy with a hole, and an op that
//! changes which copies are kept drops every copy of its peer until it lists again; those losses
//! and flushes are sent at most once per session or peer until the thread takes them). A failed write is logged and tried again,
//! 1 s doubling to 60 s (`daemon/persist_retry.rs`), never an exit; a refused removal, and a disk
//! that cannot be read, are tried again the same way. Nothing is written or removed until the
//! directory reads as this user's own (no symlink), and what was purged, removed or unlisted
//! meanwhile is applied to what it holds (`Store::admits`).
//! A leased peer (a Cloud VM) is kept too: what a lease must not leave behind is its URL, port and
//! tokens, none of which is here.

use super::*;
use std::collections::{BTreeMap, HashSet, VecDeque};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex as StdMutex, OnceLock, mpsc};
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
/// Bytes of records held in memory, every copy together.
const MEMORY_BYTES: u64 = if cfg!(test) { 24 << 10 } else { 16 << 20 };
/// Bytes of captures sent to the store's thread and not yet taken.
const QUEUED_BYTES: u64 = if cfg!(test) { 64 << 10 } else { 16 << 20 };
/// How long new records wait before their write, so a streaming turn writes every few seconds,
/// not on every token.
const FLUSH_AFTER: Duration = Duration::from_millis(if cfg!(test) { 10 } else { 2000 });
const RETRY_FIRST: Duration = Duration::from_millis(if cfg!(test) { 10 } else { 1000 });
const RETRY_MAX: Duration = Duration::from_secs(60);
/// The longest a read or a flush waits for the store's thread.
const ANSWER_WITHIN: Duration = Duration::from_secs(5);
/// Row fields a copy never repeats: a countdown (`retry.nextAt`) from a peer that is not
/// answering may already have fired.
const VOLATILE_ROW_FIELDS: &[&str] = &["retry"];
/// What every op costs in the queue on top of its records, so empty ones are bounded too.
const OP_BYTES: u64 = 256;
/// Live records of a session not taken since its last page that are remembered (`Missed`).
const MISSED_KEPT: usize = 32;

/// Which connection to a peer something came on: the peer instance (`Peer::generation`, unique
/// across instances) and its link (`Peer::link_epoch`). Both only grow, so a later link of a peer
/// name is always greater.
pub(crate) type Link = (u64, u64);

/// A page of a peer session this daemon forwarded (`_acpmux/attach`, `_acpmux/events`).
#[derive(Debug, Default)]
pub(crate) struct Page {
    /// The link it was asked on (read before the request).
    pub link: Link,
    /// The generation the session's row named when the page was asked.
    pub asked: Option<u64>,
    /// The generation the page names itself (an attach's `session.createdAt`).
    pub generation: Option<u64>,
    /// `afterSeq`: the page holds every record after it (none: the newest records).
    pub after: Option<u64>,
    pub has_more: bool,
    pub host_last_seq: Option<u64>,
    pub row: Option<Value>,
    pub records: Vec<Value>,
}

impl Page {
    /// The seqs the page covers (every record of them it was asked for), when any: an events
    /// page after `A` covers `A+1` to its last record (to the peer's `lastSeq` when it holds all
    /// there is); a page of the newest records covers its first record (the first seq, when it
    /// holds all there is) to the peer's `lastSeq`.
    fn covers(&self) -> Option<(u64, u64)> {
        let seqs = || self.records.iter().filter_map(seq_of);
        let (min, max) = (seqs().min(), seqs().max());
        let last = self.host_last_seq.or(max);
        match self.after {
            Some(after) => {
                let to = if self.has_more { max } else { last.max(max) };
                to.filter(|to| *to > after).map(|to| (after + 1, to))
            }
            None => {
                let from = if self.has_more { min? } else { 1 };
                last.max(max).filter(|to| *to >= from).map(|to| (from, to))
            }
        }
    }
}

enum Op {
    Listed {
        peer: String,
        rows: Vec<(String, Option<u64>)>,
        full: bool,
    },
    Gone {
        key: Key,
        generation: Option<u64>,
    },
    ForgetPeer(String),
    Lagged(String),
    Page {
        key: Key,
        page: Page,
    },
    Record {
        key: Key,
        link: Link,
        record: Value,
    },
    /// A capture of `key`, or an op of a peer, did not fit the queue: what it would have changed
    /// goes instead.
    Lost(Key),
    LostPeer(String),
    Flush {
        peer: Option<String>,
        done: Option<mpsc::SyncSender<()>>,
    },
}

/// What a peer's ops and captures that did not fit the queue were for, and the flushes sent:
/// each is sent once until the thread takes it, so they are bounded by the sessions and peers.
#[derive(Default)]
struct Dropped {
    keys: HashSet<Key>,
    peers: HashSet<String>,
    flushes: HashSet<Option<String>>,
}

/// The hub's handle on the store's thread, started at the first op.
pub struct PeerSnapshots {
    dir: Option<PathBuf>,
    tx: OnceLock<StdMutex<mpsc::Sender<(u64, Op)>>>,
    /// Bytes of ops sent and not yet taken.
    queued: Arc<AtomicU64>,
    dropped: Arc<StdMutex<Dropped>>,
}

impl PeerSnapshots {
    /// The store under `peers` (`store.peer_cache_dir()`); None keeps nothing.
    pub fn open(peers: Option<PathBuf>) -> Self {
        Self {
            dir: peers.map(|p| disk::root(&p)),
            tx: OnceLock::new(),
            queued: Arc::default(),
            dropped: Arc::default(),
        }
    }

    /// Sends `op` costing `cost` (a loss or a flush: bounded by `Dropped`, so never refused).
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
        let tx = self.tx.get_or_init(|| {
            let (tx, rx) = mpsc::channel();
            let store = Store::new(root.clone(), self.queued.clone(), self.dropped.clone());
            let spawned = std::thread::Builder::new()
                .name("acpmux-peer-snapshots".into())
                .spawn(move || store.run(&rx));
            if let Err(e) = spawned {
                tracing::warn!("peer snapshots: could not start their thread: {e}");
            }
            StdMutex::new(tx)
        });
        let sent = tx.lock().unwrap_or_else(|e| e.into_inner()).send((cost, op)).is_ok();
        if !sent {
            self.queued.fetch_sub(cost, Ordering::AcqRel);
        }
        sent
    }

    /// Counts `cost` more in `queued` when it fits [`QUEUED_BYTES`], in one step, so callers on
    /// several threads never pass it together. Answers whether it did.
    fn reserve(&self, cost: u64) -> bool {
        let fits = |q: u64| (q + cost <= QUEUED_BYTES).then_some(q + cost);
        self.queued.fetch_update(Ordering::AcqRel, Ordering::Acquire, fits).is_ok()
    }

    fn dropped(&self) -> std::sync::MutexGuard<'_, Dropped> {
        self.dropped.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Sends `op` of peer `peer` costing `cost`: a capture of session `key`, or (None) an op that
    /// changes which copies may be kept. Past [`QUEUED_BYTES`] it is dropped and a loss goes in its
    /// place: of the session's copy (`Op::Lost`), or of every copy of the peer until it lists
    /// again (`Op::LostPeer`). While a peer's loss waits for the thread nothing more of the peer
    /// is sent: the loss stands for all of it. One lock holds the check, the loss and the send, so
    /// nothing sent after a loss stands before it in the queue.
    fn admit(&self, peer: &str, key: Option<Key>, cost: u64, op: impl FnOnce() -> Op) {
        if self.dir.is_none() {
            return;
        }
        let mut dropped = self.dropped();
        if dropped.peers.contains(peer) {
            return;
        }
        if self.reserve(cost) {
            self.enqueue(cost, op());
            return;
        }
        match key {
            Some(key) => {
                if dropped.keys.insert(key.clone()) {
                    tracing::warn!(peer = %key.0, session = %key.1, "peer snapshot: captures fell behind; this copy goes");
                    self.send(OP_BYTES, Op::Lost(key));
                }
            }
            None => {
                dropped.peers.insert(peer.to_owned());
                tracing::warn!(peer, "peer snapshot: ops fell behind; this peer's copies go");
                self.send(OP_BYTES, Op::LostPeer(peer.to_owned()));
            }
        }
    }

    /// The generations peer `peer` lists now: every session (`full`) or the ones that changed.
    pub(crate) fn listed(&self, peer: &str, rows: Vec<(String, Option<u64>)>, full: bool) {
        let cost = OP_BYTES + rows.iter().map(|(m, _)| m.len() as u64 + 16).sum::<u64>();
        self.admit(peer, None, cost, || Op::Listed { peer: peer.to_owned(), rows, full });
    }

    /// Session `mux` of `peer` was purged: its copy goes, and `generation` (None: any) is not
    /// kept again.
    pub(crate) fn gone(&self, peer: &str, mux: &str, generation: Option<u64>) {
        let key = (peer.to_owned(), mux.to_owned());
        self.admit(peer, None, OP_BYTES, || Op::Gone { key, generation });
    }

    /// Peer `peer` was removed: all of its copies go.
    pub(crate) fn forget_peer(&self, peer: &str) {
        self.admit(peer, None, OP_BYTES, || Op::ForgetPeer(peer.to_owned()));
    }

    /// Peer `peer`'s link dropped notifications: no live record is taken until a page again.
    pub(crate) fn lagged(&self, peer: &str) {
        self.admit(peer, None, OP_BYTES, || Op::Lagged(peer.to_owned()));
    }

    pub(crate) fn page(&self, (peer, mux): (&str, &str), page: Page) {
        let row = page.row.as_ref().map_or(0, record_bytes);
        let cost = OP_BYTES + row + page.records.iter().map(record_bytes).sum::<u64>();
        let key = (peer.to_owned(), mux.to_owned());
        self.admit(peer, Some(key.clone()), cost, || Op::Page { key, page });
    }

    pub(crate) fn record(&self, (peer, mux): (&str, &str), link: Link, record: Value) {
        let cost = OP_BYTES + record_bytes(&record);
        let key = (peer.to_owned(), mux.to_owned());
        self.admit(peer, Some(key.clone()), cost, || Op::Record { key, link, record });
    }

    /// Writes what is not written yet, of peer `peer` (None: every peer), without waiting.
    pub(crate) fn flush(&self, peer: Option<&str>) {
        let peer = peer.map(str::to_owned);
        if self.dir.is_some() && self.dropped().flushes.insert(peer.clone()) {
            self.send(OP_BYTES, Op::Flush { peer, done: None });
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

fn snapshot_row(mut row: Value) -> Value {
    if let Some(obj) = row.as_object_mut() {
        for f in VOLATILE_ROW_FIELDS {
            obj.remove(*f);
        }
        obj.insert("stale".into(), Value::Bool(true));
    }
    row
}

/// Whether `record` is of session `key` (its `sessionId`): a page or a file holding another
/// session's record is not this copy.
fn of_session(record: &Value, key: &Key) -> bool {
    record.get("sessionId").and_then(Value::as_str) == Some(key.1.as_str())
}

/// `createdAt` of a session row or detail.
fn created_at(row: &Value) -> Option<u64> {
    row.get("createdAt").and_then(Value::as_u64)
}

struct Kept {
    head: Head,
    /// Its records once read (`Store::load`); None while they are only on disk.
    records: Option<BTreeMap<u64, Value>>,
    /// Bytes of `records`, and of its file on disk (0: none).
    memory: u64,
    disk: u64,
    /// The link a page last joined it on, this run: only records of that link continue it.
    epoch: Option<Link>,
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
        Self {
            head,
            records: None,
            memory: 0,
            disk,
            epoch: None,
            due: None,
            retry: None,
            failures: 0,
            used,
        }
    }
}

/// Live records of a session that were not taken (no copy a page joined on their link) since
/// its last page: the newest [`MISSED_KEPT`] of them, and the newest seq of those that went past
/// that. A page that says it covers one of them does not hold it (an older peer read its
/// `lastSeq` after its page), so what it covers ends before it.
#[derive(Default)]
struct Missed {
    link: Link,
    seqs: VecDeque<u64>,
    past: u64,
}

/// What a page does to the copy it is of.
enum Fate {
    /// It joins the copy: its records are added.
    Join,
    /// It is older history that does not reach the copy: nothing changes.
    Ignore,
    /// The copy is not this page's journal (none, another generation, rolled back, or a gap
    /// between them): the page starts a new one if it can, else the copy just goes.
    Restart,
}

struct Store {
    root: PathBuf,
    write: Writer,
    scanned: bool,
    scan_retry: Option<(Instant, Duration)>,
    copies: HashMap<Key, Kept>,
    listed: HashMap<Key, Option<u64>>,
    /// Peers whose full list came this run: a session they do not list is not theirs any more.
    full_listed: HashSet<String>,
    barred: HashMap<Key, Option<u64>>,
    /// Peers removed before the disk was read (or whose ops were lost then): their files go
    /// when it is.
    forgotten: HashSet<String>,
    /// Sessions whose copy went before the disk was read (purged, unlisted, replaced, lost):
    /// what an earlier run kept of them goes too when it is.
    unread: HashSet<Key>,
    /// The newest link each peer was seen on: anything of an older one comes too late.
    links: HashMap<String, Link>,
    missed: HashMap<Key, Missed>,
    /// Removals the filesystem refused, with their bytes, and when they are tried again.
    dead: HashMap<PathBuf, u64>,
    dead_retry: Option<(Instant, Duration)>,
    /// When something is next due (a write, a retry, a scan); kept as a running minimum so taking
    /// a record costs no walk of the copies, and recomputed after the work it wakes for.
    wake: Option<Instant>,
    /// Bytes of every loaded copy's records.
    memory: u64,
    queued: Arc<AtomicU64>,
    dropped: Arc<StdMutex<Dropped>>,
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
            listed: HashMap::new(),
            full_listed: HashSet::new(),
            barred: HashMap::new(),
            forgotten: HashSet::new(),
            unread: HashSet::new(),
            links: HashMap::new(),
            missed: HashMap::new(),
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
                self.write_due(None, false);
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
                    self.write_due(None, true);
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
            Op::Listed { peer, rows, full } => self.take_listed(&peer, rows, full),
            Op::Gone { key, generation } => {
                // A purge names the generation it removed: a newer one listed or kept since (the
                // session recreated) stays. One that names none removes whatever there is.
                let newer = |g: Option<u64>| matches!((g, generation), (Some(g), Some(p)) if g > p);
                if !self.listed.get(&key).is_some_and(|l| newer(*l)) {
                    self.listed.remove(&key);
                }
                let bar = match (self.barred.get(&key), generation) {
                    (Some(Some(a)), Some(b)) => Some((*a).max(b)),
                    (None, g) => g,
                    _ => None,
                };
                self.barred.insert(key.clone(), bar);
                self.missed.remove(&key);
                if !self.copies.get(&key).is_some_and(|c| newer(c.head.generation)) {
                    self.remove(&key);
                }
            }
            Op::ForgetPeer(peer) => self.forget_peer(&peer),
            Op::Lagged(peer) => {
                for (_, c) in self.copies.iter_mut().filter(|(k, _)| k.0 == peer) {
                    c.epoch = None;
                }
            }
            Op::Page { key, page } => self.take_page(&key, page),
            Op::Record { key, link, record } => self.take_record(&key, link, record),
            Op::Lost(key) => {
                self.dropped.lock().unwrap_or_else(|e| e.into_inner()).keys.remove(&key);
                self.remove(&key);
            }
            Op::LostPeer(peer) => {
                self.dropped.lock().unwrap_or_else(|e| e.into_inner()).peers.remove(&peer);
                // What it changed is not known: nothing of the peer is kept until it lists again.
                let keys: Vec<Key> = self.copies.keys().filter(|k| k.0 == peer).cloned().collect();
                for key in keys {
                    self.remove(&key);
                }
                self.listed.retain(|k, _| k.0 != peer);
                self.missed.retain(|k, _| k.0 != peer);
                self.full_listed.remove(&peer);
                if !self.scanned {
                    // Nor what an earlier run kept of it, once the disk reads.
                    self.forgotten.insert(peer);
                }
            }
            Op::Flush { peer, done } => {
                if done.is_none() {
                    self.dropped.lock().unwrap_or_else(|e| e.into_inner()).flushes.remove(&peer);
                }
                self.write_due(peer.as_deref(), true);
                if let Some(done) = done {
                    let _ = done.send(());
                }
            }
        }
    }

    fn forget_peer(&mut self, peer: &str) {
        let keys: Vec<Key> = self.copies.keys().filter(|k| k.0 == peer).cloned().collect();
        for key in keys {
            self.remove(&key);
        }
        self.listed.retain(|k, _| k.0 != peer);
        self.missed.retain(|k, _| k.0 != peer);
        self.barred.retain(|k, _| k.0 != peer);
        self.full_listed.remove(peer);
        self.links.remove(peer);
        if self.scanned {
            // Its files went one by one above; the directory goes only once it is empty, so a
            // peer added again under the name never loses a copy to a removal tried later.
            if let Some(dir) = disk::peer_dir(&self.root, peer) {
                let _ = std::fs::remove_dir(dir);
            }
        } else {
            self.forgotten.insert(peer.to_owned());
        }
    }

    fn take_listed(&mut self, peer: &str, rows: Vec<(String, Option<u64>)>, full: bool) {
        if full {
            let names: HashSet<&str> = rows.iter().map(|(m, _)| m.as_str()).collect();
            let unlisted = |k: &Key| k.0 == peer && !names.contains(k.1.as_str());
            self.listed.retain(|k, _| !unlisted(k));
            self.missed.retain(|k, _| !unlisted(k));
            self.barred.retain(|k, _| !unlisted(k));
            let drop: Vec<Key> = self.copies.keys().filter(|k| unlisted(k)).cloned().collect();
            for key in drop {
                self.remove(&key);
            }
            self.full_listed.insert(peer.to_owned());
        }
        for (mux, generation) in rows {
            let key = (peer.to_owned(), mux);
            if let Some(bar) = self.barred.get(&key).copied() {
                // A purged generation listed again by a list sent before the purge.
                if bar.is_none() || generation.is_none_or(|g| bar.is_some_and(|b| g <= b)) {
                    self.listed.remove(&key);
                    self.remove(&key);
                    continue;
                }
                self.barred.remove(&key);
            }
            self.listed.insert(key.clone(), generation);
            let other = self
                .copies
                .get(&key)
                .is_some_and(|c| generation.is_none() || c.head.generation != generation);
            if other {
                self.remove(&key);
            }
        }
    }

    /// The generation the peer lists for `key`, when it lists one.
    fn current(&self, key: &Key) -> Option<u64> {
        self.listed.get(key).copied().flatten()
    }

    /// Whether `link` is peer `peer`'s newest link seen (it becomes so when it is newer): anything
    /// of an older one, however late it is taken, is not kept.
    fn fresh_link(&mut self, peer: &str, link: Link) -> bool {
        match self.links.get(peer) {
            Some(newest) if link < *newest => false,
            _ => {
                self.links.insert(peer.to_owned(), link);
                true
            }
        }
    }

    /// Whether `page` shows a peer behind what copy `c` saw of it, on a link no page has joined
    /// the copy on: its journal went back (a VM resumed from an older disk, or this daemon
    /// restarted). On the link that joined it, a lower `lastSeq` is only a reply that came late.
    fn behind(c: &Kept, page: &Page, to: Option<u64>) -> bool {
        let seen = page.host_last_seq.or(to);
        c.epoch != Some(page.link)
            && seen.is_some_and(|s| s < c.head.host_last_seq.max(c.head.last_seq))
    }

    fn fate(&self, key: &Key, page: &Page, (from, to): (u64, u64), generation: u64) -> Fate {
        let Some(c) = self.copies.get(key) else { return Fate::Restart };
        let h = &c.head;
        if h.generation != Some(generation) || Self::behind(c, page, Some(to)) {
            Fate::Restart
        } else if to + 1 < h.first_seq {
            Fate::Ignore
        } else if from > h.last_seq + 1 {
            Fate::Restart
        } else {
            Fate::Join
        }
    }

    fn take_page(&mut self, key: &Key, page: Page) {
        if !self.fresh_link(&key.0, page.link) || !page.records.iter().all(|r| of_session(r, key)) {
            return;
        }
        let Some(generation) = self.current(key) else { return };
        if page.asked != Some(generation) || page.generation.is_some_and(|g| g != generation) {
            return;
        }
        let covered = self.covered(key, &page);
        let Some((from, to)) = covered else {
            // Nothing to keep, but a peer behind the copy still says it is not this journal.
            if self.copies.get(key).is_some_and(|c| Self::behind(c, &page, None)) {
                self.remove(key);
            }
            return;
        };
        self.load(key);
        match self.fate(key, &page, (from, to), generation) {
            Fate::Ignore => return,
            Fate::Join => {}
            Fate::Restart => {
                self.remove(key);
                // Only a page that names its generation itself starts a copy, and only with a
                // record in it.
                if page.generation != Some(generation) || page.records.is_empty() {
                    return;
                }
                let head = Head {
                    peer: key.0.clone(),
                    session_id: key.1.clone(),
                    generation: Some(generation),
                    first_seq: from,
                    last_seq: to,
                    ..Head::default()
                };
                let mut copy = Kept::new(head, 0);
                copy.records = Some(BTreeMap::new());
                self.copies.insert(key.clone(), copy);
            }
        }
        // What was missed before this page is accounted for: from here what is not taken is
        // missed again.
        self.missed.remove(key);
        let Some(c) = self.copies.get_mut(key) else { return };
        c.epoch = Some(page.link);
        let h = &mut c.head;
        (h.first_seq, h.last_seq) = (h.first_seq.min(from), h.last_seq.max(to));
        h.host_last_seq = h.host_last_seq.max(page.host_last_seq.unwrap_or(to)).max(to);
        h.from_start = h.first_seq <= 1;
        if let Some(row) = page.row {
            h.summary = snapshot_row(row);
        }
        self.add(key, page.records);
    }

    /// What `page` covers (`Page::covers`), ending before any live record of its link that was
    /// not taken and that it does not hold (`Missed`).
    fn covered(&self, key: &Key, page: &Page) -> Option<(u64, u64)> {
        let (from, mut to) = page.covers()?;
        let held = page.records.iter().filter_map(seq_of).max().unwrap_or(from - 1);
        if let Some(m) = self.missed.get(key).filter(|m| m.link == page.link) {
            let lowest = m.seqs.iter().copied().filter(|s| *s > held && *s <= to).min();
            if let Some(cut) = if m.past > held { Some(held + 1) } else { lowest } {
                to = to.min(cut - 1);
            }
        }
        (to >= from).then_some((from, to))
    }

    /// A live record continues only a copy a page joined on the link it came on, and only next to
    /// or inside what the copy covers: one past a seq it never saw would leave a hole. One that
    /// does not is remembered until the next page (`Missed`).
    fn take_record(&mut self, key: &Key, link: Link, record: Value) {
        let Some(seq) = seq_of(&record) else { return };
        if !self.fresh_link(&key.0, link) || !of_session(&record, key) {
            return;
        }
        let Some(generation) = self.current(key) else { return };
        let joins = |c: &Kept| {
            c.head.generation == Some(generation)
                && c.epoch == Some(link)
                && seq >= c.head.first_seq
                && seq <= c.head.last_seq + 1
        };
        if !self.copies.get(key).is_some_and(joins) {
            let m = self.missed.entry(key.clone()).or_default();
            if m.link != link {
                *m = Missed { link, ..Missed::default() };
            }
            if m.seqs.len() >= MISSED_KEPT {
                m.past = m.past.max(m.seqs.pop_front().unwrap_or(0));
            }
            m.seqs.push_back(seq);
            return;
        }
        if !self.load(key) {
            return;
        }
        if let Some(c) = self.copies.get_mut(key) {
            c.head.last_seq = c.head.last_seq.max(seq);
            c.head.host_last_seq = c.head.host_last_seq.max(seq);
        }
        self.add(key, vec![record]);
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
    /// then the least recently used copy not written yet goes.
    fn trim_memory(&mut self, keep: Option<&Key>) {
        while self.memory > MEMORY_BYTES {
            let candidates =
                self.copies.iter().filter(|(k, c)| c.records.is_some() && Some(*k) != keep);
            let clean =
                candidates.clone().filter(|(_, c)| c.due.is_none()).min_by_key(|(_, c)| c.used);
            let victim = clean
                .or_else(|| candidates.min_by_key(|(_, c)| c.used))
                .map(|(k, c)| (k.clone(), c.due.is_none()));
            match victim {
                Some((key, true)) => {
                    if let Some(c) = self.copies.get_mut(&key) {
                        c.records = None;
                        self.memory -= std::mem::take(&mut c.memory);
                    }
                }
                Some((key, false)) => {
                    tracing::warn!(peer = %key.0, session = %key.1, "peer snapshot: unwritten copies past their memory bound; this one goes");
                    self.remove(&key);
                }
                None => break,
            }
        }
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

    /// Whether a copy an earlier run kept of `key` (of `generation`) may stand, given what this
    /// run was told before the disk could be read: not of a removed peer, nor a purged
    /// generation, nor another generation than the listed one, nor a session a full list left out.
    fn admits(&self, key: &Key, generation: Option<u64>) -> bool {
        if self.forgotten.contains(&key.0)
            || self.unread.contains(key)
            || self.copies.contains_key(key)
        {
            return false;
        }
        if let Some(bar) = self.barred.get(key)
            && (bar.is_none() || generation.is_none_or(|g| bar.is_some_and(|b| g <= b)))
        {
            return false;
        }
        match self.listed.get(key) {
            Some(listed) => listed.is_some() && *listed == generation,
            None => !self.full_listed.contains(&key.0),
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
                Ok(Some(head)) if bytes <= FILE_BYTES && self.admits(&key, head.generation) => {
                    self.copies.insert(key, Kept::new(head, bytes));
                }
                _ => self.unlink(path, bytes),
            }
        }
        self.forgotten.clear();
        self.unread.clear();
        self.evict_disk(None, 0);
        true
    }

    /// Removes `key`'s copy and its file.
    fn remove(&mut self, key: &Key) {
        if !self.scanned {
            self.unread.insert(key.clone());
        }
        let Some(c) = self.copies.remove(key) else { return };
        self.memory -= c.memory;
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
        }
    }

    fn sweep(&mut self) {
        let dead: Vec<(PathBuf, u64)> = self.dead.drain().collect();
        let before = self.dead_retry.take();
        for (path, bytes) in dead {
            if disk::remove(&path).is_err() {
                self.dead.insert(path, bytes);
            } else if let Some(dir) = path.parent().filter(|d| *d != self.root) {
                // A removed peer's directory waited on this file: it goes once it is empty (one
                // still in use is not empty, and a write makes it again).
                let _ = std::fs::remove_dir(dir);
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

    /// Evicts the least recently used other copies until `size` for `key` fits [`TOTAL_BYTES`].
    /// Answers whether it fits.
    fn evict_disk(&mut self, key: Option<&Key>, size: u64) -> bool {
        while self.disk_with(key, size) > TOTAL_BYTES {
            let others = self.copies.iter().filter(|(k, c)| Some(*k) != key && c.disk > 0);
            let Some(victim) = others.min_by_key(|(_, c)| c.used).map(|(k, _)| k.clone()) else {
                return false;
            };
            self.remove(&victim);
        }
        true
    }

    /// Does what is due: a refused removal tried again, a scan that failed, and the writes due
    /// (`all`: every unwritten copy) of `peer` (None: all).
    fn write_due(&mut self, peer: Option<&str>, all: bool) {
        let now = Instant::now();
        if self.dead_retry.is_some_and(|(at, _)| all || at <= now) {
            self.sweep();
        }
        if !self.scanned && self.scan_retry.is_some_and(|(at, _)| all || at <= now) {
            self.scan();
        }
        let due: Vec<Key> = self
            .copies
            .iter()
            .filter(|(k, c)| {
                c.due.is_some_and(|d| all || d <= now) && peer.is_none_or(|p| k.0 == p)
            })
            .map(|(k, _)| k.clone())
            .collect();
        for key in due {
            if let Err(e) = self.write_one(&key) {
                self.failed(&key, &e);
            }
        }
        let due = self.copies.values().filter_map(|c| c.due).min();
        let retries = [self.dead_retry, self.scan_retry.filter(|_| !self.scanned)];
        self.wake = due.into_iter().chain(retries.into_iter().flatten().map(|(at, _)| at)).min();
    }

    fn write_one(&mut self, key: &Key) -> anyhow::Result<()> {
        if !self.scanned && !self.scan() {
            anyhow::bail!("the snapshot directory does not read");
        }
        let Some(c) = self.copies.get(key) else { return Ok(()) };
        let Some(records) = &c.records else { return Ok(()) };
        let bytes = disk::encode(&c.head, records);
        let head = serde_json::to_vec(&c.head).map_or(u64::MAX, |h| h.len() as u64 + 1);
        if head > HEAD_BYTES || bytes.len() as u64 > FILE_BYTES {
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

impl Hub {
    /// Whether `link` is still the link of peer `peer` while `generation` is the instance
    /// registered under the name (the store checks again, in order: `Store::fresh_link`).
    fn capturing(&self, peer: &str, generation: u64, link: u64) -> bool {
        self.peer(peer).is_some_and(|p| p.generation == generation && p.link_epoch() == link)
    }

    /// The generation (`createdAt`) peer `peer` lists for session `mux` now: read before a
    /// forwarded page is asked (`Page::asked`).
    pub fn listed_generation(&self, peer: &str, mux: &str) -> Option<u64> {
        self.resolve_remote(&format!("{peer}/{mux}")).and_then(|(_, _, row)| created_at(&row))
    }

    /// Keeps a live record of peer `peer`'s session `mux` (`apply_peer_notice`), which came on
    /// link `link`; `row` is the row the caller already found (Null: none, so nothing is kept).
    pub(super) fn capture_peer_record(
        &self,
        (peer, generation, link): (&str, u64, u64),
        mux: &str,
        row: &Value,
        r: &EventRecord,
    ) {
        if r.seq == 0 || r.dir == "peer" || row.is_null() || !self.capturing(peer, generation, link)
        {
            return;
        }
        let value = json!({"sessionId": mux, "seq": r.seq, "at": r.at, "dir": r.dir, "kind": r.kind, "msg": r.msg});
        self.peer_snapshots.record((peer, mux), (generation, link), value);
    }

    /// Keeps a page of peer `peer`'s session `mux` this daemon forwarded (`_acpmux/attach`,
    /// `_acpmux/events`; `server/peer_forward.rs`), asked on link `link` while the row named
    /// generation `asked`; `events`: an `_acpmux/events` page, else an attach. Only a run of the chat as a client reads it is kept: not a page of older
    /// history (`beforeSeq`), nor one of some kinds only that leaves the transcript out (the app's
    /// attach asks for `transcript` and a few more, which its live records follow too).
    pub fn capture_peer_page(
        &self,
        (peer, generation, link, asked): (&str, u64, u64, Option<u64>),
        (mux, events): (&str, bool),
        params: &Value,
        result: &Value,
    ) {
        if params.get("beforeSeq").is_some_and(|v| !v.is_null())
            || params
                .get("kinds")
                .and_then(Value::as_array)
                .is_some_and(|kinds| !kinds.iter().any(|k| k.as_str() == Some("transcript")))
            || !self.capturing(peer, generation, link)
        {
            return;
        }
        let Some(records) = result.get("events").and_then(Value::as_array) else { return };
        let page = Page {
            link: (generation, link),
            asked,
            generation: result.get("session").and_then(created_at),
            // `_acpmux/events` with no `afterSeq` pages forward from the first record.
            after: params.get("afterSeq").and_then(Value::as_u64).or(events.then_some(0)),
            has_more: result.get("hasMore") != Some(&Value::Bool(false)),
            host_last_seq: result.get("lastSeq").and_then(Value::as_u64),
            row: self.resolve_remote(&format!("{peer}/{mux}")).map(|(_, _, row)| row),
            records: records.clone(),
        };
        self.peer_snapshots.page((peer, mux), page);
    }
}

#[cfg(test)]
#[path = "peer_snapshot_tests.rs"]
mod tests;
