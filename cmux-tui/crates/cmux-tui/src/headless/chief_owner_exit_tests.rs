//! The Chief owner's exit after its app quit, on a fake clock
//! (`cargo test -p cmux-tui chief_owner_exit`).

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::mpsc::{Receiver, channel};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};

use cmux_threads::sync::Condvar;

use super::super::dev_orphan_exit::{OrphanClock, OrphanFacts, OrphanWatch, WatchState};
use super::*;

const GRACE: Duration = OWNER_EXIT_GRACE;
const HOUR: Duration = Duration::from_secs(3600);

/// The owner app: set by the test, or a real follow of a stand-in app.
enum FakeOwner {
    Manual(OwnerState),
    Real(Arc<OwnerLiveness>),
}

impl Default for FakeOwner {
    /// The app runs.
    fn default() -> Self {
        Self::Manual(OwnerState::Alive)
    }
}

#[derive(Default)]
struct FakeFacts {
    clients: AtomicUsize,
    terminals: AtomicUsize,
    unreadable: AtomicBool,
    brains: AtomicUsize,
    owner: Mutex<FakeOwner>,
}

impl FakeFacts {
    fn owner(&self) -> OwnerState {
        match &*self.owner.lock().unwrap() {
            FakeOwner::Manual(state) => *state,
            FakeOwner::Real(liveness) => liveness.state(),
        }
    }

    fn keeps(&self) -> Keeps {
        chief_owner_keeps(
            self.clients(),
            self.owner(),
            self.live_terminals(),
            self.brains.load(Ordering::SeqCst),
        )
    }
}

impl OrphanFacts for FakeFacts {
    fn clients(&self) -> usize {
        self.clients.load(Ordering::SeqCst)
    }

    fn executable_present(&self) -> bool {
        true
    }

    fn live_terminals(&self) -> Option<usize> {
        (!self.unreadable.load(Ordering::SeqCst)).then(|| self.terminals.load(Ordering::SeqCst))
    }

    fn exits(&self) -> bool {
        self.keeps().exits(true)
    }

    fn kept_by_reported_fact(&self) -> bool {
        self.owner() == OwnerState::Alive
    }
}

/// A clock that moves only when the test says so.
struct FakeClock(Mutex<Instant>);

impl OrphanClock for FakeClock {
    fn now(&self) -> Instant {
        *self.0.lock().unwrap()
    }

    fn wait_timeout<'a>(
        &self,
        changed: &Condvar,
        state: MutexGuard<'a, WatchState>,
        _timeout: Duration,
    ) -> MutexGuard<'a, WatchState> {
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

impl Fixture {
    fn start(facts: FakeFacts) -> Self {
        let clock = Arc::new(FakeClock(Mutex::new(Instant::now())));
        let facts = Arc::new(facts);
        let watch = OrphanWatch::with_timing(clock.clone(), facts.clone(), CHIEF_OWNER_TIMING);
        let (tx, fired) = channel();
        let waiter = watch.clone();
        std::thread::spawn(move || {
            let _ = tx.send(waiter.wait());
        });
        Self { clock, facts, watch, fired }
    }

    fn advance(&self, by: Duration) {
        *self.clock.0.lock().unwrap() += by;
    }

    fn not_yet(&self) {
        assert!(self.fired.recv_timeout(Duration::from_millis(60)).is_err(), "exited too early");
    }

    fn fires(&self) {
        assert_eq!(
            self.fired.recv_timeout(Duration::from_secs(5)),
            Ok(true),
            "the Chief owner outlived its app with nothing that needs it"
        );
        cmux_owner_liveness::check("chief owner (test)", true, self.facts.keeps(), true);
    }

    fn set_clients(&self, clients: usize) {
        self.facts.clients.store(clients, Ordering::SeqCst);
        self.watch.clients_changed();
    }

    /// The owning app exits, and its kernel watch reports it.
    fn app_quits(&self) {
        *self.facts.owner.lock().unwrap() = FakeOwner::Manual(OwnerState::Gone);
        self.watch.facts_changed();
    }

