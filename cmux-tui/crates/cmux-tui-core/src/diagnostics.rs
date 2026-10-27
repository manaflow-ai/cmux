//! Self-observation for the session daemon.
//!
//! The daemon should be able to say where its time goes without an operator
//! sampling it from outside. This module holds the counters that
//! `server-stats` reports: log-linear latency histograms, registry lock
//! contention with holder attribution, per-class lock wait and hold (lock
//! admission), journal writer batch metrics, and connection admission. Recording is lock-free except for the holder table,
//! which is held for nanoseconds, so the overhead stays far below the
//! millisecond-scale critical sections it measures.

use std::collections::HashMap;
use std::panic::Location;
use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use serde::Serialize;

use crate::journal_ingress::JournalLane;

mod resource_projection;
pub use resource_projection::{
    CommitSpans, ProjectionSpans, ResourceProjectionSnapshot, ResourceProjectionStats,
};
mod ipc;
pub(crate) use ipc::note_json_parse;
pub use ipc::{
    CountedWrite, IpcKindSnapshot, IpcParseSnapshot, IpcParsesSnapshot, IpcSnapshot, IpcStats,
    IpcStreamsSnapshot, IpcTransport, IpcWritesSnapshot, JsonParseScope, OpenStream,
    WRITE_STALL_THRESHOLD,
};
mod owner_panic_log;
#[cfg(debug_assertions)]
pub use owner_panic_log::spawn_owner_hang_test;
pub use owner_panic_log::{owner_hang_log_path, owner_log_dir, owner_panic_log_path};
mod slow_requests;
pub use slow_requests::{SlowRequest, SlowRequestFrame, SlowRequestsSnapshot};
mod method_latency;
pub use method_latency::{MethodLatencySnapshot, MethodLatencyStats, MethodName, MethodSample};
mod requests;
pub use requests::{REQUEST_CLASSES, RequestLatencySnapshot, RequestStats, RequestStatsSnapshot};
mod daemon_locks;
pub use daemon_locks::{
    CallerLockSnapshot, DaemonLockTable, LOCK_OPS, LockCaller, LockCallerCell, LockCallerScope,
    LockHistogramSnapshot, LockOp, LockOpScope, LockScope, LockScopeGuard, LockTableSnapshot,
    OpLockSnapshot,
};
pub(crate) use daemon_locks::{LockSlot, lock_clock, timed_acquire};
#[cfg(test)]
pub(crate) use daemon_locks::{lock_clock_reads, on_contended_lock};
#[cfg(test)]
mod bucket_golden_tests;
mod write_path;
pub(crate) use write_path::writer_took_registry_lock;
pub use write_path::{WritePathSnapshot, WritePathStats};

/// Sub-buckets per power of two. Four keeps the reported percentile within
/// 25% above the true value while costing 256 counters per histogram.
const SUB_BUCKETS_LOG2: u32 = 2;
const SUB_BUCKETS: usize = 1 << SUB_BUCKETS_LOG2;
const BUCKETS: usize = 64 * SUB_BUCKETS;

/// A waiter that spent this long on a lock is reported as a stall with the
/// site that held the lock when the wait began.
pub const LOCK_STALL_THRESHOLD: Duration = Duration::from_millis(100);
/// Acquisitions that waited at least this long count as contended.
const LOCK_CONTENDED_THRESHOLD: Duration = Duration::from_millis(1);
const TOP_SITES: usize = 8;

/// Log-linear histogram over `u64` samples. Each power of two is split into
/// four linear sub-buckets, so any percentile it reports is the upper bound
/// of a bucket at most 25% above the true sample.
pub struct LogLinearHistogram {
    buckets: Box<[AtomicU64]>,
    count: AtomicU64,
    sum: AtomicU64,
    max: AtomicU64,
}

impl Default for LogLinearHistogram {
    fn default() -> Self {
        Self::new()
    }
}

impl LogLinearHistogram {
    pub fn new() -> Self {
        Self {
            buckets: (0..BUCKETS).map(|_| AtomicU64::new(0)).collect(),
            count: AtomicU64::new(0),
            sum: AtomicU64::new(0),
            max: AtomicU64::new(0),
        }
    }

