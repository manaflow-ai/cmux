//! Method-table lookups never allocate (p05-ipc-023 acceptance): every id and
//! name lookup, hit or miss, runs under a counting allocator.
//!
//! An integration test because the counting allocator needs `unsafe`, which
//! the library forbids.

use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;
use std::hint::black_box;

use cmux_ipc::{EventId, MethodId, MethodTables};

thread_local! {
    static ALLOCATIONS: Cell<u64> = const { Cell::new(0) };
}

struct Counting;

// SAFETY: forwards to the system allocator; the counter is a const-initialized
// thread-local Cell, which never allocates.
unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        let _ = ALLOCATIONS.try_with(|count| count.set(count.get() + 1));
        // SAFETY: same contract as the caller's.
        unsafe { System.alloc(layout) }
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        // SAFETY: same contract as the caller's.
        unsafe { System.dealloc(ptr, layout) }
    }
}

#[global_allocator]
static GLOBAL: Counting = Counting;

fn allocations() -> u64 {
    ALLOCATIONS.with(Cell::get)
}

#[test]
fn methods_table_lookups_do_not_allocate() {
    let names: Vec<String> =
        ["send", "new-tab", "agent.list", "workspace.list", "output", "", "no-such-method"]
            .into_iter()
            .map(str::to_owned)
            .collect();
    let tables = MethodTables::schema();

    let before = allocations();
    let mut found = 0_u32;
    for raw in 0..=u16::MAX {
        found += u32::from(tables.method(black_box(MethodId::new(raw))).is_some());
        found += u32::from(tables.event(black_box(EventId::new(raw))).is_some());
    }
    for name in &names {
        found += u32::from(tables.v12_id(black_box(name)).is_some());
        found += u32::from(tables.v2_id(black_box(name)).is_some());
        found += u32::from(tables.event_id(black_box(name)).is_some());
    }
    let after = allocations();
    black_box(found);
    assert_eq!(after - before, 0, "lookups allocated");
}
