//! The writer thread: it takes every pending record as one batch, writes the batch with one
//! write, syncs it when it holds an acked record (group commit), rotates full segments, and
//! recovers from failed writes and syncs.
//!
//! Sync levels: an acked batch is synced with a barrier sync. The first barrier sync after a full
//! one starts the power-loss window; `Config::full_sync_interval` later the next batch's sync is a
//! full one, or, when no batch comes, a full sync runs alone. So an ack waits for a drive cache
//! flush at most once per interval, and never after an idle time.
//!
//! Sync markers (`format.rs`): after each successful sync that covered records, the writer appends
//! a marker that vouches for them, before anything else it writes to that segment, after the
//! durable listeners ran (so no reply waits for it). The next sync covers the marker; at a seal and
//! at a rotation one more full sync covers it, so a sealed or full segment ends vouched for on
//! the disk. Recovery trusts the last segment only up to its last marker and writes the records
//! after it again into a new segment.
//!
//! Failures:
//! - A failed write (a full disk): the segment is cut back to its size before the write, and the
//!   writer writes the same bytes again after a backoff. If the cut fails too, as below.
//! - A failed sync, or a failed cut: the writer never writes or syncs that segment again. A failed
//!   sync can leave the kernel's copy of its pages clean and lost, and a second sync would then
//!   report success for data that never reached the disk. It keeps every record after the durable
//!   LSN in memory (`retained`) and, after a backoff, writes them into a new segment whose header
//!   names the durable LSN as its "previous last LSN", so recovery reads the failed segment only
//!   through it. A restart in the backoff is safe too: the failed segment's records after its last
//!   marker are written again by recovery.
//! - A failed segment creation: made again from the start after a backoff.
//! - A panic on this thread (a listener's): the thread ends and the journal is closed: every
//!   append fails with `Closed`, every wait ends with `WriterEnded`, the listeners are dropped and
//!   `JournalStats::failing` says why. The daemon then stops (it never closed the journal itself),
//!   and recovery runs at its next start. The crate does not abort the process: the daemon owns
//!   that policy.
//!
//! While it backs off, the writer takes no new records; appends end in `AppendError::Backlog`
//! once `Config::max_pending_bytes` wait. Nothing waits for the disk except this thread.
//!
//! The thread sleeps on a condition variable while nothing is owed. It sets a timer only while
//! written stream records wait for their sync, synced records for their full sync, or a failure
//! for its retry.

use std::io;
use std::path::PathBuf;
use std::sync::{Arc, MutexGuard, PoisonError};
use std::time::{Duration, Instant};

use crate::Lsn;
use crate::format::{self, RECORD_HEADER_LEN, SEGMENT_HEADER_LEN, SegmentHeader};
use crate::journal::{Shared, State};
use crate::recovery::{LiveSegment, WriterStart, len64, make_segment};
use crate::storage::{Storage, StorageFile, SyncLevel};

/// Written and unsynced bytes past which a batch is synced at once, acked or not.
const MAX_UNSYNCED_BYTES: usize = 8 * 1024 * 1024;

struct Active {
    file: Box<dyn StorageFile>,
    size: u64,
}

/// What the loop does next.
struct Job {
    /// A seal or a stop: sync fully whatever is owed.
    close: bool,
    /// A stop: end after this job.
    last: bool,
}

/// A failed storage operation ([module docs](self)).
enum Failure {
    /// A write; the segment is cut back to its size before it and stays in use.
    Write(io::Error),
    /// A sync, a cut or a creation; the segment (if any) is not used again.
    Segment(io::Error),
}

/// Closes the journal when the writer thread ends, also by a panic ([module docs](self)). The
/// listeners are dropped first, so whatever a held reply waits on (a channel) closes.
struct Ended(Arc<Shared>);

impl Drop for Ended {
    fn drop(&mut self) {
        let panicked = std::thread::panicking();
        self.0.listeners.lock().unwrap_or_else(PoisonError::into_inner).clear();
        {
            let mut state = self.0.lock();
            state.ended = true;
            state.closed = true;
            if panicked {
                state.stats.failing =
                    Some("the journal writer stopped: a panic on its thread".into());
            }
        }
        self.0.durable.notify_all();
        self.0.wake.notify_all();
    }
}