    pub(crate) fn bucket_index(value: u64) -> usize {
        if value < SUB_BUCKETS as u64 {
            return value as usize;
        }
        let octave = 63 - value.leading_zeros();
        let sub = (value >> (octave - SUB_BUCKETS_LOG2)) & (SUB_BUCKETS as u64 - 1);
        octave as usize * SUB_BUCKETS + sub as usize
    }

    /// Largest value that lands in `index`.
    pub(crate) fn bucket_upper_bound(index: usize) -> u64 {
        if index < SUB_BUCKETS {
            return index as u64;
        }
        let octave = (index / SUB_BUCKETS) as u32;
        let sub = (index % SUB_BUCKETS) as u64;
        let width = 1u64 << (octave - SUB_BUCKETS_LOG2);
        // Written so the top bucket lands exactly on `u64::MAX` without
        // overflowing: (2^o - 1) + 4 * 2^(o-2) = 2^(o+1) - 1.
        ((1u64 << octave) - 1) + (sub + 1) * width
    }

    pub fn record(&self, value: u64) {
        self.buckets[Self::bucket_index(value)].fetch_add(1, Ordering::Relaxed);
        self.count.fetch_add(1, Ordering::Relaxed);
        let _ = self.sum.fetch_update(Ordering::Relaxed, Ordering::Relaxed, |sum| {
            Some(sum.saturating_add(value))
        });
        self.max.fetch_max(value, Ordering::Relaxed);
    }

    pub fn record_duration(&self, duration: Duration) {
        self.record(u64::try_from(duration.as_micros()).unwrap_or(u64::MAX));
    }

    /// The bucket counts and their sum, read once.
    fn counts(&self) -> (Vec<u64>, u64) {
        let counts: Vec<u64> = self.buckets.iter().map(|b| b.load(Ordering::Relaxed)).collect();
        let count = counts.iter().sum();
        (counts, count)
    }

    /// The upper bound of the bucket that holds the sample of rank
    /// `ceil(count * fraction)`; 0 for no samples.
    fn percentile(counts: &[u64], count: u64, fraction: f64) -> u64 {
        if count == 0 {
            return 0;
        }
        let rank = ((count as f64) * fraction).ceil().max(1.0) as u64;
        let mut seen = 0;
        for (index, bucket) in counts.iter().enumerate() {
            seen += bucket;
            if seen >= rank {
                return Self::bucket_upper_bound(index);
            }
        }
        Self::bucket_upper_bound(BUCKETS - 1)
    }

    pub fn snapshot(&self) -> HistogramSnapshot {
        self.snapshot_with_p95().0
    }

    /// [`Self::snapshot`] and the p95 from the same bucket counts.
    pub fn snapshot_with_p95(&self) -> (HistogramSnapshot, u64) {
        let (counts, count) = self.counts();
        let snapshot = HistogramSnapshot {
            count,
            mean: self.sum.load(Ordering::Relaxed).checked_div(count).unwrap_or(0),
            max: self.max.load(Ordering::Relaxed),
            p50: Self::percentile(&counts, count, 0.50),
            p90: Self::percentile(&counts, count, 0.90),
            p99: Self::percentile(&counts, count, 0.99),
        };
        (snapshot, Self::percentile(&counts, count, 0.95))
    }

    /// p50, p95, p99 and max, the distribution every perf claim gives
    /// (bucket upper bounds, as [`Self::snapshot`]).
    pub fn percentiles(&self) -> PercentilesSnapshot {
        let (counts, count) = self.counts();
        PercentilesSnapshot {
            count,
            p50: Self::percentile(&counts, count, 0.50),
            p95: Self::percentile(&counts, count, 0.95),
            p99: Self::percentile(&counts, count, 0.99),
            max: self.max.load(Ordering::Relaxed),
        }
    }
}

/// A [`LogLinearHistogram`]'s p50, p95, p99 and max; percentiles are bucket
/// upper bounds, so a reader on another clock agrees within one bucket.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize)]
pub struct PercentilesSnapshot {
    pub count: u64,
    pub p50: u64,
    pub p95: u64,
    pub p99: u64,
    pub max: u64,
}

