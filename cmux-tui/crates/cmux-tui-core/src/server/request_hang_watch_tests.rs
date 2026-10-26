//! The request scopes against this test binary's one process hang watch, on
//! a clock the tests move. Each test registers its own thread name and reads
//! only that thread's hangs: other tests' threads register too once the
//! watch runs, and their scopes may be reported when the clock moves.

use super::*;

use std::io;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, OnceLock, PoisonError};
use std::time::Instant;

use cmux_hang_watch::{Clock, Config, Hang, HangSink, ThreadKind};

/// How long a test waits in real time for the watcher to report.
const REPORT_TIMEOUT: Duration = Duration::from_secs(20);

struct TestClock(AtomicU64);

impl Clock for TestClock {
    fn now_ns(&self) -> u64 {
        self.0.load(Ordering::SeqCst)
    }
}

#[derive(Default)]
struct Recorded {
    hangs: Mutex<Vec<Hang>>,
    changed: Condvar,
}

struct TestSink(Arc<Recorded>);

impl HangSink for TestSink {
    fn record(&self, hang: &Hang) -> io::Result<()> {
        self.0.hangs.lock().unwrap_or_else(PoisonError::into_inner).push(hang.clone());
        self.0.changed.notify_all();
        Ok(())
    }
}

struct Harness {
    clock: Arc<TestClock>,
    recorded: Arc<Recorded>,
    /// The tests that move the clock run one at a time.
    serial: Mutex<()>,
}

impl Harness {
    fn get() -> &'static Harness {
        static HARNESS: OnceLock<Harness> = OnceLock::new();
        HARNESS.get_or_init(|| {
            let clock = Arc::new(TestClock(AtomicU64::new(0)));
            let recorded = Arc::<Recorded>::default();
            // A 1 ms watcher period, and no pass is ever late: the clock
            // jumps while the watcher sleeps in real time.
            let config =
                Config { min_deadline: Duration::from_millis(1), drift_tolerance: Duration::MAX };
            cmux_hang_watch::init_process(
                config,
                clock.clone(),
                Box::new(TestSink(recorded.clone())),
            )
            .expect("the test binary's one process hang watch");
            Harness { clock, recorded, serial: Mutex::new(()) }
        })
    }

    fn serial(&self) -> MutexGuard<'_, ()> {
        self.serial.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn advance(&self, by: Duration) {
        let ns = u64::try_from(by.as_nanos()).expect("a test step fits in u64 ns");
        self.clock.0.fetch_add(ns, Ordering::SeqCst);
    }

    fn hangs_of(&self, thread: &str) -> Vec<Hang> {
        let hangs = self.recorded.hangs.lock().unwrap_or_else(PoisonError::into_inner);
        hangs.iter().filter(|hang| hang.thread == thread).cloned().collect()
    }

    /// Waits until `thread` has `count` hangs and returns them.
    fn wait_for(&self, thread: &str, count: usize) -> Vec<Hang> {
        let deadline = Instant::now() + REPORT_TIMEOUT;
        let mut hangs = self.recorded.hangs.lock().unwrap_or_else(PoisonError::into_inner);
        loop {
            let found: Vec<Hang> =
                hangs.iter().filter(|hang| hang.thread == thread).cloned().collect();
            if found.len() >= count {
                return found;
            }
            let left = deadline.saturating_duration_since(Instant::now());
            assert!(!left.is_zero(), "{thread}: {count} hangs not reported in {REPORT_TIMEOUT:?}");
            hangs = self
                .recorded
                .changed
                .wait_timeout(hangs, left)
                .unwrap_or_else(PoisonError::into_inner)
                .0;
        }
    }

    /// Returns after at least one whole watcher pass ran on the clock as it
    /// is now: a control thread hangs twice in a row, and its second hang
    /// comes from a pass after the one that saw its first.
    fn full_pass(&self, control: &'static str) {
        std::thread::scope(|scope| {
            scope.spawn(|| {
                let _registered = cmux_hang_watch::register_thread(ThreadKind::Io, control);
                for count in 1..=2 {
                    let watched = cmux_hang_watch::watch(Duration::from_millis(1));
                    self.advance(Duration::from_millis(10));
                    self.wait_for(control, count);
                    drop(watched);
                }
            });
        });
    }
}

