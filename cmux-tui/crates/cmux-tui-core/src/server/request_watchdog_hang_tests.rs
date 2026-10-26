//! The hang tier of the one request watchdog: a scope of any kind busy past
//! its hang tier is written once with its kind, method and thread's stack
//! (the blocked function on top); one that ended past it unseen is written
//! with `run-ended`; short scopes of any kind wake the watchdog only on its
//! grid; an idle daemon's watchdog does not wake.

use std::sync::atomic::AtomicBool;
use std::sync::mpsc::{Receiver, channel};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use super::*;

const CREATE: WatchedMethod =
    WatchedMethod(RESOURCE_TAG | ResourceOperation::WorkspaceCreate as u32);

/// The hang tier in these tests: two grid periods of the default threshold.
const HANG: Duration = Duration::from_millis(500);

/// A watchdog whose records (of `scope` only) arrive on the receiver.
fn hang_watchdog(scope: &'static str) -> (RequestWatchdog, Receiver<serde_json::Value>) {
    let (records, received) = channel();
    let records = Mutex::new(records);
    let sink: HangSink = Box::new(move |record| {
        if record["scope"] == scope {
            let _ = records.lock().unwrap().send(record);
        }
    });
    (RequestWatchdog::for_hang_test(REQUEST_WATCHDOG_THRESHOLD, HANG, sink), received)
}

fn wakeups(watchdog: &RequestWatchdog) -> u64 {
    watchdog.shared.wakeups.load(Ordering::Relaxed)
}

/// Wakes allowed for `elapsed`: at most one per threshold period, plus one.
fn allowed_wakeups(elapsed: Duration) -> u64 {
    let periods = elapsed.as_millis().div_ceil(REQUEST_WATCHDOG_THRESHOLD.as_millis());
    u64::try_from(periods).unwrap_or(u64::MAX) + 1
}

fn wait_disarmed(shared: &Shared) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while shared.armed.load(Ordering::SeqCst) {
        assert!(Instant::now() < deadline, "the watchdog never disarmed");
        std::thread::sleep(Duration::from_millis(10));
    }
}

/// The demangled names of the function holding the pc `address`.
fn function_names(address: usize) -> Vec<String> {
    let mut names = Vec::new();
    backtrace::resolve((address + 1) as *mut std::ffi::c_void, |symbol| {
        if let Some(name) = symbol.name() {
            names.push(name.to_string());
        }
    });
    names
}

/// The handler the hang tests block in: a loop with no call.
#[inline(never)]
fn request_watchdog_hang_test_handler(stop: &AtomicBool) {
    while !stop.load(Ordering::Relaxed) {
        std::hint::spin_loop();
    }
}

/// Asserts the record's top frame is the blocked handler.
fn assert_top_frame_is_the_handler(record: &serde_json::Value) {
    let top = &record["stack"][0];
    let handler_address = request_watchdog_hang_test_handler as *const () as usize;
    let handler_frame = thread_backtrace::symbolicate_address(handler_address);
    assert_eq!(top["image"].as_str(), handler_frame.image.as_deref(), "{record}");
    let image_base = handler_address - handler_frame.offset;
    let offset = usize::try_from(top["offset"].as_u64().unwrap()).unwrap();
    let names = function_names(image_base + offset);
    assert!(
        names.iter().any(|name| name.contains("request_watchdog_hang_test_handler")),
        "the top frame {top} is in {names:?}"
    );
}

