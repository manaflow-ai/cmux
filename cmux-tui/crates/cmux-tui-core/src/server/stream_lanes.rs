//! Request lanes of a connection's client streams (`attach-streams-v1`,
//! plans/cmux-next/app-daemon-connection-DESIGN.md section 3.3).
//!
//! A request that names a stream runs on that stream's lane; lanes are
//! independent FIFOs, the ordering domains separate per-view connections
//! used to give. A slow request of one view (an attach that waits for a
//! hosted resize, a `send` to a PTY whose program stopped reading) therefore
//! never delays another view's requests or the control lane.
//!
//! Workers are threads that park on a condvar while no lane is runnable: no
//! timer and no polling at idle. A lane runs on at most one worker at a time,
//! and after each request it goes to the back of the runnable queue, so busy
//! lanes take turns. A worker is spawned only when runnable lanes outnumber
//! the workers that are not inside a job: the thread count is the high-water of concurrently
//! busy lanes.

use super::attach_frames::ClientStreamId;
use crate::panic_free::RecoverPoison;
use std::collections::HashMap;
use std::collections::VecDeque;
use std::sync::Arc;
use std::sync::Condvar;
use std::sync::Mutex;
use std::time::Duration;
use std::time::Instant;

/// Why a request was not queued.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum LaneRefusal {
    /// The lane holds its maximum count or bytes of queued requests.
    Full,
    /// The connection is closing.
    Closed,
    /// No worker thread could be started.
    Spawn,
}

/// Runs one job; false closes the connection's lanes (the connection ends).
type Runner<J> = dyn Fn(J) -> bool + Send + Sync;

pub(super) struct StreamLanes<J: Send + 'static> {
    shared: Arc<Shared<J>>,
}

struct Shared<J> {
    state: Mutex<State<J>>,
    /// Wakes a parked worker: a lane became runnable, or the lanes closed.
    work: Condvar,
    /// Wakes `wait_for_workers`: a worker ended.
    exited: Condvar,
    run: Box<Runner<J>>,
    max_jobs: usize,
    max_bytes: usize,
}

struct State<J> {
    lanes: HashMap<ClientStreamId, Lane<J>>,
    /// Lanes with queued work that no worker runs, in turn order.
    runnable: VecDeque<ClientStreamId>,
    workers: usize,
    /// Workers inside a job. A worker that is not (parked, or between jobs
    /// with the lock held) takes the next runnable lane before it parks.
    running: usize,
    /// Highest number of worker threads (diagnostics, tests).
    peak_workers: usize,
    closed: bool,
}

struct Lane<J> {
    queue: VecDeque<(J, usize)>,
    bytes: usize,
    running: bool,
}

