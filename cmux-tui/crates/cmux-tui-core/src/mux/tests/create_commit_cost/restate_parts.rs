//! The restatement of the session after a daemon start, in parts
//! (`mux/startup_restore/restate_parts.rs`).
//!
//! THE COUNTS. A part states at most 8 workspaces and runs no full projection; the parts state
//! each workspace one time; a workspace that a commit of a person stated first is left out; the
//! worker starts no part while a locker waits, at most 4 times in a row for one part; the last
//! step states each terminal that has no view.
//!
//! THE EQUIVALENCE. A part has no debug cross-check (its reference is one full projection for
//! each part). So these tests assert what the one full projection of a start gave before: after
//! the parts the journal, folded from revision 0, states the rows and the session, and a full
//! projection after the parts states nothing that a second full projection does not.
//!
//! A lost fold stands for a daemon start in the tests of an in-memory session: both leave the
//! registry with an empty fold that holds no workspace whole.

use super::super::workspace_close_cost::session_in;
use super::super::workspaces::{
    assert_journal_states_the_rows, assert_journal_states_the_session, journal_workspaces,
};
use super::super::*;
use super::lost_fold_journal::{
    changes_after, fold_is_complete, full_projections, lose_the_fold, new_root, records_after,
    restate, workspace_at, workspace_ids, workspaces_stated,
};
use crate::mux::resource_content::without_crosscheck;
use crate::mux::startup_restore::restate_parts::{
    PartStep, RESTATE_MAX_DEFERS, RESTATE_PART_WORKSPACES, holding_the_parts,
};

fn revision_of(mux: &Mux) -> u64 {
    mux.with_state(|state| state.resource_revision)
}

fn whole_workspaces(mux: &Mux) -> usize {
    mux.workspace_registry.lock().unwrap().whole_workspaces_for_test()
}

/// How many of the records state the workspace `workspace` (an upsert of its value).
fn records_that_state(records: &[Vec<(String, String, String)>], workspace: &str) -> usize {
    let value = ("upsert".to_string(), "workspace".to_string(), workspace.to_string());
    records.iter().filter(|record| record.contains(&value)).count()
}

/// BAR (a1). 20 workspaces: 3 parts of 8, 8 and 4, each ONE journal record, no full projection,
/// each workspace stated one time, and a second run states nothing.
#[test]
fn a_part_states_at_most_8_workspaces_and_runs_no_full_projection() {
    let mux = without_crosscheck(|| session_in(test_mux(), 20));
    let workspaces = workspace_ids(&mux);
    lose_the_fold(&mux);
    let (revision, full) = (revision_of(&mux), full_projections(&mux));
    let tally = mux.restate_session_in_parts().unwrap();
    assert_eq!(full_projections(&mux), full, "a part ran a full projection");
    assert_eq!(tally.skipped, 0, "{tally:?}");
    for part in &tally.parts {
        assert!(
            part.workspaces <= RESTATE_PART_WORKSPACES,
            "a part stated {} workspaces: {tally:?}",
            part.workspaces
        );
    }
    let sizes = tally.parts.iter().map(|part| part.workspaces).collect::<Vec<_>>();
    assert_eq!(sizes, [8, 8, 4], "the workspaces of each part");
    let records = records_after(&mux, revision);
    assert_eq!(records.len(), tally.parts.len(), "one journal record for each part");
    for record in &records {
        let stated = workspaces_stated(record, &workspaces);
        assert!(stated <= RESTATE_PART_WORKSPACES, "a part record states {stated} workspaces");
    }
    for workspace in &workspaces {
        assert_eq!(records_that_state(&records, workspace), 1, "workspace {workspace}");
    }
    assert_eq!(whole_workspaces(&mux), 20, "workspaces that the fold holds whole");
    assert!(!fold_is_complete(&mux), "no full projection ran, but the fold says complete");

    // The worker of a second start of the same process would find each workspace whole.
    let revision = revision_of(&mux);
    let again = mux.restate_session_in_parts().unwrap();
    assert!(again.parts.is_empty(), "the second run stated a workspace again: {again:?}");
    assert_eq!(revision_of(&mux), revision, "the second run committed a record");
    assert_eq!(full_projections(&mux), full);
    mux.shutdown();
}

