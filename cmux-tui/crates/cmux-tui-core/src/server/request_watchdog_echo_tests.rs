//! Echo thread items (p02-threads task 232): each item of `mux-line-out`,
//! `mux-pty-input`, `mux-attach-out` and `mux-render-attach-out` work is a
//! 100 ms scope of the request watchdog. One busy past it is one hang
//! record naming the thread's scope; a short one is none; an idle watchdog
//! does not wake. A holder's own loop hang comes back as one record too,
//! written by the watchdog thread.

use std::sync::Mutex;
use std::sync::mpsc::{Receiver, channel};
use std::time::{Duration, Instant};

use super::*;

/// A watchdog whose every hang record arrives on the receiver.
fn echo_watchdog() -> (RequestWatchdog, Receiver<serde_json::Value>) {
    let (records, received) = channel();
    let records = Mutex::new(records);
    let sink: HangSink = Box::new(move |record| {
        let _ = records.lock().unwrap().send(record);
    });
    let capture = Box::new(thread_backtrace::capture);
    let watchdog =
        RequestWatchdog::build(REQUEST_WATCHDOG_THRESHOLD, spawn_watchdog_thread, capture, sink);
    (watchdog, received)
}

fn wait_disarmed(shared: &Shared) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while shared.armed.load(Ordering::SeqCst) {
        assert!(Instant::now() < deadline, "the watchdog never disarmed");
        std::thread::sleep(Duration::from_millis(10));
    }
}

fn scope_and_method(record: &serde_json::Value) -> (Option<&str>, Option<&str>) {
    (record["scope"].as_str(), record["method"].as_str())
}

/// A 150 ms line-out write is one row naming `mux-line-out` at its 100 ms
/// tier; it never lands in `slow_requests`, and nothing else is written.
#[test]
fn a_150ms_line_out_item_is_one_hang_row_naming_mux_line_out() {
    let (watchdog, received) = echo_watchdog();
    let echo = watchdog.echo_watch();
    {
        let _item = echo.item(WatchKind::LineOut).expect("a free slot");
        std::thread::sleep(Duration::from_millis(150));
    }
    let record = received.recv_timeout(Duration::from_secs(10)).expect("a hang record");
    assert_eq!(scope_and_method(&record), (Some("mux-line-out"), Some("write-item")), "{record}");
    assert_eq!(record["hang_ms"], 100, "{record}");
    assert!(record["busy_ms"].as_u64().unwrap() >= 150, "{record}");
    assert!(record.get("client").is_none(), "{record}");
    wait_disarmed(&watchdog.shared);
    assert!(received.try_recv().is_err(), "one row");
    let snapshot = watchdog.snapshot();
    assert_eq!((snapshot.hangs, snapshot.total), (1, 0), "{snapshot:?}");
}

/// An item still busy past its tier is written while it runs, with the
/// stack of its thread.
#[cfg(any(target_os = "macos", target_os = "linux"))]
#[test]
fn a_busy_attach_frame_is_written_while_it_runs() {
    let (watchdog, received) = echo_watchdog();
    let watchdog = Arc::new(watchdog);
    let stop = Arc::new(AtomicBool::new(false));
    let busy = std::thread::spawn({
        let (echo, stop) = (watchdog.echo_watch(), stop.clone());
        move || {
            let _item = echo.item(WatchKind::AttachOut).expect("a free slot");
            while !stop.load(Ordering::Relaxed) {
                std::hint::spin_loop();
            }
        }
    });
    let record = received.recv_timeout(Duration::from_secs(10)).expect("a hang record");
    stop.store(true, Ordering::Relaxed);
    busy.join().unwrap();
    assert_eq!(scope_and_method(&record), (Some("mux-attach-out"), Some("frame")), "{record}");
    assert_eq!(record["duration_ms"], serde_json::Value::Null, "{record}");
    assert_eq!(record["stack_error"], serde_json::Value::Null, "{record}");
    wait_disarmed(&watchdog.shared);
    assert!(received.try_recv().is_err(), "written once");
}

/// Items under the tier write nothing and free their slots; 1000 of them
/// wake the watchdog only on its grid, and once it disarms an idle second
/// wakes it 0 times.
#[test]
fn short_echo_items_write_nothing_and_an_idle_watchdog_does_not_wake() {
    let (watchdog, received) = echo_watchdog();
    let echo = watchdog.echo_watch();
    let kinds = [WatchKind::LineOut, WatchKind::PtyInput, WatchKind::RenderAttachOut];
    let start = Instant::now();
    for kind in kinds.into_iter().cycle().take(1_000) {
        let item = echo.item(kind).expect("a free slot");
        drop(item);
        std::thread::sleep(Duration::from_millis(1));
    }
    let elapsed = start.elapsed();
    let woke = watchdog.shared.wakeups.load(Ordering::Relaxed);
    let periods = elapsed.as_millis().div_ceil(REQUEST_WATCHDOG_THRESHOLD.as_millis());
    let allowed = u64::try_from(periods).unwrap() + 1;
    assert!(woke <= allowed, "{woke} wakeups in {elapsed:?} (allowed {allowed})");
    wait_disarmed(&watchdog.shared);
    assert!(received.try_recv().is_err(), "nothing written");
    assert!(watchdog.shared.slots.iter().all(|slot| slot.busy.load(Ordering::SeqCst) == 0));

    let before = watchdog.shared.wakeups.load(Ordering::Relaxed);
    std::thread::sleep(Duration::from_secs(1));
    assert_eq!(watchdog.shared.wakeups.load(Ordering::Relaxed), before, "idle: 0 wakeups");
}

