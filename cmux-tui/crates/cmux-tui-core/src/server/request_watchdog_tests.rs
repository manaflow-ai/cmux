//! The request watchdog: one entry per overrun with its final duration, no
//! timer while idle, a bounded wake rate under any request spacing, waits by
//! design left out, a failed thread start counted, its thread row, and every
//! kind of connection frame watched.

use std::sync::Arc;
use std::sync::mpsc::channel;
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::super::terminal_io_wire::WaitForParams;
use super::super::{
    BoundedOutbound, ClientTransport, Command, ConnectionSurfaceScheduler, MessageWriter,
    QueuedSink, Request, handle_connection_frame,
};
use super::*;

const CREATE: WatchedMethod =
    WatchedMethod(RESOURCE_TAG | ResourceOperation::WorkspaceCreate as u32);

fn wakeups(watchdog: &RequestWatchdog) -> u64 {
    watchdog.shared.wakeups.load(Ordering::Relaxed)
}

/// Waits (bounded) until the watchdog thread has disarmed and parked.
fn wait_disarmed(watchdog: &RequestWatchdog) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while watchdog.shared.armed.load(Ordering::SeqCst) {
        assert!(Instant::now() < deadline, "the watchdog never disarmed");
        std::thread::sleep(Duration::from_millis(10));
    }
}

/// Waits (bounded) until the watchdog has recorded `total` requests and
/// every recorded one has its final duration.
fn wait_settled(watchdog: &RequestWatchdog, total: u64) -> SlowRequestsSnapshot {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let snapshot = watchdog.snapshot();
        if snapshot.total >= total && snapshot.recent.iter().all(|r| r.duration_ms.is_some()) {
            return snapshot;
        }
        assert!(Instant::now() < deadline, "never settled at {total}: {snapshot:?}");
        std::thread::sleep(Duration::from_millis(10));
    }
}

#[test]
fn request_watchdog_records_a_300ms_run_exactly_once() {
    let watchdog = RequestWatchdog::default();
    let scope = watchdog.begin(7, CREATE).expect("a free slot");
    std::thread::sleep(Duration::from_millis(300));
    drop(scope);
    let snapshot = wait_settled(&watchdog, 1);
    wait_disarmed(&watchdog);

    assert_eq!(watchdog.snapshot().total, 1, "{snapshot:?}");
    assert_eq!(snapshot.threshold_ms, 250);
    let [entry] = snapshot.recent.as_slice() else { panic!("one entry: {snapshot:?}") };
    assert_eq!(entry.method, "workspace.create");
    assert_eq!(entry.client, 7);
    assert!(entry.busy_ms >= 250, "{entry:?}");
    let duration = entry.duration_ms.expect("a final duration");
    assert!((300..1_000).contains(&duration), "{entry:?}");
}

#[test]
fn request_watchdog_records_a_run_still_busy_once_then_fills_its_duration() {
    let watchdog = RequestWatchdog::default();
    let scope = watchdog.begin(3, CREATE).expect("a free slot");
    let deadline = Instant::now() + Duration::from_secs(5);
    while watchdog.snapshot().total == 0 {
        assert!(Instant::now() < deadline, "never recorded while busy");
        std::thread::sleep(Duration::from_millis(10));
    }
    let running = watchdog.snapshot();
    assert_eq!(running.recent[0].duration_ms, None, "{running:?}");
    // Still busy a full threshold later: not recorded again.
    std::thread::sleep(REQUEST_WATCHDOG_THRESHOLD * 2);
    drop(scope);
    let snapshot = wait_settled(&watchdog, 1);
    wait_disarmed(&watchdog);
    let [entry] = snapshot.recent.as_slice() else { panic!("one entry: {snapshot:?}") };
    assert_eq!(watchdog.snapshot().total, 1);
    assert!(entry.busy_ms >= 250, "{entry:?}");
    assert!(entry.duration_ms.unwrap() >= entry.busy_ms + 500, "{entry:?}");
}