/// BAR (a1), the cut. A scoped walk takes the stored and the live active workspace into its
/// scope when they differ. A part that would then state 9 workspaces gives one back.
#[test]
fn a_part_that_takes_in_the_active_workspaces_is_cut_to_8() {
    let mux = without_crosscheck(|| session_in(test_mux(), 20));
    // The store says workspace 15 is active; the live tree says workspace 3 (no commit said it).
    without_crosscheck(|| {
        mux.select_workspace(Some(15), None);
        restate(&mux, "active-15");
    });
    lose_the_fold(&mux);
    {
        let mut state = mux.state.lock().unwrap();
        state.active_workspace = 3;
    }
    let full = full_projections(&mux);
    let tally = mux.restate_session_in_parts().unwrap();
    assert_eq!(full_projections(&mux), full, "a part ran a full projection");
    let sizes = tally.parts.iter().map(|part| part.workspaces).collect::<Vec<_>>();
    assert!(
        sizes.iter().all(|size| *size <= RESTATE_PART_WORKSPACES),
        "a part stated more than 8 workspaces: {sizes:?}"
    );
    assert_eq!(sizes.iter().sum::<usize>(), 20, "the workspaces that the parts stated: {sizes:?}");
    assert_eq!(sizes.first(), Some(&8), "the first part, with both active workspaces: {sizes:?}");
    assert_eq!(whole_workspaces(&mux), 20);
    assert_journal_states_the_session(&mux);
    mux.shutdown();
}

/// A rename of the workspace at `index` in the live tree that no commit stated: the name, its
/// source and its revision, as a rename makes them (the commit's name fence refuses a name that
/// changed with no new revision).
fn drift_a_name(mux: &Mux, index: usize) {
    let mut state = mux.state.lock().unwrap();
    let workspace = &mut state.workspaces[index];
    workspace.name = "drifted".into();
    workspace.name_source = crate::resource_name::NameSource::User;
    workspace.name_revision += 1;
}

/// THE EQUIVALENCE, 1 of 2. A value of the live tree that no commit stated (as the restore of a
/// start can leave one): the parts state it, with no full projection, and the journal then
/// states the rows and the session.
#[test]
fn the_parts_leave_the_journal_equal_to_the_rows_and_the_session() {
    let mux = without_crosscheck(|| session_in(test_mux(), 12));
    let drifted = workspace_ids(&mux)[7].clone();
    lose_the_fold(&mux);
    drift_a_name(&mux, 7);
    assert_ne!(journal_workspaces(&mux)[&drifted]["name"], "drifted");
    let full = full_projections(&mux);
    let tally = mux.restate_session_in_parts().unwrap();
    assert_eq!(full_projections(&mux), full, "a part ran a full projection");
    assert_eq!(tally.skipped, 0, "{tally:?}");
    assert_eq!(journal_workspaces(&mux)[&drifted]["name"], "drifted");
    assert_journal_states_the_rows(&mux);
    assert_journal_states_the_session(&mux);
    mux.shutdown();
}

/// THE EQUIVALENCE, 2 of 2. After the parts, a full projection states only what a second full
/// projection states too: the parts left no value for it.
#[test]
fn a_full_projection_after_the_parts_states_nothing_new() {
    let mux = without_crosscheck(|| session_in(test_mux(), 12));
    lose_the_fold(&mux);
    drift_a_name(&mux, 7);
    let full = full_projections(&mux);
    mux.restate_session_in_parts().unwrap();
    assert_eq!(full_projections(&mux), full, "a part ran a full projection");

    let revision = revision_of(&mux);
    without_crosscheck(|| restate(&mux, "after-the-parts"));
    let first = changes_after(&mux, revision);
    let revision = revision_of(&mux);
    without_crosscheck(|| restate(&mux, "after-the-full-projection"));
    let second = changes_after(&mux, revision);
    assert_eq!(first, second, "the full projection after the parts stated a value they left");
    assert_journal_states_the_session(&mux);
    mux.shutdown();
}

