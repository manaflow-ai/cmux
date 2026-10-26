//! Per-method request latency: one set of log-linear histograms per daemon
//! method, Chrome's per-message-type IPC timing (`mojo/core/channel.cc` and
//! the `Mojo.Channel.*` histograms count per message; the scheduler keeps
//! per-task-type queue and run times, `base/task/sequence_manager/
//! task_queue_impl.cc`). A method's slot is its row in the daemon's method
//! table (server/request_spans.rs); `server-stats` reports the methods that
//! ran when `include` names `ipc`.
//!
//! Recording is lock-free and allocates nothing: a method's histograms are
//! made the first time it runs (one `OnceLock` init per method per daemon),
//! and each request then adds to atomics.

use std::sync::OnceLock;
use std::time::Duration;

use serde::Serialize;

use super::{LogLinearHistogram, PercentilesSnapshot};

/// One answered request's timing.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct MethodSample {
    /// The line's arrival to its reply entering the outbound queue.
    pub latency: Duration,
    /// The handler's start to its reply entering the outbound queue.
    pub handler: Duration,
    /// The time the handling thread waited for locks between the two.
    pub lock_wait: Duration,
}

/// The histograms of one method, in microseconds.
#[derive(Default)]
struct MethodHistograms {
    latency_us: LogLinearHistogram,
    handler_us: LogLinearHistogram,
    lock_wait_us: LogLinearHistogram,
}

/// Every method's histograms, by slot.
pub struct MethodLatencyStats {
    slots: Box<[OnceLock<MethodHistograms>]>,
}

impl MethodLatencyStats {
    /// Room for `slots` methods; nothing is allocated per method until it runs.
    pub fn new(slots: usize) -> Self {
        Self { slots: (0..slots).map(|_| OnceLock::new()).collect() }
    }

    /// Counts one request of the method in `slot`. A slot past the table is
    /// dropped (it would be a method the table does not know).
    pub fn record(&self, slot: usize, sample: MethodSample) {
        debug_assert!(slot < self.slots.len(), "method slot {slot} is past the table");
        let Some(cell) = self.slots.get(slot) else { return };
        let histograms = cell.get_or_init(MethodHistograms::default);
        histograms.latency_us.record_duration(sample.latency);
        histograms.handler_us.record_duration(sample.handler);
        histograms.lock_wait_us.record_duration(sample.lock_wait);
    }

    /// Every method that ran, in slot order; `describe` names a slot.
    pub fn snapshot(&self, describe: impl Fn(usize) -> MethodName) -> IpcStatsSnapshot {
        let methods = self
            .slots
            .iter()
            .enumerate()
            .filter_map(|(slot, cell)| cell.get().map(|histograms| (slot, histograms)))
            .map(|(slot, histograms)| {
                let MethodName { id, method, class } = describe(slot);
                MethodLatencySnapshot {
                    method,
                    id,
                    class,
                    latency_us: histograms.latency_us.percentiles(),
                    handler_us: histograms.handler_us.percentiles(),
                    lock_wait_us: histograms.lock_wait_us.percentiles(),
                }
            })
            .filter(|method| method.latency_us.count > 0)
            .collect();
        IpcStatsSnapshot { methods }
    }
}

/// What a slot's row says about its method.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MethodName {
    /// The method id of its `daemon.request` trace slice.
    pub id: u16,
    /// The `cmd` tag, the v2 `operation`, or `route:<class>` for a line a
    /// feature route answers.
    pub method: String,
    /// Its `MethodClass` (`request_latency_us.<class>`).
    pub class: &'static str,
}

/// One method's distributions, in microseconds.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct MethodLatencySnapshot {
    pub method: String,
    pub id: u16,
    pub class: &'static str,
    pub latency_us: PercentilesSnapshot,
    pub handler_us: PercentilesSnapshot,
    pub lock_wait_us: PercentilesSnapshot,
}

/// The `server-stats` `ipc` section.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub struct IpcStatsSnapshot {
    /// The methods that ran since the daemon started, by method id.
    pub methods: Vec<MethodLatencySnapshot>,
}