/// A run just past the threshold that ends before the watchdog thread can
/// look is still recorded, with its real duration.
#[test]
fn request_watchdog_records_a_slow_run_that_ends_before_the_watchdog_wakes() {
    let watchdog = RequestWatchdog::default();
    let hold = watchdog.shared.scan_hold.lock().unwrap();
    let scope = watchdog.begin(4, CREATE).expect("a free slot");
    std::thread::sleep(REQUEST_WATCHDOG_THRESHOLD + Duration::from_millis(10));
    drop(scope);
    assert_eq!(watchdog.snapshot().total, 0, "held off: nothing scanned yet");
    drop(hold);

    let snapshot = wait_settled(&watchdog, 1);
    let [entry] = snapshot.recent.as_slice() else { panic!("one entry: {snapshot:?}") };
    let duration = entry.duration_ms.expect("a final duration");
    assert!(duration >= 260, "{entry:?}");
    assert_eq!(entry.busy_ms, duration, "{entry:?}");
    // Its thread had moved on: no stack, and none captured.
    assert_eq!(entry.stack_error, Some("run-ended"), "{entry:?}");
    assert!(entry.stack.is_empty(), "{entry:?}");
    assert_eq!(watchdog.shared.stack_captures.load(Ordering::Relaxed), 0);
    wait_disarmed(&watchdog);
}

#[test]
fn request_watchdog_records_nothing_for_a_short_run() {
    let watchdog = RequestWatchdog::default();
    drop(watchdog.begin(1, CREATE));
    wait_disarmed(&watchdog);
    assert_eq!(watchdog.snapshot().total, 0);
}

#[test]
fn request_watchdog_does_not_count_a_wait_by_design() {
    let watchdog = RequestWatchdog::default();
    let wait = Command::WaitFor(WaitForParams {
        surface: 1,
        pattern: "never".to_string(),
        timeout_ms: 1_000,
    });
    assert!(watchdog.begin_command(1, &wait).is_none(), "a wait-for is not watched");
    let scope = watchdog.begin(2, CREATE).expect("a free slot");
    scope.expect_blocking();
    std::thread::sleep(Duration::from_millis(300));
    drop(scope);
    wait_disarmed(&watchdog);
    let snapshot = watchdog.snapshot();
    assert_eq!(snapshot.total, 0, "{snapshot:?}");
    assert_eq!(snapshot.expected_waits, 2, "{snapshot:?}");
}

#[test]
fn request_watchdog_has_no_thread_and_no_wakeup_before_a_request() {
    let watchdog = RequestWatchdog::default();
    std::thread::sleep(Duration::from_millis(100));
    assert!(watchdog.shared.thread.get().is_none(), "no thread before the first request");
    assert_eq!(wakeups(&watchdog), 0);
}

#[test]
fn request_watchdog_wakes_zero_times_in_two_idle_seconds() {
    let watchdog = RequestWatchdog::default();
    drop(watchdog.begin(1, CREATE));
    wait_disarmed(&watchdog);
    let before = wakeups(&watchdog);
    std::thread::sleep(Duration::from_secs(2));
    assert_eq!(wakeups(&watchdog), before, "the parked watchdog woke while idle");
    assert!(!watchdog.shared.armed.load(Ordering::SeqCst));
}

/// Wakes allowed for `elapsed`: at most one per threshold period, plus one.
fn allowed_wakeups(elapsed: Duration) -> u64 {
    let periods = elapsed.as_millis().div_ceil(REQUEST_WATCHDOG_THRESHOLD.as_millis());
    u64::try_from(periods).unwrap_or(u64::MAX) + 1
}

#[test]
fn request_watchdog_wakes_at_most_four_times_a_second_under_1000_short_requests() {
    let watchdog = RequestWatchdog::default();
    let start = Instant::now();
    for client in 0..1_000u64 {
        drop(watchdog.begin(client, CREATE));
        std::thread::sleep(Duration::from_millis(2));
    }
    let elapsed = start.elapsed();
    let woke = wakeups(&watchdog);
    let allowed = allowed_wakeups(elapsed);
    assert!(woke <= allowed, "{woke} wakeups in {elapsed:?} (allowed {allowed})");
    assert_eq!(watchdog.snapshot().total, 0);
    wait_disarmed(&watchdog);
    let captures = watchdog.shared.stack_captures.load(Ordering::Relaxed);
    assert_eq!(captures, 0, "a short request is never captured");
}

