//! The C ABI of the one close-selection rule (`cmux_close_selection_*`).
//! The rule and its table are tested in cmux-focus-core
//! (tests/close_selection.rs); these prove the calls carry it: the quick
//! look-up, the link family, the lifetime calls, both picks, and the null,
//! none-id and null-array guards.

use cmux_layout_reducer_ffi::close_selection::{
    CloseSelection, QUICK, TASK, cmux_close_selection_forget_all, cmux_close_selection_free,
    cmux_close_selection_has_relations, cmux_close_selection_left, cmux_close_selection_made,
    cmux_close_selection_navigated, cmux_close_selection_new, cmux_close_selection_opener,
    cmux_close_selection_selected, cmux_close_selection_slot, cmux_close_selection_tab,
    cmux_close_selection_typed_navigation, cmux_close_selection_workspace,
};
use cmux_layout_reducer_ffi::focus::NONE;
use std::ptr::null;

const A: u32 = 1;
const B: u32 = 2;
const C: u32 = 3;
const D: u32 = 4;
const N: u32 = 5;
const X: u32 = 6;
const Y: u32 = 7;

struct Handle(*mut CloseSelection);

impl Handle {
    fn new() -> Self {
        Self(cmux_close_selection_new())
    }

    fn made(&self, item: u32, opener: u32, kind: u8, foreground: bool, strip: &[u32]) {
        unsafe {
            cmux_close_selection_made(
                self.0,
                item,
                opener,
                kind,
                u8::from(foreground),
                strip.as_ptr(),
                strip.len(),
            );
        }
    }

    fn selected(&self, old: u32, new: u32, gesture: bool, strip: &[u32]) {
        unsafe {
            cmux_close_selection_selected(
                self.0,
                old,
                new,
                u8::from(gesture),
                strip.as_ptr(),
                strip.len(),
            );
        }
    }

    fn opener(&self, item: u32) -> u32 {
        unsafe { cmux_close_selection_opener(self.0, item) }
    }

    fn has_relations(&self) -> bool {
        unsafe { cmux_close_selection_has_relations(self.0) != 0 }
    }

    /// The tab selected after `closed`, the selected tab of `old`, closed.
    fn tab(&self, closed: u32, old: &[u32], group: &[(u32, u32)]) -> u32 {
        tab(self.0, closed, old, group)
    }

    /// The workspace shown after `closed` left, with `rows` drawn.
    fn workspace(&self, closed: u32, old: &[u32], rows: &[u32]) -> u32 {
        workspace(self.0, closed, old, rows)
    }
}

impl Drop for Handle {
    fn drop(&mut self) {
        unsafe { cmux_close_selection_free(self.0) }
    }
}

fn tab(handle: *mut CloseSelection, closed: u32, old: &[u32], group: &[(u32, u32)]) -> u32 {
    let left: Vec<u32> = old.iter().copied().filter(|id| *id != closed).collect();
    let tabs: Vec<u32> = group.iter().map(|(tab, _)| *tab).collect();
    let groups: Vec<u32> = group.iter().map(|(_, group)| *group).collect();
    unsafe {
        cmux_close_selection_tab(
            handle,
            closed,
            old.as_ptr(),
            old.len(),
            left.as_ptr(),
            left.len(),
            left.as_ptr(),
            left.len(),
            tabs.as_ptr(),
            groups.as_ptr(),
            group.len(),
        )
    }
}

fn workspace(handle: *mut CloseSelection, closed: u32, old: &[u32], rows: &[u32]) -> u32 {
    let left: Vec<u32> = old.iter().copied().filter(|id| *id != closed).collect();
    let lengths = [rows.len() as u32];
    unsafe {
        cmux_close_selection_workspace(
            handle,
            closed,
            old.as_ptr(),
            old.len(),
            left.as_ptr(),
            left.len(),
            rows.as_ptr(),
            lengths.as_ptr(),
            1,
            null(),
            null(),
            0,
        )
    }
}

/// A pick after a close: the handle, the closed item, the strip before the close.
type Pick = fn(&Handle, u32, &[u32]) -> u32;

#[test]
fn a_quick_look_up_returns_to_the_item_it_came_from() {
    // A B* C D, a new item N after B, closed at once: B, not C.
    let picks: [Pick; 2] = [Handle::tab_plain, Handle::workspace_rows];
    for pick in picks {
        let handle = Handle::new();
        let strip = [A, B, N, C, D];
        handle.made(N, B, QUICK, true, &strip);
        handle.selected(B, N, false, &strip);
        assert_eq!(handle.opener(N), B);
        assert_eq!(pick(&handle, N, &strip), B);
        // After a visit to another item it is the next one.
        handle.selected(N, D, true, &strip);
        handle.selected(D, N, true, &strip);
        assert_eq!(handle.opener(N), NONE);
        assert_eq!(pick(&handle, N, &strip), C);
    }
}

impl Handle {
    fn tab_plain(&self, closed: u32, old: &[u32]) -> u32 {
        self.tab(closed, old, &[])
    }

