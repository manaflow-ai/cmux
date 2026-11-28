//! The DEV orphan exit policy and its watcher, on an injected clock.

use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::mpsc::{Receiver, channel};

use super::*;

const MINUTE: Duration = Duration::from_secs(60);

#[derive(Default)]
struct FakeFacts {
    clients: AtomicUsize,
    gone: AtomicBool,
    terminals: AtomicUsize,
    unreadable: AtomicBool,
}

impl OrphanFacts for FakeFacts {
    fn clients(&self) -> usize {
        self.clients.load(Ordering::SeqCst)
    }

    fn executable_present(&self) -> bool {
        !self.gone.load(Ordering::SeqCst)
    }

    fn live_terminals(&self) -> Option<usize> {
        (!self.unreadable.load(Ordering::SeqCst)).then(|| self.terminals.load(Ordering::SeqCst))
    }
}

fn facts(gone: bool, terminals: usize) -> FakeFacts {
    let facts = FakeFacts::default();
    facts.gone.store(gone, Ordering::SeqCst);
    facts.terminals.store(terminals, Ordering::SeqCst);
    facts
}

#[test]
fn an_owner_whose_executable_is_gone_stops_after_an_hour_without_a_client() {
    let start = Instant::now();
    let facts = facts(true, 2);
    assert_eq!(decide(Some(start), start + 59 * MINUTE, &facts), Decision::Wait(MINUTE));
    assert_eq!(decide(Some(start), start + 60 * MINUTE, &facts), Decision::Exit);
}

#[test]
fn an_owner_whose_executable_exists_never_leaves_live_terminals() {
    let start = Instant::now();
    let facts = facts(false, 1);
    let ten_days = start + Duration::from_secs(10 * 24 * 60 * 60);
    assert_eq!(decide(Some(start), ten_days, &facts), Decision::Wait(ORPHAN_RECHECK));
    facts.unreadable.store(true, Ordering::SeqCst);
    facts.terminals.store(0, Ordering::SeqCst);
    assert_eq!(decide(Some(start), ten_days, &facts), Decision::Wait(ORPHAN_RECHECK));
}

#[test]
fn an_owner_without_terminals_stops_after_an_hour_without_a_client() {
    let start = Instant::now();
    let facts = facts(false, 0);
    assert_eq!(decide(Some(start), start + 30 * MINUTE, &facts), Decision::Wait(30 * MINUTE));
    assert_eq!(decide(Some(start), start + 60 * MINUTE, &facts), Decision::Exit);
}

#[test]
fn a_connected_client_keeps_any_owner() {
    let facts = facts(true, 0);
    assert_eq!(decide(None, Instant::now(), &facts), Decision::Serve);
}

#[test]
fn only_dev_bundles_run_the_watcher() {
    assert!(is_dev_build(Some("com.cmuxterm.app.debug")));
    assert!(is_dev_build(Some("com.cmuxterm.app.debug.nx1")));
    for release in [
        "com.cmuxterm.app",
        "com.cmuxterm.app.nightly",
        "com.cmuxterm.app.rc",
        "com.cmuxterm.app.debugger",
    ] {
        assert!(!is_dev_build(Some(release)), "{release}");
    }
    assert!(!is_dev_build(None));
}

#[test]
fn the_bundle_id_comes_from_the_bundle_around_the_executable() {
    let dir = tempfile::tempdir().unwrap();
    for (name, id, dev) in [
        ("cmux DEV t1.app", "com.cmuxterm.app.debug.t1", true),
        ("cmux.app", "com.cmuxterm.app", false),
    ] {
        let app = dir.path().join(name);
        let bin = app.join("Contents/Resources/bin");
        std::fs::create_dir_all(&bin).unwrap();
        std::fs::write(
            app.join("Contents/Info.plist"),
            format!(
                "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\"><dict>\
                 <key>CFBundleIdentifier</key><string>{id}</string></dict></plist>\n"
            ),
        )
        .unwrap();
        let exe = bin.join("cmux-tui");
        assert_eq!(is_dev_build(bundle_id_of(&exe).as_deref()), dev, "{name}");
    }
    assert_eq!(bundle_id_of(&dir.path().join("cmux-tui")), None, "no bundle, no DEV");
}

/// A clock that moves only when the test says so, and records each timeout
/// the watcher asks for.
struct FakeClock(Mutex<Instant>, Mutex<Vec<Duration>>);

