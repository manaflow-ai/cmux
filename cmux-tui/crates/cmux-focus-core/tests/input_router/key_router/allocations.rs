//! The router allocates nothing for a plain key, its release and a bound
//! chord once its buffers have grown (DESIGN.md stage S1a acceptance: 0
//! allocations per key). A counting allocator counts each thread's
//! allocations; the other tests of this binary are only counted, never
//! changed.

use super::support::{arc, chord, key, pane, terminal, terminal_tab, topology};
use cmux_focus_core::event::{FocusEvent, Source};
use cmux_focus_core::input::{InputEvent, InputRouter, KeyPhase, KeyRecord, LaneLimit, Tier};
use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;

struct Counting;

thread_local! {
    static ALLOCATIONS: Cell<u64> = const { Cell::new(0) };
}

fn count() {
    let _ = ALLOCATIONS.try_with(|count| count.set(count.get().wrapping_add(1)));
}

// SAFETY: every call goes to the system allocator with the caller's pointer
// and layout unchanged; counting only touches a thread-local `Cell`, which
// never allocates.
unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        count();
        // SAFETY: the caller's layout, as `GlobalAlloc::alloc` requires.
        unsafe { System.alloc(layout) }
    }

    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        count();
        // SAFETY: the caller's layout, as `GlobalAlloc::alloc_zeroed` requires.
        unsafe { System.alloc_zeroed(layout) }
    }

    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        count();
        // SAFETY: `ptr` came from this allocator (the system's) with `layout`.
        unsafe { System.realloc(ptr, layout, new_size) }
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        // SAFETY: `ptr` came from this allocator (the system's) with `layout`.
        unsafe { System.dealloc(ptr, layout) }
    }
}

#[global_allocator]
static COUNTING: Counting = Counting;

/// This thread's allocations so far.
fn allocations() -> u64 {
    ALLOCATIONS.try_with(Cell::get).unwrap_or(0)
}

#[test]
fn a_key_its_release_and_a_bound_chord_allocate_nothing() {
    let mut router = InputRouter::new(LaneLimit::of(64));
    let window = arc("w1");
    let shows = topology("ws", vec![pane("p1", vec![terminal_tab("t1", "T1")])]);
    let focus =
        FocusEvent::FocusPane { pane: "p1".into(), workspace: None, source: Source::Keyboard };
    let setup = [
        InputEvent::WindowOpened { window: window.clone() },
        InputEvent::Focus {
            window: window.clone(),
            event: FocusEvent::Topology { topology: shows },
        },
        InputEvent::Focus { window, event: focus },
        InputEvent::Dispatch { reaches: Some(terminal("T1")) },
    ];
    for event in &setup {
        router.handle(event);
    }
    let typed = key("w1", 0, Some(terminal("T1")));
    let split = chord("w1", 2, "newSplit", Tier::Navigation, Some(terminal("T1")));
    let keys = [
        InputEvent::Key(typed.clone()),
        InputEvent::Key(KeyRecord { phase: KeyPhase::Up, ..typed }),
        InputEvent::Key(split.clone()),
        InputEvent::Key(KeyRecord { phase: KeyPhase::Up, ..split }),
    ];
    // The first keys grow the router's buffers.
    for _ in 0..8 {
        for event in &keys {
            router.handle(event);
        }
    }
    let before = allocations();
    for _ in 0..1000 {
        for event in &keys {
            router.handle(event);
        }
    }
    let made = allocations().wrapping_sub(before);
    assert_eq!(made, 0, "{made} allocations for 4000 key events");
}
