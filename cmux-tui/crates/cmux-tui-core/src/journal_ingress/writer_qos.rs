//! The journal writer's QoS (p02-threads-212): user-initiated while a
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
//!
//! The count sets an attempt's class when the attempt starts, so it cannot
//! help a request that starts waiting during an attempt already lowered, or
//! one that runs above the writer's class. A thread that blocks on the
//! writer (a receipt or barrier wait, a wait for lane space, an
//! indeterminate registry receipt taken later) therefore donates its class
//! while it blocks ([`RequestWaits::donate`], p05-ipc-137). The writer's
//! attempt owns a [`cmux_threads::OwnerBoost`] whose waiters raise it to the
//! highest class among them, refcounted per class (macOS
//! `pthread_override_qos_class_start_np`, Chromium's
//! `SetCurrentThreadTypeOverride` in base/threading/platform_thread_apple.mm,
//! as libdispatch does for a `dispatch_sync` waiter). An attempt that starts
//! while a thread blocks raises itself; the override ends with the attempt,
//! so between attempts and while nothing blocks no override is in force. On
//! Linux the override is a nice change: without root or an `RLIMIT_NICE`
//! that allows it, it is refused and counted, and nothing changes.

use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

#[cfg(test)]
use cmux_threads::BoostCounts;
use cmux_threads::{OwnerBoost, OwnerHold, ThreadQos, WaitBoost};
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
/// producer that waits for space in a full lane. It also carries the
/// writer's donation: the threads blocked on the writer now.
#[derive(Clone, Debug, Default)]
pub(super) struct RequestWaits(Arc<Waits>);

#[derive(Debug, Default)]
struct Waits {
    count: AtomicUsize,
    /// Owned by the writer's commit attempt; its waiters are the threads
    /// blocked on the writer.
    writer: OwnerBoost,
}

impl RequestWaits {
    /// Counts a receipt wait until the guard drops. Take it before the event
    /// is queued: the queue's send and receive order the count before the
    /// writer's read, so the attempt that commits the event sees it. The
    /// guard is owned, so a receipt that outlives its request (an
    /// indeterminate registry commit) keeps the wait counted until its
    /// answer is taken.
    pub(super) fn enter(&self) -> RequestWait {
        self.0.count.fetch_add(1, Ordering::Relaxed);
        RequestWait(self.0.clone())
    }

    fn any(&self) -> bool {
        self.0.count.load(Ordering::Relaxed) > 0
    }

    /// The calling thread blocks on the writer until the result drops: a
    /// writer attempt below the caller's class runs at it until the attempt
    /// ends. Take it before the event is queued, so the attempt that commits
    /// it starts raised, and drop it once the receipt is in. It takes a leaf
    /// lock for a moment, so a caller may hold its own locks; a thread with
    /// no registered class donates nothing.
    pub(super) fn donate(&self) -> WaitBoost<'_> {
        self.0.writer.wait()
    }

    /// Held by the writer thread for one commit attempt and the delivery of
    /// its receipts: the attempt runs at the class of the highest thread
    /// blocked on it when that is above its own. Take it after the attempt's
    /// class ([`enter_attempt`]), so it drops first.
    pub(super) fn writer_attempt(&self) -> OwnerHold<&OwnerBoost> {
        OwnerBoost::hold(&self.0.writer)
    }

    /// The overrides waiters started on the writer, and the ones refused.
    #[cfg(test)]
    fn donations(&self) -> BoostCounts {
        self.0.writer.counts()
    }
}

#[cfg(test)]
impl super::JournalIngressSender {
    /// [`RequestWaits::donations`] of this ingress's writer.
    pub(crate) fn writer_donations(&self) -> BoostCounts {
        self.state.request_waits.donations()
    }
}

/// One counted receipt wait; see [`RequestWaits::enter`].
#[derive(Debug)]
#[must_use = "the wait is counted only while the guard lives"]
pub(super) struct RequestWait(Arc<Waits>);

impl RequestWait {
    /// [`RequestWaits::donate`] for the wait this guard counts.
    pub(super) fn donate(&self) -> WaitBoost<'_> {
        self.0.writer.wait()
    }
}

impl Drop for RequestWait {
    fn drop(&mut self) {
        self.0.count.fetch_sub(1, Ordering::Relaxed);
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

#[cfg(test)]
#[path = "read_barrier_qos_tests.rs"]
mod read_barrier_qos;
