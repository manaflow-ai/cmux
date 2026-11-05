//! The public handle ([`Journal`]): append, durable LSNs, waits, listeners, seal.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError};
use std::time::{Duration, Instant};

use crate::format::{self, MAX_PAYLOAD_LEN};
use crate::recovery::{self, LiveSegment, OpenReport};
use crate::storage::{Storage, StorageLock};
use crate::writer::Writer;
use crate::{Class, Config, Lsn, Record};

/// Called with the new durable LSN each time it moves, on the writer thread. It must return
/// quickly and never wait (it wakes the replies that wait for the change).
pub(crate) type Listener = Arc<dyn Fn(Lsn) + Send + Sync>;

/// Counters since open (`Journal::stats`).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct JournalStats {
    /// The next LSN an append takes, and the last LSN written, synced, and fully synced.
    pub next_lsn: Lsn,
    pub written_lsn: Lsn,
    pub durable_lsn: Lsn,
    pub full_durable_lsn: Lsn,
    /// Batches written, records in them, and their encoded bytes.
    pub batches: u64,
    pub records: u64,
    pub bytes: u64,
    /// The most records one batch held.
    pub max_batch_records: u64,
    pub barrier_syncs: u64,
    pub full_syncs: u64,
    /// Segments the writer made since open (rotation, or after a failed sync); a segment that
    /// recovery made is not counted.
    pub segments_created: u64,
    /// Segments `Journal::retire_through` deleted since open.
    pub segments_retired: u64,
    /// Failed writes, syncs and segment creations. After each, the writer tries again after a
    /// backoff: a failed write in the same segment, anything else in a new segment.
    pub failures: u64,
    /// The last failure, while the writer has not recovered from it, or why the writer stopped.
    pub failing: Option<String>,
}

pub(crate) struct State {
    pub(crate) pending: Vec<u8>,
    pub(crate) pending_last: Lsn,
    pub(crate) pending_records: u64,
    pub(crate) pending_ack: bool,
    /// No appends any more (a seal, a drop, or the writer stopped).
    pub(crate) closed: bool,
    /// The writer stops after one last attempt (drop).
    pub(crate) stop: bool,
    /// The writer thread has ended.
    pub(crate) ended: bool,
    pub(crate) stats: JournalStats,
}

pub(crate) struct Shared {
    pub(crate) config: Config,
    pub(crate) state: Mutex<State>,
    /// Wakes the writer: records came, a seal or a stop.
    pub(crate) wake: Condvar,
    /// Wakes waiters: the durable LSN moved, or the writer ended.
    pub(crate) durable: Condvar,
    pub(crate) listeners: Mutex<Vec<Listener>>,
    /// The live segments, oldest first: recovery's, then each one the writer makes.
    pub(crate) segments: Mutex<Vec<LiveSegment>>,
}

impl Shared {
    pub(crate) fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

impl State {
    /// Whether a record of `size` bytes (header included) may join the queue now: refused when
    /// the journal is closed, or, for a `limited` record, when the queue holds records and would
    /// grow past [`Config::max_pending_bytes`] (one record is always taken, however large).
    fn admits(&self, config: &Config, size: usize, limited: bool) -> Result<(), AppendError> {
        if self.closed {
            return Err(AppendError::Closed);
        }
        if limited
            && !self.pending.is_empty()
            && self.pending.len().saturating_add(size) > config.max_pending_bytes
        {
            return Err(AppendError::Backlog);
        }
        Ok(())
    }
}

/// Why an append was refused. None of them waits for the disk.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AppendError {
    /// The journal is sealed or being dropped, or its writer stopped (a panic on its thread).
    Closed,
    /// The payload is larger than [`MAX_PAYLOAD_LEN`].
    TooLarge,
    /// [`Config::max_pending_bytes`] wait for the writer already (a slow or failing disk).
    Backlog,
}

impl std::fmt::Display for AppendError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Self::Closed => "the journal is closed",
            Self::TooLarge => "the journal record is too large",
            Self::Backlog => "the journal writer is behind (a slow or failing disk)",
        })
    }
}

impl std::error::Error for AppendError {}

/// Why a wait for durability ended without it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WaitError {
    Timeout,
    /// The LSN was never appended.
    NotAppended,
    /// The writer ended: the journal is being dropped, or a panic on its thread stopped it.
    WriterEnded,
}

