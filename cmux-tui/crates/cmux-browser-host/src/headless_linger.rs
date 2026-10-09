//! How long an unused shared headless browser stays (browser perf report,
//! root cause R1, 2026-10-08). D3 closed a profile's browser as soon as its
//! last session ended, so every one-shot `cmux browser repl` call (the
//! agent default) launched Chromium again and deleted its profile on exit:
//! about 0.45-0.6 s of each call. An unused browser now stays for
//! [`LINGER`]; a session that starts meanwhile takes it over at once, and
//! a browser still unused at the deadline closes as before.
//!
//! Pure state: the caller passes the time (an injected clock) and owns the
//! one waiting thread, which sleeps on a condition variable until the
//! deadline that [`Linger::wait`] names (no polling).

use std::time::{Duration, Instant};

/// How long an unused browser stays for the next session.
pub const LINGER: Duration = Duration::from_secs(60);

#[derive(Debug, Default)]
pub struct Linger {
    deadline: Option<Instant>,
    waiting: bool,
}

/// What the waiting thread does next.
#[derive(Debug, PartialEq, Eq)]
pub enum Next {
    /// Sleep this long, then ask again.
    Sleep(Duration),
    /// The deadline passed: close the browser if it is still unused.
    Release,
    /// Nothing is due: the thread ends.
    Stop,
}

impl Linger {
    /// The browser's last session ended at `now`. True when the caller must
    /// start the waiting thread (none waits yet); otherwise the waiting
    /// thread sees the later deadline when it wakes.
    pub fn idle(&mut self, now: Instant, linger: Duration) -> bool {
        self.deadline = Some(now + linger);
        let start = !self.waiting;
        self.waiting = true;
        start
    }

    /// The waiting thread's next step at `now`.
    pub fn wait(&mut self, now: Instant) -> Next {
        match self.deadline {
            Some(deadline) if now < deadline => Next::Sleep(deadline - now),
            Some(_) => {
                self.deadline = None;
                self.waiting = false;
                Next::Release
            }
            None => {
                self.waiting = false;
                Next::Stop
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn one_waiting_thread_follows_the_latest_idle_time() {
        let start = Instant::now();
        let mut linger = Linger::default();
        assert!(linger.idle(start, LINGER), "the first idle starts the thread");
        assert_eq!(linger.wait(start), Next::Sleep(LINGER));
        // A second one-shot call came and went: the same thread waits longer.
        let later = start + Duration::from_secs(20);
        assert!(!linger.idle(later, LINGER), "no second thread");
        assert_eq!(linger.wait(start + LINGER), Next::Sleep(Duration::from_secs(20)));
        assert_eq!(linger.wait(later + LINGER), Next::Release);
        // The thread ended with the release; the next idle starts a new one.
        assert!(linger.idle(later + LINGER * 2, LINGER));
    }
}
