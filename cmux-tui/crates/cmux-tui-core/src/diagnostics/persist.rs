//! The daemon's histograms in its crash-safe metrics file (p09-observability
//! task 131): request latency per class, the dispatch queue, the registry
//! lock and the journal writer record into `metrics-daemon-<pid>.bin`
//! (cmux-trace `metrics`, the app's CmuxNextMetrics layout), so a daemon that
//! crashed or was killed leaves its numbers for the app to fold (task 062),
//! and `server-stats` reads the same memory.
//!
//! Chrome's model: a child process's histograms live in persistent memory
//! the browser reads, also after the child died
//! (base/metrics/persistent_histogram_allocator.h,
//! components/metrics/file_metrics_provider.cc).

use std::path::{Path, PathBuf};
use std::sync::Arc;

use cmux_trace::Role;
use cmux_trace::metrics::{Header, HistogramSpec, Layout, MetricsStore, Profile};

use super::{Counts, LogLinearHistogram};

/// The microsecond layout of the app's catalog (Swift `HistogramID.layout`
/// for `.microseconds`).
const MICROSECONDS: Layout = Layout::LogLinear { maximum: 60_000_000 };
/// The count layout of the app's catalog (`.count`).
const COUNT: Layout = Layout::LogLinear { maximum: 1_000_000 };

const fn spec(name: &'static str, layout: Layout) -> HistogramSpec {
    HistogramSpec { name, layout }
}

/// The daemon's histograms, in file order. `daemon.request.<class>` (the
/// classes of [`super::REQUEST_CLASSES`]) and `daemon.dispatch.queue_us` are
/// the app catalog's names (Swift `HistogramID.daemonRequest`,
/// `.daemonDispatchQueue`); the lock and journal names are the daemon's own
/// until the catalog lists them, so `server-stats` and a local fold read them
/// and an upload drops them.
pub const DAEMON_CATALOG: [HistogramSpec; 15] = [
    spec("daemon.request.topology", MICROSECONDS),
    spec("daemon.request.terminal_io", MICROSECONDS),
    spec("daemon.request.create", MICROSECONDS),
    spec("daemon.request.query", MICROSECONDS),
    spec("daemon.request.browser", MICROSECONDS),
    spec("daemon.request.agent", MICROSECONDS),
    spec("daemon.request.cloud", MICROSECONDS),
    spec("daemon.request.other", MICROSECONDS),
    spec("daemon.dispatch.queue_us", MICROSECONDS),
    spec("daemon.lock.registry.wait_us", MICROSECONDS),
    spec("daemon.lock.registry.hold_us", MICROSECONDS),
    spec("daemon.journal.commit_us", MICROSECONDS),
    spec("daemon.journal.commit_lock_wait_us", MICROSECONDS),
    spec("daemon.journal.receipt_wait_us", MICROSECONDS),
    spec("daemon.journal.batch_size", COUNT),
];

/// This daemon process's header, starting now. Reads a few sysctls: call it
/// once at startup.
pub fn daemon_header() -> Header {
    Header::current(Role::Daemon, Profile::current(""))
}

/// Where a session's daemon keeps its metrics file: `<state root>/metrics`,
/// beside the trace rings' `<state root>/trace`.
pub fn metrics_dir(state_root: &Path) -> PathBuf {
    state_root.join("metrics")
}

/// The daemon's metrics store and its catalog. The composition root makes
/// one ([`crate::Mux::start_metrics_file`]); nothing keeps it globally.
#[derive(Clone)]
pub struct DaemonMetrics {
    store: Arc<MetricsStore>,
}

impl DaemonMetrics {
    /// A store of [`DAEMON_CATALOG`] on the heap; no file work.
    pub fn new(header: Header) -> DaemonMetrics {
        DaemonMetrics { store: Arc::new(MetricsStore::new(&DAEMON_CATALOG, header)) }
    }

    pub fn store(&self) -> &Arc<MetricsStore> {
        &self.store
    }

    /// Makes `histogram` record into the catalog's `name` from now on, with
    /// its counts so far. False for a name outside the catalog or a histogram
    /// bound before.
    pub fn bind(&self, histogram: &LogLinearHistogram, name: &str) -> bool {
        self.store.index_of(name).is_some_and(|index| histogram.persist_into(&self.store, index))
    }
}