/// Requests just over a threshold apart: each would arm a disarmed watchdog
/// if an arm added its own tick.
#[test]
fn request_watchdog_wakes_at_most_four_times_a_second_with_requests_a_period_apart() {
    for spacing in [260, 270, 300, 400, 510] {
        let watchdog = RequestWatchdog::default();
        let start = Instant::now();
        for client in 0..8u64 {
            drop(watchdog.begin(client, CREATE));
            std::thread::sleep(Duration::from_millis(spacing));
        }
        let elapsed = start.elapsed();
        let woke = wakeups(&watchdog);
        let allowed = allowed_wakeups(elapsed);
        assert!(
            woke <= allowed,
            "{spacing} ms apart: {woke} wakeups in {elapsed:?} (allowed {allowed})"
        );
        assert_eq!(watchdog.snapshot().total, 0);
    }
}

#[test]
fn request_watchdog_rearms_after_it_parked() {
    let watchdog = RequestWatchdog::default();
    drop(watchdog.begin(1, CREATE));
    wait_disarmed(&watchdog);
    let scope = watchdog.begin(2, CREATE).expect("a free slot");
    std::thread::sleep(Duration::from_millis(300));
    drop(scope);
    assert_eq!(wait_settled(&watchdog, 1).recent[0].client, 2);
}

#[test]
fn request_watchdog_counts_a_failed_thread_start_and_retries_it() {
    fn refuse(_: Box<dyn FnOnce() + Send>) -> std::io::Result<supervised::Unparker> {
        Err(std::io::Error::other("no threads"))
    }
    let watchdog = RequestWatchdog::with_seams(
        REQUEST_WATCHDOG_THRESHOLD,
        refuse,
        Box::new(thread_backtrace::capture),
    );
    drop(watchdog.begin(1, CREATE));
    assert_eq!(watchdog.snapshot().spawn_failures, 1);
    assert!(!watchdog.shared.armed.load(Ordering::SeqCst), "a failed start disarms");
    drop(watchdog.begin(2, CREATE));
    assert_eq!(watchdog.snapshot().spawn_failures, 2, "the next run tries again");
}

#[test]
fn request_watchdog_thread_row_runs_at_utility() {
    let watchdog = RequestWatchdog::default();
    drop(watchdog.begin(1, CREATE));
    let deadline = Instant::now() + Duration::from_secs(5);
    let rows = loop {
        let rows: Vec<_> =
            cmux_threads::snapshot().into_iter().filter(|row| row.name == THREAD_NAME).collect();
        if !rows.is_empty() {
            break rows;
        }
        assert!(Instant::now() < deadline, "no {THREAD_NAME} row");
        std::thread::sleep(Duration::from_millis(10));
    };
    for row in rows {
        assert_eq!(row.declared, cmux_threads::ThreadQos::Utility, "{row:?}");
    }
}

#[test]
fn request_watchdog_counts_runs_past_its_slots_as_unwatched() {
    let watchdog = RequestWatchdog::default();
    let scopes: Vec<_> =
        (0..SLOT_COUNT as u64).map(|client| watchdog.begin(client, CREATE)).collect();
    assert!(scopes.iter().all(Option::is_some));
    assert!(watchdog.begin(0, CREATE).is_none());
    assert_eq!(watchdog.snapshot().unwatched, 1);
    drop(scopes);
    assert!(watchdog.begin(0, CREATE).is_some(), "a freed slot is reused");
}

#[test]
fn request_watchdog_claims_wrap_from_the_last_slot_to_the_first() {
    let watchdog = RequestWatchdog::default();
    let last = SLOT_COUNT as u64 - 1;
    // Every run hints the last slot: the second one on finds it taken and
    // wraps to the start, until every slot is held.
    let scopes: Vec<_> = (0..SLOT_COUNT).map(|_| watchdog.begin(last, CREATE)).collect();
    assert!(scopes.iter().all(Option::is_some), "every slot is reached from the last one");
    assert!(watchdog.begin(last, CREATE).is_none());
    assert_eq!(watchdog.snapshot().unwatched, 1);
}

