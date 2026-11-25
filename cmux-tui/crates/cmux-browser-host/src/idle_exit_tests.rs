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

// Quit leaves no helper processes (P0 journey quit-leaves-no-helpers: 5 s after a quit the
// daemon's browser host still ran). The app's provider started this host; once it leaves and
// nothing else uses the host, the host ends now, as Chromium's utility processes end when
// their last client goes. The daemon starts it again on the next agent connect.
#[test]
fn quit_helpers_a_host_whose_app_provider_left_with_nothing_else_exits_at_once() {
    let f = fixture(true);
    f.clock.advance(Duration::from_secs(10));
    f.busy.store(false, Ordering::SeqCst);
    f.idle.provider_left();
    fires(&f);
}

#[test]
fn quit_helpers_a_provider_leaving_while_a_session_runs_keeps_the_host_and_the_delay() {
    let f = fixture(true);
    // The provider left; an agent's session still runs.
    f.idle.provider_left();
    f.clock.advance(Duration::from_secs(3600));
    not_yet(&f);
    // The session ends: the whole delay, as before.
    f.busy.store(false, Ordering::SeqCst);
    f.idle.changed();
    f.clock.advance(Duration::from_secs(299));
    not_yet(&f);
    f.clock.advance(Duration::from_secs(1));
    fires(&f);
}

#[test]
fn stop_ends_the_wait_without_an_exit() {
    let f = fixture(true);
    f.idle.stop();
    assert_eq!(f.fired.recv_timeout(Duration::from_secs(5)), Ok(false));
}
