//! A bounded Linux release-linker regression: freed Rust allocations must
//! return resident memory rather than remain in the libc allocator's slabs.

use std::alloc::{GlobalAlloc, Layout, System};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

struct CountingAllocator;
#[global_allocator]
static ALLOCATOR: CountingAllocator = CountingAllocator;
static LIVE: AtomicUsize = AtomicUsize::new(0);

// SAFETY: original pointers/layouts are forwarded unchanged to System; the
// accounting uses only allocation-free atomics.
unsafe impl GlobalAlloc for CountingAllocator {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        let pointer = unsafe { System.alloc(layout) };
        if !pointer.is_null() {
            LIVE.fetch_add(layout.size(), Ordering::Relaxed);
        }
        pointer
    }

    unsafe fn dealloc(&self, pointer: *mut u8, layout: Layout) {
        unsafe { System.dealloc(pointer, layout) };
        LIVE.fetch_sub(layout.size(), Ordering::Relaxed);
    }
}

fn rss_bytes() -> usize {
    let status = std::fs::read_to_string("/proc/self/status").unwrap();
    status
        .lines()
        .find(|line| line.starts_with("VmRSS:"))
        .and_then(|line| line.split_whitespace().nth(1))
        .unwrap()
        .parse::<usize>()
        .unwrap()
        * 1024
}

fn main() {
    assert!(cfg!(target_os = "linux"), "run this release fixture on Linux");
    let blocks = (0..8192).map(|index| vec![(index % 251) as u8; 16384]).collect::<Vec<_>>();
    std::hint::black_box(&blocks);
    let peak_live = LIVE.load(Ordering::Relaxed);
    let peak_rss = rss_bytes();
    drop(blocks);
    std::thread::sleep(Duration::from_millis(100));
    let after_rss = rss_bytes();
    let after_live = LIVE.load(Ordering::Relaxed);
    println!(
        "peak_live_bytes={peak_live} peak_rss_bytes={peak_rss} after_live_bytes={after_live} after_rss_bytes={after_rss}"
    );
    assert!(peak_live >= 128 * 1024 * 1024, "fixture did not allocate its workload");
    assert!(after_live < 64 * 1024, "fixture still owns allocations");
    assert!(after_rss < 64 * 1024 * 1024, "libc retained freed allocation slabs");
}
