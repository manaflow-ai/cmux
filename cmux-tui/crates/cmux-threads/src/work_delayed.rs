//! Delayed items, as Chrome's `DelayedTaskManager` (base/task/thread_pool/delayed_task_manager.cc):
//! one service thread holds every item posted with a delay, waits until the earliest is due and
//! hands it to its lane then. A retry with backoff reposts itself with a delay instead of keeping a
//! thread asleep between tries.
//!
//! - The thread starts with the first delayed item and waits with no timeout while none is queued,
//!   so an idle [`super::Work`] has 0 wakeups from it.
//! - [`super::Work::shutdown`] drops every waiting item except block items, which go to their lane at
//!   once (the lane runs them at `UserBlocking`), and refuses new ones the same way. Dropping the
//!   `Work` drops the waiting items and ends the thread.
//! - If the thread cannot start, a delayed item goes to its lane at once: a retry that runs early is
//!   harmless, one that never runs is not.

use std::cmp::Ordering;
use std::collections::BinaryHeap;
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError};
use std::time::{Duration, Instant};

use super::{Job, LaneShared, Refused, Shutdown, WorkConfig};
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
    /// Shutdown has started: non-block items are refused.
    closed: bool,
    /// The `Work` is gone: the service thread exits.
    released: bool,
}

struct DelayShared {
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
}

impl Delayed {
    pub(super) fn new(config: Arc<WorkConfig>) -> Delayed {
        Delayed {
            shared: Arc::new(DelayShared {
                state: Mutex::new(DelayState::default()),
                changed: Condvar::new(),
            }),
            config,
        }
    }

    /// Queues `job` for `lane` once `delay` has passed.
    pub(super) fn post(
        &self,
        delay: Duration,
        lane: &Arc<LaneShared>,
        job: Job,
    ) -> Result<(), Refused> {
        let mut state = self.shared.lock();
        if state.closed {
            drop(state);
            // A block item still runs: the lane takes it after close.
            return if job.shutdown == Shutdown::BlockShutdown {
                lane.submit(job)
            } else {
                Err(Refused)
            };
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

    /// Starts shutdown: drops the waiting non-block items (returned, so the caller drops them outside
    /// every lock) and hands the block items to their lanes now.
    pub(super) fn close(&self) -> Vec<Job> {
        let waiting = {
            let mut state = self.shared.lock();
            state.closed = true;
            std::mem::take(&mut state.queue)
        };
        self.shared.changed.notify_one();
        let mut dropped = Vec::new();
        for Due { lane, job, .. } in waiting.into_sorted_vec().into_iter().rev() {
            if job.shutdown == Shutdown::BlockShutdown {
                // A lane takes a block item open or closed.
                let _ = lane.submit(job);
            } else {
                dropped.push(job);
            }
        }
        dropped
    }

    fn start_thread(&self) {
        let shared = Arc::clone(&self.shared);
        let started = self.config.spawner.spawn(
            format!("{}-delay", self.config.label),
            ThreadQos::UserInitiated,
            Box::new(move || run(&shared)),
        );
        if started.is_err() {
            // Early beats never: every waiting item goes to its lane now; the next post tries again.
            let waiting = {
                let mut state = self.shared.lock();
                state.started = false;
                std::mem::take(&mut state.queue)
            };
            for Due { lane, job, .. } in waiting.into_sorted_vec().into_iter().rev() {
                let _ = lane.submit(job);
            }
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
            // A lane closed since (shutdown) refuses a non-block item, which drops it.
            let _ = lane.submit(job);
        }
    }
}

#[cfg(test)]
#[path = "work_delayed_tests.rs"]
mod tests;
