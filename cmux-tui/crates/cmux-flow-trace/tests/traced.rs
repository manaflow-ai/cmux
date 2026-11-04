//! `hop_on_traced` in its own process (this test binary): `init` reads CMUX_TRACE_FLOWS once per process, so this
//! test cannot share a binary with records.rs.

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

/// A busy path's hop (`hop_on_traced`, the daemon's output hops) records only for a terminal with a traced key press:
/// a daemon with a thousand busy terminals no longer fills the ring and drops the key presses' records (STATUS 10927).
#[test]
fn a_busy_path_hop_records_only_for_a_terminal_with_a_traced_key() {
    let dir = std::env::temp_dir().join(format!("cmux-flow-trace-traced-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    // SAFETY: set before any thread of this test binary reads the environment (`init` reads it once).
    unsafe { std::env::set_var("CMUX_TRACE_FLOWS", &dir) };
    assert!(cmux_flow_trace::init());
    let before = ALLOCATIONS.with(Cell::get);
    cmux_flow_trace::hop_on_traced("daemon.output.host", "aaaa");
    cmux_flow_trace::hop("daemon.send.write", 7, "bbbb");
    cmux_flow_trace::hop_on_traced("daemon.output.host", "aaaa");
    cmux_flow_trace::hop_on_traced("daemon.output.host", "bbbb");
    let after = ALLOCATIONS.with(Cell::get);
    assert_eq!(after - before, 0, "a hop allocated on the caller's thread");
    assert!(cmux_flow_trace::flush());
    let text =
        std::fs::read_to_string(dir.join(format!("flows-{}.jsonl", std::process::id()))).unwrap();
    let output: Vec<&str> =
        text.lines().filter(|line| line.contains("daemon.output.host")).collect();
    assert_eq!(output.len(), 1, "only the traced terminal's output hop is recorded: {text}");
    assert!(output[0].contains("\"terminal\":\"bbbb\""), "{}", output[0]);
    let _ = std::fs::remove_dir_all(&dir);
}
