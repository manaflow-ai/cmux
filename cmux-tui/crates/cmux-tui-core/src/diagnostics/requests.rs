//! Control-request latency: Chrome's per-task timing histograms
//! (`base/task/common/task_annotator.cc` times each task from its post to its
//! run; `base/metrics/histogram_macros.h` records lock-free), with a daemon
//! request as the task. The request spans (server/request_spans.rs) record
//! it; `server-stats` reports it when `include` names `requests`.

use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use serde::Serialize;

use super::{HistogramSnapshot, LogLinearHistogram, MethodLatencyStats};

/// The request classes [`RequestStats`] keeps, by index: the server's
/// `MethodClass` in declaration order (server/command_names.rs; the request
/// span tests pin the two lists to each other).
pub const REQUEST_CLASSES: [&str; 8] =
    ["topology", "terminal_io", "create", "query", "browser", "agent", "cloud", "other"];

/// Per-class request latency (a request line's arrival to its reply entering
/// the connection's outbound queue) and the dispatch queue (its parse to its
/// handler's start), over every connection of the daemon.
pub struct RequestStats {
    latency_us: [LogLinearHistogram; REQUEST_CLASSES.len()],
    dispatch_queue_us: LogLinearHistogram,
    /// The same requests by method (`server-stats` `ipc`).
    methods: MethodLatencyStats,
    /// The last id given to an async reply's trace slice.
    async_ids: AtomicU64,
}

impl Default for RequestStats {
    fn default() -> Self {
        Self {
            latency_us: std::array::from_fn(|_| LogLinearHistogram::new()),
            dispatch_queue_us: LogLinearHistogram::new(),
            methods: crate::server::method_latency_stats(),
            async_ids: AtomicU64::new(0),
        }
    }
}

impl RequestStats {
    /// One request of class `class` (an index into [`REQUEST_CLASSES`]; a
    /// larger one counts as `other`) was answered `latency` after it arrived.
    pub fn record_latency(&self, class: usize, latency: Duration) {
        self.latency_us[class.min(REQUEST_CLASSES.len() - 1)].record_duration(latency);
    }

    /// The per-method histograms.
    pub fn methods(&self) -> &MethodLatencyStats {
        &self.methods
    }

    /// One request waited `queued` from its parse to its handler's start.
    pub fn record_dispatch_queue(&self, queued: Duration) {
        self.dispatch_queue_us.record_duration(queued);
    }

    /// A fresh id for one async reply's trace slice; never 0.
    pub fn next_async_id(&self) -> u64 {
        self.async_ids.fetch_add(1, Ordering::Relaxed).wrapping_add(1)
    }

    pub fn snapshot(&self) -> RequestStatsSnapshot {
        let [topology, terminal_io, create, query, browser, agent, cloud, other] =
            std::array::from_fn(|class| self.latency_us[class].snapshot());
        RequestStatsSnapshot {
            request_latency_us: RequestLatencySnapshot {
                topology,
                terminal_io,
                create,
                query,
                browser,
                agent,
                cloud,
                other,
            },
            dispatch_queue_us: self.dispatch_queue_us.snapshot(),
        }
    }
}

/// [`RequestStats`] read at one moment.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct RequestStatsSnapshot {
    pub request_latency_us: RequestLatencySnapshot,
    pub dispatch_queue_us: HistogramSnapshot,
}

/// Arrival to reply queued, by request class (`daemon.request.<class>`).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub struct RequestLatencySnapshot {
    pub topology: HistogramSnapshot,
    pub terminal_io: HistogramSnapshot,
    pub create: HistogramSnapshot,
    pub query: HistogramSnapshot,
    pub browser: HistogramSnapshot,
    pub agent: HistogramSnapshot,
    pub cloud: HistogramSnapshot,
    pub other: HistogramSnapshot,
}
