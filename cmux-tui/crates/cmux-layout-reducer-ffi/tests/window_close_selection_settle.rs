//! The settle of the close-selection state of the windows, by question and
//! answer (`cmux_window_close_selection_settle_questions`, `_settle`): Rust
//! names the workspaces and windows it must know about, the app answers
//! with plain arrays, Rust decides who leaves the state.

use cmux_layout_reducer_ffi::focus::NONE;
use cmux_layout_reducer_ffi::window_close_selection::{
    CmuxWindowCloseSettle, RELATION_TASK, WindowCloseSelection, cmux_window_close_selection_expect,
    cmux_window_close_selection_free, cmux_window_close_selection_holds_ids,
    cmux_window_close_selection_is_empty, cmux_window_close_selection_new,
    cmux_window_close_selection_settle, cmux_window_close_selection_settle_questions,
    cmux_window_close_selection_shown,
};
use std::ptr::{null, null_mut};

const A: u32 = 0;
const B: u32 = 1;
const M: u32 = 2;
const N: u32 = 3;
const W: u32 = 0;
const V: u32 = 1;
/// A value no call writes.
const UNTOUCHED: u32 = 77;

struct Handle(*mut WindowCloseSelection);

impl Drop for Handle {
    fn drop(&mut self) {
        unsafe { cmux_window_close_selection_free(self.0) };
    }
}

/// The two full counts of the settle's questions, with no array to write to.
fn counts(handle: *mut WindowCloseSelection, window: u32, capacity: usize) -> (usize, usize) {
    let mut windows = usize::MAX;
    let none = null_mut();
    let workspaces = unsafe {
        cmux_window_close_selection_settle_questions(
            handle,
            window,
            none,
            none,
            capacity,
            &mut windows,
        )
    };
    (workspaces, windows)
}

/// What the settle of a window asks: the workspaces and the windows written
/// (sorted), and the two full counts.
struct Asked {
    workspaces: Vec<u32>,
    windows: Vec<u32>,
    workspace_count: usize,
    window_count: usize,
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

    /// A person's New Workspace in `window`, shown at once.
    fn make(&self, new: u32, old: u32, window: u32) {
        unsafe {
            cmux_window_close_selection_expect(self.0, new, window, RELATION_TASK);
            cmux_window_close_selection_shown(self.0, new, old, window, 1);
        }
    }

    fn questions(&self, window: u32, capacity: usize) -> Asked {
        let mut workspaces = vec![UNTOUCHED; capacity + 2];
        let mut windows = vec![UNTOUCHED; capacity + 2];
        let mut window_count = usize::MAX;
        let workspace_count = unsafe {
            cmux_window_close_selection_settle_questions(
                self.0,
                window,
                workspaces.as_mut_ptr(),
                windows.as_mut_ptr(),
                capacity,
                &mut window_count,
            )
        };
        // Nothing is written past `capacity`, nor past the count.
        let written = |ids: &[u32], count: usize| {
            let (head, tail) = ids.split_at(count.min(capacity));
            assert!(tail.iter().all(|id| *id == UNTOUCHED), "a write past the capacity: {ids:?}");
            let mut head = head.to_vec();
            head.sort_unstable();
            head
        };
        Asked {
            workspaces: written(&workspaces, workspace_count),
            windows: written(&windows, window_count),
            workspace_count,
            window_count,
        }
    }

    /// Answers the settle of `window`: `listed` is (workspace, the window
    /// that lists it or `NONE`, claimed), `windows` is (window, registered).
    fn settle(&self, window: u32, listed: &[(u32, u32, u8)], windows: &[(u32, u8)]) {
        let workspaces: Vec<u32> = listed.iter().map(|answer| answer.0).collect();
        let owners: Vec<u32> = listed.iter().map(|answer| answer.1).collect();
        let claimed: Vec<u8> = listed.iter().map(|answer| answer.2).collect();
        let ids: Vec<u32> = windows.iter().map(|answer| answer.0).collect();
        let exists: Vec<u8> = windows.iter().map(|answer| answer.1).collect();
        let answers = CmuxWindowCloseSettle {
            window,
            workspaces: workspaces.as_ptr(),
            owners: owners.as_ptr(),
            claimed: claimed.as_ptr(),
            workspace_count: workspaces.len(),
            windows: ids.as_ptr(),
            exists: exists.as_ptr(),
            window_count: ids.len(),
        };
        unsafe { cmux_window_close_selection_settle(self.0, &answers) };
    }
}

/// One module name in each test file of this change, so one test-name
/// filter (`window_close_selection::`) runs them all.
mod window_close_selection {
    use super::*;

    /// With nothing held the question lists are empty, nothing is written, and
    /// the app makes no second call (826 workspaces or 3: no member is read).
    #[test]
    fn with_nothing_held_there_is_no_question() {
        let state = Handle::new();
        unsafe { cmux_window_close_selection_shown(state.0, B, A, W, 1) };
        let asked = state.questions(W, 4);
        assert_eq!((asked.workspace_count, asked.window_count), (0, 0));
        assert!(asked.workspaces.is_empty() && asked.windows.is_empty());
        assert_eq!(counts(state.0, W, 0), (0, 0));
        // A null handle holds nothing; a null count pointer is not written.
        assert_eq!(counts(null_mut(), W, 9), (0, 0));
        let none = null_mut();
        let asked = unsafe {
            cmux_window_close_selection_settle_questions(state.0, W, none, none, 0, null_mut())
        };
        assert_eq!(asked, 0);
        // A settle with nothing held reads no array.
        state.settle(W, &[], &[]);
        assert!(state.is_empty() && !state.holds_ids());
    }