/// A request busy past its hang tier: in `slow_requests` at the threshold,
/// then written once to the hang log as `mux-conn` with its method, its
/// client and the stack at the hang tier, the busy handler on top.
#[cfg(any(target_os = "macos", target_os = "linux"))]
#[test]
fn request_watchdog_hang_tier_writes_the_method_and_the_handler_stack() {
    let (watchdog, received) = hang_watchdog("mux-conn");
    let watchdog = Arc::new(watchdog);
    let stop = Arc::new(AtomicBool::new(false));
    let handler = std::thread::spawn({
        let (watchdog, stop) = (watchdog.clone(), stop.clone());
        move || {
            let _scope = watchdog.begin(11, CREATE).expect("a free slot");
            request_watchdog_hang_test_handler(std::hint::black_box(&stop));
        }
    });
    let record = received.recv_timeout(Duration::from_secs(10)).expect("a hang record");
    stop.store(true, Ordering::Relaxed);
    handler.join().unwrap();

    assert_eq!(record["event"], "hang");
    assert_eq!(record["method"], "workspace.create");
    assert_eq!(record["client"], 11);
    assert_eq!(record["hang_ms"], 500);
    assert!(record["busy_ms"].as_u64().unwrap() >= 500, "{record}");
    assert_eq!(record["duration_ms"], serde_json::Value::Null, "{record}");
    assert_eq!(record["stack_error"], serde_json::Value::Null, "{record}");
    assert_top_frame_is_the_handler(&record);
    wait_disarmed(&watchdog.shared);
    assert!(received.try_recv().is_err(), "written once");
    let snapshot = watchdog.snapshot();
    assert_eq!((snapshot.total, snapshot.hangs, snapshot.hang_ms), (1, 1, 500), "{snapshot:?}");
}

/// A journal commit busy past its hang tier is written as
/// `journal-writer`/`commit-batch` and never lands in `slow_requests`.
#[cfg(any(target_os = "macos", target_os = "linux"))]
#[test]
fn request_watchdog_writes_a_blocked_journal_commit_with_its_stack() {
    let (watchdog, received) = hang_watchdog("journal-writer");
    let watchdog = Arc::new(watchdog);
    let stop = Arc::new(AtomicBool::new(false));
    let writer = std::thread::spawn({
        let (watchdog, stop) = (watchdog.clone(), stop.clone());
        move || {
            let _scope = watchdog.watch(WatchKind::JournalWriter, 0).expect("a free slot");
            request_watchdog_hang_test_handler(std::hint::black_box(&stop));
        }
    });
    let record = received.recv_timeout(Duration::from_secs(10)).expect("a hang record");
    stop.store(true, Ordering::Relaxed);
    writer.join().unwrap();
    assert_eq!(record["method"], "commit-batch");
    assert!(record.get("client").is_none(), "{record}");
    assert_top_frame_is_the_handler(&record);
    wait_disarmed(&watchdog.shared);
    assert_eq!(watchdog.snapshot().total, 0, "only a request lands in slow_requests");
}

/// A scope that ran past its hang tier and ended before the watchdog woke
/// is still written once, with its duration and `run-ended`.
#[test]
fn request_watchdog_writes_a_hang_that_ended_before_the_watchdog_woke() {
    let (watchdog, received) = hang_watchdog("journal-writer");
    let hold = watchdog.shared.scan_hold.lock().unwrap();
    let scope = watchdog.watch(WatchKind::JournalWriter, 0).expect("a free slot");
    std::thread::sleep(HANG + Duration::from_millis(50));
    drop(scope);
    drop(hold);
    let record = received.recv_timeout(Duration::from_secs(10)).expect("a hang record");
    assert_eq!(record["stack_error"], "run-ended", "{record}");
    assert!(record["duration_ms"].as_u64().unwrap() >= 500, "{record}");
    wait_disarmed(&watchdog.shared);
    assert!(received.try_recv().is_err(), "written once");
}

/// A scope of a kind with only a hang tier that ends under it frees its
/// slot at once: nothing written, nothing captured.
#[test]
fn request_watchdog_writes_nothing_for_a_short_journal_commit() {
    let (watchdog, received) = hang_watchdog("journal-writer");
    let scope = watchdog.watch(WatchKind::JournalWriter, 0).expect("a free slot");
    std::thread::sleep(REQUEST_WATCHDOG_THRESHOLD + Duration::from_millis(50));
    drop(scope);
    wait_disarmed(&watchdog.shared);
    assert!(received.try_recv().is_err());
    assert_eq!(watchdog.shared.stack_captures.load(Ordering::Relaxed), 0);
    assert!(watchdog.shared.slots.iter().all(|slot| slot.busy.load(Ordering::SeqCst) == 0));
}