/// A `mux-pty-input` write of the app (`EchoWatch::pty_input_write`) is
/// the same scope, named after its thread.
#[test]
fn a_stalled_pty_input_write_is_one_row_naming_mux_pty_input() {
    let (watchdog, received) = echo_watchdog();
    let echo = watchdog.echo_watch();
    {
        let _write = echo.pty_input_write().expect("a free slot");
        std::thread::sleep(Duration::from_millis(150));
    }
    let record = received.recv_timeout(Duration::from_secs(10)).expect("a hang record");
    assert_eq!(scope_and_method(&record), (Some("mux-pty-input"), Some("write-input")), "{record}");
    wait_disarmed(&watchdog.shared);
    assert!(received.try_recv().is_err(), "one row");
}

/// A watchdog that stopped watches no more items.
#[test]
fn a_stopped_watchdog_watches_no_item() {
    let (watchdog, _received) = echo_watchdog();
    let echo = watchdog.echo_watch();
    drop(watchdog);
    assert!(echo.item(WatchKind::LineOut).is_none());
}

/// A holder's report of its own loop is one `holder-loop` row with no
/// stack (the thread is in the holder), counted in `hangs`, written by the
/// watchdog thread and never by the holder link's reader that received it.
#[cfg(unix)]
#[test]
fn a_holder_loop_report_is_one_row_written_on_the_watchdog_thread() {
    let (records, received) = channel();
    let records = Mutex::new(records);
    let sink: HangSink = Box::new(move |record| {
        let writer = std::thread::current().name().map(str::to_owned);
        let _ = records.lock().unwrap().send((writer, record));
    });
    let capture = Box::new(thread_backtrace::capture);
    let watchdog =
        RequestWatchdog::build(REQUEST_WATCHDOG_THRESHOLD, spawn_watchdog_thread, capture, sink);
    let reader = std::thread::Builder::new()
        .name("holder-link".into())
        .spawn({
            let shared = watchdog.shared.clone();
            move || shared.report_hang("holder-loop", "holder-loop", 100, 153)
        })
        .unwrap();
    reader.join().unwrap();
    let (writer, record) = received.recv_timeout(Duration::from_secs(10)).expect("a hang record");
    assert_eq!(writer.as_deref(), Some(THREAD_NAME), "written on the watchdog thread");
    assert_eq!(scope_and_method(&record), (Some("holder-loop"), Some("holder-loop")), "{record}");
    assert_eq!((record["hang_ms"].as_u64(), record["busy_ms"].as_u64()), (Some(100), Some(153)));
    assert_eq!(record["stack_error"], "other-process", "{record}");
    assert_eq!(record["stack"], serde_json::json!([]), "{record}");
    wait_disarmed(&watchdog.shared);
    assert!(received.try_recv().is_err(), "one row");
    assert_eq!(watchdog.snapshot().hangs, 1);
}

/// Reports past the queue's bound, while the watchdog thread cannot take
/// them, are dropped and counted; the reporter never writes one itself.
#[cfg(unix)]
#[test]
fn reports_past_the_queue_bound_are_dropped_and_counted() {
    fn no_thread(_: Box<dyn FnOnce() + Send>) -> std::io::Result<supervised::Unparker> {
        Err(std::io::Error::other("no watchdog thread"))
    }
    let written = Arc::new(AtomicU64::new(0));
    let sink: HangSink = Box::new({
        let written = written.clone();
        move |_| {
            written.fetch_add(1, Ordering::Relaxed);
        }
    });
    let capture = Box::new(thread_backtrace::capture);
    let watchdog = RequestWatchdog::build(REQUEST_WATCHDOG_THRESHOLD, no_thread, capture, sink);
    let bound = u64::try_from(reported::REPORTED_HANG_QUEUE).unwrap();
    for _ in 0..bound + 3 {
        watchdog.shared.report_hang("holder-loop", "holder-loop", 100, 153);
    }
    assert_eq!(watchdog.shared.reported.dropped.load(Ordering::Relaxed), 3);
    assert_eq!(written.load(Ordering::Relaxed), 0, "nothing written off the watchdog thread");
    assert_eq!(watchdog.snapshot().hangs, 0);
    watchdog.shared.write_reported();
    assert_eq!(written.load(Ordering::Relaxed), bound);
    assert_eq!(watchdog.snapshot().hangs, bound);
}
