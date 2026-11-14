//! REVIEW2, NOT FOR MERGE. Hostile tests of the second reviewer of PR 42694.
//!
//! Each test asks one question that the PR's own tests do not ask:
//! - a real daemon start (a file registry, not a lost fold), a person's change BEFORE the first
//!   part with the debug cross-check on, then the parts: is a value left for a full projection,
//!   and does a second start restore the same session;
//! - the worker on its own thread WHILE a person creates terminals;
//! - a close and a create BETWEEN two parts;
//! - a close and a create after a lost fold with the debug cross-check ON (the PR's tests turn
//!   it off for these two).

use super::super::workspace_close_cost::session_in;
use super::super::workspaces::{assert_journal_states_the_rows, assert_journal_states_the_session};
use super::super::*;
use super::lost_fold_journal::{
    changes_after, full_projections, lose_the_fold, new_root, restate, workspace_at,
};
use crate::WorkspaceId;
use crate::mux::column_move::ColumnMoveDirection;
use crate::mux::resource_content::without_crosscheck;
use crate::mux::startup_restore::restate_parts::{PartStep, holding_the_parts};

fn whole_workspaces(mux: &Mux) -> usize {
    mux.workspace_registry.lock().unwrap().whole_workspaces_for_test()
}

/// After the parts, a full projection states only what a second full projection states too.
fn assert_a_full_projection_states_nothing_new(mux: &Arc<Mux>, key: &str) {
    let revision = mux.with_state(|state| state.resource_revision);
    without_crosscheck(|| restate(mux, &format!("{key}-first")));
    let first = changes_after(mux, revision);
    let revision = mux.with_state(|state| state.resource_revision);
    without_crosscheck(|| restate(mux, &format!("{key}-second")));
    let second = changes_after(mux, revision);
    assert_eq!(
        first, second,
        "REVIEW2: a full projection after the parts stated a value they left"
    );
}

/// For each workspace its name and, for each screen, the count of columns and the sorted tab
/// counts of its panes.
fn tree(mux: &Mux) -> Vec<(String, Vec<(usize, Vec<usize>)>)> {
    mux.with_state(|state| {
        state
            .workspaces
            .iter()
            .map(|workspace| {
                let screens = workspace
                    .screens
                    .iter()
                    .map(|screen| {
                        let mut tabs = screen
                            .root
                            .pane_ids_vec()
                            .iter()
                            .map(|pane| state.panes[pane].tabs.len())
                            .collect::<Vec<usize>>();
                        tabs.sort_unstable();
                        (screen.layout_columns.len(), tabs)
                    })
                    .collect::<Vec<(usize, Vec<usize>)>>();
                (workspace.name.to_string(), screens)
            })
            .collect()
    })
}

/// A stored session of 10 workspaces `w0`..`w9`. `w2` has two columns: its first pane, and
/// right of it a pane with two tabs. The daemon that wrote it is shut down.
fn stored_session(session: &str, root: &std::path::Path) {
    let mux = open_persistent_test_mux(session, root);
    for index in 0..10 {
        mux.new_workspace(Some(format!("w{index}")), Some((80, 24))).unwrap();
    }
    let left = mux.with_state(|state| state.workspaces[2].screens[0].active_pane);
    let created = mux.new_pane_right(left, 0.5, Some((38, 22))).unwrap();
    let right = mux.with_state(|state| state.pane_of(created.id)).expect("the new pane");
    mux.new_tab(Some(right), None, Some((38, 22))).unwrap();
    mux.select_workspace(Some(1), None);
    mux.shutdown();
}

struct Restored {
    mux: Arc<Mux>,
    /// The workspace `w2`.
    third: WorkspaceId,
    /// The pane of `w2` that has two tabs.
    right: PaneId,
    /// The second tab of `right`.
    tab: SurfaceId,
}