/// Where a persisted [`LogLinearHistogram`] records: one log-linear
/// histogram of a metrics store.
pub(super) struct PersistedSlot {
    store: Arc<MetricsStore>,
    index: usize,
    layout: Layout,
}

impl PersistedSlot {
    /// None unless `index` is a log-linear histogram of `store` (the only
    /// layout whose buckets are the daemon histogram's).
    pub(super) fn new(store: &Arc<MetricsStore>, index: usize) -> Option<PersistedSlot> {
        let layout = store.layout(index)?;
        matches!(layout, Layout::LogLinear { .. }).then(|| PersistedSlot {
            store: Arc::clone(store),
            index,
            layout,
        })
    }

    #[inline]
    pub(super) fn record(&self, value: u64) {
        self.store.record(self.index, i64::try_from(value).unwrap_or(i64::MAX));
    }

    /// Adds `samples` of the heap's bucket `bucket` (a
    /// [`LogLinearHistogram::bucket_index`]) to the file's histogram.
    pub(super) fn add_heap_bucket(&self, bucket: usize, samples: u64) {
        let lower = i64::try_from(heap_bucket_lower_bound(bucket)).unwrap_or(i64::MAX);
        self.store.add(self.index, lower, samples, 0);
    }

    /// Adds the heap's sum to the file's histogram.
    pub(super) fn add_heap_sum(&self, sum: u64) {
        self.store.add(self.index, 0, 0, sum);
    }

    /// The file's counts of this histogram; `max` stands for the overflow
    /// bucket's bound.
    pub(super) fn counts(&self, max: u64) -> Counts {
        let read = self.store.read(self.index).unwrap_or_default();
        Counts {
            count: read.buckets.iter().sum(),
            buckets: read.buckets,
            sum: read.sum,
            file_layout: Some(self.layout),
            max,
        }
    }
}

/// The smallest value of the heap histogram's bucket `bucket` (buckets 4 to 7
/// hold nothing; they map to 4).
fn heap_bucket_lower_bound(bucket: usize) -> u64 {
    if bucket < 4 {
        return bucket as u64;
    }
    if bucket < 8 {
        return 4;
    }
    let octave = (bucket / 4).min(63) as u32;
    let sub = (bucket % 4) as u64;
    (1u64 << octave) + sub * (1u64 << (octave - 2))
}

impl super::requests::RequestStats {
    /// Binds the per-class latency and the dispatch queue to `metrics`.
    /// False when they were bound before (to this or another store).
    pub fn persist_into(&self, metrics: &DaemonMetrics) -> bool {
        let mut bound = metrics.bind(self.dispatch_queue(), "daemon.dispatch.queue_us");
        for (class, name) in super::REQUEST_CLASSES.iter().enumerate() {
            bound &= metrics.bind(self.latency(class), &format!("daemon.request.{name}"));
        }
        bound
    }
}

impl super::LockStats {
    /// Binds wait and hold to `metrics` as `daemon.lock.<lock>.{wait,hold}_us`.
    pub fn persist_into(&self, metrics: &DaemonMetrics, lock: &str) {
        metrics.bind(&self.wait, &format!("daemon.lock.{lock}.wait_us"));
        metrics.bind(&self.hold, &format!("daemon.lock.{lock}.hold_us"));
    }
}

impl super::JournalWriterStats {
    /// Binds commit, commit lock wait, receipt wait and batch size to
    /// `metrics` as `daemon.journal.*`.
    pub fn persist_into(&self, metrics: &DaemonMetrics) {
        metrics.bind(&self.commit_us, "daemon.journal.commit_us");
        metrics.bind(&self.commit_lock_wait_us, "daemon.journal.commit_lock_wait_us");
        metrics.bind(&self.receipt_wait_us, "daemon.journal.receipt_wait_us");
        metrics.bind(&self.batch_size, "daemon.journal.batch_size");
    }
}

#[cfg(test)]
#[path = "persist_tests.rs"]
mod tests;