/// A create that comes before the part of its workspace states that workspace whole in its own
/// record; the parts then leave it out and state the 9 others.
#[test]
fn a_workspace_that_its_own_commit_stated_is_left_out_by_the_parts() {
    let mux = without_crosscheck(|| session_in(test_mux(), 10));
    let (target, _, target_public) = workspace_at(&mux, 4);
    lose_the_fold(&mux);
    let full = full_projections(&mux);
    without_crosscheck(|| {
        mux.create_terminal_in_workspace(target, None, None, None, Some((80, 24))).unwrap();
    });
    assert_eq!(full_projections(&mux), full, "the create before the parts ran a full projection");
    assert_eq!(whole_workspaces(&mux), 1, "the create did not leave its workspace whole");

    let revision = revision_of(&mux);
    let tally = mux.restate_session_in_parts().unwrap();
    assert_eq!(full_projections(&mux), full, "a part ran a full projection");
    assert_eq!(tally.workspaces(), 9, "workspaces that the parts stated: {tally:?}");
    assert_eq!(
        records_that_state(&records_after(&mux, revision), &target_public),
        0,
        "a part stated the workspace that its own commit stated"
    );
    assert_eq!(whole_workspaces(&mux), 10);
    assert_journal_states_the_session(&mux);
    mux.shutdown();
}

/// D181 at a start. A new workspace that a person makes before the parts end states its own
/// value and at most the value of the workspace that the focus left; the parts state the
/// others after it.
#[test]
fn a_new_workspace_before_the_parts_end_states_at_most_2_workspace_values() {
    let session = "new-workspace-before-parts";
    let root = new_root(session);
    let mux = open_persistent_test_mux(session, &root);
    for name in ["one", "two", "three", "four"] {
        mux.new_workspace(Some(name.into()), Some((80, 24))).unwrap();
    }
    mux.shutdown();
    drop(mux);

    let reopened = holding_the_parts(|| open_persistent_test_mux(session, &root));
    reopened.stop_journal_maintenance();
    let before = workspace_ids(&reopened);
    assert_eq!(before.len(), 4);
    let (_, _, was_active) =
        workspace_at(&reopened, reopened.with_state(|state| state.active_workspace));
    let (revision, full) = (revision_of(&reopened), full_projections(&reopened));
    without_crosscheck(|| {
        reopened.create_empty_workspace(Some("made".into()), None, None).unwrap();
    });
    assert_eq!(full_projections(&reopened), full, "the new workspace ran a full projection");
    let changes = changes_after(&reopened, revision);
    let stated = before
        .iter()
        .filter(|id| changes.contains(&("upsert".into(), "workspace".into(), (*id).clone())))
        .collect::<Vec<_>>();
    assert!(
        stated.iter().all(|id| **id == was_active),
        "the record of the new workspace states a workspace that it did not change: {stated:?}"
    );
    assert!(stated.len() <= 1, "workspace values of the 4 old workspaces: {stated:?}");

    let full = full_projections(&reopened);
    reopened.restate_session_in_parts().unwrap();
    assert_eq!(full_projections(&reopened), full, "a part ran a full projection");
    assert_journal_states_the_rows(&reopened);
    reopened.shutdown();
    drop(reopened);
    let _ = std::fs::remove_dir_all(&root);
}

/// D171. With a locker that waits for the registry, no part starts: 4 times in a row for one
/// part, and then the part runs. The count starts again for the next part.
#[test]
fn the_worker_starts_no_part_while_a_waiter_is_counted_and_at_most_4_times_for_one_part() {
    let mux = without_crosscheck(|| session_in(test_mux(), 10));
    lose_the_fold(&mux);
    let mut parts = mux.session_restate_parts();
    let revision = revision_of(&mux);
    for round in 0..RESTATE_MAX_DEFERS {
        let step = mux.restate_step(&mut parts, 1).unwrap();
        assert_eq!(step, PartStep::Deferred, "round {round} with a waiter");
    }
    assert_eq!(revision_of(&mux), revision, "a part started while a waiter was counted");
    assert!(parts.tally.parts.is_empty(), "{:?}", parts.tally);

    let step = mux.restate_step(&mut parts, 1).unwrap();
    assert!(matches!(step, PartStep::Stated(_)), "the fifth time the part must run: {step:?}");
    assert_eq!(parts.tally.parts.len(), 1);
    assert_eq!(parts.tally.defers, RESTATE_MAX_DEFERS);

    let step = mux.restate_step(&mut parts, 3).unwrap();
    assert_eq!(step, PartStep::Deferred, "the next part with 3 waiters");
    let step = mux.restate_step(&mut parts, 0).unwrap();
    assert!(matches!(step, PartStep::Stated(_)), "no waiter: the part runs at once: {step:?}");
    assert_eq!(parts.tally.workspaces(), 10);
    mux.shutdown();
}

