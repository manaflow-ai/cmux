//! LAUNCH 800 (2026-11-10): the first `list-workspaces` answer of a launch took 247 ms at 826
//! workspaces against 21 ms at 60 (the app's marks `daemon.snapshot_start` to
//! `daemon.snapshot_end`). A sample of the daemon showed that time in `workspaces_json`, under the
//! state lock, and about half of it in `Serializer::collect_seq`: each level of the tree gave its
//! child list to its `json!` literal as an expression, and `json!` serializes an expression into a
//! new value. So each list was built and then copied: the tabs by their pane, the panes by their
//! screen, the screens by their workspace, the workspaces by the answer. A tab was built one time
//! and copied four times, all under the state lock.
//!
//! The answer must build each node of its tree one time. The count: the allocations the answer
//! makes on its thread against the allocations of one deep copy of that answer (`Value::clone`
//! makes each string, map node and list one time). It is a count, so a loaded host does not change
//! it. The times this test prints are facts for a person; no check reads them.

use super::*;
use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;
use std::hint::black_box;
use std::time::Instant;

thread_local! {
    /// The allocations made on this thread since a test turned the count on; `None` while off.
    static COUNTED: Cell<Option<u64>> = const { Cell::new(None) };
}

/// The allocator of this crate's unit-test binary: the system allocator, with a count per thread
/// that only [`allocations_of`] turns on. A thread that does not count pays one thread-local read.
struct CountingAllocator;

fn count_one() {
    let _ = COUNTED.try_with(|count| {
        if let Some(made) = count.get() {
            count.set(Some(made.saturating_add(1)));
        }
    });
}

// SAFETY: each call goes to `System` with its arguments unchanged, so `System`'s guarantees hold.
// The count writes one `Cell` of the calling thread, which is const-initialized and has no
// destructor: it allocates nothing and never calls back into the allocator.
unsafe impl GlobalAlloc for CountingAllocator {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        count_one();
        // SAFETY: the caller meets `GlobalAlloc::alloc`'s contract, which is `System.alloc`'s.
        unsafe { System.alloc(layout) }
    }

    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        count_one();
        // SAFETY: the caller meets `GlobalAlloc::alloc_zeroed`'s contract.
        unsafe { System.alloc_zeroed(layout) }
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        // SAFETY: `ptr` came from `System` through this allocator, with this layout.
        unsafe { System.dealloc(ptr, layout) }
    }

    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, size: usize) -> *mut u8 {
        count_one();
        // SAFETY: `ptr` came from `System` through this allocator, with this layout.
        unsafe { System.realloc(ptr, layout, size) }
    }
}

#[global_allocator]
static ALLOCATOR: CountingAllocator = CountingAllocator;

/// `run`'s result and the allocations it made on this thread.
fn allocations_of<T>(run: impl FnOnce() -> T) -> (T, u64) {
    let outer = COUNTED.with(|count| count.replace(Some(0)));
    let value = run();
    let made = COUNTED.with(|count| count.replace(outer)).unwrap_or(0);
    (value, made)
}

/// The median of five runs, in milliseconds.
fn median_ms(mut run: impl FnMut()) -> f64 {
    let mut times: Vec<f64> = (0..5)
        .map(|_| {
            let start = Instant::now();
            run();
            start.elapsed().as_secs_f64() * 1000.0
        })
        .collect();
    times.sort_by(f64::total_cmp);
    times[times.len() / 2]
}

/// A session in the shape of the person's: each workspace has one screen with one pane of two
/// terminal tabs, and no terminal has a process.
fn session_of(workspaces: usize) -> Arc<Mux> {
    let mux = test_mux();
    for index in 0..workspaces {
        let surface = mux.new_workspace(Some(format!("w{index}")), Some((80, 24))).unwrap();
        let pane = mux.with_state(|state| state.pane_of(surface.id).unwrap());
        mux.new_tab(Some(pane), None, Some((80, 24))).unwrap();
    }
    mux
}

fn list_workspaces(mux: &Arc<Mux>) -> Value {
    run_json_command(mux, json!({"cmd": "list-workspaces"})).unwrap()
}

/// What the first `list-workspaces` answer of a session cost.
struct Cost {
    workspaces: usize,
    tabs: usize,
    text_bytes: usize,
    /// Allocations of the first answer: the tree decorations, the tree, the registry fields.
    answer_allocations: u64,
    /// Allocations of one deep copy of that answer.
    copy_allocations: u64,
    /// Times the answer took the session's state lock.
    state_locks: u64,
    /// The time the test took to make the session: each create checks its delta against the
    /// whole tree in a unit test, so this grows with the square of the session.
    session_made_ms: f64,
    first_answer_ms: f64,
    answer_ms: f64,
    decorations_ms: f64,
    tree_under_lock_ms: f64,
    reply_copy_ms: f64,
    text_ms: f64,
}