#[test]
fn request_watchdog_ring_keeps_the_newest_128() {
    let watchdog = RequestWatchdog::default();
    for client in 0..(SLOW_REQUEST_RING as u64 + 5) {
        watchdog.shared.record(
            0,
            busy_word(client),
            SlowRequest {
                method: "wait-for",
                client,
                started_ms: 0,
                busy_ms: 300,
                duration_ms: None,
                stack: Vec::new(),
                stack_truncated: false,
                stack_error: None,
            },
        );
    }
    let snapshot = watchdog.snapshot();
    assert_eq!(snapshot.total, SLOW_REQUEST_RING as u64 + 5);
    assert_eq!(snapshot.recent.len(), SLOW_REQUEST_RING);
    assert_eq!(snapshot.recent[0].client, 5, "the oldest entries go first");
}

#[test]
fn request_watchdog_names_every_method() {
    let wait =
        Command::WaitFor(WaitForParams { surface: 1, pattern: "x".to_string(), timeout_ms: 1 });
    assert_eq!(WatchedMethod::command(&wait).name(), "wait-for");
    assert_eq!(WatchedMethod::command(&Command::ReloadConfig).name(), "reload-config");
    for operation in ResourceOperation::ALL {
        assert_eq!(WatchedMethod::resource(*operation).name(), operation.wire_name());
    }
    for (index, stage) in FrameStage::ALL.iter().enumerate() {
        assert_eq!(*stage as usize, index, "FrameStage::ALL follows the declaration order");
        assert!(WatchedMethod::frame(*stage).name().starts_with("frame"));
    }
    assert_eq!(WatchedMethod(COMMAND_TAG | u32::from(u16::MAX)).name(), "unknown");
    assert_eq!(WatchedMethod(7 << 16).name(), "unknown");
    assert_eq!(word_start_us(busy_word(10)), Some(10));
    assert_eq!(word_start_us(busy_word(10) | FLAGS), Some(10));
    assert_eq!(word_start_us(0), None);
    assert_eq!(word_start_us(CLAIMING), None);
}

/// Measures one watched run (`begin` and the scope's drop); prints ns per
/// run. `cargo test -p cmux-tui-core --release --lib --
/// request_watchdog_begin_bench --ignored --nocapture`.
#[test]
#[ignore = "bench: run by hand (perf-hot daemon-request)"]
fn request_watchdog_begin_bench() {
    let watchdog = RequestWatchdog::default();
    let runs = 1_000_000u32;
    let start = Instant::now();
    for client in 0..runs {
        drop(std::hint::black_box(watchdog.begin(u64::from(client % 64), CREATE)));
    }
    let per_run = start.elapsed() / runs;
    println!("request_watchdog begin+end: {} ns per run", per_run.as_nanos());
}

struct Conn {
    client: u64,
    writer: MessageWriter,
    outbound: Arc<BoundedOutbound>,
    scheduler: Arc<ConnectionSurfaceScheduler>,
}

fn connect(mux: &Arc<crate::Mux>) -> Conn {
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    Conn { client, writer, outbound, scheduler }
}

/// Holds the workspace registry lock for `hold` on another thread, so a
/// handler that needs it is really slow.
fn hold_registry(mux: &Arc<crate::Mux>, hold: Duration) -> JoinHandle<()> {
    let (locked_tx, locked) = channel();
    let mux = mux.clone();
    let holder = std::thread::spawn(move || {
        let _registry = mux.workspace_registry.lock().unwrap();
        locked_tx.send(()).unwrap();
        std::thread::sleep(hold);
    });
    locked.recv().unwrap();
    holder
}

