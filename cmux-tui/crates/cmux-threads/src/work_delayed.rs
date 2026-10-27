//! Delayed items, as Chrome's `DelayedTaskManager` (base/task/thread_pool/delayed_task_manager.cc):
//! one service thread holds every item posted with a delay, waits until the earliest is due and
//! hands it to its lane then. A retry with backoff reposts itself with a delay instead of keeping a
//! thread asleep between tries.
//!
//! - The thread starts with the first delayed item and waits with no timeout while none is queued,
//!   so an idle [`super::Work`] has 0 wakeups from it.
//! - A delayed item never holds shutdown back: a block item posted with a delay is queued as a skip
//!   item, and [`super::Work::shutdown`] drops every waiting item and refuses new ones, as Chrome's
//!   `TaskTracker::WillPostTask` refuses every delayed task once shutdown has started
//!   (base/task/thread_pool/task_tracker.cc). So no block item is ever outside both this queue and
//!   its lane's count while shutdown waits. Dropping the `Work` drops the waiting items and ends the
//!   thread.
//! - The thread runs at `UserInitiated`. When the posting thread's nice value is above that (Linux),
//!   the [`super::Work`]'s launcher starts it, as it starts the lanes' workers.
//! - If the thread cannot start, a delayed item goes to its lane at once: a retry that runs early is
//!   harmless, one that never runs is not.

use std::cmp::Ordering;
use std::collections::BinaryHeap;
use std::sync::mpsc::SendError;
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError};
use std::time::{Duration, Instant};

use super::{Job, LaneShared, Launch, Launcher, Refused, Shutdown, WorkConfig, can_start_at};
use crate::qos::ThreadQos;

/// One waiting item.
struct Due {
    at: Instant,
    /// Post order, so items due at the same instant run in the order posted.
    seq: u64,
    lane: Arc<LaneShared>,
    job: Job,
}

impl PartialEq for Due {
    fn eq(&self, other: &Self) -> bool {
        (self.at, self.seq) == (other.at, other.seq)
    }
}

impl Eq for Due {}

impl PartialOrd for Due {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for Due {
    /// Reversed, so the `BinaryHeap` (a max-heap) yields the earliest item first.
    fn cmp(&self, other: &Self) -> Ordering {
        (other.at, other.seq).cmp(&(self.at, self.seq))
    }
}

#[derive(Default)]
struct DelayState {
    queue: BinaryHeap<Due>,
    next_seq: u64,
    /// The service thread is running or being started.
    started: bool,
    /// Shutdown has started: new items are refused.
    closed: bool,
    /// The `Work` is gone: the service thread exits.
    released: bool,
}

/// The queue the service thread serves; the launcher gets it to start that thread.
pub(super) struct DelayShared {
    // Lock carve-out: a short critical section over the queue; no item body, no lane lock and no
    // thread spawn runs under it.
    state: Mutex<DelayState>,
    changed: Condvar,
}

impl DelayShared {
    fn lock(&self) -> MutexGuard<'_, DelayState> {
        // No item body runs under the lock, so a poisoned lock still holds consistent state.
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

/// The delayed items of one [`super::Work`].
pub(super) struct Delayed {
    shared: Arc<DelayShared>,
    config: Arc<WorkConfig>,
    launcher: Option<Arc<Launcher>>,
}

impl Delayed {
    pub(super) fn new(config: Arc<WorkConfig>, launcher: Option<Arc<Launcher>>) -> Delayed {
        Delayed {
            shared: Arc::new(DelayShared {
                state: Mutex::new(DelayState::default()),
                changed: Condvar::new(),
            }),
            config,
            launcher,
        }
    }