/// Percentiles are bucket upper bounds; see [`LogLinearHistogram`]. Units are
/// whatever the recorder used, microseconds for every latency histogram here.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub struct HistogramSnapshot {
    pub count: u64,
    pub mean: u64,
    pub max: u64,
    pub p50: u64,
    pub p90: u64,
    pub p99: u64,
}

/// A source location that acquired a lock, rendered as `file:line`.
pub type LockSite = &'static Location<'static>;

fn site_label(site: LockSite) -> String {
    format!("{}:{}", site.file(), site.line())
}

#[derive(Clone, Copy)]
struct Holder {
    site: LockSite,
    since: Instant,
}

#[derive(Default)]
struct SiteStats {
    acquisitions: u64,
    hold_total_us: u64,
    hold_max_us: u64,
}

#[derive(Clone, Copy)]
struct Stall {
    waiter: LockSite,
    blocker: Option<LockSite>,
    waited: Duration,
}

/// Contention record for one mutex: how long acquirers waited, how long
/// holders held, which site holds it now, and which site blocked the longest
/// waiter. Sites come from `#[track_caller]`, so call sites need no labels.
#[derive(Default)]
pub struct LockStats {
    wait: LogLinearHistogram,
    hold: LogLinearHistogram,
    contended: AtomicU64,
    stalls: AtomicU64,
    holder: Mutex<Option<Holder>>,
    last_stall: Mutex<Option<Stall>>,
    sites: Mutex<HashMap<LockSite, SiteStats>>,
}

impl LockStats {
    pub fn new() -> Self {
        Self::default()
    }

    /// Call before blocking. Returns the site holding the lock at that moment
    /// so a later stall can name it.
    pub fn wait_started(&self) -> Option<LockSite> {
        self.holder.lock().unwrap_or_else(|e| e.into_inner()).map(|holder| holder.site)
    }

    /// `at` is when the lock was acquired (the caller's clock read, so this
    /// reads none).
    pub fn acquired(
        &self,
        site: LockSite,
        waited: Duration,
        blocker: Option<LockSite>,
        at: Instant,
    ) {
        self.wait.record_duration(waited);
        cmux_threads::note_thread_lock_wait(waited);
        if waited >= Duration::from_micros(500) {
            crate::debug_spans::mark_with(|| {
                format!("lock.wait {}:{} {}us", site.file(), site.line(), waited.as_micros()).into()
            });
        }
        if waited >= LOCK_CONTENDED_THRESHOLD {
            self.contended.fetch_add(1, Ordering::Relaxed);
        }
        if waited >= LOCK_STALL_THRESHOLD {
            self.stalls.fetch_add(1, Ordering::Relaxed);
            *self.last_stall.lock().unwrap_or_else(|e| e.into_inner()) =
                Some(Stall { waiter: site, blocker, waited });
        }
        *self.holder.lock().unwrap_or_else(|e| e.into_inner()) = Some(Holder { site, since: at });
    }

    /// Record a wait that ended without acquiring the mutex.
    pub fn wait_failed(&self, site: LockSite, waited: Duration, blocker: Option<LockSite>) {
        self.wait.record_duration(waited);
        cmux_threads::note_thread_lock_wait(waited);
        if waited >= LOCK_CONTENDED_THRESHOLD {
            self.contended.fetch_add(1, Ordering::Relaxed);
        }
        if waited >= LOCK_STALL_THRESHOLD {
            self.stalls.fetch_add(1, Ordering::Relaxed);
            *self.last_stall.lock().unwrap_or_else(|e| e.into_inner()) =
                Some(Stall { waiter: site, blocker, waited });
        }
    }

    pub fn released(&self, site: LockSite, held: Duration) {
        self.hold.record_duration(held);
        *self.holder.lock().unwrap_or_else(|e| e.into_inner()) = None;
        let held_us = u64::try_from(held.as_micros()).unwrap_or(u64::MAX);
        let mut sites = self.sites.lock().unwrap_or_else(|e| e.into_inner());
        let entry = sites.entry(site).or_default();
        entry.acquisitions += 1;
        entry.hold_total_us = entry.hold_total_us.saturating_add(held_us);
        entry.hold_max_us = entry.hold_max_us.max(held_us);
    }

