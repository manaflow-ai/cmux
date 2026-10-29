//! Hangs another process's watcher saw (a holder's loop pass, its HANG
//! frame), handed to the watchdog thread to write.
//!
//! The report arrives on a holder link's reader, a user-interactive thread
//! every terminal's output passes through, so the reader only queues it and
//! arms the watchdog; the `mux-request-watchdog` thread writes the hang-log
//! line on its next wake, as it writes every other hang (cmux-panic-log
//! `hang`: the watchdog thread is its one writer). Chrome's HangWatcher hands
//! a hang to its own thread the same way: the watched thread never reports
//! or writes anything (base/threading/hang_watcher.cc).

use cmux_threads::sync::Mutex;
use std::collections::VecDeque;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use super::Shared;
use crate::panic_free::RecoverPoison;

/// `stack_error` of a hang another process reported: the thread is there.
const OTHER_PROCESS: &str = "other-process";

/// Reports waiting for the watchdog thread; one that finds the queue full
/// is dropped and counted (the holder is stuck, and the queued ones say so).
pub(super) const REPORTED_HANG_QUEUE: usize = 16;

/// One reported hang, stamped when it arrived.
struct ReportedHang {
    scope: &'static str,
    method: String,
    hang_ms: u64,
    busy_ms: u64,
    at_us: u64,
}

/// The queue between the reader that receives a report and the watchdog
/// thread that writes it.
pub(super) struct ReportedHangs {
    /// Lock carve-out: one push by a holder link's reader and one pop by the
    /// watchdog thread, nothing else under it; never held across a write or
    /// an allocation (its capacity is reserved up front).
    queue: Mutex<VecDeque<ReportedHang>>,
    /// Reports dropped on a full queue.
    pub(super) dropped: AtomicU64,
}

impl Default for ReportedHangs {
    fn default() -> Self {
        Self {
            queue: Mutex::new(VecDeque::with_capacity(REPORTED_HANG_QUEUE)),
            dropped: AtomicU64::new(0),
        }
    }
}

impl Shared {
    /// Queue a hang another process's watcher saw for the watchdog thread
    /// to write, scope `scope`, counted in `hangs` once written. It has no
    /// stack: the hung thread is in that process. No disk I/O on the caller.
    pub(super) fn report_hang(
        self: &Arc<Self>,
        scope: &'static str,
        method: &str,
        hang_ms: u64,
        busy_ms: u64,
    ) {
        let report = ReportedHang {
            scope,
            method: method.to_owned(),
            hang_ms,
            busy_ms,
            at_us: self.now_us(),
        };
        {
            let mut queue = self.reported.queue.lock().recover_poison();
            if queue.len() >= REPORTED_HANG_QUEUE {
                self.reported.dropped.fetch_add(1, Ordering::Relaxed);
                return;
            }
            queue.push_back(report);
        }
        // After the push: a watchdog that disarms after this load sees the
        // queue in its last look (`has_reported`).
        self.arm();
    }

    /// Whether a report waits for [`Self::write_reported`].
    pub(super) fn has_reported(&self) -> bool {
        !self.reported.queue.lock().recover_poison().is_empty()
    }

    /// The watchdog thread: write every queued report to the hang log.
    pub(super) fn write_reported(&self) {
        loop {
            let next = self.reported.queue.lock().recover_poison().pop_front();
            let Some(report) = next else { return };
            self.hangs.fetch_add(1, Ordering::Relaxed);
            let at_ms = self.epoch_ms.saturating_add(report.at_us / 1000);
            (self.hang_sink)(serde_json::json!({
                "event": "hang",
                "scope": report.scope,
                "method": report.method,
                "hang_ms": report.hang_ms,
                "busy_ms": report.busy_ms,
                "duration_ms": null,
                "started_at_ms": at_ms.saturating_sub(report.busy_ms),
                "at_ms": at_ms,
                "stack": [],
                "stack_truncated": false,
                "stack_error": OTHER_PROCESS,
            }));
        }
    }
}
