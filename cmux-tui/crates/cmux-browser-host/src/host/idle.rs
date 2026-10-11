//! The idle end of a session (classic main: a named session ends after 30
//! minutes without a call). One deadline per session, kept by one thread
//! that waits on a condition variable until the deadline or a change (no
//! polling). Every call resets the deadline; a call in flight holds it.

use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError};
use std::time::{Duration, Instant};

/// Classic main's idle time for a named session.
pub const DEFAULT_IDLE_TIMEOUT: Duration = Duration::from_secs(30 * 60);

#[derive(Debug)]
struct State {
    deadline: Instant,
    in_flight: usize,
    /// The session ended another way (close, reset, the host's end).
    done: bool,
}

#[derive(Debug)]
pub(super) struct Idle {
    timeout: Duration,
    state: Mutex<State>,
    wake: Condvar,
}

/// One call to the session: the deadline holds until it ends, then starts
/// again from that moment.
pub(super) struct IdleCall(Arc<Idle>);

impl Drop for IdleCall {
    fn drop(&mut self) {
        let mut state = self.0.lock();
        state.in_flight = state.in_flight.saturating_sub(1);
        state.deadline = Instant::now() + self.0.timeout;
        self.0.wake.notify_all();
    }
}

impl Idle {
    pub(super) fn new(timeout: Duration) -> Arc<Idle> {
        Arc::new(Idle {
            timeout,
            state: Mutex::new(State {
                deadline: Instant::now() + timeout,
                in_flight: 0,
                done: false,
            }),
            wake: Condvar::new(),
        })
    }

    fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    pub(super) fn begin(self: &Arc<Self>) -> IdleCall {
        self.lock().in_flight += 1;
        IdleCall(self.clone())
    }

    /// The session ended another way: the watcher stops.
    pub(super) fn stop(&self) {
        self.lock().done = true;
        self.wake.notify_all();
    }

    /// True when the session is idle past its deadline (checked again by the
    /// caller under the session map's lock, so a call that just began wins).
    pub(super) fn expired(&self) -> bool {
        let state = self.lock();
        !state.done && state.in_flight == 0 && Instant::now() >= state.deadline
    }

    /// Blocks until the deadline passes with no call in flight (true) or
    /// the session ends another way (false).
    pub(super) fn wait_expired(&self) -> bool {
        let mut state = self.lock();
        loop {
            if state.done {
                return false;
            }
            if state.in_flight > 0 {
                state = self.wake.wait(state).unwrap_or_else(PoisonError::into_inner);
                continue;
            }
            let now = Instant::now();
            if now >= state.deadline {
                return true;
            }
            let wait = state.deadline - now;
            state = self.wake.wait_timeout(state, wait).unwrap_or_else(PoisonError::into_inner).0;
        }
    }
}
