//! The C ABI of the close-selection state of every window's workspaces
//! (`cmux_window_close_selection_*`). The state and its rules are tested in
//! cmux-focus-core (tests/window_close_selection*.rs); these prove each call
//! carries them, and the null-handle, none-id, null-array and empty-array
//! guards. The settle pair is in tests/window_close_selection_settle.rs.

use cmux_layout_reducer_ffi::focus::NONE;
use cmux_layout_reducer_ffi::window_close_selection::{
    CmuxWindowClosePick, CmuxWindowCloseRepair, RELATION_NONE, RELATION_QUICK, RELATION_TASK,
    WindowCloseSelection, cmux_window_close_selection_expect, cmux_window_close_selection_free,
    cmux_window_close_selection_holds_ids, cmux_window_close_selection_is_empty,
    cmux_window_close_selection_kept, cmux_window_close_selection_left,
    cmux_window_close_selection_new, cmux_window_close_selection_pick,
    cmux_window_close_selection_relation, cmux_window_close_selection_renamed,
    cmux_window_close_selection_repair_begin, cmux_window_close_selection_repair_end,
    cmux_window_close_selection_shown,
};
use std::ptr::{null, null_mut};

// Workspaces. 0 is an id like any other.
const A: u32 = 0;
const B: u32 = 1;
const C: u32 = 2;
const D: u32 = 3;
const N: u32 = 4;
const P: u32 = 5;
// Windows: their own numbering, which may reuse the workspaces' numbers.
const W: u32 = 0;
const V: u32 = 1;

struct Handle(*mut WindowCloseSelection);

impl Drop for Handle {
    fn drop(&mut self) {
        unsafe { cmux_window_close_selection_free(self.0) };
    }
}

impl Handle {
    fn new() -> Self {
        Self(cmux_window_close_selection_new())
    }

    fn is_empty(&self) -> bool {
        unsafe { cmux_window_close_selection_is_empty(self.0) != 0 }
    }

    fn holds_ids(&self) -> bool {
        unsafe { cmux_window_close_selection_holds_ids(self.0) != 0 }
    }

    fn expect(&self, workspace: u32, window: u32, relation: u8) {
        unsafe { cmux_window_close_selection_expect(self.0, workspace, window, relation) };
    }

    fn shown(&self, new: u32, old: u32, window: u32, gesture: bool) {
        unsafe { cmux_window_close_selection_shown(self.0, new, old, window, u8::from(gesture)) };
    }

    /// A person's New Workspace in window `W`.
    fn make(&self, new: u32, old: u32, relation: u8) {
        self.expect(new, W, relation);
        self.shown(new, old, W, true);
    }

    fn left(&self, workspace: u32) {
        unsafe { cmux_window_close_selection_left(self.0, workspace) };
    }

    fn pick(&self, shown: u32, previous: &[u32], members: &[u32], orders: &[&[u32]]) -> u32 {
        pick(self.0, shown, previous, members, orders)
    }

    /// The repair of a close at its press: the window showed `shown` and
    /// shows `to` now.
    fn press(&self, shown: u32, to: u32, members: &[u32]) {
        let repair = CmuxWindowCloseRepair {
            shown,
            pick: to,
            gesture: 0,
            pressed: 1,
            members: members.as_ptr(),
            member_count: members.len(),
            preferred: null(),
            preferred_count: 0,
        };
        unsafe { cmux_window_close_selection_repair_begin(self.0, &repair) };
        self.shown(to, shown, W, true);
        unsafe { cmux_window_close_selection_repair_end(self.0) };
    }
}

fn pick(
    handle: *mut WindowCloseSelection,
    shown: u32,
    previous: &[u32],
    members: &[u32],
    orders: &[&[u32]],
) -> u32 {
    let flat: Vec<u32> = orders.iter().flat_map(|order| order.iter().copied()).collect();
    let lengths: Vec<u32> = orders.iter().map(|order| order.len() as u32).collect();
    let close = CmuxWindowClosePick {
        shown,
        previous: previous.as_ptr(),
        previous_count: previous.len(),
        members: members.as_ptr(),
        member_count: members.len(),
        orders: flat.as_ptr(),
        order_lengths: lengths.as_ptr(),
        order_count: lengths.len(),
    };
    unsafe { cmux_window_close_selection_pick(handle, &close) }
}