fn cost_of(workspaces: usize) -> Cost {
    let start = Instant::now();
    let mux = session_of(workspaces);
    let session_made_ms = start.elapsed().as_secs_f64() * 1000.0;
    let locks_before = crate::mux::state_locks_taken_on_this_thread();
    let start = Instant::now();
    let (answer, answer_allocations) = allocations_of(|| list_workspaces(&mux));
    let first_answer_ms = start.elapsed().as_secs_f64() * 1000.0;
    let state_locks = crate::mux::state_locks_taken_on_this_thread() - locks_before;
    let (copy, copy_allocations) = allocations_of(|| answer.clone());
    assert_eq!(copy, answer);
    let listed = answer["workspaces"].as_array().unwrap();
    assert!(listed.len() >= workspaces, "the answer lists {} workspaces", listed.len());
    let tabs: usize = listed
        .iter()
        .flat_map(|workspace| workspace["screens"].as_array().unwrap())
        .flat_map(|screen| screen["panes"].as_array().unwrap())
        .map(|pane| pane["tabs"].as_array().unwrap().len())
        .sum();
    let decorations = mux.tree_decorations();
    Cost {
        workspaces: listed.len(),
        tabs,
        text_bytes: answer.to_string().len(),
        answer_allocations,
        copy_allocations,
        state_locks,
        session_made_ms,
        first_answer_ms,
        answer_ms: median_ms(|| {
            black_box(list_workspaces(&mux));
        }),
        decorations_ms: median_ms(|| {
            black_box(mux.tree_decorations());
        }),
        tree_under_lock_ms: median_ms(|| {
            black_box(mux.with_state(|state| workspaces_json(state, &decorations)));
        }),
        // What `send_response_with_details` does with the answer before it writes it.
        reply_copy_ms: median_ms(|| {
            black_box(serde_json::to_value(&answer).unwrap());
        }),
        text_ms: median_ms(|| {
            black_box(serde_json::to_vec(&answer).unwrap());
        }),
    }
}

/// An answer may make 1.5 times the allocations of a deep copy of itself: one for the tree, a half
/// for all the rest (the tree decorations, the short IDs, the strings it reads from surfaces;
/// measured: 0.16). One list that is built and then copied by its parent takes the answer above
/// this: the copy of the tabs alone adds up to 0.71 (the three copies together added 2.13).
const COPIES_ALLOWED_TIMES_2: u64 = 3;

/// Prints what the answer cost and fails when it built nodes of its tree more than one time.
fn check(cost: &Cost) {
    println!(
        "list-workspaces cost: {} workspaces, {} tabs, {} bytes of text: answer {} allocations, \
         one deep copy {} allocations, ratio {:.2}, {} allocations for each workspace; state lock \
         taken {} times; first answer {:.2} ms; medians of 5: answer {:.2} ms, tree decorations \
         {:.2} ms, tree built and dropped under the state lock {:.2} ms, copy of the reply {:.2} \
         ms, text {:.2} ms; the test made the session in {:.0} ms",
        cost.workspaces,
        cost.tabs,
        cost.text_bytes,
        cost.answer_allocations,
        cost.copy_allocations,
        cost.answer_allocations as f64 / cost.copy_allocations as f64,
        cost.answer_allocations / cost.workspaces as u64,
        cost.state_locks,
        cost.first_answer_ms,
        cost.answer_ms,
        cost.decorations_ms,
        cost.tree_under_lock_ms,
        cost.reply_copy_ms,
        cost.text_ms,
        cost.session_made_ms,
    );
    assert!(
        2 * cost.answer_allocations <= COPIES_ALLOWED_TIMES_2 * cost.copy_allocations,
        "the first list-workspaces answer at {} workspaces made {} allocations, {:.2} times the \
         {} of one deep copy of it (allowed: 1.5 times): it builds nodes of its tree more than one \
         time",
        cost.workspaces,
        cost.answer_allocations,
        cost.answer_allocations as f64 / cost.copy_allocations as f64,
        cost.copy_allocations,
    );
}

#[test]
fn the_first_list_workspaces_answer_builds_each_node_one_time_at_60_workspaces() {
    check(&cost_of(60));
}

/// The person's session. Not in a default run: each create of a unit-test session checks its delta
/// against the whole tree, so the test's own session of 826 workspaces takes long to make.
///
///     cargo test --locked -p cmux-tui-core --lib -- list_workspaces_cost --include-ignored --nocapture
#[test]
#[ignore = "826 workspaces: the unit-test session takes long to make; run with --include-ignored"]
fn the_first_list_workspaces_answer_builds_each_node_one_time_at_826_workspaces() {
    check(&cost_of(826));
}