    fn workspace_rows(&self, closed: u32, old: &[u32]) -> u32 {
        self.workspace(closed, old, old)
    }
}

#[test]
fn a_link_family_picks_child_sibling_then_opener() {
    let handle = Handle::new();
    let mut strip = vec![A, B, C, D];
    // B opens X and Y in the background: each goes after B's last child.
    for child in [X, Y] {
        let after = unsafe {
            cmux_close_selection_slot(handle.0, B, strip.as_ptr(), strip.len(), null(), 0)
        };
        let at = strip.iter().position(|id| *id == after).unwrap() + 1;
        strip.insert(at, child);
        handle.made(child, B, TASK, false, &strip);
    }
    assert_eq!(strip, [A, B, X, Y, C, D]);
    // Closing the opener selects its first child; closing a child, its sibling.
    assert_eq!(handle.tab(B, &strip, &[]), X);
    handle.selected(B, X, true, &strip);
    assert_eq!(handle.tab(X, &strip, &[]), Y);
    assert_eq!(handle.workspace(X, &strip, &strip), Y);
    // X leaves: Y is selected by the close, then returns to the opener.
    unsafe { cmux_close_selection_left(handle.0, X) };
    let strip = [A, B, Y, C, D];
    handle.selected(X, Y, false, &strip);
    assert_eq!(handle.tab(Y, &strip, &[]), B);
    // A typed navigation in the link tab starts another task: the next tab.
    unsafe { cmux_close_selection_typed_navigation(handle.0, Y, strip.as_ptr(), strip.len()) };
    assert_eq!(handle.opener(Y), NONE);
    assert_eq!(handle.tab(Y, &strip, &[]), C);
}

#[test]
fn the_first_typed_navigation_of_a_new_tab_keeps_its_opener() {
    let handle = Handle::new();
    let strip = [A, B, N, C];
    handle.made(N, B, QUICK, true, &strip);
    unsafe { cmux_close_selection_typed_navigation(handle.0, N, strip.as_ptr(), strip.len()) };
    assert_eq!(handle.opener(N), B);
    unsafe { cmux_close_selection_typed_navigation(handle.0, N, strip.as_ptr(), strip.len()) };
    assert_eq!(handle.opener(N), NONE);
    handle.made(X, B, TASK, false, &strip);
    unsafe { cmux_close_selection_forget_all(handle.0, strip.as_ptr(), strip.len()) };
    assert_eq!(handle.opener(X), B, "X is not an item of the strip named");
    let strip = [A, B, X, C];
    unsafe { cmux_close_selection_forget_all(handle.0, strip.as_ptr(), strip.len()) };
    assert_eq!(handle.opener(X), NONE);
}

#[test]
fn another_navigation_ends_just_made() {
    let handle = Handle::new();
    let strip = [A, B, N, C];
    handle.made(N, B, QUICK, true, &strip);
    // A link click in the new tab: its opener stays, its next typed navigation is not the first.
    unsafe { cmux_close_selection_navigated(handle.0, N) };
    assert_eq!(handle.opener(N), B);
    unsafe { cmux_close_selection_typed_navigation(handle.0, N, strip.as_ptr(), strip.len()) };
    assert_eq!(handle.opener(N), NONE);
}

#[test]
fn has_relations_follows_the_relations() {
    let handle = Handle::new();
    let strip = [A, B, N, C];
    assert!(!handle.has_relations());
    // A person's item with no selected item is "just made" but holds no relation.
    handle.made(N, NONE, QUICK, true, &strip);
    assert!(!handle.has_relations());
    handle.made(X, B, TASK, false, &strip);
    assert!(handle.has_relations());
    unsafe { cmux_close_selection_left(handle.0, X) };
    assert!(!handle.has_relations());
    assert_eq!(unsafe { cmux_close_selection_has_relations(std::ptr::null_mut()) }, 0);
}

#[test]
fn a_none_item_changes_nothing() {
    let handle = Handle::new();
    let strip = [A, B, N, C];
    handle.made(NONE, B, TASK, true, &strip);
    assert!(!handle.has_relations());
    handle.made(N, B, QUICK, true, &strip);
    // A selection of none is no move away from N, and a navigation of none is no navigation.
    handle.selected(N, NONE, true, &strip);
    unsafe {
        cmux_close_selection_typed_navigation(handle.0, NONE, strip.as_ptr(), strip.len());
        cmux_close_selection_navigated(handle.0, NONE);
        cmux_close_selection_left(handle.0, NONE);
    }
    assert_eq!(handle.opener(N), B);
    assert_eq!(handle.tab(N, &strip, &[]), B);
}