/// D171, the count that the worker reads. `waiters()` counts a locker from its call to its
/// take: 0 with no locker, 1 while a second thread waits for a held mutex, 0 again after that
/// thread has the lock.
#[test]
fn waiters_counts_a_locker_that_waits_and_no_locker_that_holds() {
    let mutex = Arc::new(SignaledMutex::new(0u32));
    assert_eq!(mutex.waiters(), 0);
    let guard = mutex.lock().unwrap();
    assert_eq!(mutex.waiters(), 0, "the holder is no waiter");
    let second = mutex.clone();
    let waiting = std::thread::spawn(move || {
        let mut guard = second.lock().unwrap();
        *guard += 1;
    });
    let deadline = Instant::now() + Duration::from_secs(10);
    while mutex.waiters() == 0 && Instant::now() < deadline {
        std::thread::yield_now();
    }
    assert_eq!(mutex.waiters(), 1, "the second locker waits and is not counted");
    drop(guard);
    waiting.join().unwrap();
    assert_eq!(mutex.waiters(), 0, "a locker that has the lock is no waiter");
    assert_eq!(*mutex.lock().unwrap(), 1);
}

/// The worker on its own thread, as a daemon runs it: it waits for ready, states the session in
/// parts and records its laps. BAR (a3) by the laps: the worker stays away from the locks, in
/// sum, at least as long as its parts held them.
#[test]
fn the_worker_thread_states_the_session_and_records_its_laps() {
    let mux = without_crosscheck(|| session_in(test_mux(), 10));
    lose_the_fold(&mux);
    assert!(mux.session_restate_laps_for_test().is_none());
    let full = full_projections(&mux);
    mux.startup_adoptions_released.store(true, Ordering::Release);
    let worker = mux.spawn_session_restate().expect("the worker thread did not start");
    worker.join().unwrap();

    assert_eq!(full_projections(&mux), full, "the worker ran a full projection");
    assert_eq!(whole_workspaces(&mux), 10);
    let laps = mux.session_restate_laps_for_test().expect("the worker recorded no laps");
    let laps = laps.as_array().unwrap();
    let steps = laps.iter().map(|lap| lap["step"].as_str().unwrap()).collect::<Vec<_>>();
    assert_eq!(
        steps,
        [
            "session.restate.wait",
            "session.restate.part",
            "session.restate.part",
            "session.restate.pause",
            "session.restate"
        ],
        "{laps:?}"
    );
    assert_eq!(laps[1]["workspaces"], 8, "{laps:?}");
    assert_eq!(laps[2]["workspaces"], 2, "{laps:?}");
    let (pause, sum) = (&laps[3], &laps[4]);
    assert_eq!(sum["parts"], 2, "{sum}");
    assert_eq!(sum["skipped"], 0, "{sum}");
    assert_eq!(
        sum["values"].as_u64().unwrap(),
        laps[1]["values"].as_u64().unwrap() + laps[2]["values"].as_u64().unwrap(),
        "{laps:?}"
    );
    assert!(
        pause["ms"].as_f64().unwrap() >= sum["ms"].as_f64().unwrap(),
        "the worker paused less than its parts held the locks: {laps:?}"
    );
    assert_journal_states_the_session(&mux);
    mux.shutdown();
}