/// The second daemon of the stored session, with its parts held back.
fn reopened_holding_the_parts(session: &str, root: &std::path::Path) -> Restored {
    let mux = holding_the_parts(|| open_persistent_test_mux(session, root));
    mux.stop_journal_maintenance();
    let found = mux.with_state(|state| {
        let workspace = state.workspaces.iter().find(|workspace| workspace.name == "w2")?;
        let screen = workspace.screens.first()?;
        let right = screen
            .root
            .pane_ids_vec()
            .into_iter()
            .find(|pane| state.panes[pane].tabs.len() == 2)?;
        let tab = *state.panes[&right].tabs.get(1)?;
        Some((workspace.id, right, tab, state.workspaces.len(), screen.layout_columns.len()))
    });
    let (third, right, tab, workspaces, columns) = found
        .expect("REVIEW2 PRECONDITION (the restore, not the parts): no pane with two tabs in w2");
    assert_eq!(workspaces, 10, "REVIEW2 PRECONDITION (the restore, not the parts): workspaces");
    assert_eq!(columns, 2, "REVIEW2 PRECONDITION (the restore, not the parts): columns of w2");
    Restored { mux, third, right, tab }
}

/// The parts of the start, then: no part failed, the journal states the rows, a full projection
/// finds nothing left, and a third daemon restores the same tree.
fn assert_the_parts_and_a_next_start_keep_the_session(
    restored: Restored,
    session: &str,
    root: &std::path::Path,
    full: u64,
    key: &str,
) {
    let mux = &restored.mux;
    let tally = mux.restate_session_in_parts().unwrap();
    assert_eq!(full_projections(mux), full, "REVIEW2: a part ran a full projection");
    assert_eq!(
        (tally.failed, tally.skipped),
        (0, 0),
        "REVIEW2: a part of a real start was not stated: {tally:?}"
    );
    assert_journal_states_the_rows(mux);
    assert_a_full_projection_states_nothing_new(mux, key);
    let before = tree(mux);
    mux.shutdown();
    drop(restored);

    let again = open_persistent_test_mux(session, root);
    assert_eq!(
        tree(&again),
        before,
        "REVIEW2 (NOT PROVEN to be this PR's): the next start restored another session"
    );
    assert_journal_states_the_rows(&again);
    again.shutdown();
    drop(again);
    let _ = std::fs::remove_dir_all(root);
}

/// A real start. Before the first part a person moves a column, makes a terminal and makes a
/// workspace, each with the debug cross-check on.
#[test]
fn review2_changes_before_the_parts_of_a_real_start_leave_nothing_for_a_full_projection() {
    let session = "review2-before-parts";
    let root = new_root(session);
    stored_session(session, &root);
    let restored = reopened_holding_the_parts(session, &root);
    let full = full_projections(&restored.mux);
    restored.mux.move_column_as(&Actor::Daemon, restored.right, ColumnMoveDirection::Left).unwrap();
    restored
        .mux
        .create_terminal_in_workspace(restored.third, None, None, None, Some((80, 24)))
        .unwrap();
    restored.mux.new_workspace(Some("late".into()), Some((80, 24))).unwrap();
    assert_eq!(
        full_projections(&restored.mux),
        full,
        "REVIEW2: a change before the parts ran a full projection"
    );
    assert_the_parts_and_a_next_start_keep_the_session(
        restored,
        session,
        &root,
        full,
        "review2-before-parts",
    );
}

/// A real start. Before the first part a person drags the second tab of a pane to a column of
/// its own, with the debug cross-check on.
#[test]
fn review2_a_tab_drag_before_the_parts_of_a_real_start_keeps_the_session() {
    let session = "review2-drag-before-parts";
    let root = new_root(session);
    stored_session(session, &root);
    let restored = reopened_holding_the_parts(session, &root);
    let full = full_projections(&restored.mux);
    restored.mux.move_tab_to_column(restored.tab, restored.right, None, None, None, None).unwrap();
    assert_eq!(
        full_projections(&restored.mux),
        full,
        "REVIEW2: a tab drag before the parts ran a full projection"
    );
    assert_the_parts_and_a_next_start_keep_the_session(
        restored,
        session,
        &root,
        full,
        "review2-drag-before-parts",
    );
}

