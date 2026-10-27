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
            Some(key) => {
                // wakeup-allow: deadline the earliest job's due time on the wake grid; a schedule, cancel or stop ends it first
                state = wake.wait_timeout(state, aligned_wait(key.0 - now)).unwrap().0;
            }
            None => state = wake.wait(state).unwrap(),
        }
    }
}

/// The wait until a job due `delay` from now, as a never-sooner
/// [`crate::wake::deadline`]: the supervisor's idle stops and restarts
/// share a wake with the daemon's other deadlines near them.
fn aligned_wait(delay: Duration) -> Duration {
    let now = crate::wake::Ticks::now();
    crate::wake::deadline(now, delay, crate::wake::Policy::FlexibleNoSooner).wait_from(now)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc;

    /// Real time only bounds how long the test waits for the timer thread.
    const SAFETY_BOUND: Duration = Duration::from_secs(30);

    #[test]
    fn a_job_wait_is_never_sooner_than_its_delay_and_within_its_leeway() {
        for (delay, leeway) in [
            (Duration::from_millis(20), Duration::from_millis(8)),
            (Duration::from_secs(5), Duration::from_millis(500)),
            (Duration::from_secs(60), Duration::from_secs(1)),
        ] {
            let wait = aligned_wait(delay);
            assert!(wait >= delay && wait <= delay + leeway, "{delay:?} waits {wait:?}");
        }
    }

    #[test]
    fn jobs_run_in_deadline_order_and_cancelled_ones_never_run() {
        let timers = Timers::default();
        // The first job holds the timer thread until every job is scheduled
        // and the cancel is in, so no deadline can pass ahead of the cancel.
        let (open_gate, gate) = mpsc::channel::<()>();
        timers.schedule(Duration::ZERO, move || {
            let _ = gate.recv();
        });
        let (tx, rx) = mpsc::channel();
        let t = tx.clone();
        timers.schedule(Duration::from_millis(40), move || t.send(2).unwrap());
        let t = tx.clone();
        let cancelled = timers.schedule(Duration::from_millis(10), move || t.send(9).unwrap());
        timers.schedule(Duration::from_millis(20), move || tx.send(1).unwrap());
        timers.cancel(cancelled);
        drop(open_gate);
        assert_eq!(rx.recv_timeout(SAFETY_BOUND).unwrap(), 1);
        assert_eq!(rx.recv_timeout(SAFETY_BOUND).unwrap(), 2);
        // Every job that held a sender has run or was dropped by the cancel.
        assert_eq!(rx.recv_timeout(SAFETY_BOUND), Err(mpsc::RecvTimeoutError::Disconnected));
        timers.stop();
    }
}
