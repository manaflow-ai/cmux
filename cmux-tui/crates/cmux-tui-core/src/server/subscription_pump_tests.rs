//! The subscription pump runs its drain only when woken: once at start,
//! once per wake (coalesced while a turn is posted), again after a yield,
//! and never while nothing wakes it.

use super::*;
use std::sync::mpsc;
use std::time::Duration;

/// A drain that answers each turn with the next of `script` (then `Idle`)
/// and reports each turn it ran.
struct Scripted {
    script: Vec<Turn>,
    turns: mpsc::Sender<usize>,
    count: usize,
    dropped: Arc<AtomicBool>,
}

impl SubscriptionDrain for Scripted {
    fn turn(&mut self) -> Turn {
        self.count += 1;
        let _ = self.turns.send(self.count);
        if self.script.is_empty() { Turn::Idle } else { self.script.remove(0) }
    }
}

impl Drop for Scripted {
    fn drop(&mut self) {
        self.dropped.store(true, Ordering::SeqCst);
    }
}

fn scripted(script: Vec<Turn>) -> (Box<Scripted>, mpsc::Receiver<usize>, Arc<AtomicBool>) {
    let (turns, seen) = mpsc::channel();
    let dropped = Arc::new(AtomicBool::new(false));
    (Box::new(Scripted { script, turns, count: 0, dropped: dropped.clone() }), seen, dropped)
}

fn turn(seen: &mpsc::Receiver<usize>) -> usize {
    seen.recv_timeout(Duration::from_secs(2)).expect("the drain ran a turn")
}

/// Nothing more runs: no turn within a short wait (no idle wakeup).
fn quiet(seen: &mpsc::Receiver<usize>) {
    assert!(seen.recv_timeout(Duration::from_millis(100)).is_err(), "a turn ran with no wake");
}

#[test]
fn a_pump_runs_once_at_start_and_once_per_wake_never_idle() {
    let mux = Mux::new_for_test("subscription-pump-wake", crate::SurfaceOptions::default());
    let pump = SubscriptionPump::new(&mux);
    let hook = pump.hook();
    let (drain, seen, _) = scripted(Vec::new());
    hook();
    pump.start(drain).expect("posted");
    assert_eq!(turn(&seen), 1, "the first turn");
    quiet(&seen);
    hook();
    assert_eq!(turn(&seen), 2, "a wake runs a turn");
    quiet(&seen);
    mux.shutdown();
}

#[test]
fn a_yield_runs_again_and_done_drops_the_drain_and_fires_stop() {
    let mux = Mux::new_for_test("subscription-pump-done", crate::SurfaceOptions::default());
    let pump = SubscriptionPump::new(&mux);
    let stop = pump.stop().clone();
    let weak = Arc::downgrade(&pump.inner);
    let (drain, seen, dropped) = scripted(vec![Turn::Yield, Turn::Done]);
    pump.start(drain).expect("posted");
    assert_eq!(turn(&seen), 1);
    assert_eq!(turn(&seen), 2, "a yield runs the next turn with no wake");
    let deadline = std::time::Instant::now() + Duration::from_secs(2);
    while !(dropped.load(Ordering::SeqCst) && weak.upgrade().is_none()) {
        assert!(std::time::Instant::now() < deadline, "the done pump stayed alive");
        std::thread::sleep(Duration::from_millis(5));
    }
    assert!(stop.is_fired(), "a done drain fires its stop interrupt");
    mux.shutdown();
}

#[test]
fn a_fired_stop_wakes_the_drain() {
    let mux = Mux::new_for_test("subscription-pump-stop", crate::SurfaceOptions::default());
    let pump = SubscriptionPump::new(&mux);
    let stop = pump.stop().clone();
    let (drain, seen, _) = scripted(vec![Turn::Idle, Turn::Done]);
    pump.start(drain).expect("posted");
    assert_eq!(turn(&seen), 1);
    quiet(&seen);
    stop.fire();
    assert_eq!(turn(&seen), 2, "the close's interrupt wakes the drain");
    mux.shutdown();
}

#[test]
fn wakes_coalesce_while_a_turn_is_posted() {
    let mux = Mux::new_for_test("subscription-pump-coalesce", crate::SurfaceOptions::default());
    let pump = SubscriptionPump::new(&mux);
    let hook = pump.hook();
    let (drain, seen, _) = scripted(Vec::new());
    // Before the start every wake is covered by the first turn.
    for _ in 0..100 {
        hook();
    }
    pump.start(drain).expect("posted");
    assert_eq!(turn(&seen), 1);
    quiet(&seen);
    mux.shutdown();
}

#[test]
fn a_refused_start_drops_the_drain() {
    let mux = Mux::new_for_test("subscription-pump-refused", crate::SurfaceOptions::default());
    let pump = SubscriptionPump::new(&mux);
    let stop = pump.stop().clone();
    let (drain, seen, dropped) = scripted(Vec::new());
    mux.shutdown();
    assert!(pump.start(drain).is_err(), "a start after shutdown is refused");
    assert!(dropped.load(Ordering::SeqCst), "the refused drain was kept");
    assert!(stop.is_fired());
    quiet(&seen);
}
