//! Regression tests for `task.list` materialization and ordering.

use std::alloc::{GlobalAlloc, Layout, System};
use std::collections::BTreeSet;
use std::sync::atomic::{AtomicUsize, Ordering};

use cmux_tasks_core::ids::Principal;
use cmux_tasks_core::model::{Description, Priority, State, Task};
use cmux_tasks_core::query::{self, ListFilter};

struct CountingAllocator;

static ALLOCATED_BYTES: AtomicUsize = AtomicUsize::new(0);

unsafe impl GlobalAlloc for CountingAllocator {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        let ptr = unsafe { System.alloc(layout) };
        if !ptr.is_null() {
            ALLOCATED_BYTES.fetch_add(layout.size(), Ordering::Relaxed);
        }
        ptr
    }

    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        let ptr = unsafe { System.alloc_zeroed(layout) };
        if !ptr.is_null() {
            ALLOCATED_BYTES.fetch_add(layout.size(), Ordering::Relaxed);
        }
        ptr
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        unsafe { System.dealloc(ptr, layout) };
    }

    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        let next = unsafe { System.realloc(ptr, layout, new_size) };
        if !next.is_null() {
            ALLOCATED_BYTES.fetch_add(new_size, Ordering::Relaxed);
        }
        next
    }
}

#[global_allocator]
static ALLOCATOR: CountingAllocator = CountingAllocator;

fn reset_allocations() {
    ALLOCATED_BYTES.store(0, Ordering::Relaxed);
}

fn allocated_bytes() -> usize {
    ALLOCATED_BYTES.load(Ordering::Relaxed)
}

fn task(id: &str, number: u64, description_len: usize) -> Task {
    Task {
        id: id.to_owned(),
        number,
        title: format!("Task {number}"),
        description: Description { text: "x".repeat(description_len), version: 0 },
        status: "st_backlog".to_owned(),
        priority: Priority::None,
        assignee: None,
        delegate: None,
        labels: BTreeSet::new(),
        project: None,
        parent: None,
        estimate: None,
        due: None,
        sort_key: format!("{number:08}"),
        attention: None,
        created_by: Principal::user("usr_test"),
        created_at: number as i64,
        updated_at: number as i64,
        started_at: None,
        completed_at: None,
        canceled_at: None,
        manual_status_at: None,
        archived: false,
        deleted: false,
    }
}

fn large_state(task_count: usize, description_len: usize) -> State {
    let mut state = State::new("team", "CMX");
    for number in 0..task_count {
        let id = format!("task_{number:04}");
        state.tasks.insert(id.clone(), task(&id, number as u64, description_len));
    }
    state
}

#[test]
fn list_limit_one_does_not_clone_unreturned_descriptions() {
    let state = large_state(64, 64 * 1024);
    let caller = Principal::user("usr_test");
    let filter = ListFilter { limit: Some(1), ..ListFilter::default() };

    // Fixture setup allocates the descriptions. Only list's materialization is
    // measured so this remains a regression for the query implementation.
    reset_allocations();
    let result = query::list(&state, &caller, &filter);
    let bytes = allocated_bytes();

    assert_eq!(result.len(), 1);
    assert!(bytes < 512 * 1024, "limit=1 materialized too many task bytes: {bytes} allocated");
}