impl FakeClock {
    fn advance(&self, by: Duration) {
        *self.0.lock().unwrap() += by;
    }

    fn asked(&self, timeout: Duration) -> bool {
        self.1.lock().unwrap().contains(&timeout)
    }
}

impl OrphanClock for FakeClock {
    fn now(&self) -> Instant {
        *self.0.lock().unwrap()
    }

    fn wait_timeout<'a>(
        &self,
        changed: &Condvar,
        state: MutexGuard<'a, WatchState>,
        timeout: Duration,
    ) -> MutexGuard<'a, WatchState> {
        self.1.lock().unwrap().push(timeout);
        // Real time is not this clock's time: wake soon and read it again.
        changed.wait_timeout(state, Duration::from_millis(2)).unwrap().0
    }
}

struct Fixture {
    clock: Arc<FakeClock>,
    facts: Arc<FakeFacts>,
    watch: Arc<OrphanWatch>,
    fired: Receiver<bool>,
}

fn fixture(facts: FakeFacts) -> Fixture {
    let clock = Arc::new(FakeClock(Mutex::new(Instant::now()), Mutex::new(Vec::new())));
    let facts = Arc::new(facts);
    let watch = OrphanWatch::new(clock.clone(), facts.clone());
    let (tx, fired) = channel();
    let waiter = watch.clone();
    std::thread::spawn(move || {
        let _ = tx.send(waiter.wait());
    });
    Fixture { clock, facts, watch, fired }
}

fn not_yet(f: &Fixture) {
    assert!(f.fired.recv_timeout(Duration::from_millis(60)).is_err(), "exited too early");
}

fn fires(f: &Fixture) {
    assert_eq!(f.fired.recv_timeout(Duration::from_secs(5)), Ok(true));
}

#[test]
fn the_watcher_stops_an_orphan_an_hour_after_the_last_client_left() {
    let f = fixture(facts(true, 3));
    f.clock.advance(59 * MINUTE);
    not_yet(&f);
    // A client comes back: no exit while it is connected, however long.
    f.facts.clients.store(1, Ordering::SeqCst);
    f.watch.clients_changed();
    f.clock.advance(5 * 60 * MINUTE);
    not_yet(&f);
    // It leaves: the hour starts again from now.
    f.facts.clients.store(0, Ordering::SeqCst);
    f.watch.clients_changed();
    f.clock.advance(59 * MINUTE);
    not_yet(&f);
    f.clock.advance(MINUTE);
    fires(&f);
}

#[test]
fn the_watcher_notices_a_deleted_executable_after_the_hour() {
    let f = fixture(facts(false, 1));
    f.clock.advance(5 * 60 * MINUTE);
    not_yet(&f);
    // Past the hour with live terminals it only looks again later.
    assert!(f.clock.asked(ORPHAN_RECHECK), "no recheck was scheduled");
    f.facts.gone.store(true, Ordering::SeqCst);
    f.clock.advance(ORPHAN_RECHECK);
    fires(&f);
}

#[test]
fn a_stopped_watcher_returns_false() {
    let f = fixture(facts(false, 1));
    f.watch.stop();
    assert_eq!(f.fired.recv_timeout(Duration::from_secs(5)), Ok(false));
}

#[test]
fn the_check_under_the_fence_sees_a_terminal_started_since_the_decision() {
    // `start_for_owner` hands `stop_owner` the same facts the watcher used;
    // here a terminal starts between the decision and the stop.
    let facts = facts(false, 0);
    assert!(orphaned(&facts));
    facts.terminals.store(1, Ordering::SeqCst);
    assert!(!orphaned(&facts), "a terminal that started since the decision keeps the owner");
}

#[test]
fn shortened_timing_drives_the_same_policy() {
    // The debug-only test seams (CMUX_TUI_TEST_DEV_ORPHAN_DELAY_MS and
    // _RECHECK_MS) only change these two intervals.
    let timing = Timing { delay: Duration::from_millis(200), recheck: Duration::from_millis(50) };
    let start = Instant::now();
    let gone = facts(true, 1);
    let live = facts(false, 1);
    let at = |ms| start + Duration::from_millis(ms);
    assert_eq!(
        decide_with(Some(start), at(150), &gone, timing),
        Decision::Wait(Duration::from_millis(50))
    );
    assert_eq!(decide_with(Some(start), at(200), &gone, timing), Decision::Exit);
    assert_eq!(decide_with(Some(start), at(10_000), &live, timing), Decision::Wait(timing.recheck));
}