    /// Queues `job` for `lane` once `delay` has passed; a block item is queued as a skip item.
    pub(super) fn post(
        &self,
        delay: Duration,
        lane: &Arc<LaneShared>,
        mut job: Job,
    ) -> Result<(), Refused> {
        if job.shutdown == Shutdown::BlockShutdown {
            job.shutdown = Shutdown::SkipOnShutdown;
        }
        let mut state = self.shared.lock();
        if state.closed {
            drop(state);
            drop(job);
            return Err(Refused);
        }
        let at = Instant::now() + delay;
        let seq = state.next_seq;
        state.next_seq += 1;
        let earliest = state.queue.peek().is_none_or(|first| at < first.at);
        state.queue.push(Due { at, seq, lane: Arc::clone(lane), job });
        let start = !std::mem::replace(&mut state.started, true);
        drop(state);
        if start {
            self.start_thread();
        } else if earliest {
            self.shared.changed.notify_one();
        }
        Ok(())
    }

    /// Items waiting for their delay.
    pub(super) fn pending(&self) -> usize {
        self.shared.lock().queue.len()
    }

    /// Starts shutdown: refuses new items and returns the waiting ones (none is a block item), so the
    /// caller drops them outside every lock.
    pub(super) fn close(&self) -> Vec<Job> {
        let waiting = {
            let mut state = self.shared.lock();
            state.closed = true;
            std::mem::take(&mut state.queue)
        };
        self.shared.changed.notify_one();
        waiting.into_vec().into_iter().map(|Due { job, .. }| job).collect()
    }

    /// Starts the service thread here, or through the launcher when this thread's nice value is
    /// above `UserInitiated` ([`can_start_at`]).
    fn start_thread(&self) {
        let launcher = self.launcher.as_ref().filter(|_| !can_start_at(ThreadQos::UserInitiated));
        let Some(launcher) = launcher else {
            start_thread(&self.shared, &self.config);
            return;
        };
        let request =
            Launch::Delay { shared: Arc::clone(&self.shared), config: Arc::clone(&self.config) };
        if let Err(SendError(request)) = launcher.requests.send(request) {
            // The launcher is gone only if it panicked: start the thread here, at this thread's
            // nice value, rather than strand the waiting items.
            request.start();
        }
    }
}

/// Starts the service thread of `shared`. If it cannot start, every waiting item goes to its lane
/// now (early beats never) and the next post tries again.
pub(super) fn start_thread(shared: &Arc<DelayShared>, config: &WorkConfig) {
    let thread_shared = Arc::clone(shared);
    let started = config.spawner.spawn(
        format!("{}-delay", config.label),
        ThreadQos::UserInitiated,
        Box::new(move || run(&thread_shared)),
    );
    if started.is_err() {
        let waiting = {
            let mut state = shared.lock();
            state.started = false;
            std::mem::take(&mut state.queue)
        };
        for Due { lane, job, .. } in waiting.into_sorted_vec().into_iter().rev() {
            let _ = lane.submit(job);
        }
    }
}

impl Drop for Delayed {
    fn drop(&mut self) {
        let waiting = {
            let mut state = self.shared.lock();
            state.released = true;
            std::mem::take(&mut state.queue)
        };
        self.shared.changed.notify_one();
        drop(waiting);
    }
}

/// The service thread: hands each item to its lane when it is due.
fn run(shared: &DelayShared) {
    let mut due = Vec::new();
    loop {
        {
            let mut state = shared.lock();
            loop {
                if state.released {
                    return;
                }
                let now = Instant::now();
                while state.queue.peek().is_some_and(|first| first.at <= now) {
                    due.extend(state.queue.pop());
                }
                if !due.is_empty() {
                    break;
                }
                let Some(remaining) = state.queue.peek().map(|first| first.at - now) else {
                    state = shared.changed.wait(state).unwrap_or_else(PoisonError::into_inner);
                    continue;
                };
                // wakeup-allow: deadline the earliest delayed item's due time; an earlier post ends the wait first
                let waited = shared.changed.wait_timeout(state, remaining);
                state = waited.unwrap_or_else(PoisonError::into_inner).0;
            }
        }
        for Due { lane, job, .. } in due.drain(..) {
            // A lane closed since (shutdown) refuses the item, which drops it.
            let _ = lane.submit(job);
        }
    }
}

#[cfg(test)]
#[path = "work_delayed_tests.rs"]
mod tests;
