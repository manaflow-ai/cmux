//! The host loops' hang-watch registrations, on a watch with a manual
//! clock: an item open past its loop's deadline is one hang under the loop's thread name, and the
//! wait between items is never blamed.

use std::io;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use cmux_hang_watch::{Clock, Config, Hang, HangSink, HangWatch, ThreadKind};

use super::HostLoop;

const LOOPS: [HostLoop; 3] = [HostLoop::Pty, HostLoop::Parser, HostLoop::ClientInput];

#[derive(Default)]
struct ManualClock(AtomicU64);

impl ManualClock {
    fn advance(&self, by: Duration) -> u64 {
        let by = u64::try_from(by.as_nanos()).unwrap_or(u64::MAX);
        self.0.fetch_add(by, Ordering::SeqCst) + by
    }
}

impl Clock for ManualClock {
    fn now_ns(&self) -> u64 {
        self.0.load(Ordering::SeqCst)
    }
}

#[derive(Clone, Default)]
struct Collect(Arc<Mutex<Vec<Hang>>>);

impl HangSink for Collect {
    fn record(&self, hang: &Hang) -> io::Result<()> {
        self.0.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).push(hang.clone());
        Ok(())
    }
}

impl Collect {
    fn hangs(&self) -> Vec<Hang> {
        self.0.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).clone()
    }
}

#[test]
fn host_loops_blame_an_item_past_its_deadline_and_never_the_wait_between_items() {
    for lane in LOOPS {
        let clock = Arc::new(ManualClock::default());
        let sink = Collect::default();
        let watch = HangWatch::new(Config::default(), clock.clone(), Box::new(sink.clone()));
        let guard = watch.register_thread(lane.kind(), lane.thread_name());
        assert!(guard.is_registered());

        // Waiting for the next item, far past the deadline: no scope is open.
        let now = clock.advance(lane.deadline() * 4);
        assert_eq!(watch.check(now).hangs, 0, "{lane:?} blamed for its wait");

        let item = lane.watch(&guard);
        assert!(item.is_watching());
        let now = clock.advance(lane.deadline() - Duration::from_millis(1));
        assert_eq!(watch.check(now).hangs, 0, "{lane:?} blamed within its deadline");
        let now = clock.advance(Duration::from_millis(2));
        assert_eq!(watch.check(now).hangs, 1, "{lane:?} item past its deadline");
        drop(item);

        let now = clock.advance(lane.deadline() * 4);
        assert_eq!(watch.check(now).hangs, 0, "{lane:?} blamed after its item closed");
        let hangs = sink.hangs();
        assert_eq!(hangs.len(), 1);
        assert_eq!(hangs[0].thread, lane.thread_name());
        assert_eq!(hangs[0].kind, lane.kind());
        assert_eq!(hangs[0].deadline_ms, lane.deadline().as_millis() as u64);
    }
}

#[test]
fn host_loops_are_the_threads_the_host_starts() {
    let names: Vec<_> = LOOPS.iter().map(|lane| lane.thread_name()).collect();
    assert_eq!(names, ["terminal-host-pty", "terminal-host-parser", "terminal-host-client-input"]);
    // A parser command is a serial lane's item; the PTY and client loops do bounded I/O.
    assert_eq!(HostLoop::Parser.kind(), ThreadKind::Lane);
    assert_eq!(HostLoop::Pty.kind(), ThreadKind::Io);
    assert_eq!(HostLoop::ClientInput.kind(), ThreadKind::Io);
}

#[test]
fn host_loops_outside_a_hang_watched_process_watch_nothing() {
    // This test process never started the process watch: a host embedded in it is inert.
    if cmux_hang_watch::stats().is_some() {
        return;
    }
    let guard = HostLoop::Pty.register();
    assert!(!guard.is_registered());
    assert!(!HostLoop::Pty.watch(&guard).is_watching());
}