#[test]
fn a_workspace_pick_reads_each_order_and_the_sections() {
    let handle = Handle::new();
    let old = [A, B, C, D];
    let left = [A, B, D];
    // Two orders, flattened: the drawn rows do not list C, the model's rows do (b c d a).
    let orders = [A, B, D, B, C, D, A];
    let lengths = [3u32, 4];
    let pick = |rows: &[u32], sections: &[u32]| unsafe {
        cmux_close_selection_workspace(
            handle.0,
            C,
            old.as_ptr(),
            old.len(),
            left.as_ptr(),
            left.len(),
            orders.as_ptr(),
            lengths.as_ptr(),
            lengths.len(),
            rows.as_ptr(),
            sections.as_ptr(),
            rows.len(),
        )
    };
    // The second order decides: the row below c there.
    assert_eq!(pick(&[], &[]), D);
    // With c in b's section and d in another: the row above, of its own section.
    assert_eq!(pick(&[B, C, D], &[1, 1, 2]), B);
}

#[test]
fn a_tab_pick_skips_hidden_tabs_and_a_slot_skips_pinned_ones() {
    let handle = Handle::new();
    let old = [A, B, C, D];
    let left = [A, C, D];
    let shown = [A, D];
    let pick = unsafe {
        cmux_close_selection_tab(
            handle.0,
            B,
            old.as_ptr(),
            old.len(),
            left.as_ptr(),
            left.len(),
            shown.as_ptr(),
            shown.len(),
            null(),
            null(),
            0,
        )
    };
    assert_eq!(pick, D, "C is in a collapsed group");
    // B's child X stands after the pinned C: C does not end B's run.
    let order = [A, B, C, X, D];
    handle.made(X, B, TASK, false, &order);
    let slot = |pinned: &[u32]| unsafe {
        cmux_close_selection_slot(
            handle.0,
            B,
            order.as_ptr(),
            order.len(),
            pinned.as_ptr(),
            pinned.len(),
        )
    };
    assert_eq!(slot(&[]), B);
    assert_eq!(slot(&[C]), X);
}

#[test]
fn no_relation_picks_by_position_and_group() {
    let handle = Handle::new();
    let strip = [A, B, C, D];
    assert_eq!(handle.tab(B, &strip, &[]), C);
    assert_eq!(handle.tab(D, &strip, &[]), C);
    assert_eq!(handle.tab(C, &strip, &[(B, 1), (C, 1)]), B);
    assert_eq!(handle.workspace(B, &strip, &strip), C);
    assert_eq!(handle.workspace(D, &strip, &strip), C);
    // The drawn rows decide for a workspace: a b d c drawn, c is below d.
    assert_eq!(handle.workspace(D, &strip, &[A, B, D, C]), C);
    assert_eq!(handle.workspace(C, &strip, &[A, B, D, C]), D);
    assert_eq!(handle.tab(A, &[A], &[]), NONE);
}

#[test]
fn null_handles_and_arrays_are_safe() {
    let strip = [A, B, C];
    // A null handle is no relation: the positional pick.
    assert_eq!(tab(std::ptr::null_mut(), B, &strip, &[]), C);
    assert_eq!(workspace(std::ptr::null_mut(), C, &strip, &strip), B);
    unsafe {
        cmux_close_selection_made(std::ptr::null_mut(), N, B, QUICK, 1, strip.as_ptr(), 3);
        cmux_close_selection_selected(std::ptr::null_mut(), A, B, 1, strip.as_ptr(), 3);
        cmux_close_selection_typed_navigation(std::ptr::null_mut(), A, strip.as_ptr(), 3);
        cmux_close_selection_navigated(std::ptr::null_mut(), A);
        cmux_close_selection_left(std::ptr::null_mut(), A);
        cmux_close_selection_forget_all(std::ptr::null_mut(), strip.as_ptr(), 3);
        cmux_close_selection_free(std::ptr::null_mut());
        assert_eq!(cmux_close_selection_opener(std::ptr::null_mut(), A), NONE);
        assert_eq!(
            cmux_close_selection_slot(std::ptr::null_mut(), B, strip.as_ptr(), 3, null(), 0),
            B
        );
    }
    // A null array with a count changes nothing and picks none.
    let handle = Handle::new();
    unsafe {
        cmux_close_selection_made(handle.0, N, B, QUICK, 1, null(), 3);
        assert_eq!(cmux_close_selection_opener(handle.0, N), NONE);
        assert_eq!(
            cmux_close_selection_tab(
                handle.0,
                B,
                null(),
                3,
                strip.as_ptr(),
                3,
                strip.as_ptr(),
                3,
                null(),
                null(),
                0
            ),
            NONE
        );
        let lengths = [9u32];
        assert_eq!(
            cmux_close_selection_workspace(
                handle.0,
                B,
                strip.as_ptr(),
                3,
                strip.as_ptr(),
                3,
                null(),
                lengths.as_ptr(),
                1,
                null(),
                null(),
                0
            ),
            NONE
        );
        assert_eq!(cmux_close_selection_slot(handle.0, B, null(), 3, null(), 0), B);
    }
}

const HEADER: &str = include_str!("../include/cmux_layout_reducer_ffi.h");

/// The opener kinds are written by hand on both sides.
#[test]
fn the_opener_kinds_are_the_header_constants() {
    assert!(HEADER.contains(&format!("CMUX_CLOSE_SELECTION_QUICK = {QUICK},")));
    assert!(HEADER.contains(&format!("CMUX_CLOSE_SELECTION_TASK = {TASK},")));
}