    pub fn snapshot(&self) -> LockStatsSnapshot {
        let holder = self.holder.lock().unwrap_or_else(|e| e.into_inner()).map(|holder| {
            LockHolderSnapshot {
                site: site_label(holder.site),
                held_for_us: u64::try_from(holder.since.elapsed().as_micros()).unwrap_or(u64::MAX),
            }
        });
        let last_stall = self.last_stall.lock().unwrap_or_else(|e| e.into_inner()).map(|stall| {
            LockStallSnapshot {
                waiter: site_label(stall.waiter),
                blocker: stall.blocker.map(site_label),
                waited_us: u64::try_from(stall.waited.as_micros()).unwrap_or(u64::MAX),
            }
        });
        let mut top_sites: Vec<LockSiteSnapshot> = self
            .sites
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .iter()
            .map(|(site, stats)| LockSiteSnapshot {
                site: site_label(site),
                acquisitions: stats.acquisitions,
                hold_total_us: stats.hold_total_us,
                hold_max_us: stats.hold_max_us,
            })
            .collect();
        top_sites.sort_by(|a, b| b.hold_total_us.cmp(&a.hold_total_us).then(a.site.cmp(&b.site)));
        top_sites.truncate(TOP_SITES);
        LockStatsSnapshot {
            wait_us: self.wait.snapshot(),
            hold_us: self.hold.snapshot(),
            contended_acquisitions: self.contended.load(Ordering::Relaxed),
            stalls: self.stalls.load(Ordering::Relaxed),
            holder,
            last_stall,
            top_sites,
        }
    }
}

#[derive(Clone, Debug, Default, Serialize)]
pub struct LockStatsSnapshot {
    pub wait_us: HistogramSnapshot,
    pub hold_us: HistogramSnapshot,
    /// Acquisitions that waited at least 1 ms.
    pub contended_acquisitions: u64,
    /// Acquisitions that waited at least [`LOCK_STALL_THRESHOLD`].
    pub stalls: u64,
    pub holder: Option<LockHolderSnapshot>,
    pub last_stall: Option<LockStallSnapshot>,
    /// Sites ordered by total hold time, at most eight.
    pub top_sites: Vec<LockSiteSnapshot>,
}

#[derive(Clone, Debug, Serialize)]
pub struct LockHolderSnapshot {
    pub site: String,
    pub held_for_us: u64,
}

#[derive(Clone, Debug, Serialize)]
pub struct LockStallSnapshot {
    pub waiter: String,
    pub blocker: Option<String>,
    pub waited_us: u64,
}

#[derive(Clone, Debug, Serialize)]
pub struct LockSiteSnapshot {
    pub site: String,
    pub acquisitions: u64,
    pub hold_total_us: u64,
    pub hold_max_us: u64,
}

/// Wait and hold of one class of callers on one lock.
#[derive(Default)]
struct LockClassHistograms {
    wait: LogLinearHistogram,
    hold: LogLinearHistogram,
}

impl LockClassHistograms {
    fn snapshot(&self) -> LockClassSnapshot {
        let (wait_us, wait_p95_us) = self.wait.snapshot_with_p95();
        LockClassSnapshot { wait_us, wait_p95_us, hold_us: self.hold.snapshot() }
    }
}

/// Per-class wait and hold of one lock that admits by class
/// (`server::priority_gate`), plus how often automation yielded.
#[derive(Default)]
pub struct LockClassStats {
    frontend: LockClassHistograms,
    program: LockClassHistograms,
    automation: LockClassHistograms,
    automation_yields: AtomicU64,
    automation_due_admissions: AtomicU64,
}

impl LockClassStats {
    fn class(&self, cause: crate::event_cause::EventCause) -> &LockClassHistograms {
        use crate::event_cause::EventCause;
        match cause {
            EventCause::Frontend => &self.frontend,
            EventCause::Program => &self.program,
            EventCause::Automation => &self.automation,
        }
    }

    pub(crate) fn waited(&self, cause: crate::event_cause::EventCause, waited: Duration) {
        self.class(cause).wait.record_duration(waited);
    }

