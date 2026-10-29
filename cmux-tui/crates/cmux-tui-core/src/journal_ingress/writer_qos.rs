//! The journal writer's QoS: user-initiated while a
//! request waits for one of its receipts, utility otherwise.
//!
//! Chromium raises a sequence's priority when work someone waits on is
//! queued to it (`PooledSequencedTaskRunner::UpdatePriority`,
//! base/task/thread_pool/pooled_sequenced_task_runner.h) and runs
//! best-effort sequences on its background threads. Here every receipt wait
//! is counted before its event is queued; the writer reads the count at the
//! start of each commit attempt and runs that attempt below its declared
//! class only when the count is zero.
//!
//! The lowered class is a [`WorkQos`], so a ranked lock the attempt takes
//! (the registry connection) raises the writer while it holds it, as it does
//! a lowered request (`crate::lock_rank`). It is behind the default-off
//! `daemonRequestQos` feature with the request classes, and like them it is
//! never entered when the process could not take it back (Linux without
//! root or an `RLIMIT_NICE` that allows nice 0): the writer then stays at
//! its declared class.

use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use cmux_threads::ThreadQos;
use cmux_tui_platform::qos::WorkQos;

use crate::Mux;

/// The class the writer thread is started at, and runs at while a request
/// waits on it.
pub(super) const WRITER_QOS: ThreadQos = ThreadQos::UserInitiated;

/// The class of an attempt no request waits on.
pub(super) const IDLE_WRITER_QOS: ThreadQos = ThreadQos::Utility;

/// Receipt waits in progress: requests that queued an event with a
/// completion and have not taken its result yet, an indeterminate receipt
/// a registry commit keeps for later (`PendingRegistryReceipt`), and a
/// producer that waits for space in a full lane.
#[derive(Clone, Debug, Default)]
pub(super) struct RequestWaits(Arc<AtomicUsize>);

impl RequestWaits {
    /// Counts a receipt wait until the guard drops. Take it before the event
    /// is queued: the queue's send and receive order the count before the
    /// writer's read, so the attempt that commits the event sees it. The
    /// guard is owned, so a receipt that outlives its request (an
    /// indeterminate registry commit) keeps the wait counted until its
    /// answer is taken.
    pub(super) fn enter(&self) -> RequestWait {
        self.0.fetch_add(1, Ordering::Relaxed);
        RequestWait(self.0.clone())
    }

    fn any(&self) -> bool {
        self.0.load(Ordering::Relaxed) > 0
    }
}

/// One counted receipt wait; see [`RequestWaits::enter`].
#[derive(Debug)]
#[must_use = "the wait is counted only while the guard lives"]
pub(super) struct RequestWait(Arc<AtomicUsize>);

impl Drop for RequestWait {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::Relaxed);
    }
}

/// The class of one commit attempt, held for the attempt and its receipts:
/// `None` (the declared [`WRITER_QOS`]) while a request waits, else
/// [`IDLE_WRITER_QOS`] with the feature on.
pub(super) fn enter_attempt(mux: &Mux, waits: &RequestWaits) -> Option<WorkQos> {
    if waits.any() {
        return None;
    }
    mux.request_qos().enter_class(IDLE_WRITER_QOS)
}

#[cfg(test)]
#[path = "writer_qos_tests.rs"]
mod tests;
