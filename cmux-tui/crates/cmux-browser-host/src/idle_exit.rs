//! The supervised host's idle stop (browser-host.md, step c2 follow-up): the
//! host exits after `delay` with no session open and no app provider
//! connected, and the daemon starts it again on the next agent connect (it
//! holds the listening sockets). One waiting thread, woken by changes or by
//! the deadline on an injected clock; no polling.
//!
//! A connected provider keeps the host: if the host stopped under a
//! connected app, the app would start it again at once to reconnect.

use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError};
use std::time::{Duration, Instant};

/// How long a supervised host waits with nothing to serve before it exits.
pub const DEFAULT_IDLE_EXIT: Duration = Duration::from_secs(5 * 60);

/// The time source of the idle stop. Tests inject a fake.
pub trait IdleClock: Send + Sync {
    fn now(&self) -> Instant;

    /// Waits on `changed` until it is notified or `timeout` passes on this
    /// clock (a spurious wake is fine: the caller checks again).
    fn wait_timeout<'a>(
        &self,
        changed: &Condvar,
        state: MutexGuard<'a, IdleState>,
        timeout: Duration,
    ) -> MutexGuard<'a, IdleState>;
}

/// The real clock.
pub struct SystemClock;

impl IdleClock for SystemClock {
    fn now(&self) -> Instant {
        Instant::now()
    }

    fn wait_timeout<'a>(
        &self,
        changed: &Condvar,
        state: MutexGuard<'a, IdleState>,
        timeout: Duration,
    ) -> MutexGuard<'a, IdleState> {
        changed.wait_timeout(state, timeout).unwrap_or_else(PoisonError::into_inner).0
    }
}

/// What the idle stop knows.
#[derive(Debug, Default)]
pub struct IdleState {
    /// When the host last became idle; `None` while it serves something.
    idle_since: Option<Instant>,
    stopped: bool,
}

/// Busy probe: true while a session is open or a provider is connected.
pub type BusyProbe = Box<dyn Fn() -> bool + Send + Sync>;

/// One idle stop per supervised host.
pub struct IdleExit {
    delay: Duration,
    clock: Arc<dyn IdleClock>,
    busy: BusyProbe,
    state: Mutex<IdleState>,
    changed: Condvar,
}

impl IdleExit {
    /// Idle from now unless `busy` says otherwise.
    pub fn new(delay: Duration, clock: Arc<dyn IdleClock>, busy: BusyProbe) -> Arc<IdleExit> {
        let idle = Arc::new(IdleExit {
            delay,
            clock,
            busy,
            state: Mutex::new(IdleState::default()),
            changed: Condvar::new(),
        });
        idle.changed();
        idle
    }

    fn lock(&self) -> MutexGuard<'_, IdleState> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Red commit stub: changes are ignored.
    pub fn changed(&self) {}

    /// Ends [`IdleExit::wait`] with false.
    pub fn stop(&self) {
        self.lock().stopped = true;
        self.changed.notify_all();
    }

    /// Red commit stub: never fires; returns false at [`IdleExit::stop`].
    pub fn wait(&self) -> bool {
        let mut state = self.lock();
        while !state.stopped {
            state = self.changed.wait(state).unwrap_or_else(PoisonError::into_inner);
        }
        let _ = (self.delay, &self.clock, &self.busy, state.idle_since);
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicBool, Ordering};

    /// A clock that moves only when the test says so.
    struct FakeClock(Mutex<Instant>);

    impl FakeClock {
        fn advance(&self, by: Duration) {
            *self.0.lock().unwrap() += by;
        }
    }

    impl IdleClock for FakeClock {
        fn now(&self) -> Instant {
            *self.0.lock().unwrap()
        }

        fn wait_timeout<'a>(
            &self,
            changed: &Condvar,
            state: MutexGuard<'a, IdleState>,
            _timeout: Duration,
        ) -> MutexGuard<'a, IdleState> {
            // Real time is not this clock's time: wake soon and let the
            // caller read the fake clock again.
            changed.wait_timeout(state, Duration::from_millis(2)).unwrap().0
        }
    }

    struct Fixture {
        clock: Arc<FakeClock>,
        busy: Arc<AtomicBool>,
        idle: Arc<IdleExit>,
        fired: std::sync::mpsc::Receiver<bool>,
    }

    fn fixture(busy_at_start: bool) -> Fixture {
        let clock = Arc::new(FakeClock(Mutex::new(Instant::now())));
        let busy = Arc::new(AtomicBool::new(busy_at_start));
        let probe = busy.clone();
        let idle = IdleExit::new(
            Duration::from_secs(300),
            clock.clone(),
            Box::new(move || probe.load(Ordering::SeqCst)),
        );
        let (tx, fired) = std::sync::mpsc::channel();
        let waiter = idle.clone();
        std::thread::spawn(move || {
            let _ = tx.send(waiter.wait());
        });
        Fixture { clock, busy, idle, fired }
    }

    fn not_yet(f: &Fixture) {
        assert!(f.fired.recv_timeout(Duration::from_millis(50)).is_err(), "fired too early");
    }

    fn fires(f: &Fixture) {
        assert_eq!(f.fired.recv_timeout(Duration::from_secs(5)), Ok(true));
    }

    #[test]
    fn an_idle_host_exits_after_the_whole_delay_and_not_before() {
        let f = fixture(false);
        f.clock.advance(Duration::from_secs(299));
        not_yet(&f);
        f.clock.advance(Duration::from_secs(1));
        fires(&f);
    }

    #[test]
    fn a_session_or_provider_cancels_the_delay_and_its_end_starts_it_again() {
        let f = fixture(false);
        f.clock.advance(Duration::from_secs(200));
        f.busy.store(true, Ordering::SeqCst);
        f.idle.changed();
        f.clock.advance(Duration::from_secs(3600));
        not_yet(&f);
        f.busy.store(false, Ordering::SeqCst);
        f.idle.changed();
        f.clock.advance(Duration::from_secs(299));
        not_yet(&f);
        f.clock.advance(Duration::from_secs(1));
        fires(&f);
    }

    #[test]
    fn a_host_busy_from_the_start_never_exits_while_busy() {
        let f = fixture(true);
        f.clock.advance(Duration::from_secs(3600));
        not_yet(&f);
    }

    #[test]
    fn stop_ends_the_wait_without_an_exit() {
        let f = fixture(true);
        f.idle.stop();
        assert_eq!(f.fired.recv_timeout(Duration::from_secs(5)), Ok(false));
    }
}