    /// Follows a real stand-in app, and the apps `file` names after it.
    fn follow_real(&self, app: OwnerApp, file: Option<PathBuf>) {
        let liveness = OwnerLiveness::new(file);
        let observer = Arc::downgrade(&self.watch);
        liveness.observe(move || {
            if let Some(watch) = observer.upgrade() {
                watch.facts_changed();
            }
        });
        *self.facts.owner.lock().unwrap() = FakeOwner::Real(liveness.clone());
        follow(&liveness, app);
    }

    /// Moves the clock a grace at a time until the owner exits (the kernel
    /// reports an exit on its own thread).
    fn fires_soon(&self, what: &str) {
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            self.advance(GRACE);
            if let Ok(fired) = self.fired.recv_timeout(Duration::from_millis(50)) {
                assert!(fired);
                return;
            }
            assert!(Instant::now() < deadline, "{what}");
        }
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        self.watch.stop();
    }
}

#[test]
fn chief_owner_exit_never_while_its_app_runs() {
    // Nothing live and no client for hours: the app still runs, so Home may
    // connect at any time.
    let f = Fixture::start(FakeFacts::default());
    f.advance(HOUR * 24);
    f.not_yet();
}

#[test]
fn chief_owner_exit_soon_after_its_app_quits() {
    let f = Fixture::start(FakeFacts::default());
    f.advance(HOUR);
    f.app_quits();
    f.advance(GRACE - Duration::from_millis(500));
    f.not_yet();
    f.advance(Duration::from_millis(500));
    f.fires();
}

#[test]
fn chief_owner_exit_waits_for_the_brain_host_at_work() {
    // The Chief's brain host is a client while a turn or a subagent works
    // (Keep Sessions Running): the owner stays until it leaves.
    let f = Fixture::start(FakeFacts::default());
    f.set_clients(1);
    f.app_quits();
    f.advance(HOUR);
    f.not_yet();
    f.set_clients(0);
    f.advance(GRACE - Duration::from_millis(500));
    f.not_yet();
    f.advance(Duration::from_millis(500));
    f.fires();
}

#[test]
fn chief_owner_exit_waits_for_a_live_brain_of_another_chief() {
    let f = Fixture::start(FakeFacts { brains: AtomicUsize::new(1), ..FakeFacts::default() });
    f.app_quits();
    f.advance(GRACE);
    f.not_yet();
    f.facts.brains.store(0, Ordering::SeqCst);
    f.advance(CHIEF_OWNER_TIMING.recheck);
    f.fires();
}

#[test]
fn chief_owner_exit_waits_for_a_live_terminal() {
    let f = Fixture::start(FakeFacts { terminals: AtomicUsize::new(1), ..FakeFacts::default() });
    f.app_quits();
    f.advance(HOUR);
    f.not_yet();
    f.facts.terminals.store(0, Ordering::SeqCst);
    f.advance(CHIEF_OWNER_TIMING.recheck);
    f.fires();
}

#[test]
fn chief_owner_exit_stays_with_an_unreadable_registry() {
    let f = Fixture::start(FakeFacts { unreadable: AtomicBool::new(true), ..FakeFacts::default() });
    f.app_quits();
    f.advance(HOUR);
    f.not_yet();
}

/// The kernel watch: the owning app's process exits (here a child that is
/// killed), and the grace starts with no polling of the process.
#[test]
fn chief_owner_exit_watches_the_app_process_in_the_kernel() {
    let app = std::process::Command::new("sleep").arg("600").spawn().expect("a stand-in app");
    let f = Fixture::start(FakeFacts::default());
    f.follow_real(OwnerApp::parse(Some(&app.id().to_string())), None);
    f.advance(HOUR);
    f.not_yet();
    quit(app);
    f.fires_soon("the app's exit never ended the Chief owner");
}

