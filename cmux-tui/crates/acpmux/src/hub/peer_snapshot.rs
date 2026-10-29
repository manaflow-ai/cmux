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
//!   generation of each session is current; a row naming an older generation than the one listed
//!   is a list read before it and takes nothing back. A copy of another generation, or of a session
//!   it no longer lists, goes. A purged generation (`barred`) is not listed again until a full list
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
//! [`KEPT_TOTAL`] for what copies cost themselves, loaded or not (written copies go first);
//! [`QUEUED_BYTES`] of ops waiting for the thread, each counted at least [`OP_BYTES`] and reserved
//! before it is sent (past it every copy of the op's peer goes, never a copy with a hole, until it
//! lists again; a loss and a flush are sent at most once per peer until the thread takes them). A failed write is logged and tried again,
//! 1 s doubling to 60 s (`daemon/persist_retry.rs`), never an exit; a refused removal, and a disk
//! that cannot be read, are tried again the same way. Nothing is written or removed until the
//! directory reads as this user's own (no symlink), and what was purged, removed or unlisted
//! meanwhile is applied to what it holds (`Store::admits`).
//! A leased peer (a Cloud VM) is kept too: what a lease must not leave behind is its URL, port and
//! tokens, none of which is here.

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
/// Bytes of records held in memory, every copy together.
const MEMORY_BYTES: u64 = if cfg!(test) { 24 << 10 } else { 16 << 20 };
/// Purged sessions whose generation is barred (`Store::bar`).
const BARRED_KEYS: usize = if cfg!(test) { 8 } else { 4096 };
/// Sessions and peers removed before the disk reads that are remembered one by one; past it,
/// everything an earlier run kept goes once it reads.
const UNREAD_KEYS: usize = if cfg!(test) { 8 } else { 4096 };
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
/// What every copy costs in memory on top of its records and its head (its key, its retry
/// state), so empty copies and copies only on disk are bounded too, by [`KEPT_TOTAL`].
const KEPT_BYTES: u64 = 256;
/// What every copy costs itself (`Kept::own`), every copy together, loaded or not.
const KEPT_TOTAL: u64 = if cfg!(test) { 16 << 10 } else { 4 << 20 };
/// Sessions whose listed generation the store keeps, every peer together; one listed past it
/// keeps no copy (its pages are not taken) until a full list of its peer makes room.
const LISTED_KEYS: usize = if cfg!(test) { 64 } else { 65536 };

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
    /// The peer's `lastSeq` with the page: how far it had gone (rollbacks, `Store::behind`).
    pub host_last_seq: Option<u64>,
    /// How far the page holds every record of the kinds it was asked for, when the peer says
    /// (`pageThrough`: its `lastSeq` read before the page). A peer that does not say may have
    /// taken records between the page and its `lastSeq`, so its page covers its own records only.
    pub through: Option<u64>,
    pub row: Option<Value>,
    pub records: Vec<Value>,
}

