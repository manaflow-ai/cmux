//! The flight recorder in its own process (no other test hops here): with CMUX_TRACE_FLOWS unset it still keeps
//! the newest hops, overwrites the oldest past [`cmux_flow_trace::RECENT_EVENTS`], cuts by age, and records
//! with no allocation.

use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;
use std::time::Duration;

use cmux_flow_trace::{RECENT_EVENTS, RECENT_PER_SHARD, RecentEvent, dump_recent, hop, hop_id};

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

/// More threads than shards, so every shard fills.
const RECENT_EVENTS_THREADS: u64 = cmux_flow_trace::RECENT_SHARDS as u64 + 2;

#[test]
fn the_ring_keeps_the_newest_hops_under_overflow_with_no_allocation() {
    assert!(
        std::env::var_os("CMUX_TRACE_FLOWS").is_none(),
        "run this test without CMUX_TRACE_FLOWS"
    );
    assert!(!cmux_flow_trace::init());
    let total = RECENT_PER_SHARD as u64 * 3 + 17;
    hop_id("flight.warm", 0, &[0; 16]); // reads this thread's id once
    let mut out = [RecentEvent::EMPTY; RECENT_EVENTS];
    let before = ALLOCATIONS.with(Cell::get);
    for flow in 1..=total {
        hop("flight.overflow", flow, "00ff");
    }
    let count = dump_recent(&mut out, None);
    assert_eq!(ALLOCATIONS.with(Cell::get) - before, 0, "a hop or a dump allocated");

    // One thread writes one shard: its newest RECENT_PER_SHARD hops.
    assert_eq!(count, RECENT_PER_SHARD);
    let flows: Vec<u64> = out[..count].iter().map(|event| event.flow).collect();
    let newest: Vec<u64> = (total - RECENT_PER_SHARD as u64 + 1..=total).collect();
    assert_eq!(flows, newest, "the newest RECENT_PER_SHARD, oldest first");
    assert!(
        out[..count]
            .iter()
            .all(|event| event.name == "flight.overflow" && event.terminal() == "00ff")
    );

    // A smaller buffer keeps the newest.
    let mut few = [RecentEvent::EMPTY; 4];
    assert_eq!(dump_recent(&mut few, None), 4);
    assert_eq!(few.map(|event| event.flow), [total - 3, total - 2, total - 1, total]);

    // An age cut drops what is older.
    std::thread::sleep(Duration::from_millis(50));
    hop_id("flight.fresh", 9, &[0x0f; 16]);
    let count = dump_recent(&mut out, Some(Duration::from_millis(20)));
    assert_eq!(count, 1);
    assert_eq!(out[0].name, "flight.fresh");
    assert_eq!(out[0].terminal(), "0f".repeat(16));

    let mut json = String::new();
    cmux_flow_trace::write_json_array(&mut json, &out[..1]).unwrap();
    assert!(json.starts_with("[{\"hop\":\"flight.fresh\",\"flow\":9,\"terminal\":\""), "{json}");

    // Threads on other shards: the dump merges every shard by clock, newest last.
    let threads: Vec<_> = (0..RECENT_EVENTS_THREADS)
        .map(|thread| {
            std::thread::spawn(move || {
                for flow in 0..RECENT_PER_SHARD as u64 * 2 {
                    hop("flight.many", thread * 1000 + flow, "");
                }
            })
        })
        .collect();
    for thread in threads {
        thread.join().unwrap();
    }
    let count = dump_recent(&mut out, None);
    assert_eq!(count, RECENT_EVENTS, "every shard full");
    let many = out.iter().filter(|event| event.name == "flight.many").count();
    assert!(many >= RECENT_EVENTS - 2 * RECENT_PER_SHARD, "the other threads' hops: {many}");
    assert!(
        out.windows(2).all(|pair| pair[0].age_ns >= pair[1].age_ns),
        "oldest first across shards"
    );
}