/// The holder link's frames go through the process's watchdog: 1000 short
/// frames 1 ms apart wake it only on its grid (at most 4/s), and a frame
/// blocked past its tier is written as `holder-link` with its frame kind.
/// The only test in this binary that makes a watchdog the process's.
#[cfg(unix)]
#[test]
fn process_watchdog_wakes_on_its_grid_under_1000_short_holder_frames() {
    let (watchdog, received) = hang_watchdog("holder-link");
    assert!(watchdog.watch_for_process(), "one process watchdog per test binary");
    let data = u32::from(cmux_holder::wire::Kind::Data as u16);
    let start = Instant::now();
    for _ in 0..1_000 {
        let token = process_enter(WatchKind::HolderLink, data);
        assert_ne!(token, 0, "a free slot");
        process_exit(token);
        std::thread::sleep(Duration::from_millis(1));
    }
    let elapsed = start.elapsed();
    let woke = wakeups(&watchdog);
    let allowed = allowed_wakeups(elapsed);
    assert!(woke <= allowed, "{woke} wakeups in {elapsed:?} (allowed {allowed})");
    wait_disarmed(&watchdog.shared);
    assert_eq!(watchdog.shared.stack_captures.load(Ordering::Relaxed), 0);
    // Spaced wider than the hang tier: each costs at most the arm and the
    // grid ticks to its disarm, never a wake per deadline of a dead scope.
    let (before, start) = (wakeups(&watchdog), Instant::now());
    for _ in 0..3 {
        process_exit(process_enter(WatchKind::HolderLink, data));
        std::thread::sleep(HANG + Duration::from_millis(100));
    }
    let (woke, elapsed) = (wakeups(&watchdog) - before, start.elapsed());
    let allowed = allowed_wakeups(elapsed);
    assert!(woke <= allowed, "{woke} wakeups in {elapsed:?} for 3 frames (allowed {allowed})");

    let token = process_enter(WatchKind::HolderLink, data);
    let record = received.recv_timeout(Duration::from_secs(10)).expect("a hang record");
    process_exit(token);
    assert_eq!(record["method"], "data", "{record}");
    assert_eq!(record["hang_ms"], 500, "{record}");
}

/// An idle daemon: once startup settles, its one watchdog (requests,
/// journal commits) parks with no timer and does not wake.
#[test]
fn an_idle_daemon_watchdog_does_not_wake() {
    let mux = crate::Mux::new_for_test("idle-hang-watchdog", crate::SurfaceOptions::default());
    wait_disarmed(&mux.request_watchdog.shared);
    let before = mux.request_watchdog.snapshot().watchdog_wakeups;
    std::thread::sleep(Duration::from_secs(2));
    let snapshot = mux.request_watchdog.snapshot();
    assert_eq!(snapshot.watchdog_wakeups, before, "the idle daemon's watchdog woke");
    assert_eq!(snapshot.hangs, 0);
}

/// Each kind names its scope and methods in a record.
#[test]
fn watch_kinds_name_their_scopes_and_methods() {
    assert_eq!(WatchKind::MuxConn.name(), "mux-conn");
    assert_eq!(WatchKind::MuxConn.method_name(CREATE.0), "workspace.create");
    assert_eq!(WatchKind::MuxConn.hang(), Duration::from_secs(2));
    assert_eq!(WatchKind::JournalWriter.name(), "journal-writer");
    assert_eq!(WatchKind::JournalWriter.method_name(0), "commit-batch");
    assert_eq!(WatchKind::JournalWriter.hang(), Duration::from_secs(2));
    #[cfg(unix)]
    {
        let data = u32::from(cmux_holder::wire::Kind::Data as u16);
        assert_eq!(WatchKind::HolderLink.name(), "holder-link");
        assert_eq!(WatchKind::HolderLink.method_name(data), "data");
        assert_eq!(WatchKind::HolderLink.method_name(0xffff), "unknown");
        assert_eq!(WatchKind::HolderLink.hang(), Duration::from_secs(1));
    }
    for kind in [WatchKind::MuxConn, WatchKind::JournalWriter] {
        assert_eq!(WatchKind::from_raw(kind.raw()), kind);
    }
}