/// A newer app reused this owner (it wrote the pid file): the first app's
/// exit does not end it; the newer app's does.
#[test]
fn chief_owner_exit_follows_the_newer_app_that_reused_the_owner() {
    let dir = tempfile::tempdir().expect("dir");
    let file = dir.path().join("owner-app.pid");
    let first = std::process::Command::new("sleep").arg("600").spawn().expect("first app");
    let second = std::process::Command::new("sleep").arg("600").spawn().expect("second app");
    std::fs::write(&file, format!("{}\n", second.id())).expect("pid file");
    let f = Fixture::start(FakeFacts::default());
    f.follow_real(OwnerApp::parse(Some(&first.id().to_string())), Some(file));
    quit(first);
    for _ in 0..10 {
        f.advance(GRACE);
        f.not_yet();
    }
    quit(second);
    f.fires_soon("the newer app's exit never ended the Chief owner");
}

fn quit(mut app: std::process::Child) {
    app.kill().expect("the stand-in app ends");
    app.wait().expect("reaped");
}

// cp/redesign-quit-helpers (principled audit, R2/R3): whether an owning
// app lives is a level, read from current truth. On the base the first app's
// exit armed a latch for good: a newer app that started after that quit and
// reused this owner (it wrote the pid file) did not keep it, so the owner
// stopped under a running app as soon as no client was connected.
#[test]
fn chief_owner_exit_owner_level_a_newer_app_after_the_quit_keeps_the_owner() {
    let dir = tempfile::tempdir().expect("dir");
    let file = dir.path().join("owner-app.pid");
    let mut first = std::process::Command::new("sleep").arg("600").spawn().expect("first app");
    let f = Fixture::start(FakeFacts::default());
    follow_app(&f, first.id(), &file);
    first.kill().expect("first app ends");
    first.wait().expect("reaped");
    // Lets the kernel report the first app's exit before the newer app
    // starts (only so the base shows its latch; the level needs no wait).
    std::thread::sleep(Duration::from_millis(300));
    let mut second = std::process::Command::new("sleep").arg("600").spawn().expect("second app");
    std::fs::write(&file, format!("{}\n", second.id())).expect("pid file");
    // The newer app's Home connects and leaves (a reconnect) while it runs.
    f.set_clients(1);
    f.set_clients(0);
    for _ in 0..10 {
        f.advance(GRACE);
        f.not_yet();
    }
    second.kill().expect("second app ends");
    second.wait().expect("reaped");
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        f.advance(GRACE);
        if let Ok(fired) = f.fired.recv_timeout(Duration::from_millis(50)) {
            assert!(fired);
            break;
        }
        assert!(Instant::now() < deadline, "the newer app's exit never ended the Chief owner");
    }
}

/// The owner follows the app `pid` and then the apps `file` names.
fn follow_app(f: &Fixture, pid: u32, file: &Path) {
    f.follow_real(OwnerApp::parse(Some(&pid.to_string())), Some(file.to_path_buf()));
}

#[test]
fn chief_owner_exit_file_is_in_the_chief_home() {
    assert_eq!(
        owner_app_file(Path::new("/u/.cmux/chief/x/tui")),
        Some(PathBuf::from("/u/.cmux/chief/x/state/owner-app.pid"))
    );
}

#[test]
fn chief_owner_exit_applies_only_to_a_chief_owner_an_app_started() {
    let app = OwnerApp::parse(Some("4242"));
    assert!(applies("cmux-chief-3d0749d3", app));
    // The app's own daemon keeps the person's terminals (quit-persistence.md).
    assert!(!applies("cmux-app--89e32288", app));
    // A Chief owner `cmux chief` started has no app to follow.
    assert!(!applies("cmux-chief-3d0749d3", OwnerApp::parse(None)));
}

#[test]
fn chief_owner_exit_rule() {
    let exits =
        |terminals, brains, owner| chief_owner_keeps(0, owner, terminals, brains).exits(true);
    assert!(exits(Some(0), 0, OwnerState::Gone));
    assert!(!exits(Some(0), 0, OwnerState::Alive));
    assert!(!exits(Some(1), 0, OwnerState::Gone));
    assert!(!exits(None, 0, OwnerState::Gone));
    assert!(!exits(Some(0), 1, OwnerState::Gone));
    assert!(!chief_owner_keeps(1, OwnerState::Gone, Some(0), 0).exits(true));
}