fn kept(current: u32, members: &[u32], preferred: &[u32]) -> u32 {
    unsafe {
        cmux_window_close_selection_kept(
            current,
            members.as_ptr(),
            members.len(),
            preferred.as_ptr(),
            preferred.len(),
        )
    }
}

/// One module name in each test file of this change, so one test-name
/// filter (`window_close_selection::`) runs them all.
mod window_close_selection {
    use super::*;

    /// The create rule, all 16 combinations of its four facts. It replaces the
    /// macOS app's `WorkspaceSpawn.quickOpener(setting:)`: nil unless
    /// `opensNewTabPage`, `ActionRunScope.isPersonsAction()` and
    /// `ActionRunScope.viewChangeAllowed()`; then `!setting.placesAfterCurrent`
    /// (true: the quick look-up; false: lasts as a link tab's).
    #[test]
    fn the_create_rule_for_all_sixteen_combinations() {
        for bits in 0u8..16 {
            let (page, person, view, after) = (bits & 1, bits & 2, bits & 4, bits & 8);
            let wanted = match (page != 0 && person != 0 && view != 0, after != 0) {
                (false, _) => RELATION_NONE,
                (true, true) => RELATION_TASK,
                (true, false) => RELATION_QUICK,
            };
            let relation = cmux_window_close_selection_relation(page, person, view, after);
            assert_eq!(relation, wanted, "page {page} person {person} view {view} after {after}");
        }
        assert_eq!((RELATION_NONE, RELATION_QUICK, RELATION_TASK), (0, 1, 2));
    }

    #[test]
    fn a_task_create_returns_to_its_opener_and_a_visit_elsewhere_ends_it() {
        let state = Handle::new();
        let rows = [A, B, N, C, D];
        assert!(state.is_empty() && !state.holds_ids());
        state.expect(N, W, RELATION_TASK);
        assert!(state.is_empty() && state.holds_ids());
        state.shown(N, B, W, true);
        assert!(!state.is_empty());
        assert_eq!(state.pick(N, &rows, &[A, B, C, D], &[&rows]), B);
        state.shown(D, N, W, true);
        assert!(state.is_empty() && !state.holds_ids());
        assert_eq!(state.pick(N, &rows, &[A, B, C, D], &[&rows]), C);
    }

    #[test]
    fn a_quick_create_ends_on_any_visit_and_a_none_create_makes_no_relation() {
        let state = Handle::new();
        let rows = [A, B, C, N];
        state.make(N, A, RELATION_QUICK);
        assert_eq!(state.pick(N, &rows, &[A, B, C], &[&rows]), A);
        state.shown(A, N, W, false);
        assert!(state.is_empty() && !state.holds_ids());
        for relation in [RELATION_NONE, 3, u8::MAX] {
            state.make(N, A, relation);
            assert!(state.is_empty() && !state.holds_ids(), "relation {relation}");
        }
        assert_eq!(state.pick(N, &rows, &[A, B, C], &[&rows]), C);
    }

    #[test]
    fn left_ends_the_relation_and_renamed_moves_it() {
        let state = Handle::new();
        state.make(N, B, RELATION_TASK);
        state.left(N);
        assert!(state.is_empty() && !state.holds_ids());
        state.expect(N, W, RELATION_TASK);
        unsafe { cmux_window_close_selection_renamed(state.0, W, V) };
        state.shown(N, B, W, true);
        assert!(state.is_empty(), "the create followed its window to its new identity");
        state.expect(N, W, RELATION_TASK);
        unsafe { cmux_window_close_selection_renamed(state.0, W, V) };
        state.shown(N, B, V, true);
        assert!(!state.is_empty());
    }

