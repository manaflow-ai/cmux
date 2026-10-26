//! The busy thread's stack in each recorded request: it names the handler
//! the run is in, it is dropped when the run ended during the capture, and
//! an entry without one says why.

use std::sync::mpsc::channel;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde_json::json;

use super::*;

const CREATE: WatchedMethod =
    WatchedMethod(RESOURCE_TAG | ResourceOperation::WorkspaceCreate as u32);

/// Waits (bounded) until the watchdog has recorded `total` requests.
fn wait_total(watchdog: &RequestWatchdog, total: u64) -> SlowRequestsSnapshot {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let snapshot = watchdog.snapshot();
        if snapshot.total >= total {
            return snapshot;
        }
        assert!(Instant::now() < deadline, "never recorded {total}: {snapshot:?}");
        std::thread::sleep(Duration::from_millis(5));
    }
}

/// The demangled names of the function holding the pc `address` and of the
/// functions inlined there. `backtrace::resolve` looks up the byte before an
/// address (it takes return addresses), so the pc is passed one past.
fn function_names(address: usize) -> Vec<String> {
    let mut names = Vec::new();
    backtrace::resolve((address + 1) as *mut std::ffi::c_void, |symbol| {
        if let Some(name) = symbol.name() {
            names.push(name.to_string());
        }
    });
    names
}

/// The handler the stack test runs past the threshold: a loop with no call,
/// so the captured pc lies inside it.
#[inline(never)]
fn request_watchdog_stack_test_handler(stop: &AtomicBool) {
    while !stop.load(Ordering::Relaxed) {
        std::hint::spin_loop();
    }
}

/// A 300 ms handler's entry carries its thread's stack: the stored image
/// and offset resolve to the handler, and the image's build id is the test
/// binary's.
#[cfg(any(target_os = "macos", target_os = "linux"))]
#[test]
fn request_watchdog_stack_symbolicates_to_the_busy_handler() {
    let watchdog = Arc::new(RequestWatchdog::default());
    let stop = Arc::new(AtomicBool::new(false));
    let started = Instant::now();
    let handler = std::thread::spawn({
        let watchdog = watchdog.clone();
        let stop = stop.clone();
        move || {
            let _scope = watchdog.begin(9, CREATE).expect("a free slot");
            request_watchdog_stack_test_handler(std::hint::black_box(&stop));
        }
    });
    wait_total(&watchdog, 1);
    // Run the handler to 300 ms, as in the acceptance test.
    std::thread::sleep(Duration::from_millis(300).saturating_sub(started.elapsed()));
    stop.store(true, Ordering::Relaxed);
    handler.join().unwrap();

    let snapshot = watchdog.snapshot();
    let [entry] = snapshot.recent.as_slice() else { panic!("one entry: {snapshot:?}") };
    assert_eq!(watchdog.shared.stack_captures.load(Ordering::Relaxed), 1);
    assert_eq!(entry.stack_error, None, "{entry:?}");
    let top = entry.stack.first().expect("the interrupted pc");
    let handler_address = request_watchdog_stack_test_handler as *const () as usize;
    let handler_frame = thread_backtrace::symbolicate_address(handler_address);
    assert!(top.image.is_some() && top.image == handler_frame.image, "{top:?}");
    assert!(top.image_id.is_some() || handler_frame.image_id.is_none(), "{top:?}");
    assert_eq!(top.image_id, handler_frame.image_id, "{top:?}");
    let image_base = handler_address - handler_frame.offset;
    let names = function_names(image_base + top.offset as usize);
    assert!(
        names.iter().any(|name| name.contains("request_watchdog_stack_test_handler")),
        "the top frame {top:?} is in {names:?}"
    );
}

/// A run that ends while its thread is being captured gets no stack: the
/// frames are the thread's next work.
#[cfg(any(target_os = "macos", target_os = "linux"))]
#[test]
fn request_watchdog_stack_is_dropped_when_the_run_ends_during_the_capture() {
    // The capture seam tells the run to end, waits until it did, then
    // captures its thread, which is now waiting for other work.
    let (end_tx, end_rx) = channel::<()>();
    let (ended_tx, ended_rx) = channel::<()>();
    let ended_rx = Mutex::new(ended_rx);
    let capture: CaptureStack = Box::new(move |thread| {
        end_tx.send(()).unwrap();
        ended_rx.lock().unwrap().recv().unwrap();
        thread_backtrace::capture(thread)
    });
    let watchdog = Arc::new(RequestWatchdog::with_seams(
        Duration::from_millis(20),
        spawn_watchdog_thread,
        capture,
    ));
    let (release_tx, release_rx) = channel::<()>();
    let runner = std::thread::spawn({
        let watchdog = watchdog.clone();
        move || {
            let scope = watchdog.begin(5, CREATE).expect("a free slot");
            end_rx.recv().unwrap();
            drop(scope);
            ended_tx.send(()).unwrap();
            release_rx.recv().unwrap();
        }
    });

    let snapshot = wait_total(&watchdog, 1);
    release_tx.send(()).unwrap();
    runner.join().unwrap();
    let [entry] = snapshot.recent.as_slice() else { panic!("one entry: {snapshot:?}") };
    assert_eq!(watchdog.shared.stack_captures.load(Ordering::Relaxed), 1);
    assert_eq!(entry.stack_error, Some("run-ended"), "{entry:?}");
    assert!(entry.stack.is_empty(), "{entry:?}");
}

/// A request recorded while its thread is unknown keeps its entry and says
/// why it has no stack.
#[test]
fn request_watchdog_stack_error_names_a_missing_thread() {
    let watchdog = RequestWatchdog::new(Duration::from_millis(20));
    let scope = watchdog.begin(3, CREATE).expect("a free slot");
    // As on an OS without captures: the slot holds no thread.
    scope.slot.thread.store(0, Ordering::Relaxed);
    let snapshot = wait_total(&watchdog, 1);
    drop(scope);
    assert_eq!(snapshot.recent[0].stack_error, Some("unsupported"), "{snapshot:?}");
    assert!(snapshot.recent[0].stack.is_empty());
}

/// server-stats serializes the stack with each entry.
#[test]
fn request_watchdog_stack_serializes_frames() {
    let request = SlowRequest {
        method: "list-workspaces",
        client: 1,
        started_ms: 2,
        busy_ms: 300,
        duration_ms: Some(310),
        stack: vec![SlowRequestFrame {
            image: Some("cmux-tui".to_string()),
            image_id: Some("0011aabb".to_string()),
            offset: 0x1234,
            symbol: None,
        }],
        stack_truncated: true,
        stack_error: None,
    };
    assert_eq!(
        serde_json::to_value(&request).unwrap(),
        json!({
            "method": "list-workspaces", "client": 1, "started_ms": 2, "busy_ms": 300,
            "duration_ms": 310,
            "stack": [{"image": "cmux-tui", "image_id": "0011aabb", "offset": 0x1234,
                "symbol": null}],
            "stack_truncated": true,
            "stack_error": null,
        })
    );
}
