//! The unit-test binary's allocator. It counts per thread and only while a
//! test turns counting on, so tests running on other threads meanwhile do
//! not change a probe's numbers. Two counters: bytes still allocated (what a
//! structure retains) and allocation calls (what a frame allocates).

use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;

thread_local! {
    /// Bytes this thread holds while live-byte counting is on (`Some`).
    static LIVE: Cell<Option<isize>> = const { Cell::new(None) };
    /// Allocation calls on this thread while call counting is on (`Some`).
    static CALLS: Cell<Option<usize>> = const { Cell::new(None) };
}

struct CountingAllocator;

fn count(delta: isize, call: bool) {
    let _ = LIVE.try_with(|live| {
        if let Some(value) = live.get() {
            live.set(Some(value.saturating_add(delta)));
        }
    });
    if call {
        let _ = CALLS.try_with(|calls| {
            if let Some(value) = calls.get() {
                calls.set(Some(value.saturating_add(1)));
            }
        });
    }
}

unsafe impl GlobalAlloc for CountingAllocator {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        count(layout.size() as isize, true);
        unsafe { System.alloc(layout) }
    }

    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        count(layout.size() as isize, true);
        unsafe { System.alloc_zeroed(layout) }
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        count(-(layout.size() as isize), false);
        unsafe { System.dealloc(ptr, layout) }
    }

    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, size: usize) -> *mut u8 {
        count(size as isize - layout.size() as isize, true);
        unsafe { System.realloc(ptr, layout, size) }
    }
}

#[global_allocator]
static ALLOCATOR: CountingAllocator = CountingAllocator;

/// Start counting the bytes this thread keeps allocated.
pub(crate) fn start_live_bytes() {
    LIVE.with(|live| live.set(Some(0)));
}

/// Stop counting and return the bytes still allocated since the start.
pub(crate) fn take_live_bytes() -> isize {
    LIVE.with(|live| live.replace(None)).unwrap_or_default()
}

/// Run `body` and return its result with the allocation calls (allocations
/// and reallocations) it made on this thread.
pub(crate) fn count_allocations<T>(body: impl FnOnce() -> T) -> (T, usize) {
    let outer = CALLS.with(|calls| calls.replace(Some(0)));
    let value = body();
    let made = CALLS.with(|calls| calls.replace(outer)).unwrap_or_default();
    (value, made)
}
