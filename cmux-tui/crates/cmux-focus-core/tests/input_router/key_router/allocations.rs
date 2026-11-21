//! The router allocates nothing for a plain key, its release and a bound
//! chord once its buffers have grown (DESIGN.md stage S1a acceptance: 0
//! allocations per key). A counting allocator counts each thread's
//! allocations; the other tests of this binary are only counted, never
//! changed.

use super::support::{arc, chord, key, pane, terminal, terminal_tab, topology};
use cmux_focus_core::event::{FocusEvent, Source};
use cmux_focus_core::input::{InputEvent, InputRouter, KeyPhase, KeyRecord, LaneLimit, Tier};
use cmux_focus_core::topology::{Kind, Pane, Tab, Topology};
use cmux_focus_core::window::WindowFocus;
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

/// A topology report that changes only which tab a pane shows (Cmd-1, a tab
/// click, a switch back) lists the same tabs: the router keeps its tab index,
/// which holds each tab's id, surface, kind and host terminal and never the
/// selection, and makes no more allocations than the window's focus alone.
/// Before, the router rebuilt the whole index on every report that ran the
/// reducer (an `Arc<str>` per tab id, surface and host terminal): the S2 focus
/// A/B measured a topology report 13 % slower through the input handle
/// (8.04 -> 9.13 us p50, 30 panes).
#[test]
fn a_report_that_only_selects_another_tab_rebuilds_no_tab_index() {
    let layout = |selected: &str| {
        let tab = |id: String, kind: Kind| Tab {
            surface: Some(format!("surface-{id}")),
            terminal: matches!(kind, Kind::Terminal).then(|| format!("host-{id}")),
            id,
            kind,
        };
        let panes = (0..6)
            .map(|index| Pane {
                id: format!("pane-{index}"),
                tabs: vec![
                    tab(format!("a{index}"), Kind::Terminal),
                    tab(format!("b{index}"), Kind::Browser),
                ],
                selected: Some(format!("{selected}{index}")),
            })
            .collect();
        Topology::new(Some("workspace".into()), panes, Vec::new())
    };
    let (shows_a, shows_b) = (layout("a"), layout("b"));
    let mut alone = WindowFocus::new();
    let mut effects = Vec::new();
    let mut router = InputRouter::new(LaneLimit::of(64));
    router.handle(&InputEvent::WindowOpened { window: arc("w1") });
    // The same switches once before the count, so every buffer has grown to them.
    for topology in [&shows_a, &shows_b, &shows_a] {
        alone.set_topology(topology.clone(), &mut effects);
        router.set_focus_topology("w1", topology.clone());
    }
    let (for_alone, for_router) = (shows_b.clone(), shows_b);
    let start = allocations();
    let reduced = alone.set_topology(for_alone, &mut effects);
    let window_alone = allocations().wrapping_sub(start);
    let start = allocations();
    router.set_focus_topology("w1", for_router);
    let in_router = allocations().wrapping_sub(start);
    assert!(reduced.ran, "the report changed nothing: it would not exercise the index");
    assert_eq!(
        in_router, window_alone,
        "the router made {in_router} allocations for a report that only selects other tabs, the \
         window focus alone {window_alone} (the router rebuilt its tab index?)"
    );
}
