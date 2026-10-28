//! Setting, scoping and reading the crash keys allocates nothing:
//! a hang reporter or a panic hook reads them on any
//! thread, even one whose allocator is what hung. A counting global
//! allocator tallies this thread's allocations around the calls.

use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;

use cmux_panic_log::crash_keys::{self, HungThread, Key, MAX_RECORD_BYTES};

struct Counting;

thread_local! {
    static ALLOCATIONS: Cell<u64> = const { Cell::new(0) };
}

// SAFETY: forwards every call to the system allocator unchanged; the count
// is a const-initialized thread local, which allocates nothing itself.
unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        let _ = ALLOCATIONS.try_with(|count| count.set(count.get() + 1));
        // SAFETY: the caller's layout, passed through.
        unsafe { System.alloc(layout) }
    }

    unsafe fn dealloc(&self, pointer: *mut u8, layout: Layout) {
        // SAFETY: the pointer came from `alloc` above with this layout.
        unsafe { System.dealloc(pointer, layout) }
    }
}

#[global_allocator]
static ALLOCATOR: Counting = Counting;

fn allocations(body: impl FnOnce()) -> u64 {
    let before = ALLOCATIONS.with(Cell::get);
    body();
    ALLOCATIONS.with(Cell::get) - before
}

#[test]
fn the_probe_sees_an_allocation() {
    assert!(allocations(|| drop(std::hint::black_box(vec![1u8; 64]))) > 0);
}

#[test]
fn writing_scoping_and_reading_keys_allocates_nothing() {
    let mut buffer = [0u8; MAX_RECORD_BYTES];
    let mut written = 0;
    let mut inner_read = 0;
    let count = allocations(|| {
        crash_keys::set(Key::DaemonEpoch, 7);
        let outer = crash_keys::scoped(Key::ActionId, crash_keys::stable_key("workspace.new"));
        {
            let _inner = crash_keys::scoped(Key::ActionId, crash_keys::stable_key("pane.split"));
            let _ = crash_keys::note_hung(HungThread { id: 77, kind: 2 });
            let snapshot = crash_keys::snapshot();
            written = snapshot.write_line(&mut buffer);
            inner_read = std::hint::black_box(snapshot.hung_threads().count());
        }
        std::hint::black_box(crash_keys::get(Key::ActionId));
        drop(outer);
        crash_keys::clear_hung(77);
        // A thread's own key (a request's method): its first use on this thread too.
        let own = crash_keys::scoped_thread(Key::CefState, 3);
        std::hint::black_box(crash_keys::thread_value(Key::CefState));
        drop(own);
    });
    assert_eq!(count, 0, "the crash keys allocated {count} times");
    assert_eq!(inner_read, 1);
    assert_eq!(crash_keys::get(Key::ActionId), 0, "the outermost scope puts 0 back");
    let line = std::str::from_utf8(&buffer[..written]).unwrap();
    let expected = format!(
        "crash_keys action_id={} daemon_epoch=7 hung_threads=1 hung_kind_0=2\n",
        crash_keys::stable_key("pane.split")
    );
    assert_eq!(line, expected);
    assert!(crash_keys::snapshot().hung_threads().next().is_none());
}
