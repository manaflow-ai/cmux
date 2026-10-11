//! A confirmed layout undo commits through unrelated commits that land
//! between its precondition read and its commit.

use super::*;

/// A confirmed undo reads the resource revision just before its commit.
/// An unrelated commit in that window (a shell's OSC 7 cwd update, a
/// rename) must not refuse the undo the user confirmed: the confirmation
/// token still fences exactly what closes (layout_undo flake, 1 of 30).
#[test]
fn confirmed_layout_undo_survives_an_unrelated_commit_before_it_commits() {
    let mux = test_mux();
    let first = mux.new_workspace(None, Some((80, 22))).unwrap();
    let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let right = mux.new_pane_right(first_pane, 0.5, Some((38, 22))).unwrap();
    let right_pane = mux.with_state(|state| state.pane_of(right.id).unwrap());
    let LayoutUndoResult::ConfirmationRequired { revision, .. } =
        mux.undo_layout(right_pane, None, false).unwrap()
    else {
        panic!("a created pane needs confirmation");
    };
    let workspace = mux.with_state(|state| state.workspaces[0].id);
    let fired = Arc::new(AtomicBool::new(false));
    *mux.layout_undo_before_commit.lock().unwrap() = Some(Arc::new({
        let mux = Arc::downgrade(&mux);
        let fired = fired.clone();
        move || {
            if !fired.swap(true, Ordering::SeqCst)
                && let Some(mux) = mux.upgrade()
            {
                assert!(mux.rename_workspace(workspace, "renamed meanwhile".into()));
            }
        }
    }));

    let result = mux.undo_layout(right_pane, Some(revision), true);
    assert!(fired.load(Ordering::SeqCst), "the unrelated commit ran before the undo commit");
    assert!(matches!(result, Ok(LayoutUndoResult::Undone { .. })), "{result:?}");
    mux.with_state(|state| assert!(!state.panes.contains_key(&right_pane)));
}