/// A dispatched `Command` that really runs 300 ms on the connection's
/// request sequence gives one entry, named by its `cmd`.
#[test]
fn request_watchdog_records_a_slow_command_on_the_connection_sequence() {
    let mux = crate::Mux::new_for_test("request-watchdog-cmd", crate::SurfaceOptions::default());
    let conn = connect(&mux);
    let holder = hold_registry(&mux, Duration::from_millis(300));
    let mut list = Some(Request { id: Some(json!(1)), cmd: Command::ListWorkspaces });
    assert_eq!(
        conn.scheduler.dispatch(mux.clone(), conn.client, &mut list, 0, conn.writer.clone()),
        Some(true)
    );
    conn.scheduler.finish_and_wait();
    holder.join().unwrap();
    let reply: Value = serde_json::from_str(&conn.outbound.try_pop().expect("a reply")).unwrap();
    assert_eq!(reply["ok"], true, "{reply}");

    let snapshot = wait_settled(&mux.request_watchdog, 1);
    assert_eq!(snapshot.total, 1, "{snapshot:?}");
    assert_eq!(snapshot.recent[0].method, "list-workspaces");
    assert_eq!(snapshot.recent[0].client, conn.client);
}

/// A dispatched `Command` still blocked when the watchdog records it (the
/// registry is held 600 ms, past the first scan at 250-500 ms) carries the
/// stack of the scheduler thread it runs on.
#[cfg(any(target_os = "macos", target_os = "linux"))]
#[test]
fn request_watchdog_stack_of_a_slow_command_on_the_connection_sequence() {
    let mux = crate::Mux::new_for_test("request-watchdog-stack", crate::SurfaceOptions::default());
    let conn = connect(&mux);
    let holder = hold_registry(&mux, Duration::from_millis(600));
    let mut list = Some(Request { id: Some(json!(1)), cmd: Command::ListWorkspaces });
    assert_eq!(
        conn.scheduler.dispatch(mux.clone(), conn.client, &mut list, 0, conn.writer.clone()),
        Some(true)
    );
    conn.scheduler.finish_and_wait();
    holder.join().unwrap();

    let snapshot = wait_settled(&mux.request_watchdog, 1);
    let [entry] = snapshot.recent.as_slice() else { panic!("one entry: {snapshot:?}") };
    assert_eq!(entry.method, "list-workspaces");
    assert!(entry.busy_ms < 600, "recorded while blocked: {entry:?}");
    assert_eq!(entry.stack_error, None, "{entry:?}");
    assert!(!entry.stack.is_empty(), "{entry:?}");
}

/// A `wait-for` that waits its full 300 ms timeout is expected, not slow.
#[test]
fn request_watchdog_leaves_a_long_wait_for_out() {
    let mux = crate::Mux::new_for_test("request-watchdog-wait", crate::SurfaceOptions::default());
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    let conn = connect(&mux);
    let mut wait = Some(Request {
        id: Some(json!(1)),
        cmd: Command::WaitFor(WaitForParams {
            surface: surface.id,
            pattern: "never-matches".to_string(),
            timeout_ms: 300,
        }),
    });
    assert_eq!(
        conn.scheduler.dispatch(mux.clone(), conn.client, &mut wait, 0, conn.writer.clone()),
        Some(true)
    );
    conn.scheduler.finish_and_wait();
    let reply: Value = serde_json::from_str(&conn.outbound.try_pop().unwrap()).unwrap();
    assert_eq!(reply["error"], json!("timeout waiting for pattern"), "{reply}");
    wait_disarmed(&mux.request_watchdog);

    let snapshot = mux.request_watchdog.snapshot();
    assert_eq!(snapshot.total, 0, "{snapshot:?}");
    assert_eq!(snapshot.expected_waits, 1, "{snapshot:?}");
    mux.close_surface(surface.id).unwrap();
}

