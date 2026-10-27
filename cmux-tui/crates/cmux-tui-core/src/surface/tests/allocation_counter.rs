//! Counts the heap allocations one closure makes on the calling thread.
//!
//! Rust installs this allocator for the whole cmux-tui-core unit-test binary;
//! counting is off unless the thread is inside [`count_allocations`], so other
//! test threads and other tests are not measured.

use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;

struct CountingAllocator;

std::thread_local! {
    static COUNTING: Cell<bool> = const { Cell::new(false) };
    static ALLOCATIONS: Cell<Allocations> = const { Cell::new(Allocations::ZERO) };
}

#[global_allocator]
static TEST_ALLOCATOR: CountingAllocator = CountingAllocator;

/// Allocations (and reallocations) made by a measured closure.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(super) struct Allocations {
    pub(super) count: usize,
    /// Allocations of at least [`Self::LARGE_BYTES`]: payload buffers.
    pub(super) large: usize,
}

impl Allocations {
    const ZERO: Self = Self { count: 0, large: 0 };
    pub(super) const LARGE_BYTES: usize = 256;
}

fn record(size: usize) {
    let counting = COUNTING.try_with(Cell::get).unwrap_or(false);
    if counting {
        let _ = ALLOCATIONS.try_with(|total| {
            let mut next = total.get();
            next.count += 1;
            next.large += usize::from(size >= Allocations::LARGE_BYTES);
            total.set(next);
        });
    }
}

// SAFETY: every call forwards to the system allocator with the same layout;
// `record` only touches const-initialized thread-locals and never allocates.
unsafe impl GlobalAlloc for CountingAllocator {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        record(layout.size());
        unsafe { System.alloc(layout) }
    }

    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        record(layout.size());
        unsafe { System.alloc_zeroed(layout) }
    }

    unsafe fn dealloc(&self, pointer: *mut u8, layout: Layout) {
        unsafe { System.dealloc(pointer, layout) }
    }

    unsafe fn realloc(&self, pointer: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        record(new_size);
        unsafe { System.realloc(pointer, layout, new_size) }
    }
}

/// Runs `work` and returns its result with the allocations it made on this
/// thread.
pub(super) fn count_allocations<T>(work: impl FnOnce() -> T) -> (T, Allocations) {
    ALLOCATIONS.with(|total| total.set(Allocations::ZERO));
    COUNTING.with(|counting| counting.set(true));
    let result = work();
    COUNTING.with(|counting| counting.set(false));
    (result, ALLOCATIONS.with(Cell::get))
}
