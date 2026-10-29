//! The supervised host's stop (browser-host.md, step c2 follow-up), by the
//! stop rule every app helper follows (`cmux-owner-liveness`; principled
//! audit lagQuitHelpers, 2026-10-29, which replaced the `provider_gone`
//! edge of cp/lag-quit-helpers):
//!
//! > the host exits when it has no client (an agent connection or the app's
//! > provider link), no live owner app and no live work (an open session).
//!
//! The owner app is the process of the provider that connected last
//! (`cmux_owner_liveness::peer_app`), followed as a level: while it runs it
//! keeps the host, also while its provider link is down (the app reconnects
//! it with backoff; if the host stopped, it would only be started again).
//! Once that app is gone, the host exits as soon as the rule holds (a quit
//! left the host running for its whole delay before, cmux-ad 2026-10-27).
//! With no app ever connected, it exits after `delay`. The daemon starts it
//! again on the next agent connect (it holds the listening sockets).
//!
//! The rule is read again at every change ([`IdleExit::changed`]: a session,
//! a connection or the provider changed, or the owner app exited) and at the
//! deadline, on an injected clock. One waiting thread; no polling.

use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError};
use std::time::{Duration, Instant};

use cmux_owner_liveness::{Keeps, OwnerState};

/// How long a supervised host no app served waits with nothing to serve
/// before it exits.
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
    /// When the stop rule last started to hold; `None` while it does not.
    idle_since: Option<Instant>,
    /// Bumped by each [`IdleExit::changed`]: a read that a change raced is
    /// read again.
    changes: u64,
    stopped: bool,
}

/// Reads what keeps the host now (clients, the owner app, live work). Call
/// it with no idle-stop lock held: it takes the session and provider locks.
pub type KeepsProbe = Box<dyn Fn() -> Keeps + Send + Sync>;

/// One idle stop per supervised host.
pub struct IdleExit {
    delay: Duration,
    clock: Arc<dyn IdleClock>,
    probe: KeepsProbe,
    state: Mutex<IdleState>,
    changed: Condvar,
}

impl IdleExit {
    /// Reads the rule now; `probe` says what keeps the host.
    pub fn new(delay: Duration, clock: Arc<dyn IdleClock>, probe: KeepsProbe) -> Arc<IdleExit> {
        let idle = Arc::new(IdleExit {
            delay,
            clock,
            probe,
            state: Mutex::new(IdleState::default()),
            changed: Condvar::new(),
        });
        idle.changed();
        idle
    }

    fn lock(&self) -> MutexGuard<'_, IdleState> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// How long the rule must hold before the host exits: no time once its
    /// owner app is gone, `delay` when no app ever served it.
    fn delay_for(&self, owner: OwnerState) -> Duration {
        match owner {
            OwnerState::Gone => Duration::ZERO,
            OwnerState::Unnamed | OwnerState::Alive => self.delay,
        }
    }

    /// Records `keeps` read at `now`: the rule starts or stops holding.
    fn record(&self, state: &mut IdleState, keeps: Keeps) {
        if keeps.exits(false) {
            state.idle_since.get_or_insert(self.clock.now());
        } else {
            state.idle_since = None;
        }
        cmux_owner_liveness::check("cmux-browser-host", state.idle_since.is_some(), keeps, false);
    }

    /// Something the rule reads changed: a session opened or ended, a
    /// connection came or went, the provider connected or left, or the
    /// owner app exited. Call it with no session or provider lock held.
    pub fn changed(&self) {
        let keeps = (self.probe)();
        let mut state = self.lock();
        state.changes = state.changes.wrapping_add(1);
        self.record(&mut state, keeps);
        drop(state);
        self.changed.notify_all();
    }

    /// Ends [`IdleExit::wait`] with false (the host stops another way).
    pub fn stop(&self) {
        self.lock().stopped = true;
        self.changed.notify_all();
    }