    /// One relation: the settle asks about its two workspaces only. A workspace
    /// another window lists now (moved) leaves the state.
    #[test]
    fn a_relation_asks_about_its_two_workspaces_and_a_moved_one_leaves() {
        let state = Handle::new();
        state.make(N, B, W);
        let asked = state.questions(W, 4);
        assert_eq!((asked.workspace_count, asked.window_count), (2, 0));
        assert_eq!(asked.workspaces, [B, N]);
        // Still listed by its window: the relation stays (a row hidden at the
        // press of a close that can still be cancelled).
        state.settle(W, &[(B, W, 0), (N, W, 0)], &[]);
        assert!(!state.is_empty());
        state.settle(W, &[(B, W, 0), (N, V, 0)], &[]);
        assert!(state.is_empty() && !state.holds_ids());
    }

    /// A capacity that is too small: the full counts come back, the arrays hold
    /// the first `capacity` ids and nothing is written past them, and the state
    /// does not change, so the app calls again with larger arrays.
    #[test]
    fn a_capacity_that_is_too_small_returns_the_needed_counts() {
        let state = Handle::new();
        state.make(N, B, W);
        unsafe { cmux_window_close_selection_expect(state.0, M, V, RELATION_TASK) };
        let small = state.questions(W, 1);
        assert_eq!((small.workspace_count, small.window_count), (2, 1));
        assert_eq!(small.workspaces.len(), 1);
        assert!(small.workspaces == [B] || small.workspaces == [N]);
        assert_eq!(small.windows, [V]);
        let zero = state.questions(W, 0);
        assert_eq!((zero.workspace_count, zero.window_count), (2, 1));
        assert!(zero.workspaces.is_empty() && zero.windows.is_empty());
        // Null arrays: the counts only.
        assert_eq!(counts(state.0, W, 8), (2, 1));
        let full = state.questions(W, 2);
        assert_eq!((full.workspaces, full.windows), (vec![B, N], vec![V]));
        // Seen from the other window: its create, and window W.
        let other = state.questions(V, 2);
        assert_eq!((other.workspaces, other.windows), (vec![M], vec![W]));
    }

    /// The relations and creates of a window that is not registered any more
    /// leave; those of a registered one stay.
    #[test]
    fn the_workspaces_of_a_window_that_is_gone_leave() {
        let state = Handle::new();
        state.make(N, B, V);
        unsafe { cmux_window_close_selection_expect(state.0, M, V, RELATION_TASK) };
        state.settle(W, &[], &[(V, 1)]);
        assert!(!state.is_empty());
        assert_eq!(state.questions(V, 4).workspaces, [B, M, N]);
        state.settle(W, &[], &[(V, 0)]);
        assert!(state.is_empty() && !state.holds_ids());
    }

    /// A create its window waits for (not listed yet, claimed) stays; one the
    /// window lists and did not show, and one that failed, get no opener.
    #[test]
    fn a_waiting_create_stays_and_a_listed_or_failed_one_leaves() {
        let state = Handle::new();
        unsafe { cmux_window_close_selection_expect(state.0, M, W, RELATION_TASK) };
        assert_eq!(state.questions(W, 4).workspaces, [M]);
        state.settle(W, &[(M, NONE, 1)], &[]);
        assert!(state.holds_ids());
        state.settle(W, &[(M, W, 1)], &[]);
        assert!(!state.holds_ids());
        unsafe { cmux_window_close_selection_expect(state.0, M, W, RELATION_TASK) };
        state.settle(W, &[(M, NONE, 0)], &[]);
        assert!(!state.holds_ids());
    }

    /// A null struct, a null array with a nonzero count and a none window
    /// change nothing; a question with no answer reads as listed by no window.
    #[test]
    fn the_guards_of_the_settle() {
        let state = Handle::new();
        state.make(N, B, W);
        let ids = [B, N];
        let owners = [W, V];
        let claimed = [0u8, 0];
        let good = |window: u32| CmuxWindowCloseSettle {
            window,
            workspaces: ids.as_ptr(),
            owners: owners.as_ptr(),
            claimed: claimed.as_ptr(),
            workspace_count: 2,
            windows: null(),
            exists: null(),
            window_count: 0,
        };
        let broken = [
            good(NONE),
            CmuxWindowCloseSettle { workspaces: null(), ..good(W) },
            CmuxWindowCloseSettle { owners: null(), ..good(W) },
            CmuxWindowCloseSettle { claimed: null(), ..good(W) },
            CmuxWindowCloseSettle { window_count: 1, ..good(W) },
        ];
        unsafe {
            cmux_window_close_selection_settle(state.0, null());
            cmux_window_close_selection_settle(null_mut(), &good(W));
            for answers in &broken {
                cmux_window_close_selection_settle(state.0, answers);
            }
        }
        assert!(!state.is_empty());
        assert_eq!(state.questions(NONE, 4).workspace_count, 0);
        // No answer for "n" and "b": listed by no window, so their relation ends.
        state.settle(W, &[], &[]);
        assert!(state.is_empty() && !state.holds_ids());
    }
}