    /// The pick prepares its own inputs: an opener no row lists (the tile `P`)
    /// is picked, and a workspace no row lists yet is picked with the opener
    /// rank. A close of several rows is the same call.
    #[test]
    fn the_pick_takes_raw_orders_and_a_close_of_several_rows() {
        let state = Handle::new();
        let rows = [A, B, N, C];
        state.make(N, P, RELATION_TASK);
        assert_eq!(state.pick(N, &[A, B, N, C, P], &[A, B, C, P], &[&rows, &rows]), P);
        state.left(N);
        state.make(N, B, RELATION_TASK);
        assert_eq!(state.pick(N, &[A, B, C, N], &[A, B, C], &[&[A, B, C], &[A, B, C]]), B);
        assert_eq!(state.pick(N, &[A, B, C, N], &[A, B, C], &[]), B);
        // a b c d n*, Close Below on c closes d and n: the opener of n.
        let five = [A, B, C, D, N];
        assert_eq!(state.pick(N, &five, &[A, B, C], &[&five]), B);
        // The opener closes with it: the row above the last row.
        assert_eq!(state.pick(N, &five, &[A, C, D], &[&five]), D);
    }

    /// The press of a close keeps a quick relation: the cancelled close shows
    /// the row again with its opener.
    #[test]
    fn a_quick_relation_outlives_the_press_of_a_cancelled_close() {
        let state = Handle::new();
        let rows = [A, B, C, N];
        state.make(N, A, RELATION_QUICK);
        assert_eq!(state.pick(N, &rows, &[A, B, C], &[&rows]), A);
        state.press(N, A, &[A, B, C]);
        assert!(!state.is_empty(), "the press of a close ended the quick relation");
        state.shown(N, A, W, true);
        assert_eq!(state.pick(N, &rows, &[A, B, C], &[&rows]), A);
        state.left(N);
        assert!(state.is_empty() && !state.holds_ids());
    }

    /// A repair's selection is the close's, whatever the window reports; a
    /// workspace the person moved in is theirs only when the caller says so.
    #[test]
    fn only_the_caller_makes_a_preferred_selection_a_gesture() {
        for gesture in [0u8, 1] {
            let state = Handle::new();
            let (members, preferred) = ([A, B, N, C, D], [D]);
            state.make(N, B, RELATION_TASK);
            assert_eq!(kept(N, &members, &preferred), D);
            let repair = CmuxWindowCloseRepair {
                shown: N,
                pick: D,
                gesture,
                pressed: 0,
                members: members.as_ptr(),
                member_count: members.len(),
                preferred: preferred.as_ptr(),
                preferred_count: preferred.len(),
            };
            unsafe { cmux_window_close_selection_repair_begin(state.0, &repair) };
            assert!(state.holds_ids());
            state.shown(D, N, W, true);
            unsafe { cmux_window_close_selection_repair_end(state.0) };
            assert_eq!(state.is_empty(), gesture != 0, "gesture {gesture}");
        }
    }

    #[test]
    fn kept_is_the_first_preferred_member_else_a_current_member_else_none() {
        assert_eq!(kept(B, &[A, B, C], &[D, C]), C);
        assert_eq!(kept(B, &[A, B, C], &[D]), B);
        assert_eq!(kept(B, &[A, B, C], &[]), B);
        assert_eq!(kept(N, &[A, B, C], &[]), NONE);
        assert_eq!(kept(NONE, &[A, B, C], &[]), NONE);
        assert_eq!(kept(A, &[], &[]), NONE);
        let none = unsafe { cmux_window_close_selection_kept(A, null(), 3, null(), 0) };
        assert_eq!(none, NONE);
        let one = [A];
        let none = unsafe { cmux_window_close_selection_kept(A, one.as_ptr(), 1, null(), 2) };
        assert_eq!(none, NONE);
        let empty = unsafe { cmux_window_close_selection_kept(A, null(), 0, null(), 0) };
        assert_eq!(empty, NONE);
    }

    #[test]
    fn a_null_handle_holds_nothing_and_picks_by_position() {
        let none: *mut WindowCloseSelection = null_mut();
        unsafe {
            cmux_window_close_selection_free(none);
            assert_eq!(cmux_window_close_selection_is_empty(none), 1);
            assert_eq!(cmux_window_close_selection_holds_ids(none), 0);
            cmux_window_close_selection_expect(none, N, W, RELATION_TASK);
            cmux_window_close_selection_shown(none, N, B, W, 1);
            cmux_window_close_selection_left(none, N);
            cmux_window_close_selection_renamed(none, W, V);
            cmux_window_close_selection_repair_begin(none, null());
            cmux_window_close_selection_repair_end(none);
        }
        let rows = [A, B, N, C];
        assert_eq!(pick(none, N, &rows, &[A, B, C], &[&rows]), C);
        assert_eq!(pick(none, C, &[A, B, C], &[A, B], &[]), B);
    }

