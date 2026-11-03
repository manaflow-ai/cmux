//! The public handle ([`Journal`]): append, durable LSNs, waits, listeners, seal.

use std::path::Path;
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError};
use std::time::{Duration, Instant};

use crate::format::{self, MAX_PAYLOAD_LEN};
use crate::recovery::{self, OpenReport};
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
}

impl Shared {
    pub(crate) fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
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
        });
        let report = recovered.report;
        let lock = recovered.lock;
        let writer = Writer::new(shared.clone(), storage, dir.to_path_buf(), recovered.writer);
        let handle = std::thread::Builder::new()
            .name("cmux-journal-writer".into())
            .spawn(move || writer.run())
            .map_err(|error| OpenError::Io { what: "writer thread".into(), error })?;
        Ok((Self { shared, writer: Some(handle), _lock: lock }, report))
    }

    /// Appends one record and returns its LSN. A memory copy: no I/O, no wait. The record is
    /// durable once [`Journal::durable_lsn`] reaches the LSN.
    pub fn append(&self, kind: u16, class: Class, payload: &[u8]) -> Result<Lsn, AppendError> {
        if payload.len() > MAX_PAYLOAD_LEN {
            return Err(AppendError::TooLarge);
        }
        // The payload's checksum is computed before the lock; the lock covers the LSN and copy.
        let crc = format::payload_crc(payload);
        let mut state = self.shared.lock();
        if state.closed {
            return Err(AppendError::Closed);
        }
        let size = format::record_len(payload.len());
        if !state.pending.is_empty()
            && state.pending.len().saturating_add(size) > self.shared.config.max_pending_bytes
        {
            return Err(AppendError::Backlog);
        }
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