impl Page {
    /// The seqs the page covers (every record of them it was asked for), when any: an events
    /// page after `A` covers `A+1` to its last record (to `through` when it holds all there is);
    /// a page of the newest records covers its first record (the first seq, when it holds all
    /// there is) to its last record, or to `through`. A page is one read of the peer's log, so
    /// every record of the kinds asked up to its last one is in it; past that, only `through`
    /// says what it holds.
    fn covers(&self) -> Option<(u64, u64)> {
        let seqs = || self.records.iter().filter_map(seq_of);
        let (min, max) = (seqs().min(), seqs().max());
        let to = self.through.max(max);
        match self.after {
            Some(after) => {
                // One that holds all there is up to `afterSeq` itself (a catch-up that found nothing
                // new) covers no seq, `after + 1..=after`, but still joins the copy on its link.
                let to = if self.has_more { max } else { to };
                to.filter(|to| *to >= after).map(|to| (after + 1, to))
            }
            None => {
                let from = if self.has_more { min? } else { 1 };
                to.filter(|to| *to >= from).map(|to| (from, to))
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
    Lagged {
        peer: String,
        link: Link,
    },
    Page {
        key: Key,
        page: Page,
    },
    Record {
        key: Key,
        link: Link,
        record: Value,
    },
    /// An op of the peer did not fit the queue: what it would have changed goes instead.
    LostPeer(String),
    /// `_acpmux/peer_snapshot` (`read.rs`).
    Read {
        key: Key,
        generation: Option<u64>,
        bounds: (usize, usize),
        reply: mpsc::SyncSender<Value>,
    },
    Flush {
        peer: Option<String>,
        done: Option<mpsc::SyncSender<()>>,
    },
}

/// The peers whose ops did not fit the queue (with whether a removal of the peer was among
/// them), and the flushes sent: each is sent once until the thread takes it, so they are bounded
/// by the peers.
#[derive(Default)]
struct Dropped {
    peers: HashMap<String, bool>,
    /// Of `peers`, those whose loss could not be sent yet (no thread then): sent at their next op.
    unsent: HashSet<String>,
    flushes: HashSet<Option<String>>,
}

/// The ops a thread that ended (a panic) never took, for the thread started after it.
type Untaken = Arc<StdMutex<Vec<Op>>>;

/// An op in the queue, with what it costs there. Its cost is given back once the thread takes it
/// or it goes; one the thread never takes (it ended with the op still queued) goes to `Untaken`,
/// which the next thread takes before anything else (`Store::run`).
struct Queued {
    cost: u64,
    op: Option<Op>,
    queued: Arc<AtomicU64>,
    untaken: Untaken,
}

impl Queued {
    fn take(mut self) -> Option<Op> {
        self.op.take()
    }
}

impl Drop for Queued {
    fn drop(&mut self) {
        self.queued.fetch_sub(self.cost, Ordering::AcqRel);
        if let Some(op) = self.op.take() {
            self.untaken.lock().unwrap_or_else(|e| e.into_inner()).push(op);
        }
    }
}

/// The store's thread: its queue, and its handle, which the next thread joins if it ends.
struct Thread {
    tx: mpsc::Sender<Queued>,
    handle: std::thread::JoinHandle<()>,
}

/// The hub's handle on the store's thread, started at the first op.
pub struct PeerSnapshots {
    dir: Option<PathBuf>,
    /// Set once the thread runs: a spawn that failed, or a thread that ended, is started again at
    /// the next op.
    tx: StdMutex<Option<Thread>>,
    /// The thread that ended, until the next one joins it (`Store::run`).
    ended: Arc<StdMutex<Option<std::thread::JoinHandle<()>>>>,
    /// Bytes of ops sent and not yet taken.
    queued: Arc<AtomicU64>,
    dropped: Arc<StdMutex<Dropped>>,
    untaken: Untaken,
}

impl PeerSnapshots {
    /// The store in the daemon's home `home` (`disk::root`, beside `peers/`); None keeps nothing.
    pub fn open(home: Option<PathBuf>) -> Self {
        Self {
            dir: home.map(|h| disk::root(&h)),
            tx: StdMutex::new(None),
            ended: Arc::default(),
            queued: Arc::default(),
            dropped: Arc::default(),
            untaken: Arc::default(),
        }
    }

    /// Sends `op` costing `cost` (a loss or a flush: bounded by `Dropped`, so never refused).
    fn send(&self, cost: u64, op: Op) -> bool {
        self.queued.fetch_add(cost, Ordering::AcqRel);
        self.enqueue(cost, op)
    }

    /// Sends `op` whose `cost` is already counted in `queued`; its cost is given back when it is
    /// not sent, or once taken (`Queued`). Not sent (no thread could start), the caller says what
    /// goes instead, so callers hold `dropped` while they send.
    fn enqueue(&self, cost: u64, op: Op) -> bool {
        let (queued, untaken) = (self.queued.clone(), self.untaken.clone());
        let mut msg = Queued { cost, op: Some(op), queued, untaken };
        let Some(root) = &self.dir else {
            msg.op = None;
            return false;
        };
        let mut thread = self.tx.lock().unwrap_or_else(|e| e.into_inner());
        // A thread that ended (it panicked) is started again, once, for this op, as after a
        // restart: it reads the disk again first.
        for _ in 0..2 {
            if thread.is_none() {
                let (tx, rx) = mpsc::channel();
                let store = Store::new(root.clone(), self.dropped.clone());
                let (ended, untaken) = (self.ended.clone(), self.untaken.clone());
                let spawned = std::thread::Builder::new()
                    .name("acpmux-peer-snapshots".into())
                    .spawn(move || store.run(&rx, &ended, &untaken));
                match spawned {
                    Ok(handle) => *thread = Some(Thread { tx, handle }),
                    Err(e) => tracing::warn!("peer snapshots: could not start their thread: {e}"),
                }
            }
            let Some(running) = thread.as_ref() else { break };
            match running.tx.send(msg) {
                Ok(()) => return true,
                Err(mpsc::SendError(back)) => {
                    msg = back;
                    if let Some(gone) = thread.take() {
                        let before = self
                            .ended
                            .lock()
                            .unwrap_or_else(|e| e.into_inner())
                            .replace(gone.handle);
                        // One no thread joined yet (a start that failed since) has ended too.
                        if let Some(before) = before {
                            let _ = before.join();
                        }
                    }
                }
            }
        }
        msg.op = None;
        false
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

    /// Sends `op` of peer `peer` costing `cost`. Past [`QUEUED_BYTES`] it is dropped and a loss of
    /// the peer goes in its place (`Op::LostPeer`): every copy of the peer goes, and nothing of it
    /// is kept until it lists again. While the loss waits for the thread nothing more of the peer
    /// is sent: the loss stands for all of it, so losses are bounded by the peers. One lock holds
    /// the check, the loss and the send, so nothing sent after a loss stands before it.
    /// A removal of the peer (`forget`) lost so is kept with the loss: the loss removes the peer.
    fn admit(&self, peer: &str, cost: u64, forget: bool, op: impl FnOnce() -> Op) {
        if self.dir.is_none() {
            return;
        }
        let mut dropped = self.dropped();
        if let Some(removed) = dropped.peers.get_mut(peer) {
            *removed |= forget;
        } else if !(self.reserve(cost) && self.enqueue(cost, op())) {
            // Past the bound, or not sent (no thread): a loss of the peer stands for it.
            dropped.peers.insert(peer.to_owned(), forget);
            dropped.unsent.insert(peer.to_owned());
            tracing::warn!(peer, "peer snapshot: captures fell behind; this peer's copies go");
        }
        self.send_unsent(&mut dropped);
    }

    /// Sends every loss not sent yet (one each), with whichever peer's op or flush comes next:
    /// the one that starts the thread again, or any after it. Answers whether none is left.
    fn send_unsent(&self, dropped: &mut Dropped) -> bool {
        let unsent: Vec<String> = dropped.unsent.iter().cloned().collect();
        for lost in unsent {
            if !self.send(OP_BYTES, Op::LostPeer(lost.clone())) {
                return false;
            }
            dropped.unsent.remove(&lost);
        }
        true
    }

    /// The generations peer `peer` lists now: every session (`full`) or the ones that changed.
    pub(crate) fn listed(&self, peer: &str, rows: Vec<(String, Option<u64>)>, full: bool) {
        let cost = OP_BYTES + rows.iter().map(|(m, _)| m.len() as u64 + 16).sum::<u64>();
        self.admit(peer, cost, false, || Op::Listed { peer: peer.to_owned(), rows, full });
    }

    /// Session `mux` of `peer` was purged: its copy goes, and `generation` (None: any) is not
    /// kept again.
    pub(crate) fn gone(&self, peer: &str, mux: &str, generation: Option<u64>) {
        let key = (peer.to_owned(), mux.to_owned());
        let cost = OP_BYTES + (peer.len() + mux.len()) as u64;
        self.admit(peer, cost, false, || Op::Gone { key, generation });
    }

    /// Peer `peer` was removed: all of its copies go.
    pub(crate) fn forget_peer(&self, peer: &str) {
        self.admit(peer, OP_BYTES, true, || Op::ForgetPeer(peer.to_owned()));
    }

    /// Peer `peer`'s link `link` dropped notifications: no live record of it is taken until a
    /// page again. A copy a later link's page joined keeps taking that link's records.
    pub(crate) fn lagged(&self, peer: &str, link: Link) {
        self.admit(peer, OP_BYTES, false, || Op::Lagged { peer: peer.to_owned(), link });
    }

    pub(crate) fn page(&self, (peer, mux): (&str, &str), page: Page) {
        let row = page.row.as_ref().map_or(0, record_bytes);
        let records = page.records.iter().map(record_bytes).sum::<u64>();
        let cost = OP_BYTES + mux.len() as u64 + row + records;
        self.admit(peer, cost, false, || Op::Page { key: (peer.to_owned(), mux.to_owned()), page });
    }

    pub(crate) fn record(&self, (peer, mux): (&str, &str), link: Link, record: Value) {
        let cost = OP_BYTES + mux.len() as u64 + record_bytes(&record);
        self.admit(peer, cost, false, || Op::Record {
            key: (peer.to_owned(), mux.to_owned()),
            link,
            record,
        });
    }

    /// Writes what is not written yet, of peer `peer` (None: every peer), without waiting.
    pub(crate) fn flush(&self, peer: Option<&str>) {
        if self.dir.is_none() {
            return;
        }
        let peer = peer.map(str::to_owned);
        let mut dropped = self.dropped();
        // A loss not sent yet goes first: the flush never writes what it removes. One that cannot
        // go (no thread starts) holds the flush back too: no thread would take it either.
        // Marked once queued (not queued: no thread, the next flush tries again).
        if self.send_unsent(&mut dropped)
            && !dropped.flushes.contains(&peer)
            && self.send(OP_BYTES, Op::Flush { peer: peer.clone(), done: None })
        {
            dropped.flushes.insert(peer);
        }
    }

    /// Writes what is not written yet and waits for it, at most [`ANSWER_WITHIN`] (shutdown). It
    /// costs nothing in `queued`: each caller waits for its own, so they are bounded by their
    /// callers (the shutdown's one), and no capture is refused for one.
    pub(crate) fn flush_now(&self) {
        let (done, rx) = mpsc::sync_channel(1);
        let sent = {
            let mut dropped = self.dropped();
            self.send_unsent(&mut dropped)
                && self.send(0, Op::Flush { peer: None, done: Some(done) })
        };
        if sent {
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
    /// What the copy itself costs in memory, loaded or not: [`KEPT_BYTES`], its key, its head
    /// (bounded apart from its records, by [`KEPT_TOTAL`]).
    own: u64,
    /// The link a page last joined it on, this run, while no lag of that link came after: only
    /// records of that link continue it.
    epoch: Option<Link>,
    /// The link a page last joined it on, this run, lag or not: a page of that link with a lower
    /// `lastSeq` only came late (`Store::behind`).
    joined: Option<Link>,
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
        let (memory, epoch, joined, due, retry, failures, own) = (0, None, None, None, None, 0, 0);
        Self { head, records: None, memory, disk, own, epoch, joined, due, retry, failures, used }
    }
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
    /// The generation each session is listed with (None: listed with none, which keeps no copy),
    /// at most [`LISTED_KEYS`]; for a peer whose full list came, a session it does not list or
    /// lists with none is not here.
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
    /// More than [`UNREAD_KEYS`] of `unread` or `forgotten`: everything an earlier run kept goes.
    unread_all: bool,
    /// The newest link each peer was seen on: anything of an older one comes too late.
    links: HashMap<String, Link>,
    /// Removals the filesystem refused, with their bytes, and when they are tried again.
    dead: HashMap<PathBuf, u64>,
    dead_retry: Option<(Instant, Duration)>,
    /// When something is next due (a write, a retry, a scan); kept as a running minimum so taking
    /// a record costs no walk of the copies, and recomputed after the work it wakes for.
    wake: Option<Instant>,
    /// Bytes of every loaded copy's records.
    memory: u64,
    /// What every copy costs itself (`Kept::own`).
    own: u64,
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
    fn new(root: PathBuf, dropped: Arc<StdMutex<Dropped>>) -> Self {
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
            unread_all: false,
            links: HashMap::new(),
            dead: HashMap::new(),
            dead_retry: None,
            wake: None,
            memory: 0,
            own: 0,
            dropped,
        }
    }

    /// The thread: does what is due, then takes the next op, in order. It ends, after a last
    /// write, when the hub's handle is gone. A thread that ended before it (a panic) is gone first,
    /// and what it never took (`Untaken`) is taken as lost before any op this one is sent.
    fn run(
        mut self,
        rx: &mpsc::Receiver<Queued>,
        ended: &StdMutex<Option<std::thread::JoinHandle<()>>>,
        untaken: &StdMutex<Vec<Op>>,
    ) {
        let before = ended.lock().unwrap_or_else(|e| e.into_inner()).take();
        if let Some(before) = before {
            let _ = before.join();
        }
        let lost = std::mem::take(&mut *untaken.lock().unwrap_or_else(|e| e.into_inner()));
        self.scan();
        for op in lost {
            self.untaken(op);
        }
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
                Ok(queued) => {
                    if let Some(op) = queued.take() {
                        self.take(op);
                    }
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
            Op::Listed { peer, rows, full } => self.take_listed(&peer, rows, full),
            // An id no file can have has no copy, nor any to bar.
            Op::Gone { key, .. } if disk::path(&self.root, &key).is_none() => {
                self.listed.remove(&key);
            }
            Op::Gone { key, generation } => {
                // A purge names the generation it removed: a newer one listed or kept since (the
                // session recreated) stays. One that names none removes whatever there is.
                let newer = |g: Option<u64>| matches!((g, generation), (Some(g), Some(p)) if g > p);
                if !self.listed.get(&key).is_some_and(|l| newer(*l)) {
                    self.listed.remove(&key);
                }
                // One that names none over a bar of a generation is that purge told again (the
                // hub's own purge first, then the peer's notice once the row is gone), so it keeps
                // the bar: a session recreated since is listed again.
                let bar = match (self.barred.get(&key), generation) {
                    (Some(Some(a)), Some(b)) => Some((*a).max(b)),
                    (Some(Some(a)), None) => Some(*a),
                    (None, g) => g,
                    (Some(None), _) => None,
                };
                self.bar(key.clone(), bar);
                // Before the disk reads, the bar alone says what an earlier run kept of it that
                // goes: a newer generation there stays too.
                if !self.copies.get(&key).is_some_and(|c| newer(c.head.generation)) {
                    self.discard(&key);
                }
            }
            Op::ForgetPeer(peer) => self.forget_peer(&peer),
            Op::Lagged { peer, link } => {
                // The lag tells of the link too: anything of an older one comes too late.
                // Records of the link stop joining until a page again; the link still joined the
                // copy, so a late page of it is only late (`joined`).
                self.fresh_link(&peer, link);
                for (_, c) in self.copies.iter_mut().filter(|(k, _)| k.0 == peer) {
                    c.epoch = c.epoch.filter(|e| *e != link);
                }
            }
            Op::Page { key, page } => self.take_page(&key, page),
            Op::Record { key, link, record } => self.take_record(&key, link, record),
            Op::LostPeer(peer) => {
                let mut dropped = self.dropped.lock().unwrap_or_else(|e| e.into_inner());
                let forget = dropped.peers.remove(&peer) == Some(true);
                drop(dropped);
                self.lose_peer(peer, forget);
            }
            Op::Read { key, generation, bounds, reply } => {
                let _ = reply.send(self.read(&key, generation, bounds));
            }
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

    /// An op a thread that ended never took, taken before anything the next thread is sent: a
    /// flush is no longer queued (a shutdown's waiter is answered as its reply goes), and what an
    /// op of a peer would have done goes as a loss of the peer, as one past the bound does.
    fn untaken(&mut self, op: Op) {
        let (peer, forget) = match op {
            Op::Flush { peer, done: None } => {
                self.dropped.lock().unwrap_or_else(|e| e.into_inner()).flushes.remove(&peer);
                return;
            }
            Op::Flush { .. } => return,
            // Its reader is answered at once that there is nothing (its reply went with it).
            Op::Read { .. } => return,
            Op::LostPeer(_) => return self.take(op),
            Op::ForgetPeer(peer) => (peer, true),
            Op::Listed { peer, .. } | Op::Lagged { peer, .. } => (peer, false),
            Op::Page { key, .. } | Op::Record { key, .. } | Op::Gone { key, .. } => (key.0, false),
        };
        self.lose_peer(peer, forget);
    }

    /// Bars `key` (`Op::Gone`), within [`BARRED_KEYS`]: past it, a bar of a session neither
    /// kept nor listed goes first (it bars only a list sent before its purge, which the peer's
    /// order already rules out), else any other.
    fn bar(&mut self, key: Key, bar: Option<u64>) {
        if self.barred.len() >= BARRED_KEYS && !self.barred.contains_key(&key) {
            let idle = |k: &Key| !self.copies.contains_key(k) && !self.listed.contains_key(k);
            let old = self.barred.keys().find(|k| idle(k)).or_else(|| self.barred.keys().next());
            if let Some(old) = old.cloned() {
                self.barred.remove(&old);
                // Before the disk reads, the bar stood for what an earlier run kept of it: past
                // the bound, everything an earlier run kept goes instead.
                if !self.scanned {
                    self.unread_all = true;
                }
            }
        }
        self.barred.insert(key, bar);
    }

    /// What ops of peer `peer` changed is not known (they were lost): nothing of the peer is kept
    /// until it lists again, nor what an earlier run kept of it once the disk reads. A removal of
    /// the peer among them (`forget`) removes it whole, bars and links.
    fn lose_peer(&mut self, peer: String, forget: bool) {
        if forget {
            return self.forget_peer(&peer);
        }
        let keys: Vec<Key> = self.copies.keys().filter(|k| k.0 == peer).cloned().collect();
        for key in keys {
            self.remove(&key);
        }
        self.listed.retain(|k, _| k.0 != peer);
        self.full_listed.remove(&peer);
        self.forget_unread(peer);
    }

    fn forget_peer(&mut self, peer: &str) {
        let keys: Vec<Key> = self.copies.keys().filter(|k| k.0 == peer).cloned().collect();
        for key in keys {
            self.remove(&key);
        }
        self.listed.retain(|k, _| k.0 != peer);
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
            self.forget_unread(peer.to_owned());
        }
    }

    /// Before the disk reads: what an earlier run kept of peer `peer` goes when it does. Past
    /// [`UNREAD_KEYS`] everything an earlier run kept goes instead.
    fn forget_unread(&mut self, peer: String) {
        if !self.scanned && !self.forgotten.contains(&peer) {
            if self.forgotten.len() < UNREAD_KEYS {
                self.forgotten.insert(peer);
            } else {
                self.unread_all = true;
            }
        }
    }

    fn take_listed(&mut self, peer: &str, rows: Vec<(String, Option<u64>)>, full: bool) {
        if full {
            let names: HashSet<&str> = rows.iter().map(|(m, _)| m.as_str()).collect();
            let unlisted = |k: &Key| k.0 == peer && !names.contains(k.1.as_str());
            self.listed.retain(|k, _| !unlisted(k));
            self.barred.retain(|k, _| !unlisted(k));
            let drop: Vec<Key> = self.copies.keys().filter(|k| unlisted(k)).cloned().collect();
            for key in drop {
                self.remove(&key);
            }
            self.full_listed.insert(peer.to_owned());
        }
        for (mux, generation) in rows {
            let key = (peer.to_owned(), mux);
            // An id no file can have keeps no copy, nor a place in the list.
            if disk::path(&self.root, &key).is_none() {
                continue;
            }
            // A session's generation (`createdAt`) only grows: a row naming an older one than the
            // one listed is a list read before the change that named the newer (a peer's watch
            // reply can reach the hub after notices it sent later), so it takes nothing back.
            if let (Some(Some(now)), Some(g)) = (self.listed.get(&key), generation)
                && g < *now
            {
                continue;
            }
            if let Some(bar) = self.barred.get(&key).copied() {
                // A purged generation listed again by a list sent before the purge: nothing of it
                // is taken, and what the purge left (a newer generation listed or kept) stays.
                if bar.is_none() || generation.is_none_or(|g| bar.is_some_and(|b| g <= b)) {
                    continue;
                }
                self.barred.remove(&key);
            }
            // Listed with none by a peer whose full list came reads as not listed (no entry).
            let room = self.listed.len() < LISTED_KEYS || self.listed.contains_key(&key);
            if generation.is_none() && self.full_listed.contains(peer) {
                self.listed.remove(&key);
            } else if room {
                self.listed.insert(key.clone(), generation);
            } else {
                tracing::debug!(
                    peer,
                    "peer snapshot: too many sessions listed; this one keeps no copy"
                );
            }
            let other = self
                .copies
                .get(&key)
                .is_some_and(|c| !room || generation.is_none() || c.head.generation != generation);
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
        let seen = page.host_last_seq.or(page.through).or(to);
        c.joined != Some(page.link)
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
        // Seqs a client's number holds exactly (`seq_of`): no watermark a peer sends can make a
        // bound's `+ 1` overflow.
        let fits = |s: Option<u64>| s.is_none_or(|s| s < 1 << 53);
        // A record with no such seq makes the page not one: nothing of it is taken.
        if !(fits(page.after) && fits(page.through) && fits(page.host_last_seq))
            || page.records.iter().any(|r| seq_of(r).is_none())
        {
            return;
        }
        // A key with no file name (an id too long for one) is never kept: it could not be written.
        if disk::path(&self.root, key).is_none()
            || !self.fresh_link(&key.0, page.link)
            || !page.records.iter().all(|r| of_session(r, key))
        {
            return;
        }
        let Some(generation) = self.current(key) else { return };
        if page.asked != Some(generation) || page.generation.is_some_and(|g| g != generation) {
            return;
        }
        // A row past what a copy's head may hold is not kept (it could never be written).
        let row = page.row.as_ref().map(|row| snapshot_row(row.clone()));
        if row.as_ref().is_some_and(|r| record_bytes(r) > HEAD_BYTES) {
            self.remove(key);
            return;
        }
        // An attach of a journal with no record of the kinds asked yet (it names its generation
        // and holds all there is) starts an empty copy, so its first live record joins.
        let empty = page.generation == Some(generation)
            && page.after.is_none()
            && !page.has_more
            && page.records.is_empty();
        let covered = page.covers().or(empty.then_some((1, 0)));
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
                // Only a page that names its generation itself starts a copy.
                if page.generation != Some(generation) {
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
                self.insert(key.clone(), copy);
            }
        }
        let Some(c) = self.copies.get_mut(key) else { return };
        (c.epoch, c.joined) = (Some(page.link), Some(page.link));
        let h = &mut c.head;
        (h.first_seq, h.last_seq) = (h.first_seq.min(from), h.last_seq.max(to));
        // How far the peer was seen: its `lastSeq`, and how far it said it held (a page cut by
        // `hasMore` covers only its records, but the peer's log still went that far).
        let seen = page.host_last_seq.unwrap_or(0).max(page.through.unwrap_or(0)).max(to);
        h.host_last_seq = h.host_last_seq.max(seen);
        h.from_start = h.first_seq <= 1;
        if let Some(row) = row {
            h.summary = row;
            self.charge(key);
        }
        self.add(key, page.records);
    }

    /// A live record continues only a copy a page joined on the link it came on, and only next to
    /// or inside what the copy covers: one past a seq it never saw would leave a hole.
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
        // Until the disk reads only its retry wakes the thread (`write_due`): a capture never
        // brings back a write's time that passed meanwhile.
        if self.scanned {
            self.wake_by(due);
        }
        self.trim_memory(Some(key));
    }

    /// Keeps `key`'s loaded copy within [`SESSION_EVENTS`] and [`SESSION_BYTES`]: its oldest
    /// records go, and the copy then covers only what follows them (a record larger than the
    /// bound on its own goes too). Answers whether any went. A record goes at most once after it
    /// came, so however many one large record pushes out, the work is paid for by their adding:
    /// O(log n) per record, never a walk of the copy per record.
    fn bound(&mut self, key: &Key) -> bool {
        let Store { copies, memory, .. } = self;
        let Some(c) = copies.get_mut(key) else { return false };
        let Some(held) = c.records.as_mut() else { return false };
        let mut cut = false;
        while held.len() > SESSION_EVENTS || c.memory > SESSION_BYTES {
            let Some((seq, old)) = held.pop_first() else { break };
            c.memory -= record_bytes(&old);
            *memory -= record_bytes(&old);
            c.head.first_seq = c.head.first_seq.max(seq.saturating_add(1));
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
            let loaded =
                self.copies.iter().filter(|(k, c)| c.records.is_some() && Some(*k) != keep);
            let lru = |(k, c): (&Key, &Kept)| (c.used, k.clone());
            // Written: on disk, and nothing since (a copy not written yet has no file).
            let unload =
                loaded.clone().filter(|(_, c)| c.disk > 0 && c.due.is_none()).map(lru).min();
            if let Some((_, key)) = unload {
                if let Some(c) = self.copies.get_mut(&key) {
                    c.records = None;
                    self.memory -= std::mem::take(&mut c.memory);
                }
                continue;
            }
            let Some((_, key)) = loaded.map(lru).min() else { break };
            tracing::warn!(peer = %key.0, session = %key.1, "peer snapshot: unwritten copies past their memory bound; this one goes");
            self.remove(&key);
        }
    }

    /// Within [`KEPT_TOTAL`]: the least recently used written copy goes, file and all; then (none
    /// left) the least recently used copy not written yet.
    /// `keep`, the copy charged, goes too only when it is written (one a scan restored).
    fn trim_kept(&mut self, keep: &Key) {
        while self.own > KEPT_TOTAL {
            let written = |c: &Kept| c.disk > 0 && c.due.is_none();
            let others = self.copies.iter().filter(|(k, c)| *k != keep || written(c));
            let lru = |(k, c): (&Key, &Kept)| (c.used, k.clone(), c.due.is_some());
            let oldest = others.clone().filter(|(_, c)| written(c)).map(lru).min();
            let Some((_, key, unwritten)) = oldest.or_else(|| others.map(lru).min()) else {
                break;
            };
            if unwritten {
                tracing::warn!(peer = %key.0, session = %key.1, "peer snapshot: unwritten copies past their bound; this one goes");
            }
            self.remove(&key);
        }
    }

    /// Starts `key`'s copy (one already there goes), counting what it costs itself.
    fn insert(&mut self, key: Key, copy: Kept) {
        self.discard(&key);
        self.copies.insert(key.clone(), copy);
        self.charge(&key);
    }

    /// Counts again what `key`'s copy costs itself, after its head changed.
    fn charge(&mut self, key: &Key) {
        // A head no file can hold (the whole line, as `write_one` measures it) is not kept, nor
        // counted.
        let line = |c: &Kept| serde_json::to_vec(&c.head).map_or(u64::MAX, |h| h.len() as u64);
        if self.copies.get(key).is_some_and(|c| !disk::head_fits(line(c))) {
            self.remove(key);
            return;
        }
        let Some(c) = self.copies.get_mut(key) else { return };
        let own = KEPT_BYTES + (key.0.len() + key.1.len()) as u64 + record_bytes(&c.head.summary);
        self.own = self.own - std::mem::replace(&mut c.own, own) + own;
        self.trim_kept(key);
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

    /// Whether a copy an earlier run kept of `key` (of `generation`) may stand, given what this
    /// run was told before the disk could be read: not of a removed peer, nor a purged
    /// generation, nor another generation than the listed one, nor a session a full list left out.
    fn admits(&self, key: &Key, generation: Option<u64>) -> bool {
        if self.unread_all
            || self.forgotten.contains(&key.0)
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
                    self.insert(key, Kept::new(head, bytes));
                }
                _ => self.unlink(path, bytes),
            }
        }
        self.forgotten.clear();
        self.unread.clear();
        self.unread_all = false;
        self.evict_disk(None, 0);
        true
    }

    /// Removes `key`'s copy and its file, and, before the disk reads, what an earlier run kept
    /// of it.
    fn remove(&mut self, key: &Key) {
        if !self.scanned && !self.unread.contains(key) {
            if self.unread.len() < UNREAD_KEYS {
                self.unread.insert(key.clone());
            } else {
                self.unread_all = true;
            }
        }
        self.discard(key);
    }

    /// Removes `key`'s copy and its file.
    fn discard(&mut self, key: &Key) {
        let Some(c) = self.copies.remove(key) else { return };
        self.memory -= c.memory;
        self.own -= c.own;
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

impl Hub {
    /// Whether `link` is still the link of peer `peer` while `generation` is the instance
    /// registered under the name (the store checks again, in order: `Store::fresh_link`).
    /// Sends a capture's op when it is of instance `generation` and link `link` still, checked
    /// and sent under the rows lock (lock order: `remote_sessions`, then `peers`): an instance that
    /// replaces it registers under that lock (`spawn_peer`), so its listing comes after this op.
    fn capture_on(&self, peer: &str, (generation, link): (u64, u64), send: impl FnOnce()) {
        let _rows = self.remote_sessions.lock().unwrap_or_else(|e| e.into_inner());
        if self.peer(peer).is_some_and(|p| p.generation == generation && p.link_epoch() == link) {
            send();
        }
    }

    /// The generation (`createdAt`) peer `peer` lists for session `mux` now (a forwarded page's
    /// `Page::asked` is the one the row it was resolved by named).
    #[cfg(test)]
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
        if r.seq == 0 || r.dir == "peer" || row.is_null() {
            return;
        }
        let value = json!({"sessionId": mux, "seq": r.seq, "at": r.at, "dir": r.dir, "kind": r.kind, "msg": r.msg});
        self.capture_on(peer, (generation, link), || {
            self.peer_snapshots.record((peer, mux), (generation, link), value);
        });
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
        // `kinds` is a name or a list of names (`EventKinds`): without `transcript`, the page
        // leaves the chat out.
        let transcript = |k: &Value| k.as_str() == Some("transcript");
        let leaves_out = match params.get("kinds") {
            None | Some(Value::Null) => false,
            Some(Value::Array(kinds)) => !kinds.iter().any(transcript),
            Some(kind) => !transcript(kind),
        };
        if params.get("beforeSeq").is_some_and(|v| !v.is_null()) || leaves_out {
            return;
        }
        let Some(records) = result.get("events").and_then(Value::as_array) else { return };
        let page = Page {
            link: (generation, link),
            asked,
            // An attach names it in its session, an events page beside its records (acpmux 5/8 and
            // later). A page that names none (an older peer's events page) only joins a copy of
            // the generation asked, never starts one: a generation read before the request cannot
            // say which journal answered it.
            generation: result.get("session").and_then(created_at).or_else(|| created_at(result)),
            // `_acpmux/events` with no `afterSeq` pages forward from the first record.
            after: params.get("afterSeq").and_then(Value::as_u64).or(events.then_some(0)),
            has_more: result.get("hasMore") != Some(&Value::Bool(false)),
            host_last_seq: result.get("lastSeq").and_then(Value::as_u64),
            // Only a peer that says how far its page holds is taken past the page's last record.
            through: result.get("pageThrough").and_then(Value::as_u64),
            row: self.resolve_remote(&format!("{peer}/{mux}")).map(|(_, _, row)| row),
            records: records.clone(),
        };
        self.capture_on(peer, (generation, link), || self.peer_snapshots.page((peer, mux), page));
    }
}

mod read;

#[cfg(test)]
#[path = "peer_snapshot_tests.rs"]
mod tests;