impl<J: Send + 'static> StreamLanes<J> {
    /// Lanes that run each job with `run`. `max_jobs` and `max_bytes` bound
    /// what one lane may hold queued.
    pub(super) fn new(
        max_jobs: usize,
        max_bytes: usize,
        run: impl Fn(J) -> bool + Send + Sync + 'static,
    ) -> Self {
        Self {
            shared: Arc::new(Shared {
                state: Mutex::new(State {
                    lanes: HashMap::new(),
                    runnable: VecDeque::new(),
                    workers: 0,
                    running: 0,
                    peak_workers: 0,
                    closed: false,
                }),
                work: Condvar::new(),
                exited: Condvar::new(),
                run: Box::new(run),
                max_jobs,
                max_bytes,
            }),
        }
    }

    /// Queue `job` (retaining `bytes`) on `lane`, after every earlier job of
    /// that lane. Never waits.
    pub(super) fn submit(
        &self,
        lane: ClientStreamId,
        job: J,
        bytes: usize,
    ) -> Result<(), LaneRefusal> {
        let mut state = self.shared.state.lock().recover_poison();
        if state.closed {
            return Err(LaneRefusal::Closed);
        }
        let entry = state.lanes.entry(lane).or_insert_with(|| Lane {
            queue: VecDeque::new(),
            bytes: 0,
            running: false,
        });
        if entry.queue.len() >= self.shared.max_jobs
            || bytes > self.shared.max_bytes.saturating_sub(entry.bytes)
        {
            return Err(LaneRefusal::Full);
        }
        let was_idle = entry.queue.is_empty() && !entry.running;
        entry.queue.push_back((job, bytes));
        entry.bytes += bytes;
        if was_idle {
            state.runnable.push_back(lane);
        }
        // Every worker not inside a job takes one runnable lane before it parks;
        // spawn when the runnable lanes outnumber them.
        let spawn = was_idle && state.runnable.len() > state.workers - state.running;
        if spawn {
            state.workers += 1;
            state.peak_workers = state.peak_workers.max(state.workers);
        }
        drop(state);
        if spawn {
            let shared = self.shared.clone();
            let spawned = std::thread::Builder::new()
                .name("mux-stream-lane".into())
                .spawn(move || run_worker(&shared));
            if spawned.is_err() {
                let mut state = self.shared.state.lock().recover_poison();
                state.workers -= 1;
                if state.workers > 0 {
                    // A running worker takes the lane when it finishes its job.
                    return Ok(());
                }
                // No worker exists, so nothing took the job: take it back out.
                if let Some(entry) = state.lanes.get_mut(&lane)
                    && let Some((_, bytes)) = entry.queue.pop_back()
                {
                    entry.bytes -= bytes;
                }
                if state.lanes.get(&lane).is_some_and(|entry| entry.queue.is_empty()) {
                    state.lanes.remove(&lane);
                    state.runnable.retain(|candidate| *candidate != lane);
                }
                return Err(LaneRefusal::Spawn);
            }
        } else if was_idle {
            self.shared.work.notify_one();
        }
        Ok(())
    }

    /// Stop taking jobs, run every queued one, and wait for the workers.
    pub(super) fn finish_and_wait(&self) {
        self.close_with(false);
        self.wait_for_workers(None);
    }

    /// Stop taking jobs, drop the queued ones, and wait up to `timeout` for
    /// the running ones. True when every worker ended.
    pub(super) fn close_and_wait(&self, timeout: Duration) -> bool {
        self.close_with(true);
        self.wait_for_workers(Some(timeout))
    }

    /// Stop taking jobs and drop the queued ones; running ones finish.
    /// Never waits.
    pub(super) fn close(&self) {
        self.close_with(true);
    }

    fn close_with(&self, drop_queued: bool) {
        let dropped: Vec<J> = {
            let mut state = self.shared.state.lock().recover_poison();
            state.closed = true;
            let mut dropped = Vec::new();
            if drop_queued {
                state.runnable.clear();
                for lane in state.lanes.values_mut() {
                    dropped.extend(lane.queue.drain(..).map(|(job, _)| job));
                    lane.bytes = 0;
                }
                state.lanes.retain(|_, lane| lane.running);
            }
            dropped
        };
        // Jobs drop outside the lock (their permits release other state).
        drop(dropped);
        self.shared.work.notify_all();
    }

    fn wait_for_workers(&self, timeout: Option<Duration>) -> bool {
        let deadline = timeout.and_then(|timeout| Instant::now().checked_add(timeout));
        let mut state = self.shared.state.lock().recover_poison();
        while state.workers > 0 {
            state = match deadline {
                None => self.shared.exited.wait(state).recover_poison(),
                Some(deadline) => {
                    let remaining = deadline.saturating_duration_since(Instant::now());
                    if remaining.is_zero() {
                        return false;
                    }
                    self.shared.exited.wait_timeout(state, remaining).recover_poison().0
                }
            };
        }
        true
    }

    /// Worker threads started so far at most at once.
    #[cfg(test)]
    pub(super) fn peak_workers(&self) -> usize {
        self.shared.state.lock().recover_poison().peak_workers
    }
}

fn run_worker<J: Send + 'static>(shared: &Shared<J>) {
    let mut state = shared.state.lock().recover_poison();
    loop {
        if let Some(lane) = state.runnable.pop_front() {
            let Some(entry) = state.lanes.get_mut(&lane) else { continue };
            let Some((job, bytes)) = entry.queue.pop_front() else { continue };
            entry.bytes -= bytes;
            entry.running = true;
            state.running += 1;
            drop(state);
            let keep_open = (shared.run)(job);
            state = shared.state.lock().recover_poison();
            state.running -= 1;
            if !keep_open {
                state.closed = true;
                state.runnable.clear();
                for lane in state.lanes.values_mut() {
                    lane.queue.clear();
                    lane.bytes = 0;
                }
                // Parked workers end too.
                shared.work.notify_all();
            }
            if let Some(entry) = state.lanes.get_mut(&lane) {
                entry.running = false;
                if entry.queue.is_empty() {
                    state.lanes.remove(&lane);
                } else {
                    // The lane takes its next turn after the others.
                    state.runnable.push_back(lane);
                }
            }
            continue;
        }
        if state.closed {
            break;
        }
        state = shared.work.wait(state).recover_poison();
    }
    state.workers -= 1;
    drop(state);
    shared.exited.notify_all();
}

#[cfg(test)]
#[path = "stream_lanes_tests.rs"]
mod tests;