pub(crate) struct Writer {
    shared: Arc<Shared>,
    storage: Arc<dyn Storage>,
    dir: PathBuf,
    journal_id: u64,
    active: Option<Active>,
    /// The number the next new segment takes.
    next_seq: u64,
    /// Every record taken from `pending` and not yet durable, encoded, in LSN order.
    retained: Vec<u8>,
    /// The LSN of the last record in `retained`.
    retained_last: Lsn,
    retained_ack: bool,
    /// Bytes of `retained` written to `active`.
    written: usize,
    /// When the oldest written and unsynced byte was written.
    unsynced_since: Option<Instant>,
    /// Records were written to `active` after its last marker.
    unmarked: bool,
    /// A marker `active` owes, for this LSN.
    marker: Option<Lsn>,
    /// A marker was written to `active` after its last sync.
    marker_unsynced: bool,
    durable: Lsn,
    full_durable: Lsn,
    /// When a barrier sync first made records durable that no full sync covers yet.
    unfull_since: Option<Instant>,
    retry_at: Option<Instant>,
    backoff: Duration,
}

impl Writer {
    pub(crate) fn new(
        shared: Arc<Shared>,
        storage: Arc<dyn Storage>,
        dir: PathBuf,
        start: WriterStart,
    ) -> Self {
        let durable = shared.lock().stats.durable_lsn;
        let backoff = shared.config.retry_min;
        let tail = start.tail;
        Self {
            shared,
            storage,
            dir,
            journal_id: start.journal_id,
            next_seq: tail.seq.saturating_add(1),
            active: Some(Active { file: tail.file, size: tail.size }),
            retained: Vec::new(),
            retained_last: durable,
            retained_ack: false,
            written: 0,
            unsynced_since: None,
            unmarked: false,
            marker: None,
            marker_unsynced: false,
            durable,
            full_durable: durable,
            unfull_since: None,
            retry_at: None,
            backoff,
        }
    }

    pub(crate) fn run(mut self) {
        let _ended = Ended(Arc::clone(&self.shared));
        loop {
            let job = self.next_job();
            if let Err(failure) = self.work(job.close) {
                self.fail(failure);
            }
            if job.last {
                break;
            }
        }
    }

    /// Waits until something is owed and says what.
    fn next_job(&mut self) -> Job {
        // The guard borrows this clone, so `self` stays free for `take`.
        let shared = Arc::clone(&self.shared);
        let mut state = shared.lock();
        loop {
            let now = Instant::now();
            if state.stop {
                // One last attempt at what is pending, then the thread ends.
                self.take(&mut state);
                return Job { close: true, last: true };
            }
            if let Some(at) = self.retry_at {
                if now < at {
                    state = self.wait(state, Some(at));
                    continue;
                }
                self.retry_at = None;
                return Job { close: state.closed, last: false };
            }
            let took = self.take(&mut state);
            let owed = !self.retained.is_empty() || self.durable > self.full_durable;
            if took || (state.closed && owed) || self.sync_due(now) || self.full_due(now) {
                return Job { close: state.closed, last: false };
            }
            let deadline = self.deadline();
            state = self.wait(state, deadline);
        }
    }

