//! The sink end to end, in its own process (this test binary), with CMUX_TRACE_FLOWS set: one JSON line per
//! hop with the clock, ids and thread, and a hop that allocates nothing once `init` ran.

use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;

/// Counts the allocations of the calling thread only (the writer thread allocates freely).
struct ThreadCounting;

thread_local! {
    static ALLOCATIONS: Cell<usize> = const { Cell::new(0) };
}

// SAFETY: forwards every call to the system allocator; the counter is a const-initialised thread-local Cell.
unsafe impl GlobalAlloc for ThreadCounting {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        ALLOCATIONS.with(|count| count.set(count.get() + 1));
        unsafe { System.alloc(layout) }
    }
    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        unsafe { System.dealloc(ptr, layout) }
    }
}

#[global_allocator]
static ALLOCATOR: ThreadCounting = ThreadCounting;

#[test]
fn hops_reach_the_file_as_json_lines_and_allocate_nothing() {
    let dir = std::env::temp_dir().join(format!("cmux-flow-trace-test-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    // SAFETY: set before any thread of this test binary reads the environment (`init` reads it once).
    unsafe { std::env::set_var("CMUX_TRACE_FLOWS", &dir) };
    assert!(cmux_flow_trace::init());
    assert!(cmux_flow_trace::enabled());
    let before = ALLOCATIONS.with(Cell::get);
    cmux_flow_trace::hop("daemon.send.write", 42, "00ff");
    cmux_flow_trace::hop_id("host.pty.write", 0, &[0xab; 16]);
    let after = ALLOCATIONS.with(Cell::get);
    assert_eq!(after - before, 0, "a hop allocated on the caller's thread");
    assert!(cmux_flow_trace::flush());
    let text =
        std::fs::read_to_string(dir.join(format!("flows-{}.jsonl", std::process::id()))).unwrap();
    let lines: Vec<&str> = text.lines().collect();
    assert_eq!(lines.len(), 2, "{text}");
    assert!(
        lines[0].starts_with(
            "{\"hop\":\"daemon.send.write\",\"flow\":42,\"terminal\":\"00ff\",\"pid\":"
        ),
        "{}",
        lines[0]
    );
    assert!(lines[1].contains(&format!("\"terminal\":\"{}\"", "ab".repeat(16))), "{}", lines[1]);
    let t = |line: &str| -> u64 {
        line.rsplit("\"t_ns\":").next().unwrap().trim_end_matches('}').parse().unwrap()
    };
    assert!(t(lines[1]) >= t(lines[0]) && t(lines[0]) > 0);
    let _ = std::fs::remove_dir_all(&dir);
}