    #[test]
    fn a_none_id_changes_nothing() {
        let state = Handle::new();
        state.expect(NONE, W, RELATION_TASK);
        state.expect(N, NONE, RELATION_TASK);
        assert!(!state.holds_ids());
        state.make(N, B, RELATION_TASK);
        state.shown(NONE, N, W, true);
        state.shown(D, N, NONE, true);
        state.left(NONE);
        unsafe {
            cmux_window_close_selection_renamed(state.0, NONE, V);
            cmux_window_close_selection_renamed(state.0, W, NONE);
        }
        let rows = [A, B, N, C];
        assert_eq!(state.pick(N, &rows, &[A, B, C], &[&rows]), B);
        // Nothing was shown: the first member. No member: none.
        assert_eq!(state.pick(NONE, &rows, &[A, B, C], &[&rows]), A);
        assert_eq!(state.pick(N, &rows, &[], &[&rows]), NONE);
        // A create shown by a window that showed nothing makes no relation.
        state.left(N);
        state.expect(N, W, RELATION_TASK);
        state.shown(N, NONE, W, true);
        assert!(state.is_empty() && !state.holds_ids());
    }

    #[test]
    fn a_null_struct_or_array_of_the_pick_gives_none() {
        let state = Handle::new();
        let rows = [A, B, N, C];
        let left = [A, B, C];
        let lengths = [4u32];
        state.make(N, B, RELATION_TASK);
        assert_eq!(unsafe { cmux_window_close_selection_pick(state.0, null()) }, NONE);
        let good = || CmuxWindowClosePick {
            shown: N,
            previous: rows.as_ptr(),
            previous_count: rows.len(),
            members: left.as_ptr(),
            member_count: left.len(),
            orders: rows.as_ptr(),
            order_lengths: lengths.as_ptr(),
            order_count: 1,
        };
        assert_eq!(unsafe { cmux_window_close_selection_pick(state.0, &good()) }, B);
        let broken = [
            CmuxWindowClosePick { previous: null(), ..good() },
            CmuxWindowClosePick { members: null(), ..good() },
            CmuxWindowClosePick { orders: null(), ..good() },
            CmuxWindowClosePick { order_lengths: null(), ..good() },
        ];
        for close in &broken {
            assert_eq!(unsafe { cmux_window_close_selection_pick(state.0, close) }, NONE);
            assert_eq!(unsafe { cmux_window_close_selection_pick(null_mut(), close) }, NONE);
        }
        // Empty arrays with null pointers are empty arrays.
        let empty = CmuxWindowClosePick {
            previous: null(),
            previous_count: 0,
            orders: null(),
            order_lengths: null(),
            order_count: 0,
            ..good()
        };
        assert_eq!(unsafe { cmux_window_close_selection_pick(state.0, &empty) }, A);
        // The relation is still there.
        assert_eq!(unsafe { cmux_window_close_selection_pick(state.0, &good()) }, B);
    }

    /// A null repair or a null array still starts a repair, so each begin has
    /// its end; an end with no repair running changes nothing.
    #[test]
    fn a_repair_with_a_null_struct_or_array_still_nests() {
        let state = Handle::new();
        unsafe { cmux_window_close_selection_repair_end(state.0) };
        assert!(!state.holds_ids());
        let broken = CmuxWindowCloseRepair {
            shown: N,
            pick: B,
            gesture: 1,
            pressed: 1,
            members: null(),
            member_count: 3,
            preferred: null(),
            preferred_count: 2,
        };
        unsafe {
            cmux_window_close_selection_repair_begin(state.0, null());
            cmux_window_close_selection_repair_begin(state.0, &broken);
        }
        assert!(state.holds_ids());
        unsafe { cmux_window_close_selection_repair_end(state.0) };
        assert!(state.holds_ids());
        unsafe { cmux_window_close_selection_repair_end(state.0) };
        assert!(!state.holds_ids());
    }
}