/// The worker on its own thread, as a daemon runs it, WHILE a person makes 12 terminals in
/// workspaces that had a part, have none yet, or get one now.
#[test]
fn review2_creates_while_the_worker_thread_runs_leave_the_session_stated() {
    let mux = without_crosscheck(|| session_in(test_mux(), 40));
    let targets =
        [0, 5, 12, 20, 27, 33, 39, 8, 16, 24, 31, 37].map(|index| workspace_at(&mux, index).0);
    lose_the_fold(&mux);
    let full = full_projections(&mux);
    mux.startup_adoptions_released.store(true, Ordering::Release);
    let worker = mux.spawn_session_restate().expect("the worker thread did not start");
    without_crosscheck(|| {
        for target in targets {
            mux.create_terminal_in_workspace(target, None, None, None, Some((80, 24))).unwrap();
        }
    });
    worker.join().unwrap();

    assert_eq!(full_projections(&mux), full, "REVIEW2: a part or a create ran a full projection");
    let laps = mux.session_restate_laps_for_test().expect("the worker recorded no laps");
    let sum = laps
        .as_array()
        .unwrap()
        .iter()
        .find(|lap| lap["step"] == "session.restate")
        .expect("no session.restate lap")
        .clone();
    assert_eq!(sum["failed"], 0, "REVIEW2: {laps}");
    assert_eq!(sum["skipped"], 0, "REVIEW2: {laps}");
    assert_eq!(whole_workspaces(&mux), 40, "REVIEW2: workspaces that the fold holds whole: {laps}");
    assert_journal_states_the_session(&mux);
    assert_a_full_projection_states_nothing_new(&mux, "review2-worker-and-creates");
    mux.shutdown();
}

/// Between the first part and the next one a person closes a workspace that waits for its part
/// and makes a terminal in another one that waits.
#[test]
fn review2_a_close_and_a_create_between_two_parts_leave_the_session_stated() {
    let mux = without_crosscheck(|| session_in(test_mux(), 20));
    lose_the_fold(&mux);
    let full = full_projections(&mux);
    let mut parts = mux.session_restate_parts();
    let first = mux.restate_step(&mut parts, 0).unwrap();
    assert!(matches!(first, PartStep::Stated(_)), "REVIEW2: the first part: {first:?}");

    let (_, key, _) = workspace_at(&mux, 15);
    let (target, _, _) = workspace_at(&mux, 17);
    let mutation = WorkspaceMutation::daemon("review2-close-between-parts", "test").unwrap();
    without_crosscheck(|| {
        mux.close_workspace_ending_terminals(None, Some(&key), None, None, &mutation).unwrap();
        mux.create_terminal_in_workspace(target, None, None, None, Some((80, 24))).unwrap();
    });

    let mut steps = 0;
    loop {
        match mux.restate_step(&mut parts, 0).unwrap() {
            PartStep::Done => break,
            PartStep::Deferred => std::thread::sleep(std::time::Duration::from_millis(5)),
            _ => {}
        }
        steps += 1;
        assert!(steps < 800, "REVIEW2: the restatement did not end in 800 steps");
    }
    assert_eq!(full_projections(&mux), full, "REVIEW2: a part or a change ran a full projection");
    assert_eq!(whole_workspaces(&mux), 19, "REVIEW2: workspaces that the fold holds whole");
    assert_journal_states_the_session(&mux);
    assert_a_full_projection_states_nothing_new(&mux, "review2-between-parts");
    mux.shutdown();
}

/// The PR's test of a close after a lost fold turns the debug cross-check off for the close.
/// Here it is on.
#[test]
fn review2_a_workspace_close_after_a_lost_fold_passes_the_debug_cross_check() {
    let mux = without_crosscheck(|| session_in(test_mux(), 4));
    let (_, key, _) = workspace_at(&mux, 2);
    lose_the_fold(&mux);
    let full = full_projections(&mux);
    let mutation = WorkspaceMutation::daemon("review2-close-after-lost-fold", "test").unwrap();
    mux.close_workspace_ending_terminals(None, Some(&key), None, None, &mutation).unwrap();
    assert_eq!(full_projections(&mux), full, "REVIEW2: the close ran a full projection");
    assert_journal_states_the_session(&mux);
    mux.shutdown();
}

/// The PR's tests of a create before the parts turn the debug cross-check off for the create.
/// Here it is on.
#[test]
fn review2_a_create_after_a_lost_fold_passes_the_debug_cross_check() {
    let mux = without_crosscheck(|| session_in(test_mux(), 10));
    let (target, _, _) = workspace_at(&mux, 4);
    lose_the_fold(&mux);
    let full = full_projections(&mux);
    mux.create_terminal_in_workspace(target, None, None, None, Some((80, 24))).unwrap();
    assert_eq!(full_projections(&mux), full, "REVIEW2: the create ran a full projection");
    assert_journal_states_the_session(&mux);
    mux.shutdown();
}