    fn wait<'a>(
        &self,
        state: MutexGuard<'a, State>,
        until: Option<Instant>,
    ) -> MutexGuard<'a, State> {
        match until {
            None => self.shared.wake.wait(state).unwrap_or_else(PoisonError::into_inner),
            Some(at) => {
                let left = at.saturating_duration_since(Instant::now());
                self.shared.wake.wait_timeout(state, left).unwrap_or_else(PoisonError::into_inner).0
            }
        }
    }

    /// Moves the pending records into `retained`: one batch.
    fn take(&mut self, state: &mut State) -> bool {
        if state.pending.is_empty() {
            return false;
        }
        let stats = &mut state.stats;
        stats.batches = stats.batches.saturating_add(1);
        stats.records = stats.records.saturating_add(state.pending_records);
        stats.bytes = stats.bytes.saturating_add(len64(state.pending.len()));
        stats.max_batch_records = stats.max_batch_records.max(state.pending_records);
        if self.retained.is_empty() {
            // The emptied buffer goes back as the next pending one.
            std::mem::swap(&mut self.retained, &mut state.pending);
        } else {
            self.retained.extend_from_slice(&state.pending);
            state.pending.clear();
        }
        self.retained_last = state.pending_last;
        self.retained_ack |= state.pending_ack;
        state.pending_last = 0;
        state.pending_records = 0;
        state.pending_ack = false;
        true
    }

    /// Written stream records waited out their delay.
    fn sync_due(&self, now: Instant) -> bool {
        !self.retained.is_empty()
            && self.written == self.retained.len()
            && self
                .unsynced_since
                .is_some_and(|since| passed(since, self.shared.config.stream_sync_delay, now))
    }

    /// Synced records waited out the full-sync interval.
    fn full_due(&self, now: Instant) -> bool {
        self.unfull_since
            .is_some_and(|since| passed(since, self.shared.config.full_sync_interval, now))
    }

    fn deadline(&self) -> Option<Instant> {
        let config = &self.shared.config;
        let written = !self.retained.is_empty() && self.written == self.retained.len();
        let stream = if written {
            self.unsynced_since.and_then(|since| since.checked_add(config.stream_sync_delay))
        } else {
            None
        };
        let full = self.unfull_since.and_then(|since| since.checked_add(config.full_sync_interval));
        match (stream, full) {
            (Some(a), Some(b)) => Some(a.min(b)),
            (a, b) => a.or(b),
        }
    }

    fn work(&mut self, close: bool) -> Result<(), Failure> {
        // Records to write or sync, or synced records a full sync still owes. A rotation closes a
        // fully synced segment, so it owes nothing and the next segment waits for the next record.
        let owed = !self.retained.is_empty() || self.durable > self.full_durable;
        if self.active.is_none() {
            if !owed {
                return Ok(());
            }
            // After a failed sync or full sync, the records after `durable` (in `retained`) go into
            // the new segment, and its full syncs flush the drive cache for every file, so the
            // records the failed segment holds through `durable` become fully durable too.
            self.create_segment().map_err(Failure::Segment)?;
        }
        // A marker that a failed write left owed goes first.
        self.write_marker()?;
        let now = Instant::now();
        if self.written < self.retained.len() {
            let Some(active) = self.active.as_mut() else {
                return Err(Failure::Segment(no_segment()));
            };
            let unwritten = self.retained.get(self.written..).unwrap_or_default();
            if let Err(error) = active.file.append(unwritten) {
                return Err(cut_back(active, error));
            }
            active.size = active.size.saturating_add(len64(unwritten.len()));
            self.written = self.retained.len();
            self.unmarked = true;
            if self.unsynced_since.is_none() {
                self.unsynced_since = Some(now);
            }
            let last = self.retained_last;
            self.publish(|stats| stats.written_lsn = last);
        }
        let segment_bytes = self.shared.config.segment_bytes;
        let full_segment = self.active.as_ref().is_some_and(|active| active.size >= segment_bytes);
        // A full sync: at a seal, at a rotation, or when synced records waited out the interval.
        let full = close || full_segment || self.full_due(now);
        let held = !self.retained.is_empty();
        let stream_delay = self.shared.config.stream_sync_delay;
        let due = held
            && (self.retained_ack
                || self.retained.len() >= MAX_UNSYNCED_BYTES
                || self.unsynced_since.is_some_and(|since| passed(since, stream_delay, now)));
        if due || (full && owed) {
            let level = if full { SyncLevel::Full } else { SyncLevel::Barrier };
            self.sync(level).map_err(Failure::Segment)?;
            self.write_marker()?;
        }
        if (close || full_segment) && self.marker_unsynced {
            // A sealed or full segment ends with its marker on the disk, so the next open finds
            // every record vouched for and writes none again.
            self.sync_marker().map_err(Failure::Segment)?;
        }
        if full_segment && self.retained.is_empty() {
            // Fully synced: the next record makes the next segment.
            self.active = None;
        }
        Ok(())
    }

    fn sync(&mut self, level: SyncLevel) -> io::Result<()> {
        let Some(active) = self.active.as_mut() else { return Err(no_segment()) };
        active.file.sync(level)?;
        self.marker_unsynced = false;
        let now = Instant::now();
        if !self.retained.is_empty() {
            self.durable = self.retained_last;
        }
        if self.unmarked {
            // Every record in the segment is on the disk now: the next write vouches for them.
            self.marker = Some(self.durable);
        }
        match level {
            SyncLevel::Full => {
                self.full_durable = self.durable;
                self.unfull_since = None;
            }
            SyncLevel::Barrier => {
                if self.durable > self.full_durable && self.unfull_since.is_none() {
                    self.unfull_since = Some(now);
                }
            }
        }
        self.retained.clear();
        self.retained_ack = false;
        self.written = 0;
        self.unsynced_since = None;
        self.backoff = self.shared.config.retry_min;
        let (durable, full_durable) = (self.durable, self.full_durable);
        let advanced = self.publish(|stats| {
            let advanced = durable > stats.durable_lsn;
            stats.durable_lsn = durable;
            stats.full_durable_lsn = full_durable;
            match level {
                SyncLevel::Barrier => stats.barrier_syncs = stats.barrier_syncs.saturating_add(1),
                SyncLevel::Full => stats.full_syncs = stats.full_syncs.saturating_add(1),
            }
            stats.failing = None;
            advanced
        });
        self.shared.durable.notify_all();
        if advanced {
            let listeners =
                self.shared.listeners.lock().unwrap_or_else(PoisonError::into_inner).clone();
            for listener in listeners {
                listener(durable);
            }
        }
        Ok(())
    }

    /// Appends the marker `active` owes ([module docs](self)). It is not synced here: the next
    /// sync covers it, and recovery syncs the last segment before it reads it.
    fn write_marker(&mut self) -> Result<(), Failure> {
        let Some(lsn) = self.marker else { return Ok(()) };
        let Some(active) = self.active.as_mut() else { return Ok(()) };
        let mut bytes = Vec::with_capacity(RECORD_HEADER_LEN);
        format::encode_marker(&mut bytes, lsn);
        if let Err(error) = active.file.append(&bytes) {
            return Err(cut_back(active, error));
        }
        active.size = active.size.saturating_add(len64(bytes.len()));
        self.marker = None;
        self.unmarked = false;
        self.marker_unsynced = true;
        Ok(())
    }

    /// A full sync of `active` for its last marker alone (a seal or a rotation).
    fn sync_marker(&mut self) -> io::Result<()> {
        let Some(active) = self.active.as_mut() else { return Err(no_segment()) };
        active.file.sync(SyncLevel::Full)?;
        self.marker_unsynced = false;
        self.publish(|stats| stats.full_syncs = stats.full_syncs.saturating_add(1));
        Ok(())
    }

    fn create_segment(&mut self) -> io::Result<()> {
        let header = SegmentHeader {
            journal_id: self.journal_id,
            seq: self.next_seq,
            first_lsn: self.durable.saturating_add(1),
            prev_last: self.durable,
        };
        let file = make_segment(self.storage.as_ref(), &self.dir, &header)?;
        self.shared
            .segments
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(LiveSegment { seq: header.seq, prev_last: header.prev_last });
        self.active = Some(Active { file, size: len64(SEGMENT_HEADER_LEN) });
        self.next_seq = header.seq.saturating_add(1);
        self.written = 0;
        self.unmarked = false;
        self.marker = None;
        self.marker_unsynced = false;
        self.publish(|stats| stats.segments_created = stats.segments_created.saturating_add(1));
        Ok(())
    }

    /// A failed write, sync or segment creation ([module docs](self)).
    fn fail(&mut self, failure: Failure) {
        let error = match failure {
            Failure::Write(error) => error,
            Failure::Segment(error) => {
                // Nothing in this segment after `durable` is trusted from now on.
                self.active = None;
                self.written = 0;
                self.unsynced_since = None;
                self.unmarked = false;
                self.marker = None;
                self.marker_unsynced = false;
                error
            }
        };
        self.retry_at = Instant::now().checked_add(self.backoff);
        self.backoff = self.backoff.saturating_mul(2).min(self.shared.config.retry_max);
        let text = error.to_string();
        self.publish(|stats| {
            stats.failures = stats.failures.saturating_add(1);
            stats.failing = Some(text);
        });
        self.shared.durable.notify_all();
    }

    fn publish<T>(&self, change: impl FnOnce(&mut crate::JournalStats) -> T) -> T {
        change(&mut self.shared.lock().stats)
    }
}

/// A failed append: the segment is cut back to its size before it. A failed cut ends the
/// segment's use.
fn cut_back(active: &mut Active, error: io::Error) -> Failure {
    match active.file.truncate(active.size) {
        Ok(()) => Failure::Write(error),
        Err(_) => Failure::Segment(error),
    }
}

fn passed(since: Instant, delay: Duration, now: Instant) -> bool {
    since.checked_add(delay).is_none_or(|due| now >= due)
}

fn no_segment() -> io::Error {
    io::Error::other("the journal has no open segment")
}