    pub(crate) fn held(&self, cause: crate::event_cause::EventCause, held: Duration) {
        self.class(cause).hold.record_duration(held);
    }

    /// An automation caller found a frontend caller waiting and yielded.
    pub(crate) fn automation_yielded(&self) {
        self.automation_yields.fetch_add(1, Ordering::Relaxed);
    }

    /// A yielding automation caller's admission came due while frontend
    /// callers still waited.
    pub(crate) fn automation_admitted_while_yielding(&self) {
        self.automation_due_admissions.fetch_add(1, Ordering::Relaxed);
    }

    pub fn snapshot(&self) -> LockClassesSnapshot {
        LockClassesSnapshot {
            frontend: self.frontend.snapshot(),
            program: self.program.snapshot(),
            automation: self.automation.snapshot(),
            automation_yields: self.automation_yields.load(Ordering::Relaxed),
            automation_due_admissions: self.automation_due_admissions.load(Ordering::Relaxed),
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub struct LockClassSnapshot {
    pub wait_us: HistogramSnapshot,
    /// The p95 of `wait_us`, a bucket upper bound like the others.
    pub wait_p95_us: u64,
    pub hold_us: HistogramSnapshot,
}

/// One lock's acquisitions by class: `frontend` (the verified app for the
/// person), `program` (terminal output, hooks, the journal writer) and
/// `automation` (agents, scripts, the CLI, pages).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub struct LockClassesSnapshot {
    pub frontend: LockClassSnapshot,
    pub program: LockClassSnapshot,
    pub automation: LockClassSnapshot,
    /// Automation acquisitions that found a frontend caller waiting and
    /// yielded to it.
    pub automation_yields: u64,
    /// Yielding automation callers let through because their admission
    /// came due (at least one every 4 ms) while frontends still waited.
    pub automation_due_admissions: u64,
}

/// The `lock_classes` section of `server-stats`.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub struct DaemonLockClassesSnapshot {
    pub registry: LockClassesSnapshot,
    pub registry_connection: LockClassesSnapshot,
    pub state: LockClassesSnapshot,
}

const WRITER_IDLE: u8 = 0;
const WRITER_WAITING_LOCK: u8 = 1;
const WRITER_COMMITTING: u8 = 2;

/// What the journal writer thread is doing right now.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum WriterPhase {
    Idle,
    WaitingLock,
    Committing,
}

/// Journal writer metrics: batch shape, commit cost, lane depth, and how
/// long producers waited for receipts.
pub struct JournalWriterStats {
    batches: AtomicU64,
    terminal_events: AtomicU64,
    durable_events: AtomicU64,
    batch_size: LogLinearHistogram,
    commit_us: LogLinearHistogram,
    commit_lock_wait_us: LogLinearHistogram,
    receipt_wait_us: LogLinearHistogram,
    commit_failures: AtomicU64,
    deadline_expiries: AtomicU64,
    terminal_queued: AtomicUsize,
    durable_queued: AtomicUsize,
    phase: Mutex<WriterPhaseState>,
}

impl Default for JournalWriterStats {
    fn default() -> Self {
        Self {
            batches: AtomicU64::new(0),
            terminal_events: AtomicU64::new(0),
            durable_events: AtomicU64::new(0),
            batch_size: LogLinearHistogram::new(),
            commit_us: LogLinearHistogram::new(),
            commit_lock_wait_us: LogLinearHistogram::new(),
            receipt_wait_us: LogLinearHistogram::new(),
            commit_failures: AtomicU64::new(0),
            deadline_expiries: AtomicU64::new(0),
            terminal_queued: AtomicUsize::new(0),
            durable_queued: AtomicUsize::new(0),
            phase: Mutex::new(WriterPhaseState { code: WRITER_IDLE, since: Instant::now() }),
        }
    }
}

impl JournalWriterStats {
    fn queued(&self, lane: JournalLane) -> &AtomicUsize {
        match lane {
            JournalLane::Terminal => &self.terminal_queued,
            JournalLane::Durable => &self.durable_queued,
        }
    }