impl std::fmt::Display for WaitError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Self::Timeout => "the journal record is not durable yet",
            Self::NotAppended => "no journal record has that LSN",
            Self::WriterEnded => "the journal writer ended",
        })
    }
}

impl std::error::Error for WaitError {}

/// Why a seal did not finish: the last LSN, what was durable, and the writer's failure.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SealError {
    pub last_lsn: Lsn,
    pub full_durable_lsn: Lsn,
    pub failing: Option<String>,
}

impl std::fmt::Display for SealError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "journal seal: {} of {} records fully durable",
            self.full_durable_lsn, self.last_lsn
        )?;
        if let Some(failing) = &self.failing {
            write!(f, " ({failing})")?;
        }
        Ok(())
    }
}

impl std::error::Error for SealError {}

/// Why open failed.
#[derive(Debug)]
pub enum OpenError {
    /// Another writer holds the journal's lock.
    Locked,
    Io {
        what: String,
        error: std::io::Error,
    },
    /// The caller's replay refused a record.
    Replay {
        lsn: Lsn,
        error: String,
    },
}

impl std::fmt::Display for OpenError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Locked => f.write_str("another process holds the journal"),
            Self::Io { what, error } => write!(f, "journal {what}: {error}"),
            Self::Replay { lsn, error } => write!(f, "journal replay of record {lsn}: {error}"),
        }
    }
}

impl std::error::Error for OpenError {}

/// One append-only journal (crate docs). `Send` and `Sync`: every daemon thread appends through
/// one shared handle.
pub struct Journal {
    shared: Arc<Shared>,
    storage: Arc<dyn Storage>,
    dir: PathBuf,
    /// This journal's id, in every segment's header: kept across opens and retirements while one
    /// segment is left, new for a journal made from nothing ([`Journal::journal_id`]).
    journal_id: u64,
    writer: Option<std::thread::JoinHandle<()>>,
    /// Held as long as the writer may write; released after the writer is joined.
    _lock: Box<dyn StorageLock>,
}

