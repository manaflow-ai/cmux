//! One-shot timers for the supervisor (idle stop, crash restart after
//! `Backoff`). One thread, started on the first schedule, sleeps on a
//! condition variable until the earliest deadline or a change; with nothing
//! scheduled it blocks without a timeout (no polling, idle-wakeups.md).

use std::collections::BTreeMap;
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

type Job = Box<dyn FnOnce() + Send>;

#[derive(Default)]
struct State {
    next_id: u64,
    jobs: BTreeMap<(Instant, u64), Job>,
    started: bool,
    stopped: bool,
}

#[derive(Clone, Default)]
pub struct Timers {
    shared: Arc<(Mutex<State>, Condvar)>,
}

/// Cancels the job when passed to [`Timers::cancel`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TimerId(Instant, u64);

impl Timers {
    pub fn schedule(&self, after: Duration, job: impl FnOnce() + Send + 'static) -> TimerId {
        let (lock, wake) = &*self.shared;
        let mut state = lock.lock().unwrap();
        state.next_id += 1;
        let key = (Instant::now() + after, state.next_id);
        state.jobs.insert(key, Box::new(job));
        if !state.started {
            state.started = true;
            let shared = self.shared.clone();
            let _ = std::thread::Builder::new()
                .name("cmux-apps-timers".into())
                .spawn(move || run(&shared));
        }
        wake.notify_one();
        TimerId(key.0, key.1)
    }

    pub fn cancel(&self, id: TimerId) {
        let (lock, wake) = &*self.shared;
        lock.lock().unwrap().jobs.remove(&(id.0, id.1));
        wake.notify_one();
    }

    /// Ends the thread; pending jobs never run.
    pub fn stop(&self) {
        let (lock, wake) = &*self.shared;
        let mut state = lock.lock().unwrap();
        state.stopped = true;
        state.jobs.clear();
        wake.notify_one();
    }
}

fn run(shared: &(Mutex<State>, Condvar)) {
    let (lock, wake) = shared;
    let mut state = lock.lock().unwrap();
    loop {
        if state.stopped {
            return;
        }
        let now = Instant::now();
        match state.jobs.keys().next().copied() {
            Some(key) if key.0 <= now => {
                let job = state.jobs.remove(&key).expect("due job");
                drop(state);
                job();
                state = lock.lock().unwrap();
            }
            Some(key) => state = wake.wait_timeout(state, key.0 - now).unwrap().0,
            None => state = wake.wait(state).unwrap(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc;

    #[test]
    fn jobs_run_in_deadline_order_and_cancelled_ones_never_run() {
        let timers = Timers::default();
        let (tx, rx) = mpsc::channel();
        let t = tx.clone();
        timers.schedule(Duration::from_millis(40), move || t.send(2).unwrap());
        let t = tx.clone();
        let cancelled = timers.schedule(Duration::from_millis(10), move || t.send(9).unwrap());
        timers.schedule(Duration::from_millis(20), move || tx.send(1).unwrap());
        timers.cancel(cancelled);
        assert_eq!(rx.recv_timeout(Duration::from_secs(2)).unwrap(), 1);
        assert_eq!(rx.recv_timeout(Duration::from_secs(2)).unwrap(), 2);
        assert!(rx.recv_timeout(Duration::from_millis(50)).is_err());
        timers.stop();
    }
}
