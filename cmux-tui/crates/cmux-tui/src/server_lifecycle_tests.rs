//! The headless owner idle exit on a fake clock (`cargo test -p cmux-tui idle_exit`).

use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::mpsc::{Receiver, channel};
use std::sync::{Mutex, MutexGuard};
use std::time::Instant;

use cmux_threads::sync::Condvar;

use super::dev_orphan_exit::{OrphanClock, WatchState};
use super::*;

const GRACE: Duration = IDLE_EXIT_GRACE;
const SECOND: Duration = Duration::from_secs(1);

#[derive(Default)]
struct FakeFacts {
    clients: AtomicUsize,
    terminals: AtomicUsize,
    unreadable: AtomicBool,
    agents: AtomicBool,
    owner: AtomicBool,
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
        idle_exits(
            self.live_terminals(),
            self.agents.load(Ordering::SeqCst),
            self.owner.load(Ordering::SeqCst),
        )
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
        let watch = OrphanWatch::with_timing(clock.clone(), facts.clone(), IDLE_TIMING);
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
        assert_eq!(self.fired.recv_timeout(Duration::from_secs(5)), Ok(true));
    }

    fn set_clients(&self, clients: usize) {
        self.facts.clients.store(clients, Ordering::SeqCst);
        self.watch.clients_changed();
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        self.watch.stop();
    }
}

#[test]
fn idle_exit_after_the_grace_with_nothing_live() {
    let f = Fixture::start(FakeFacts::default());
    f.advance(GRACE - SECOND);
    f.not_yet();
    f.advance(SECOND);
    f.fires();
}

#[test]
fn idle_exit_never_with_a_client_and_the_grace_restarts_when_it_leaves() {
    let f = Fixture::start(FakeFacts::default());
    f.advance(GRACE - SECOND);
    // An updated app reconnects within the grace.
    f.set_clients(1);
    f.advance(GRACE * 5);
    f.not_yet();
    f.set_clients(0);
    f.advance(GRACE - SECOND);
    f.not_yet();
    f.advance(SECOND);
    f.fires();
}

#[test]
fn idle_exit_stays_with_a_live_terminal() {
    // Own PTYs and holder-hosted ones are both live registry terminals.
    let f = Fixture::start(FakeFacts { terminals: AtomicUsize::new(1), ..FakeFacts::default() });
    f.advance(GRACE * 5);
    f.not_yet();
    f.facts.terminals.store(0, Ordering::SeqCst);
    f.advance(GRACE);
    f.fires();
}

#[test]
fn idle_exit_stays_with_an_unreadable_registry() {
    let f = Fixture::start(FakeFacts { unreadable: AtomicBool::new(true), ..FakeFacts::default() });
    f.advance(GRACE * 5);
    f.not_yet();
}

#[test]
fn idle_exit_stays_with_a_live_agent() {
    let f = Fixture::start(FakeFacts { agents: AtomicBool::new(true), ..FakeFacts::default() });
    f.advance(GRACE * 5);
    f.not_yet();
}

#[test]
fn idle_exit_stays_while_the_owning_app_runs() {
    let f = Fixture::start(FakeFacts { owner: AtomicBool::new(true), ..FakeFacts::default() });
    f.advance(GRACE * 5);
    f.not_yet();
    f.facts.owner.store(false, Ordering::SeqCst);
    f.advance(GRACE);
    f.fires();
}

#[test]
fn idle_exit_rule() {
    assert!(idle_exits(Some(0), false, false));
    assert!(!idle_exits(Some(1), false, false));
    assert!(!idle_exits(None, false, false));
    assert!(!idle_exits(Some(0), true, false));
    assert!(!idle_exits(Some(0), false, true));
}

#[test]
fn idle_exit_is_off_by_default() {
    let defaults = cmux_features::Snapshot::defaults(cmux_features::Channel::Release);
    assert!(!defaults.is_enabled(cmux_features::feature::LEFTOVER_DAEMON_IDLE_EXIT));
    for channel in [cmux_features::Channel::Dev, cmux_features::Channel::Nightly] {
        let snapshot = cmux_features::Snapshot::defaults(channel);
        assert!(!snapshot.is_enabled(cmux_features::feature::LEFTOVER_DAEMON_IDLE_EXIT));
    }
}