/// A v2 resource line runs on its connection's control sequence; a slow one is named by
/// its operation.
#[test]
fn request_watchdog_records_a_slow_resource_line() {
    let mux = crate::Mux::new_for_test("request-watchdog-v2", crate::SurfaceOptions::default());
    let conn = connect(&mux);
    let line = json!({
        "protocol": "cmux.protocol/2",
        "type": "request",
        "id": "r1",
        "operation": "workspace.list",
        "params": {"machine": "current", "session": "current"},
    });
    let holder = hold_registry(&mux, Duration::from_millis(300));
    assert!(handle_connection_frame(
        &mux,
        conn.client,
        ClientTransport::Unix,
        &line.to_string(),
        &conn.writer,
        &conn.scheduler,
    ));
    holder.join().unwrap();
    let reply: Value = serde_json::from_str(&conn.outbound.try_pop().expect("a reply")).unwrap();
    assert_eq!(reply["ok"], true, "{reply}");

    let snapshot = wait_settled(&mux.request_watchdog, 1);
    assert_eq!(snapshot.total, 1, "{snapshot:?}");
    assert_eq!(snapshot.recent[0].method, "workspace.list");
    assert_eq!(snapshot.recent[0].client, conn.client);
    assert!(snapshot.recent[0].duration_ms.unwrap() >= 250, "{snapshot:?}");
}

/// A frame a connection handler answers itself (`agent-cli-intents-list`
/// reads the workspace registry on its connection's control sequence) is watched and
/// named by its handler.
#[cfg(unix)]
#[test]
fn request_watchdog_records_a_slow_sniffed_frame() {
    use super::super::origin_gate::{set_role_for_test, set_verified_app_for_test};

    let mux =
        crate::Mux::new_for_test("request-watchdog-sniffed", crate::SurfaceOptions::default());
    let conn = connect(&mux);
    set_role_for_test(&mux, conn.client, "main");
    set_verified_app_for_test(&mux, conn.client, true);
    let line = json!({"id": 1, "cmd": "agent-cli-intents-list",
        "expected_machine_id": mux.machine_public_id,
        "expected_session_id": mux.session_public_id});
    let holder = hold_registry(&mux, Duration::from_millis(300));
    assert!(handle_connection_frame(
        &mux,
        conn.client,
        ClientTransport::Unix,
        &line.to_string(),
        &conn.writer,
        &conn.scheduler,
    ));
    holder.join().unwrap();
    let reply: Value = serde_json::from_str(&conn.outbound.try_pop().expect("a reply")).unwrap();
    assert_eq!(reply["ok"], true, "{reply}");

    let snapshot = wait_settled(&mux.request_watchdog, 1);
    assert_eq!(snapshot.total, 1, "{snapshot:?}");
    assert_eq!(snapshot.recent[0].method, "frame:agent-cli-intents");
}

/// A remote-relay `fs.*` frame is watched from the first line of the frame
/// (the client registry is held 300 ms, so the reader's client lookup is
/// slow) and, ended before the watchdog looks, named by the stage it ended
/// in: the reader hands a remote line to the relay on its connection's
/// control sequence.
#[cfg(unix)]
#[test]
fn request_watchdog_records_a_slow_remote_fs_frame() {
    let mux = crate::Mux::new_for_test("request-watchdog-relay", crate::SurfaceOptions::default());
    let hold = mux.request_watchdog.shared.scan_hold.lock().unwrap();
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let client = mux.control_clients.register(ClientTransport::Remote, writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    let (locked_tx, locked) = channel();
    let holder = {
        let mux = mux.clone();
        std::thread::spawn(move || {
            let _clients = mux.control_clients.state.lock().unwrap();
            locked_tx.send(()).unwrap();
            std::thread::sleep(Duration::from_millis(300));
        })
    };
    locked.recv().unwrap();
    assert!(handle_connection_frame(
        &mux,
        client,
        ClientTransport::Remote,
        r#"{"id":1,"cmd":"fs.stat","path":"/x"}"#,
        &writer,
        &scheduler,
    ));
    holder.join().unwrap();
    drop(hold);
    let reply: Value = serde_json::from_str(&outbound.try_pop().expect("a reply")).unwrap();
    assert_eq!(reply["ok"], false, "no fs owner on a test daemon: {reply}");

    let snapshot = wait_settled(&mux.request_watchdog, 1);
    assert_eq!(snapshot.total, 1, "{snapshot:?}");
    assert_eq!(snapshot.recent[0].method, "frame:remote-relay");
    assert_eq!(snapshot.recent[0].client, client);
}