    /// Call before the event becomes visible to the writer, so a drain can
    /// never observe a depth below the events it removes.
    pub(crate) fn enqueued(&self, lane: JournalLane) {
        self.queued(lane).fetch_add(1, Ordering::Relaxed);
    }

    /// Undo [`Self::enqueued`] when the channel refused the event.
    pub(crate) fn enqueue_failed(&self, lane: JournalLane) {
        self.drained(lane, 1);
    }

    pub(crate) fn drained(&self, lane: JournalLane, count: usize) {
        // Saturate so a miscounted path degrades to a wrong gauge, never a
        // wrapped one.
        let _ = self.queued(lane).fetch_update(Ordering::Relaxed, Ordering::Relaxed, |depth| {
            Some(depth.saturating_sub(count))
        });
    }

    pub fn batch_committed(&self, terminal_events: usize, durable_events: usize) {
        self.batches.fetch_add(1, Ordering::Relaxed);
        self.terminal_events.fetch_add(terminal_events as u64, Ordering::Relaxed);
        self.durable_events.fetch_add(durable_events as u64, Ordering::Relaxed);
        self.batch_size.record((terminal_events + durable_events) as u64);
    }

    pub fn commit_finished(&self, lock_wait: Duration, commit: Duration) {
        self.commit_lock_wait_us.record_duration(lock_wait);
        self.commit_us.record_duration(commit);
    }

    pub fn commit_failed(&self) {
        self.commit_failures.fetch_add(1, Ordering::Relaxed);
    }

    pub fn deadline_expired(&self) {
        self.deadline_expiries.fetch_add(1, Ordering::Relaxed);
    }

    pub fn receipt_waited(&self, waited: Duration) {
        self.receipt_wait_us.record_duration(waited);
    }

    pub fn set_phase(&self, phase: WriterPhase) {
        let code = match phase {
            WriterPhase::Idle => WRITER_IDLE,
            WriterPhase::WaitingLock => WRITER_WAITING_LOCK,
            WriterPhase::Committing => WRITER_COMMITTING,
        };
        let mut state = self.phase.lock().unwrap_or_else(|e| e.into_inner());
        *state = WriterPhaseState { code, since: Instant::now() };
    }

    pub fn snapshot(&self) -> JournalWriterSnapshot {
        let phase_state = self.phase.lock().unwrap_or_else(|e| e.into_inner());
        let phase = match phase_state.code {
            WRITER_WAITING_LOCK => WriterPhase::WaitingLock,
            WRITER_COMMITTING => WriterPhase::Committing,
            _ => WriterPhase::Idle,
        };
        let phase_for_us =
            u64::try_from(phase_state.since.elapsed().as_micros()).unwrap_or(u64::MAX);
        drop(phase_state);
        JournalWriterSnapshot {
            batches: self.batches.load(Ordering::Relaxed),
            terminal_events: self.terminal_events.load(Ordering::Relaxed),
            durable_events: self.durable_events.load(Ordering::Relaxed),
            batch_size: self.batch_size.snapshot(),
            commit_us: self.commit_us.snapshot(),
            commit_lock_wait_us: self.commit_lock_wait_us.snapshot(),
            receipt_wait_us: self.receipt_wait_us.snapshot(),
            commit_failures: self.commit_failures.load(Ordering::Relaxed),
            deadline_expiries: self.deadline_expiries.load(Ordering::Relaxed),
            terminal_queued: self.terminal_queued.load(Ordering::Relaxed),
            durable_queued: self.durable_queued.load(Ordering::Relaxed),
            phase,
            phase_for_us,
        }
    }
}

struct WriterPhaseState {
    code: u8,
    since: Instant,
}

#[derive(Clone, Debug, Serialize)]
pub struct JournalWriterSnapshot {
    pub batches: u64,
    pub terminal_events: u64,
    pub durable_events: u64,
    /// Events per committed batch. A mean near one under load means
    /// producers are being throttled before they reach the queue.
    pub batch_size: HistogramSnapshot,
    /// Transaction time including the fullfsync, excluding lock wait.
    pub commit_us: HistogramSnapshot,
    /// Time the writer waited for the registry lock before each batch.
    pub commit_lock_wait_us: HistogramSnapshot,
    /// Time producers waited from enqueue to receipt.
    pub receipt_wait_us: HistogramSnapshot,
    pub commit_failures: u64,
    pub deadline_expiries: u64,
    pub terminal_queued: usize,
    pub durable_queued: usize,
    pub phase: WriterPhase,
    pub phase_for_us: u64,
}