/// The last step. A terminal with no view (its workspace was closed, the terminal runs on) is
/// in no workspace, so no part states it: one more scoped commit does, one time.
#[test]
fn the_last_step_states_each_terminal_that_has_no_view_one_time() {
    let mux = test_mux();
    mux.new_workspace(Some("kept".into()), Some((80, 24))).unwrap();
    let source = mux.new_workspace(Some("closed".into()), Some((80, 24))).unwrap();
    let terminal = source
        .terminal_public_id()
        .expect("a hosted terminal has a public id")
        .as_str()
        .to_string();
    let workspace = mux.surface_workspace(source.id).expect("the workspace of the terminal");
    assert!(mux.close_workspace_at_revision(workspace, None).unwrap().is_some());
    assert!(mux.with_state(|state| state.pane_of(source.id).is_none()), "it has a view");

    lose_the_fold(&mux);
    let (revision, full) = (revision_of(&mux), full_projections(&mux));
    let tally = mux.restate_session_in_parts().unwrap();
    assert_eq!(full_projections(&mux), full, "a step ran a full projection");
    let value = ("upsert".to_string(), "terminal".to_string(), terminal);
    let records = records_after(&mux, revision);
    assert_eq!(
        records.iter().filter(|record| record.contains(&value)).count(),
        1,
        "records that state the terminal with no view: {records:?}"
    );
    assert_eq!(tally.parts.len(), 2, "the part of the workspace and the last step: {tally:?}");

    // A second run does not state it again: the journal holds its value.
    mux.restate_session_in_parts().unwrap();
    let records = records_after(&mux, revision);
    assert_eq!(
        records.iter().filter(|record| record.contains(&value)).count(),
        1,
        "the second run stated the terminal with no view again: {records:?}"
    );
    assert_eq!(full_projections(&mux), full);
    mux.shutdown();
}

/// A part that the registry refuses keeps only its own workspace out. 12 workspaces; the live
/// name of one changed with no new name revision, which the fence of the stored name refuses
/// (`workspace_name_store::fence_stored_name`). The 8 workspaces of its part go back and each
/// gets a part of its own: 7 are stated, the one stays not whole, and the part of the last 4
/// runs after it. Before, the first refused part stopped the restatement, and the rows of each
/// workspace after it stayed as the start left them.
#[test]
fn a_part_that_the_registry_refuses_keeps_only_its_own_workspace_out() {
    let mux = without_crosscheck(|| session_in(test_mux(), 12));
    let workspaces = workspace_ids(&mux);
    lose_the_fold(&mux);
    {
        let mut state = mux.state.lock().unwrap();
        state.workspaces[5].name = "no-new-revision".into();
    }
    let (revision, full) = (revision_of(&mux), full_projections(&mux));
    let tally = mux.restate_session_in_parts().expect("one refused part stopped the restatement");
    assert_eq!(full_projections(&mux), full, "a part ran a full projection");
    let sizes = tally.parts.iter().map(|part| part.workspaces).collect::<Vec<_>>();
    assert_eq!(sizes, [1, 1, 1, 1, 1, 1, 1, 4], "the workspaces of each committed part");
    let records = records_after(&mux, revision);
    for (index, workspace) in workspaces.iter().enumerate() {
        assert_eq!(
            records_that_state(&records, workspace),
            usize::from(index != 5),
            "records that state the workspace at {index}"
        );
    }
    assert_eq!(whole_workspaces(&mux), 11, "each workspace but the refused one is whole");
    mux.shutdown();
}

/// No part starts while the daemon ends terminals: each step stands back and commits nothing,
/// with no limit of times (it is not a locker that waits), and the part runs when the
/// teardown ends. The same test holds for a shutdown and a hand-off of the hosts
/// (`journal_maintenance_paused`). Before, the worker read the shutdown flag only.
#[test]
fn no_part_starts_while_the_daemon_ends_terminals() {
    let mux = without_crosscheck(|| session_in(test_mux(), 10));
    lose_the_fold(&mux);
    let mut parts = mux.session_restate_parts();
    let revision = revision_of(&mux);
    let teardown = mux.begin_terminal_teardown();
    for round in 0..RESTATE_MAX_DEFERS + 2 {
        let step = mux.restate_step(&mut parts, 0).unwrap();
        assert_eq!(step, PartStep::Deferred, "round {round} while the daemon ends terminals");
    }
    assert_eq!(revision_of(&mux), revision, "a part started while the daemon ended terminals");
    assert_eq!(parts.tally.defers, 0, "a teardown counted as a locker: {:?}", parts.tally);
    drop(teardown);
    let step = mux.restate_step(&mut parts, 0).unwrap();
    assert!(matches!(step, PartStep::Stated(_)), "after the teardown the part runs: {step:?}");
    mux.shutdown();
}
