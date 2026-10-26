//! The hang watcher: an idle process has no watcher wakeups, a scope past
//! its hang deadline is written once with its method and the stack of its
//! thread (top frame: the blocked function), and the jank tier is counted.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, channel};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use cmux_panic_log::hang::{
    self, HangFrame, HangKind, HangScope, HangStack, HangWatcher, StackSampler,
};
use cmux_tui_platform::thread_backtrace::{self, ThreadHandle};

fn method_name(method: u32) -> &'static str {
    match method {
        1 => "list-workspaces",
        2 => "commit-batch",
        _ => "unknown",
    }
}

static BLOCKING: HangKind =
    HangKind::new("test-blocking", None, Duration::from_millis(100), method_name);

static SLOW: HangKind = HangKind::new(
    "test-slow",
    Some(Duration::from_millis(20)),
    Duration::from_secs(30),
    method_name,
);

static LONG: HangKind = HangKind::new("test-long", None, Duration::from_secs(30), method_name);

/// The sampler the daemon installs (cmux-tui-core `diagnostics::hang_log`).
fn platform_sampler() -> StackSampler {
    StackSampler {
        current_thread: || ThreadHandle::current().map_or(0, ThreadHandle::raw),
        capture: Box::new(|raw| {
            let thread = ThreadHandle::from_raw(raw).ok_or("unsupported")?;
            let backtrace = thread_backtrace::capture(thread).map_err(|error| error.as_str())?;
            Ok(HangStack {
                frames: backtrace
                    .symbolicate()
                    .into_iter()
                    .map(|frame| HangFrame {
                        image: frame.image,
                        image_id: frame.image_id,
                        offset: frame.offset as u64,
                        symbol: frame.symbol,
                    })
                    .collect(),
                truncated: backtrace.truncated(),
            })
        }),
    }
}

fn channel_watcher(sampler: StackSampler) -> (HangWatcher, Receiver<serde_json::Value>) {
    let (records, received) = channel();
    let records = Mutex::new(records);
    let sink = Box::new(move |record| {
        let _ = records.lock().unwrap().send(record);
    });
    (HangWatcher::start(sink, sampler).unwrap(), received)
}

/// Waits (bounded) until `done` holds.
fn wait_until(what: &str, done: impl Fn() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while !done() {
        assert!(Instant::now() < deadline, "never {what}");
        std::thread::sleep(Duration::from_millis(2));
    }
}

/// The demangled names of the function holding the pc `address` and of the
/// functions inlined there (`resolve` looks up the byte before an address).
fn function_names(address: usize) -> Vec<String> {
    let mut names = Vec::new();
    backtrace::resolve((address + 1) as *mut std::ffi::c_void, |symbol| {
        if let Some(name) = symbol.name() {
            names.push(name.to_string());
        }
    });
    names
}

/// The blocked function: a loop with no call, so the captured pc lies in it.
#[inline(never)]
fn hang_test_blocked_handler(stop: &AtomicBool) {
    while !stop.load(Ordering::Relaxed) {
        std::hint::spin_loop();
    }
}

#[test]
fn an_idle_watcher_never_wakes() {
    let (watcher, _records) = channel_watcher(StackSampler::none());
    wait_until("parked at start", || watcher.stats().wakeups == 1 && watcher.is_idle());
    std::thread::sleep(Duration::from_millis(200));
    assert_eq!(watcher.stats().wakeups, 1, "{:?}", watcher.stats());

    // A short scope wakes it at most twice (the open, its deadline); then
    // it parks with no timeout again.
    drop(watcher.watch(&BLOCKING, 1));
    wait_until("idle after the scope", || watcher.is_idle() && watcher.stats().wakeups >= 2);
    std::thread::sleep(Duration::from_millis(150));
    let after = watcher.stats();
    std::thread::sleep(Duration::from_millis(300));
    assert_eq!(watcher.stats(), after);
    assert!(after.wakeups <= 3, "{after:?}");
    assert_eq!((after.hangs, after.janks, after.missed_hangs), (0, 0, 0), "{after:?}");
}

#[cfg(any(target_os = "macos", target_os = "linux"))]
#[test]
fn a_blocked_scope_is_written_once_with_the_blocked_function_on_top() {
    let (watcher, records) = channel_watcher(platform_sampler());
    let watcher = Arc::new(watcher);
    let stop = Arc::new(AtomicBool::new(false));
    let blocked = std::thread::spawn({
        let (watcher, stop) = (watcher.clone(), stop.clone());
        move || {
            let _scope = watcher.watch(&BLOCKING, 1);
            hang_test_blocked_handler(std::hint::black_box(&stop));
        }
    });
    let record = records.recv_timeout(Duration::from_secs(5)).expect("a hang record");
    // Keep it blocked past another deadline: still one record.
    std::thread::sleep(Duration::from_millis(250));
    stop.store(true, Ordering::Relaxed);
    blocked.join().unwrap();
    assert!(records.recv_timeout(Duration::from_millis(100)).is_err(), "one record only");

    assert_eq!(record["event"], "hang");
    assert_eq!(record["scope"], "test-blocking");
    assert_eq!(record["method"], "list-workspaces");
    assert_eq!(record["hang_ms"], 100);
    assert!(record["busy_ms"].as_u64().unwrap() >= 100, "{record}");
    assert_eq!(record["stack_error"], serde_json::Value::Null, "{record}");
    let top = &record["stack"][0];
    let handler = hang_test_blocked_handler as *const () as usize;
    let handler_frame = thread_backtrace::symbolicate_address(handler);
    assert_eq!(top["image"].as_str(), handler_frame.image.as_deref(), "{record}");
    let image_base = handler - handler_frame.offset;
    let offset = usize::try_from(top["offset"].as_u64().unwrap()).unwrap();
    let names = function_names(image_base + offset);
    assert!(
        names.iter().any(|name| name.contains("hang_test_blocked_handler")),
        "the top frame {top} is in {names:?}"
    );
    let stats = watcher.stats();
    assert_eq!((stats.hangs, stats.stack_captures, stats.missed_hangs), (1, 1, 0), "{stats:?}");
}

