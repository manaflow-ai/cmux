//! Opt-in synthetic `task.list` allocation and timing experiment.
//!
//! Run from `cmux-tui`: `cargo run -p cmux-tasks-core --example list_scaling`.
//! Uses the workspace dev profile, already-sorted manual keys, 256-byte
//! descriptions and no selective filters. Fixture construction is excluded.
//! Allocation totals include caller/filter construction and full realloc
//! requests; timing wraps only the query, including allocator atomics and
//! excluding returned-view destruction. Quantiles describe 31 five-call batch
//! means, not individual-request tails or application latency.

use std::alloc::{GlobalAlloc, Layout, System};
use std::collections::BTreeSet;
use std::hint::black_box;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use cmux_tasks_core::ids::Principal;
use cmux_tasks_core::model::{Description, Priority, State, Task};
use cmux_tasks_core::query::{self, ListFilter};

struct CountingAllocator;
static ALLOCATED_BYTES: AtomicUsize = AtomicUsize::new(0);
#[global_allocator]
static ALLOCATOR: CountingAllocator = CountingAllocator;

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
        let ptr = unsafe { System.realloc(ptr, layout, new_size) };
        if !ptr.is_null() {
            ALLOCATED_BYTES.fetch_add(new_size, Ordering::Relaxed);
        }
        ptr
    }
}

fn fixture(rows: usize) -> State {
    let mut state = State::new("team", "CMX");
    for n in 0..rows {
        let id = format!("task_{n:08}");
        state.tasks.insert(
            id.clone(),
            Task {
                id,
                number: n as u64,
                title: format!("Task {n}"),
                description: Description { text: "x".repeat(256), version: 0 },
                status: "st_backlog".to_owned(),
                priority: Priority::None,
                assignee: None,
                delegate: None,
                labels: BTreeSet::new(),
                project: None,
                parent: None,
                estimate: None,
                due: None,
                sort_key: format!("{n:08}"),
                attention: None,
                created_by: Principal::user("usr_test"),
                created_at: n as i64,
                updated_at: n as i64,
                started_at: None,
                completed_at: None,
                canceled_at: None,
                manual_status_at: None,
                archived: false,
                deleted: false,
            },
        );
    }
    state
}

fn list_once(state: &State, limit: Option<usize>) -> (Duration, usize) {
    ALLOCATED_BYTES.store(0, Ordering::Relaxed);
    let caller = Principal::user("usr_test");
    let filter = ListFilter { limit, ..ListFilter::default() };
    let start = Instant::now();
    let result = query::list(black_box(state), black_box(&caller), black_box(&filter));
    let elapsed = start.elapsed();
    black_box(result);
    (elapsed, ALLOCATED_BYTES.load(Ordering::Relaxed))
}

fn percentile(sorted: &[u128], p: usize) -> u128 {
    let index = (sorted.len() * p).div_ceil(100).saturating_sub(1);
    sorted[index]
}

fn main() {
    for rows in [1_000, 10_000] {
        let state = fixture(rows);
        for limit in [Some(1), Some(50), None] {
            for _ in 0..8 {
                let _ = list_once(&state, limit);
            }
            let mut batch_means = Vec::with_capacity(31);
            let mut bytes = 0;
            for _ in 0..31 {
                let mut total = 0u128;
                for _ in 0..5 {
                    let (elapsed, allocated) = list_once(&state, limit);
                    total += elapsed.as_nanos();
                    bytes = allocated;
                }
                batch_means.push(total / 5);
            }
            batch_means.sort_unstable();
            println!(
                "rows={rows} limit={limit:?} allocated_bytes={bytes} batch_mean_ns p50={} p95={} p99={}",
                percentile(&batch_means, 50),
                percentile(&batch_means, 95),
                percentile(&batch_means, 99)
            );
        }
    }
}
