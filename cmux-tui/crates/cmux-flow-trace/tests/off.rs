//! CMUX_TRACE_FLOWS unset (this test binary never sets it): `init` starts nothing and a hop does no
//! allocation; it returns after one load of the unset sink.

use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;

/// Counts the allocations of the calling thread only (libtest's own threads allocate freely).
struct Counting;

thread_local! {
    static ALLOCATIONS: Cell<usize> = const { Cell::new(0) };
}

// SAFETY: forwards every call to the system allocator; the counter is a const-initialised thread-local Cell.
unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        ALLOCATIONS.with(|count| count.set(count.get() + 1));
        unsafe { System.alloc(layout) }
    }
    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        unsafe { System.dealloc(ptr, layout) }
    }
}

#[global_allocator]
static ALLOCATOR: Counting = Counting;

#[test]
fn a_hop_with_marks_off_allocates_nothing_and_starts_nothing() {
    assert!(
        std::env::var_os("CMUX_TRACE_FLOWS").is_none(),
        "run this test without CMUX_TRACE_FLOWS"
    );
    assert!(!cmux_flow_trace::init());
    assert!(!cmux_flow_trace::enabled());
    let before = ALLOCATIONS.with(Cell::get);
    for _ in 0..10_000 {
        cmux_flow_trace::hop("daemon.send.write", 7, "00ff");
        cmux_flow_trace::hop_id("holder.pty.read", 0, &[1; 16]);
    }
    assert_eq!(ALLOCATIONS.with(Cell::get) - before, 0, "a hop with marks off allocated");
    assert!(!cmux_flow_trace::flush(), "flush with marks off reported a writer");
}