#[test]
fn a_scope_past_the_jank_tier_is_counted_not_written() {
    let (watcher, records) = channel_watcher(StackSampler::none());
    let scope = watcher.watch(&SLOW, 2);
    wait_until("counted as jank", || watcher.stats().janks == 1);
    drop(scope);
    // A scope that ends past jank before the watcher looks is counted by its end.
    let scope = watcher.watch(&SLOW, 2);
    std::thread::sleep(Duration::from_millis(40));
    drop(scope);
    wait_until("both counted", || watcher.stats().janks == 2);
    assert!(records.try_recv().is_err());
    assert_eq!(watcher.stats().hangs, 0);
}

#[test]
fn a_shorter_deadline_wakes_a_watcher_sleeping_for_a_longer_one() {
    let (watcher, records) = channel_watcher(StackSampler::none());
    let long = watcher.watch(&LONG, 1);
    wait_until("asleep for the long scope", || !watcher.is_idle());
    std::thread::sleep(Duration::from_millis(20));
    let opened = Instant::now();
    let short = watcher.watch(&BLOCKING, 2);
    let record = records.recv_timeout(Duration::from_secs(5)).expect("a hang record");
    assert!(opened.elapsed() < Duration::from_secs(2), "{:?}", opened.elapsed());
    assert_eq!(record["scope"], "test-blocking");
    assert_eq!(record["method"], "commit-batch");
    assert_eq!(record["stack_error"], "unsupported", "no sampler: {record}");
    drop((short, long));
}

#[test]
fn a_scope_that_ends_during_the_capture_keeps_no_stack() {
    let (end_tx, end_rx) = channel::<()>();
    let (ended_tx, ended_rx) = channel::<()>();
    let (end_tx, ended_rx) = (Mutex::new(end_tx), Mutex::new(ended_rx));
    let sampler = StackSampler {
        current_thread: || 7,
        capture: Box::new(move |_| {
            end_tx.lock().unwrap().send(()).unwrap();
            ended_rx.lock().unwrap().recv().unwrap();
            Ok(HangStack {
                frames: vec![HangFrame {
                    image: Some("next-work".into()),
                    image_id: None,
                    offset: 1,
                    symbol: None,
                }],
                truncated: false,
            })
        }),
    };
    let (watcher, records) = channel_watcher(sampler);
    let runner = std::thread::spawn({
        move || {
            let scope = watcher.watch(&BLOCKING, 1);
            end_rx.recv().unwrap();
            drop(scope);
            ended_tx.send(()).unwrap();
        }
    });
    let record = records.recv_timeout(Duration::from_secs(5)).expect("a hang record");
    runner.join().unwrap();
    assert_eq!(record["stack_error"], "scope-ended", "{record}");
    assert_eq!(record["stack"], serde_json::json!([]));
}

#[test]
fn the_file_sink_appends_one_line_with_the_fields() {
    let dir = std::env::temp_dir().join(format!("cmux-hang-log-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("hangs.jsonl");
    let _ = std::fs::remove_file(&path);
    let mut fields = cmux_panic_log::Fields::new();
    fields.insert("session".into(), "s".into());
    let watcher =
        HangWatcher::start(hang::file_sink(path.clone(), fields), StackSampler::none()).unwrap();
    let scope = watcher.watch(&BLOCKING, 2);
    wait_until("written", || std::fs::read_to_string(&path).is_ok_and(|text| !text.is_empty()));
    drop(scope);
    let text = std::fs::read_to_string(&path).unwrap();
    let lines: Vec<serde_json::Value> =
        text.lines().map(|line| serde_json::from_str(line).unwrap()).collect();
    assert_eq!(lines.len(), 1, "{text}");
    assert_eq!(lines[0]["session"], "s");
    assert_eq!(lines[0]["scope"], "test-blocking");
    assert_eq!(lines[0]["method"], "commit-batch");
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn every_scope_is_inert_before_install() {
    // No test in this binary installs a watcher.
    assert!(hang::installed().is_none());
    let scope = hang::watch_scope(&BLOCKING, 1);
    scope.set_method(2);
    drop(scope);
    assert_eq!(hang::enter(&BLOCKING, 1), hang::HangToken::NONE);
    let _: HangScope<'static> = HangScope::inert();
}
