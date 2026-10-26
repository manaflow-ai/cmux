//! The request watchdog: one entry per overrun, no timer while idle, a
//! bounded wake rate under many short requests, its thread row.

use std::sync::Arc;
use std::time::{Duration, Instant};

use serde_json::json;

use super::super::{
    BoundedOutbound, ClientTransport, Command, ConnectionSurfaceScheduler, MessageWriter,
    QueuedSink, Request,
};
use super::*;

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

/// Waits (bounded) until the watchdog has recorded `total` requests.
fn wait_total(watchdog: &RequestWatchdog, total: u64) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while watchdog.snapshot().total < total {
        assert!(Instant::now() < deadline, "the watchdog never recorded {total} requests");
        std::thread::sleep(Duration::from_millis(10));
    }
}

#[test]
fn request_watchdog_records_a_300ms_run_exactly_once() {
    let watchdog = RequestWatchdog::default();
    let scope = watchdog.begin(7, "wait-for").expect("a free slot");
    std::thread::sleep(Duration::from_millis(300));
    wait_total(&watchdog, 1);
    // Still busy a full threshold later: not recorded again.
    std::thread::sleep(REQUEST_WATCHDOG_THRESHOLD * 2);
    drop(scope);
    wait_disarmed(&watchdog);

    let snapshot = watchdog.snapshot();
    assert_eq!(snapshot.total, 1, "{snapshot:?}");
    assert_eq!(snapshot.threshold_ms, 250);
    let [entry] = snapshot.recent.as_slice() else { panic!("one entry: {snapshot:?}") };
    assert_eq!(entry.method, "wait-for");
    assert_eq!(entry.client, 7);
    assert!(entry.busy_ms >= 250, "{entry:?}");
}

#[test]
fn request_watchdog_records_nothing_for_a_short_run() {
    let watchdog = RequestWatchdog::default();
    drop(watchdog.begin(1, "list-workspaces"));
    wait_disarmed(&watchdog);
    assert_eq!(watchdog.snapshot().total, 0);
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
    drop(watchdog.begin(1, "list-workspaces"));
    wait_disarmed(&watchdog);
    let before = wakeups(&watchdog);
    std::thread::sleep(Duration::from_secs(2));
    assert_eq!(wakeups(&watchdog), before, "the parked watchdog woke while idle");
    assert!(!watchdog.shared.armed.load(Ordering::SeqCst));
}

#[test]
fn request_watchdog_wakes_at_most_four_times_a_second_under_1000_short_requests() {
    let watchdog = RequestWatchdog::default();
    let start = Instant::now();
    for client in 0..1_000u64 {
        drop(watchdog.begin(client, "send-text"));
        std::thread::sleep(Duration::from_millis(2));
    }
    let elapsed = start.elapsed();
    let woke = wakeups(&watchdog);
    // One wake at the arm, then at most one per threshold period.
    let periods = elapsed.as_millis().div_ceil(REQUEST_WATCHDOG_THRESHOLD.as_millis());
    let allowed = u64::try_from(periods).unwrap_or(u64::MAX) + 1;
    assert!(woke <= allowed, "{woke} wakeups in {elapsed:?} (allowed {allowed})");
    assert_eq!(watchdog.snapshot().total, 0);
    wait_disarmed(&watchdog);
}

#[test]
fn request_watchdog_rearms_after_it_parked() {
    let watchdog = RequestWatchdog::default();
    drop(watchdog.begin(1, "list-workspaces"));
    wait_disarmed(&watchdog);
    let scope = watchdog.begin(2, "wait-for").expect("a free slot");
    wait_total(&watchdog, 1);
    drop(scope);
    assert_eq!(watchdog.snapshot().recent[0].client, 2);
}

#[test]
fn request_watchdog_thread_row_runs_at_utility() {
    let watchdog = RequestWatchdog::default();
    drop(watchdog.begin(1, "list-workspaces"));
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
        (0..SLOT_COUNT as u64).map(|client| watchdog.begin(client, "send-text")).collect();
    assert!(scopes.iter().all(Option::is_some));
    assert!(watchdog.begin(0, "send-text").is_none());
    assert_eq!(watchdog.snapshot().unwatched, 1);
    drop(scopes);
    assert!(watchdog.begin(0, "send-text").is_some(), "a freed slot is reused");
}

#[test]
fn request_watchdog_ring_keeps_the_newest_128() {
    let watchdog = RequestWatchdog::default();
    for client in 0..(SLOW_REQUEST_RING as u64 + 5) {
        watchdog.shared.record(SlowRequest {
            method: "wait-for",
            client,
            started_ms: 0,
            busy_ms: 300,
        });
    }
    let snapshot = watchdog.snapshot();
    assert_eq!(snapshot.total, SLOW_REQUEST_RING as u64 + 5);
    assert_eq!(snapshot.recent.len(), SLOW_REQUEST_RING);
    assert_eq!(snapshot.recent[0].client, 5, "the oldest entries go first");
}

#[test]
fn request_watchdog_names_unknown_methods() {
    assert_eq!(word_method(busy_word(10, method_index("wait-for"))), "wait-for");
    assert_eq!(word_method(busy_word(10, method_index("no-such-command"))), "unknown");
    assert_eq!(word_start_us(busy_word(10, 3)), Some(10));
    assert_eq!(word_start_us(0), None);
    assert_eq!(word_start_us(CLAIMING), None);
}

/// The real request path: a `wait-for` that times out after 300 ms on the
/// connection's control sequence gives one `slow_requests` entry.
#[test]
fn request_watchdog_records_a_300ms_wait_for_on_the_connection_sequence() {
    let mux = crate::Mux::new_for_test("request-watchdog", crate::SurfaceOptions::default());
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let mut wait = Some(Request {
        id: Some(json!(1)),
        cmd: Command::WaitFor {
            surface: surface.id,
            pattern: "never-matches".to_string(),
            timeout_ms: 300,
        },
    });
    assert_eq!(scheduler.dispatch(mux.clone(), client, &mut wait, 0, writer), Some(true));
    scheduler.finish_and_wait();
    let reply: serde_json::Value =
        serde_json::from_str(&outbound.try_pop().expect("the wait-for reply")).unwrap();
    assert_eq!(reply["error"], json!("timeout waiting for pattern"), "{reply}");
    wait_disarmed(&mux.request_watchdog);

    let snapshot = mux.request_watchdog.snapshot();
    assert_eq!(snapshot.total, 1, "{snapshot:?}");
    assert_eq!(snapshot.recent[0].method, "wait-for");
    assert_eq!(snapshot.recent[0].client, client);
    mux.close_surface(surface.id).unwrap();
}