    /// Blocks until the stop rule has held for its delay (true) or
    /// [`IdleExit::stop`] (false).
    pub fn wait(&self) -> bool {
        let mut state = self.lock();
        loop {
            if state.stopped {
                return false;
            }
            let changes = state.changes;
            // The probe takes the session and provider locks: read it unlocked.
            drop(state);
            let keeps = (self.probe)();
            state = self.lock();
            if state.stopped {
                return false;
            }
            if state.changes != changes {
                continue;
            }
            self.record(&mut state, keeps);
            state = match state.idle_since {
                None => self.changed.wait(state).unwrap_or_else(PoisonError::into_inner),
                Some(since) => {
                    let delay = self.delay_for(keeps.owner);
                    let idle_for = self.clock.now().saturating_duration_since(since);
                    if idle_for >= delay {
                        return true;
                    }
                    self.clock.wait_timeout(&self.changed, state, delay - idle_for)
                }
            };
        }
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
        /// A session is open (or, for these tests, an agent connection).
        busy: Arc<AtomicBool>,
        owner: Arc<Mutex<OwnerState>>,
        idle: Arc<IdleExit>,
        fired: std::sync::mpsc::Receiver<bool>,
    }

    /// A host no app served yet, busy or not.
    fn fixture(busy_at_start: bool) -> Fixture {
        let clock = Arc::new(FakeClock(Mutex::new(Instant::now())));
        let busy = Arc::new(AtomicBool::new(busy_at_start));
        let owner = Arc::new(Mutex::new(OwnerState::Unnamed));
        let (probe, owned) = (busy.clone(), owner.clone());
        let idle = IdleExit::new(
            Duration::from_secs(300),
            clock.clone(),
            Box::new(move || Keeps {
                clients: false,
                owner: *owned.lock().unwrap(),
                live_work: probe.load(Ordering::SeqCst),
            }),
        );
        let (tx, fired) = std::sync::mpsc::channel();
        let waiter = idle.clone();
        std::thread::spawn(move || {
            let _ = tx.send(waiter.wait());
        });
        Fixture { clock, busy, owner, idle, fired }
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

    // The app quits (cmux-ad 2026-10-27: a quit left the app's helpers
    // running). The app's provider served this host; once that app is gone
    // and nothing else uses the host, the host ends now, as Chromium's
    // utility processes end when their last client goes. The daemon starts
    // it again on the next agent connect.
    #[test]
    fn a_host_whose_app_quit_with_nothing_else_exits_at_once() {
        let f = fixture(true);
        *f.owner.lock().unwrap() = OwnerState::Alive;
        f.idle.changed();
        f.clock.advance(Duration::from_secs(10));
        f.busy.store(false, Ordering::SeqCst);
        f.idle.changed();
        f.clock.advance(Duration::from_secs(3600));
        not_yet(&f);
        app_quits(&f);
        fires(&f);
    }

    // The app runs with its provider link down (it reconnects with
    // backoff): the host stays for it, whatever the delay.
    #[test]
    fn a_host_whose_app_runs_stays_without_its_provider_link() {
        let f = fixture(false);
        *f.owner.lock().unwrap() = OwnerState::Alive;
        f.idle.changed();
        f.clock.advance(Duration::from_secs(3600));
        not_yet(&f);
    }

    // cp/redesign-quit-helpers (principled audit, R2/R3): the app's exit is
    // a level. On the base, `provider_gone` was an edge that a busy read
    // cleared: the app quit while an agent's session ran, and when that
    // session ended the host waited its whole delay with no app, no client
    // and no work, where the policy says it must exit.
    #[test]
    fn owner_level_a_host_whose_app_quit_during_a_session_exits_when_it_ends() {
        let f = fixture(true);
        app_quits(&f);
        f.clock.advance(Duration::from_secs(10));
        not_yet(&f);
        f.busy.store(false, Ordering::SeqCst);
        f.idle.changed();
        fires(&f);
    }

    /// The app that served the host quit (its provider left, its process is
    /// gone): the owner's kernel watch reports it.
    fn app_quits(f: &Fixture) {
        *f.owner.lock().unwrap() = OwnerState::Gone;
        f.idle.changed();
    }

    #[test]
    fn stop_ends_the_wait_without_an_exit() {
        let f = fixture(true);
        f.idle.stop();
        assert_eq!(f.fired.recv_timeout(Duration::from_secs(5)), Ok(false));
    }
}