#[test]
fn request_hang_watch_reports_a_query_past_its_class_deadline() {
    const THREAD: &str = "request-hang-test-query";
    let harness = Harness::get();
    let _serial = harness.serial();
    let _registered = cmux_hang_watch::register_thread(ThreadKind::Control, THREAD);
    let owner = RequestHang::enter(MethodClass::Query);
    assert!(owner.is_some(), "a request with no frame owns its scope");
    harness.advance(Duration::from_millis(1_500));
    let hangs = harness.wait_for(THREAD, 1);
    assert_eq!(hangs[0].deadline_ms, 1_000);
    assert_eq!(hangs[0].kind, ThreadKind::Control);
}

#[test]
fn request_hang_watch_frame_takes_its_requests_class_deadline() {
    const THREAD: &str = "request-hang-test-frame";
    let harness = Harness::get();
    let _serial = harness.serial();
    let _registered = cmux_hang_watch::register_thread(ThreadKind::Io, THREAD);
    let frame = RequestHang::frame();
    assert!(frame.is_some(), "a frame owns its thread's scope");
    assert!(RequestHang::frame().is_none(), "a nested frame keeps the running scope");
    assert!(RequestHang::enter(MethodClass::Create).is_none(), "the frame's scope watches it");
    harness.advance(Duration::from_millis(6_000));
    harness.wait_for(THREAD, 1);
    // The frame's own 1 s deadline closed when the request began.
    assert!(harness.hangs_of(THREAD).iter().all(|hang| hang.deadline_ms == 5_000));
}

#[test]
fn request_hang_watch_does_not_blame_a_may_wait_round_trip() {
    const THREAD: &str = "request-hang-test-agent-wait";
    let harness = Harness::get();
    let _serial = harness.serial();
    let _registered = cmux_hang_watch::register_thread(ThreadKind::Control, THREAD);
    let _owner = RequestHang::enter(MethodClass::Agent);
    ipc_reply(|| {
        harness.advance(Duration::from_secs(20));
        harness.full_pass("request-hang-test-agent-control");
    });
    assert_eq!(harness.hangs_of(THREAD), Vec::new());
}

#[test]
fn request_hang_watch_still_watches_a_query_through_a_round_trip() {
    const THREAD: &str = "request-hang-test-query-wait";
    let harness = Harness::get();
    let _serial = harness.serial();
    let _registered = cmux_hang_watch::register_thread(ThreadKind::Control, THREAD);
    let _owner = RequestHang::enter(MethodClass::Query);
    let hangs = ipc_reply(|| {
        harness.advance(Duration::from_secs(2));
        harness.wait_for(THREAD, 1)
    });
    assert_eq!(hangs[0].deadline_ms, 1_000);
}

#[test]
fn request_hang_watch_does_not_blame_wait_for() {
    const THREAD: &str = "request-hang-test-wait-for";
    let harness = Harness::get();
    let _serial = harness.serial();
    let _registered = cmux_hang_watch::register_thread(ThreadKind::Control, THREAD);
    let command: Command = serde_json::from_value(serde_json::json!({
        "cmd": "wait-for",
        "surface": 1,
        "pattern": "never",
        "timeout_ms": 60_000,
    }))
    .expect("a wait-for command");
    assert!(command.waits_by_design());
    let _owner = RequestHang::enter_command(&command);
    harness.advance(Duration::from_secs(30));
    harness.full_pass("request-hang-test-wait-for-control");
    assert_eq!(harness.hangs_of(THREAD), Vec::new());
}

#[test]
fn request_hang_watch_scope_owner_ends_the_request() {
    let frame = RequestHang::frame();
    assert!(frame.is_some());
    assert_eq!(current_class(), None, "a frame has no class until it reaches its request");
    assert!(RequestHang::enter(MethodClass::Browser).is_none());
    assert_eq!(current_class(), Some(MethodClass::Browser));
    drop(frame);
    assert_eq!(current_class(), None);
    let owner = RequestHang::enter(MethodClass::Topology);
    assert!(owner.is_some(), "the next request on the thread opens its own scope");
    assert_eq!(current_class(), Some(MethodClass::Topology));
}
