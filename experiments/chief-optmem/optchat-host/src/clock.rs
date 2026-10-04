use std::sync::{Condvar, Mutex};
use std::time::{Duration, Instant};

/// Time for the compactor's fixed retry wait, injected so tests run without
/// real 10 s sleeps. It is the only place the host waits on time.
pub trait Clock: Send + Sync {
    /// Blocks the calling worker thread for `d`.
    fn sleep(&self, d: Duration);
}

/// Real time.
#[derive(Clone, Copy, Debug, Default)]
pub struct SystemClock;

impl Clock for SystemClock {
    fn sleep(&self, d: Duration) {
        std::thread::sleep(d);
    }
}

/// Time that moves only when a test calls `advance`.
#[derive(Debug, Default)]
pub struct ManualClock {
    state: Mutex<ManualState>,
    changed: Condvar,
}

#[derive(Debug, Default)]
struct ManualState {
    now: Duration,
    sleepers: usize,
}

impl ManualClock {
    pub fn new() -> ManualClock {
        ManualClock::default()
    }

    /// Moves time forward, waking every sleeper whose deadline passed.
    pub fn advance(&self, d: Duration) {
        self.state.lock().expect("clock").now += d;
        self.changed.notify_all();
    }

    /// Threads blocked in `sleep` now.
    pub fn sleepers(&self) -> usize {
        self.state.lock().expect("clock").sleepers
    }

    /// Blocks until at least `n` threads sleep, or `limit` of real time passes.
    pub fn wait_for_sleepers(&self, n: usize, limit: Duration) -> bool {
        let end = Instant::now() + limit;
        let mut st = self.state.lock().expect("clock");
        while st.sleepers < n {
            let left = end.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return false;
            }
            st = self.changed.wait_timeout(st, left).expect("clock").0;
        }
        true
    }
}

impl Clock for ManualClock {
    fn sleep(&self, d: Duration) {
        let mut st = self.state.lock().expect("clock");
        let deadline = st.now + d;
        st.sleepers += 1;
        self.changed.notify_all();
        while st.now < deadline {
            st = self.changed.wait(st).expect("clock");
        }
        st.sleepers -= 1;
        self.changed.notify_all();
    }
}