impl Journal {
    /// Recovers the journal in `dir` (made when missing) and starts its writer. `replay` gets
    /// every record after `from` (the caller's compaction point), in LSN order, before this
    /// returns; a replay error aborts the open. When this returns `Ok`, every record handed to
    /// `replay` is fully durable (fully synced, or written again into a fully synced segment), so
    /// it is as durable as an acknowledged one. When it returns an error, the caller drops what
    /// the replay built: some of those records may not be on the disk.
    pub fn open(
        storage: Arc<dyn Storage>,
        dir: &Path,
        config: Config,
        from: Lsn,
        replay: &mut dyn FnMut(Record<'_>) -> Result<(), String>,
    ) -> Result<(Self, OpenReport), OpenError> {
        let recovered = recovery::recover(storage.as_ref(), dir, from, replay)?;
        let start = recovered.next_lsn.saturating_sub(1);
        let shared = Arc::new(Shared {
            config,
            state: Mutex::new(State {
                pending: Vec::new(),
                pending_last: 0,
                pending_records: 0,
                pending_ack: false,
                closed: false,
                stop: false,
                ended: false,
                stats: JournalStats {
                    next_lsn: recovered.next_lsn,
                    written_lsn: start,
                    durable_lsn: start,
                    full_durable_lsn: start,
                    ..JournalStats::default()
                },
            }),
            wake: Condvar::new(),
            durable: Condvar::new(),
            listeners: Mutex::new(Vec::new()),
            segments: Mutex::new(recovered.live),
        });
        let report = recovered.report;
        let lock = recovered.lock;
        let journal_id = recovered.writer.journal_id;
        let writer =
            Writer::new(shared.clone(), Arc::clone(&storage), dir.to_path_buf(), recovered.writer);
        let handle = std::thread::Builder::new()
            .name("cmux-journal-writer".into())
            .spawn(move || writer.run())
            .map_err(|error| OpenError::Io { what: "writer thread".into(), error })?;
        let journal = Self {
            shared,
            storage,
            dir: dir.to_path_buf(),
            journal_id,
            writer: Some(handle),
            _lock: lock,
        };
        Ok((journal, report))
    }

    /// Appends one record and returns its LSN. A memory copy: no I/O, no wait. The record is
    /// durable once [`Journal::durable_lsn`] reaches the LSN.
    pub fn append(&self, kind: u16, class: Class, payload: &[u8]) -> Result<Lsn, AppendError> {
        self.append_admitted(kind, class, payload, true)
    }

    /// Appends one control record as [`Journal::append`] does, except that a full queue never
    /// refuses it ([`AppendError::Backlog`]): for a record its caller must not lose to a slow or
    /// failing disk, and appends a bounded number of times (acpmux's `frozen` record, once per
    /// store). Still refused when the journal is closed or the payload is too large.
    pub fn append_control(
        &self,
        kind: u16,
        class: Class,
        payload: &[u8],
    ) -> Result<Lsn, AppendError> {
        self.append_admitted(kind, class, payload, false)
    }

    fn append_admitted(
        &self,
        kind: u16,
        class: Class,
        payload: &[u8],
        limited: bool,
    ) -> Result<Lsn, AppendError> {
        if payload.len() > MAX_PAYLOAD_LEN {
            return Err(AppendError::TooLarge);
        }
        // The payload's checksum is computed before the lock; the lock covers the LSN and copy.
        let crc = format::payload_crc(payload);
        let mut state = self.shared.lock();
        let size = format::record_len(payload.len());
        state.admits(&self.shared.config, size, limited)?;
        let lsn = state.stats.next_lsn;
        state.stats.next_lsn = lsn.saturating_add(1);
        let was_empty = state.pending.is_empty();
        format::encode_record(&mut state.pending, lsn, kind, class, payload, &crc);
        state.pending_last = lsn;
        state.pending_records = state.pending_records.saturating_add(1);
        state.pending_ack |= class == Class::Ack;
        drop(state);
        if was_empty {
            self.shared.wake.notify_one();
        }
        Ok(lsn)
    }

    /// Whether [`Journal::append`] of a `payload_len`-byte payload would be refused now, and why.
    /// A caller that runs this check and its append under one lock of its own, with every append
    /// under that lock, is sure of the append unless the writer stops in between
    /// ([`AppendError::Closed`]): only appends fill the queue, and only the writer empties it.
    pub fn check_append(&self, payload_len: usize) -> Result<(), AppendError> {
        if payload_len > MAX_PAYLOAD_LEN {
            return Err(AppendError::TooLarge);
        }
        self.shared.lock().admits(&self.shared.config, format::record_len(payload_len), true)
    }

    /// This journal's id (never 0). LSNs are unique only within one id: a journal made again from
    /// nothing (its folder removed) starts another id and may give out LSNs an older one gave. A
    /// caller that keeps an LSN outside the journal keeps the id beside it.
    pub fn journal_id(&self) -> u64 {
        self.journal_id
    }

    /// Every record up to this LSN is synced (survives a crash of any process and a kernel
    /// panic).
    pub fn durable_lsn(&self) -> Lsn {
        self.shared.lock().stats.durable_lsn
    }

    /// Every record up to this LSN is fully synced (survives a power loss).
    pub fn full_durable_lsn(&self) -> Lsn {
        self.shared.lock().stats.full_durable_lsn
    }

    /// The LSN of the last record appended (0 for none).
    pub fn last_lsn(&self) -> Lsn {
        self.shared.lock().stats.next_lsn.saturating_sub(1)
    }

    pub fn stats(&self) -> JournalStats {
        self.shared.lock().stats.clone()
    }

    /// Calls `listener` with the new durable LSN each time it moves, on the writer thread. It
    /// must return quickly and never wait: it only releases the replies that wait for the LSN.
    /// When the writer stops, the listeners are dropped, so a channel a listener sends on closes.
    pub fn on_durable(&self, listener: impl Fn(Lsn) + Send + Sync + 'static) {
        self.shared
            .listeners
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(Arc::new(listener));
    }

    /// Ends the reports of the damage that earlier opens found: every open reports it again
    /// ([`OpenReport::damage`]) until the daemon has told the person and calls this. The record
    /// moves into `quarantine/` (kept, never deleted). It renames and syncs folders on the
    /// caller's thread: call it off any request path.
    pub fn clear_damage(&self) -> std::io::Result<()> {
        recovery::clear_damage(self.storage.as_ref(), &self.dir)
    }

    /// Deletes the segments that hold no record after `compacted`, the caller's compaction point:
    /// every record at or before it is in the caller's own durable output (its projection,
    /// synced, and the checkpoint that names `compacted`, synced too). A segment is deleted when
    /// the next segment's "previous last LSN" is at or before `compacted` (recovery reads nothing
    /// past that from it), so the newest segment is never deleted. `compacted` is capped at the
    /// durable LSN. Returns how many segments it deleted.
    ///
    /// The only delete in this crate. The caller must open the journal later with a compaction
    /// point at or after `compacted`: recovery skips a segment the point covers, so a crash in
    /// the middle of a retirement, or a delete that a crash takes back, is harmless; an older
    /// compaction point is reported as `Damage::Missing`. It deletes and syncs the folder on the
    /// caller's thread: call it from a background thread, never on a request path. A segment
    /// whose delete fails stays live, and a later call deletes it.
    pub fn retire_through(&self, compacted: Lsn) -> std::io::Result<usize> {
        let compacted = compacted.min(self.durable_lsn());
        let retiring: Vec<LiveSegment> = {
            let mut live = self.shared.segments.lock().unwrap_or_else(PoisonError::into_inner);
            let count = live
                .windows(2)
                .take_while(|pair| pair.get(1).is_some_and(|next| next.prev_last <= compacted))
                .count();
            live.drain(..count).collect()
        };
        if retiring.is_empty() {
            return Ok(0);
        }
        for (index, segment) in retiring.iter().enumerate() {
            let path = self.dir.join(format::segment_name(segment.seq));
            match self.storage.remove_file(&path) {
                Ok(()) => {}
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                Err(error) => {
                    // This one and the rest stay live, ahead of the segments made since.
                    let mut live =
                        self.shared.segments.lock().unwrap_or_else(PoisonError::into_inner);
                    let mut restored = retiring.get(index..).unwrap_or_default().to_vec();
                    restored.append(&mut live);
                    *live = restored;
                    drop(live);
                    self.count_retired(index);
                    return Err(error);
                }
            }
        }
        self.count_retired(retiring.len());
        self.storage.sync_dir(&self.dir)?;
        Ok(retiring.len())
    }

    fn count_retired(&self, count: usize) {
        let mut state = self.shared.lock();
        let retired = u64::try_from(count).unwrap_or(u64::MAX);
        state.stats.segments_retired = state.stats.segments_retired.saturating_add(retired);
    }

    /// Blocks until record `lsn` is durable. For tests and tools: a daemon's request path
    /// never blocks on the disk; it holds its reply until a listener says the LSN is durable.
    pub fn wait_durable(&self, lsn: Lsn, timeout: Duration) -> Result<(), WaitError> {
        let deadline = Instant::now().checked_add(timeout);
        let mut state = self.shared.lock();
        loop {
            if state.stats.durable_lsn >= lsn {
                return Ok(());
            }
            if lsn >= state.stats.next_lsn {
                return Err(WaitError::NotAppended);
            }
            if state.ended {
                return Err(WaitError::WriterEnded);
            }
            let now = Instant::now();
            let left =
                deadline.map_or(Duration::MAX, |deadline| deadline.saturating_duration_since(now));
            if left.is_zero() {
                return Err(WaitError::Timeout);
            }
            state = self
                .shared
                .durable
                .wait_timeout(state, left)
                .unwrap_or_else(PoisonError::into_inner)
                .0;
        }
    }

    /// Stops appends and waits until every record is fully synced (a clean shutdown and a
    /// handoff: the next process reads all of it). Returns the last LSN.
    pub fn seal(&self, timeout: Duration) -> Result<Lsn, SealError> {
        let deadline = Instant::now().checked_add(timeout);
        let mut state = self.shared.lock();
        state.closed = true;
        self.shared.wake.notify_one();
        loop {
            let last = state.stats.next_lsn.saturating_sub(1);
            if state.stats.full_durable_lsn >= last {
                return Ok(last);
            }
            let now = Instant::now();
            let left =
                deadline.map_or(Duration::MAX, |deadline| deadline.saturating_duration_since(now));
            if left.is_zero() || state.ended {
                return Err(SealError {
                    last_lsn: last,
                    full_durable_lsn: state.stats.full_durable_lsn,
                    failing: state.stats.failing.clone(),
                });
            }
            state = self
                .shared
                .durable
                .wait_timeout(state, left)
                .unwrap_or_else(PoisonError::into_inner)
                .0;
        }
    }
}

impl Drop for Journal {
    /// Closes the journal: the writer makes one last attempt to write and fully sync what is
    /// pending, then ends. Call [`Journal::seal`] first for a shutdown that must keep everything.
    fn drop(&mut self) {
        {
            let mut state = self.shared.lock();
            state.closed = true;
            state.stop = true;
        }
        self.shared.wake.notify_one();
        if let Some(handle) = self.writer.take() {
            let _ = handle.join();
        }
    }
}
