//! Self-observation for the session daemon.
//!
//! The daemon should be able to say where its time goes without an operator
//! sampling it from outside. This module holds the counters that
//! `server-stats` reports: log-linear latency histograms, registry lock
//! contention with holder attribution, journal writer batch metrics, and
//! connection admission. Recording is lock-free except for the holder table,
//! which is held for nanoseconds, so the overhead stays far below the
//! millisecond-scale critical sections it measures.

use std::collections::HashMap;
use std::panic::Location;
use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use serde::Serialize;

use crate::journal_ingress::JournalLane;

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

    fn bucket_index(value: u64) -> usize {
        if value < SUB_BUCKETS as u64 {
            return value as usize;
        }
        let octave = 63 - value.leading_zeros();
        let sub = (value >> (octave - SUB_BUCKETS_LOG2)) & (SUB_BUCKETS as u64 - 1);
        octave as usize * SUB_BUCKETS + sub as usize
    }

    /// Largest value that lands in `index`.
    fn bucket_upper_bound(index: usize) -> u64 {
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

    pub fn snapshot(&self) -> HistogramSnapshot {
        let counts: Vec<u64> = self.buckets.iter().map(|b| b.load(Ordering::Relaxed)).collect();
        let count: u64 = counts.iter().sum();
        let percentile = |fraction: f64| -> u64 {
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
        };
        HistogramSnapshot {
            count,
            mean: self.sum.load(Ordering::Relaxed).checked_div(count).unwrap_or(0),
            max: self.max.load(Ordering::Relaxed),
            p50: percentile(0.50),
            p90: percentile(0.90),
            p99: percentile(0.99),
        }
    }
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

    pub fn acquired(&self, site: LockSite, waited: Duration, blocker: Option<LockSite>) {
        self.wait.record_duration(waited);
        if waited >= LOCK_CONTENDED_THRESHOLD {
            self.contended.fetch_add(1, Ordering::Relaxed);
        }
        if waited >= LOCK_STALL_THRESHOLD {
            self.stalls.fetch_add(1, Ordering::Relaxed);
            *self.last_stall.lock().unwrap_or_else(|e| e.into_inner()) =
                Some(Stall { waiter: site, blocker, waited });
        }
        *self.holder.lock().unwrap_or_else(|e| e.into_inner()) =
            Some(Holder { site, since: Instant::now() });
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
}

pub const SERVER_STATS_SCHEMA: u32 = 1;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn histogram_percentiles_are_bucket_upper_bounds_within_a_quarter() {
        let histogram = LogLinearHistogram::new();
        for value in [1u64, 2, 3, 5, 9, 17, 100, 1000, 20_000, 1_000_000] {
            histogram.record(value);
            let index = LogLinearHistogram::bucket_index(value);
            let upper = LogLinearHistogram::bucket_upper_bound(index);
            assert!(upper >= value, "{value} above its bucket bound {upper}");
            assert!(upper <= value + value / 4 + 1, "{value} bound {upper} too loose");
            if index > 0 {
                assert!(LogLinearHistogram::bucket_upper_bound(index - 1) < value);
            }
        }
        let snapshot = histogram.snapshot();
        assert_eq!(snapshot.count, 10);
        assert_eq!(snapshot.max, 1_000_000);
        assert!(snapshot.p50 >= 9 && snapshot.p50 <= 12, "{snapshot:?}");
        assert!(snapshot.p99 >= 1_000_000, "{snapshot:?}");
    }

    #[test]
    fn empty_histogram_reports_zeros() {
        assert_eq!(LogLinearHistogram::new().snapshot(), HistogramSnapshot::default());
    }

    #[test]
    fn default_constructed_stats_can_record() {
        let histogram = LogLinearHistogram::default();
        histogram.record(u64::MAX);
        histogram.record(u64::MAX);
        let snapshot = histogram.snapshot();
        assert_eq!((snapshot.count, snapshot.max, snapshot.p99), (2, u64::MAX, u64::MAX));
        assert_eq!(snapshot.mean, u64::MAX / 2, "sum saturates instead of wrapping");
        let stats = LockStats::default();
        stats.acquired(Location::caller(), Duration::from_secs(1), None);
        assert_eq!(stats.snapshot().wait_us.count, 1);
    }

    #[test]
    fn lock_stats_track_holder_stalls_and_sites() {
        let stats = LockStats::new();
        let site_a: LockSite = Location::caller();
        assert!(stats.wait_started().is_none());
        stats.acquired(site_a, Duration::from_micros(10), None);
        let snapshot = stats.snapshot();
        assert_eq!(
            snapshot.holder.as_ref().map(|h| h.site.as_str()),
            Some(site_label(site_a).as_str())
        );
        assert_eq!(snapshot.contended_acquisitions, 0);

        let blocker = stats.wait_started();
        assert_eq!(blocker, Some(site_a));
        stats.released(site_a, Duration::from_millis(3));
        stats.acquired(site_a, LOCK_STALL_THRESHOLD, blocker);
        stats.released(site_a, Duration::from_millis(1));

        let snapshot = stats.snapshot();
        assert!(snapshot.holder.is_none());
        assert_eq!(snapshot.contended_acquisitions, 1);
        assert_eq!(snapshot.stalls, 1);
        let stall = snapshot.last_stall.expect("stall recorded");
        assert_eq!(stall.blocker.as_deref(), Some(site_label(site_a).as_str()));
        assert_eq!(snapshot.top_sites.len(), 1);
        assert_eq!(snapshot.top_sites[0].acquisitions, 2);
        assert_eq!(snapshot.top_sites[0].hold_max_us, 3_000);
        assert_eq!(snapshot.hold_us.count, 2);
    }

    #[test]
    fn writer_stats_follow_queue_and_batches() {
        let stats = JournalWriterStats::default();
        stats.enqueued(JournalLane::Durable);
        stats.enqueued(JournalLane::Durable);
        stats.enqueued(JournalLane::Terminal);
        assert_eq!(stats.snapshot().durable_queued, 2);
        stats.enqueue_failed(JournalLane::Durable);
        assert_eq!(stats.snapshot().durable_queued, 1);
        stats.enqueued(JournalLane::Durable);
        stats.drained(JournalLane::Durable, 2);
        stats.drained(JournalLane::Terminal, 5);
        stats.set_phase(WriterPhase::Committing);
        stats.batch_committed(1, 2);
        stats.commit_finished(Duration::from_micros(5), Duration::from_millis(20));
        stats.set_phase(WriterPhase::Idle);
        let snapshot = stats.snapshot();
        assert_eq!((snapshot.durable_queued, snapshot.terminal_queued), (0, 0));
        assert_eq!(snapshot.batches, 1);
        assert_eq!(snapshot.batch_size.max, 3);
        assert!(snapshot.commit_us.p50 >= 20_000);
        assert_eq!(snapshot.phase, WriterPhase::Idle);
    }

    #[test]
    fn writer_phase_snapshot_uses_one_timestamp_for_each_phase() {
        let stats = JournalWriterStats::default();
        stats.set_phase(WriterPhase::WaitingLock);
        let waiting = stats.snapshot();
        std::thread::sleep(Duration::from_millis(1));
        stats.set_phase(WriterPhase::Committing);
        let committing = stats.snapshot();

        assert_eq!(waiting.phase, WriterPhase::WaitingLock);
        assert_eq!(committing.phase, WriterPhase::Committing);
        assert!(committing.phase_for_us < 100_000, "phase timestamp was not reset: {committing:?}");
    }

    #[test]
    fn connection_stats_enforce_the_limit_and_count_refusals() {
        let stats = ConnectionStats::default();
        assert!(stats.try_claim(2));
        assert!(stats.try_claim(2));
        assert!(!stats.try_claim(2));
        stats.release();
        assert!(stats.try_claim(2));
        let snapshot = stats.snapshot(2);
        assert_eq!(
            (snapshot.active, snapshot.peak, snapshot.accepted, snapshot.refused),
            (2, 2, 3, 1)
        );
    }
}