/// Connection admission on the control socket.
#[derive(Default)]
pub struct ConnectionStats {
    active: AtomicU64,
    peak: AtomicU64,
    refused: AtomicU64,
    accepted: AtomicU64,
}

impl ConnectionStats {
    /// Claims a slot if fewer than `limit` connections are active.
    pub fn try_claim(&self, limit: u64) -> bool {
        match self.active.fetch_update(Ordering::AcqRel, Ordering::Acquire, |count| {
            (count < limit).then_some(count + 1)
        }) {
            Ok(previous) => {
                // Use the count this claim produced, not a later reload: a
                // release in between would under-report the peak.
                self.peak.fetch_max(previous + 1, Ordering::Relaxed);
                self.accepted.fetch_add(1, Ordering::Relaxed);
                true
            }
            Err(_) => {
                self.refused.fetch_add(1, Ordering::Relaxed);
                false
            }
        }
    }

    pub fn release(&self) {
        self.active.fetch_sub(1, Ordering::AcqRel);
    }

    pub fn active(&self) -> u64 {
        self.active.load(Ordering::Acquire)
    }

    pub fn snapshot(&self, limit: u64) -> ConnectionSnapshot {
        ConnectionSnapshot {
            active: self.active.load(Ordering::Acquire),
            peak: self.peak.load(Ordering::Relaxed),
            limit,
            accepted: self.accepted.load(Ordering::Relaxed),
            refused: self.refused.load(Ordering::Relaxed),
        }
    }
}

#[derive(Clone, Debug, Default, Serialize)]
pub struct ConnectionSnapshot {
    pub active: u64,
    pub peak: u64,
    pub limit: u64,
    pub accepted: u64,
    /// Connections dropped because `limit` was reached. Any non-zero value
    /// means a client saw a failed connect, which for hooks is a lost event.
    pub refused: u64,
}

/// Everything `server-stats` returns.
#[derive(Clone, Debug, Serialize)]
pub struct ServerStatsSnapshot {
    pub schema: u32,
    pub uptime_ms: u64,
    pub registry_lock: LockStatsSnapshot,
    pub journal_writer: Option<JournalWriterSnapshot>,
    pub connections: ConnectionSnapshot,
    /// Present only when the request names `resource_projection` in
    /// `include`: older SDK decoders refuse unknown result fields.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub resource_projection: Option<ResourceProjectionSnapshot>,
    /// Present only when the request names `write_path` in `include`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub write_path: Option<WritePathSnapshot>,
    /// Present only when the request names `request_path_io` in `include`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub request_path_io: Option<crate::request_path::RequestPathIoSnapshot>,
    /// Present only when the request names `slow_requests` in `include`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub slow_requests: Option<SlowRequestsSnapshot>,
    /// Arrival to reply queued by request class; present only when the
    /// request names `requests` in `include`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub request_latency_us: Option<RequestLatencySnapshot>,
    /// Parse to handler start, every class (`daemon.dispatch.queue_us`);
    /// present only when the request names `requests` in `include`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub dispatch_queue_us: Option<HistogramSnapshot>,
    /// Wait and hold by class on the registry, registry connection and
    /// state locks; present only when the request names `lock_classes`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub lock_classes: Option<DaemonLockClassesSnapshot>,
    /// Streams, sequence depths, messages and bytes by kind, parses per
    /// request, write syscalls and stalls and bad_message closes; present
    /// only when the request names `ipc` in `include`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ipc: Option<IpcSnapshot>,
    /// Request latency, handler time and lock wait by method; present only
    /// when the request names `ipc_methods` in `include`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ipc_methods: Option<Vec<MethodLatencySnapshot>>,
}

pub const SERVER_STATS_SCHEMA: u32 = 1;
