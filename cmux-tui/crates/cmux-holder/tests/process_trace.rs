//! [`ProcessTrace`], the holder's real tracer seam, on this process's own
//! `cmux_trace` tracer (one test: the tracer is process-wide). Its budget
//! is in ring bytes, and its first start maps the recording ring off the
//! caller's thread, wakes the loop and runs on the loop's poll.

#![cfg(unix)]

use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use cmux_holder::holder::{ProcessTrace, TraceControl};
use cmux_holder::wire::TraceStart;

mod support;

static WOKE: AtomicBool = AtomicBool::new(false);

fn wake() {
    WOKE.store(true, Ordering::Release);
}

fn recording() -> bool {
    cmux_trace::status().is_some_and(|status| status.recording)
}

fn wait_for(what: &str, mut done: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(20);
    while !done() {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(5));
    }
}

#[test]
fn the_process_tracer_checks_its_budget_in_bytes_and_maps_its_ring_off_the_loop() {
    let mut trace = ProcessTrace::new(wake);
    assert!(!trace.available(), "no tracer runs before init");
    let dir = support::unique_dir("cmpt");
    cmux_trace::init_blackbox(&dir, cmux_trace::Role::Holder).unwrap().wait().unwrap();
    assert!(trace.available());

    let bytes = ProcessTrace::recording_bytes();
    let categories = cmux_trace::category::FRAME | cmux_trace::category::INPUT;
    let over = trace.start(TraceStart { categories, budget_bytes: bytes - 1 });
    assert!(over.unwrap_err().contains("over its budget"), "a ring bigger than the budget");
    assert!(!WOKE.load(Ordering::Acquire), "a refused start maps nothing");

    // The first start waits for the map thread, then runs on the poll.
    let exact = TraceStart { categories, budget_bytes: bytes };
    trace.start(exact).unwrap();
    assert!(!recording(), "the first start does not map on the caller's thread");
    wait_for("the map thread's wake", || WOKE.load(Ordering::Acquire));
    assert_eq!(trace.poll(), Some(Ok(())));
    assert_eq!(trace.poll(), None, "once");
    assert!(recording());
    let status = cmux_trace::status().unwrap();
    assert_eq!(status.recording_bytes, bytes, "the budget unit is the ring's bytes");
    assert_eq!(status.categories & categories, categories);
    assert!(trace.start(exact).unwrap_err().contains("already"));
    trace.stop().unwrap();
    assert!(!recording());

    // Mapped: a start runs at once, in memory.
    trace.start(TraceStart { categories, budget_bytes: 0 }).unwrap();
    assert!(recording());
    assert_eq!(trace.poll(), None);
    trace.stop().unwrap();
    assert!(!recording());
    assert!(trace.stop().is_err(), "no recording runs");
    let _ = std::fs::remove_dir_all(&dir);
}
