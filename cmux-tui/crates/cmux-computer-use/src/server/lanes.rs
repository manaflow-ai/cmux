//! A small thread pool with one ordered lane per agent session: the calls
//! of one session run one at a time, in the order they arrived, and a slow
//! call of one session never holds up another session's calls.
//!
//! A call the bridge retries after a dropped connection lands in the same
//! lane behind the first attempt, so by the time the retry runs the first
//! attempt has finished and the engine answers the retry from its memory of
//! that `call_id` instead of acting twice.

use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError};

/// Threads at most; more sessions than this wait their turn round-robin.
pub const MAX_THREADS: usize = 16;

type Job = Box<dyn FnOnce() + Send + 'static>;

#[derive(Default)]
struct State {
    /// session -> its waiting jobs; present while the session is scheduled
    /// or one of its jobs runs.
    queues: HashMap<String, VecDeque<Job>>,
    /// Sessions with a job ready and none running.
    ready: VecDeque<String>,
    threads: usize,
    idle: usize,
    stopped: bool,
}

#[derive(Default)]
pub struct Lanes {
    state: Mutex<State>,
    wake: Condvar,
    /// Signalled when a pool thread exits.
    drained: Condvar,
}

const THREAD_NAME: &str = "cmux-cu-call";

impl Lanes {
    pub fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }

    fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Queues `job` behind the session's earlier jobs.
    pub fn submit(self: &Arc<Self>, session: &str, job: impl FnOnce() + Send + 'static) {
        let mut state = self.lock();
        if state.stopped {
            return;
        }
        if let Some(queue) = state.queues.get_mut(session) {
            queue.push_back(Box::new(job));
            return;
        }
        state.queues.insert(session.to_string(), VecDeque::from([Box::new(job) as Job]));
        state.ready.push_back(session.to_string());
        if state.idle == 0 && state.threads < MAX_THREADS {
            state.threads += 1;
            let lanes = Arc::clone(self);
            let spawned =
                std::thread::Builder::new().name(THREAD_NAME.into()).spawn(move || lanes.run());
            if spawned.is_err() {
                state.threads -= 1;
            }
        }
        drop(state);
        self.wake.notify_one();
    }

    fn run(self: Arc<Self>) {
        let mut state = self.lock();
        loop {
            while state.ready.is_empty() && !state.stopped {
                state.idle += 1;
                state = self.wake.wait(state).unwrap_or_else(PoisonError::into_inner);
                state.idle -= 1;
            }
            let Some(session) = state.ready.pop_front() else {
                // Stopped with nothing ready.
                state.threads -= 1;
                drop(state);
                self.drained.notify_all();
                return;
            };
            let job = state.queues.get_mut(&session).and_then(VecDeque::pop_front);
            drop(state);
            if let Some(job) = job {
                // A panicking call must not take the lane (or the pool thread) with it.
                let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(job));
            }
            state = self.lock();
            match state.queues.get(&session) {
                Some(queue) if !queue.is_empty() => {
                    state.ready.push_back(session);
                }
                _ => {
                    state.queues.remove(&session);
                }
            }
        }
    }

    /// Drops every waiting job, then returns once every running job has
    /// finished and every pool thread has exited, so nothing the jobs use
    /// (the engine, the host's callbacks) is touched after this returns.
    /// Called from a pool thread, it waits for every thread but its own.
    pub fn stop(&self) {
        let mut state = self.lock();
        state.stopped = true;
        state.ready.clear();
        state.queues.clear();
        self.wake.notify_all();
        let own = usize::from(std::thread::current().name() == Some(THREAD_NAME));
        while state.threads > own {
            state = self.drained.wait(state).unwrap_or_else(PoisonError::into_inner);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc;
    use std::time::Duration;

    #[test]
    fn stop_waits_for_the_running_call() {
        let lanes = Lanes::new();
        let (started_tx, started_rx) = mpsc::channel::<()>();
        let finished = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let done = Arc::clone(&finished);
        lanes.submit("a", move || {
            started_tx.send(()).unwrap();
            std::thread::sleep(Duration::from_millis(200));
            done.store(true, std::sync::atomic::Ordering::SeqCst);
        });
        started_rx.recv().unwrap();
        lanes.stop();
        assert!(finished.load(std::sync::atomic::Ordering::SeqCst), "stop returned mid-call");
    }

    #[test]
    fn one_session_runs_in_order_and_others_are_not_blocked() {
        let lanes = Lanes::new();
        let (gate_tx, gate_rx) = mpsc::channel::<()>();
        let (done_tx, done_rx) = mpsc::channel::<String>();
        let gate = Mutex::new(gate_rx);
        let slow_done = done_tx.clone();
        lanes.submit("a", move || {
            gate.lock().unwrap().recv().unwrap();
            slow_done.send("a1".into()).unwrap();
        });
        let a2 = done_tx.clone();
        lanes.submit("a", move || a2.send("a2".into()).unwrap());
        let b1 = done_tx;
        lanes.submit("b", move || b1.send("b1".into()).unwrap());
        // b runs while a's first job is still blocked.
        assert_eq!(done_rx.recv_timeout(Duration::from_secs(5)).unwrap(), "b1");
        gate_tx.send(()).unwrap();
        assert_eq!(done_rx.recv_timeout(Duration::from_secs(5)).unwrap(), "a1");
        assert_eq!(done_rx.recv_timeout(Duration::from_secs(5)).unwrap(), "a2");
        lanes.stop();
    }

    #[test]
    fn a_panicking_job_does_not_stop_its_lane() {
        let lanes = Lanes::new();
        let (tx, rx) = mpsc::channel::<u8>();
        lanes.submit("s", || panic!("boom"));
        lanes.submit("s", move || tx.send(7).unwrap());
        assert_eq!(rx.recv_timeout(Duration::from_secs(5)).unwrap(), 7);
        lanes.stop();
    }
}
