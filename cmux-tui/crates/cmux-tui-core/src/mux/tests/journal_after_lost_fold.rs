//! What the journal states after the registry lost its fold of it.
//!
//! The registry keeps a fold of the values the journal states (`workspace_registry/public_fold.rs`)
//! so a commit can drop the values the journal has already. A daemon start and a commit whose
//! receipt did not come lose it. Before, the next create or close then ran the full projection
//! and stated every live resource of the session again. Now the fold starts again empty, the
//! commit stays scoped, and its record states the whole of its own workspace and no other.
//!
//! That full projection was also a repair: it stated again each value that a row had got with no
//! journal record of its own. So these tests assert what a reader of the journal gets (the
//! journal folded from revision 0), not only what the commit cost.

use std::collections::BTreeSet;

use super::workspace_close_cost::session_in;
use super::workspaces::{
    assert_journal_states_the_rows, assert_journal_states_the_session, journal_workspaces,
};
use super::*;
use crate::WorkspaceId;
use crate::mux::resource_content::without_crosscheck;
use crate::resource_name::NameSource;

/// One full projection commit: every live resource is stated, and the fold is complete after it.
fn restate(mux: &Arc<Mux>, key: &str) {
    let operation = "test.restate";
    let fingerprint = serde_json::json!({"operation": operation, "fixture": key});
    let expected_revision = mux.with_state(|state| state.resource_revision);
    mux.prepare_resource_effect(
        &WorkspaceMutation::daemon(key, "test").unwrap(),
        operation,
        &fingerprint,
        &serde_json::json!({}),
        None,
        Some(expected_revision),
    )
    .unwrap();
    mux.mark_resource_effect_executing(key, operation, &fingerprint).unwrap();
    mux.commit_full_resource_effect_projection(key, operation, &fingerprint, serde_json::json!({}))
        .unwrap();
}

/// The registry loses its fold, as after a commit whose receipt did not come.
fn lose_the_fold(mux: &Mux) {
    mux.workspace_registry.lock().unwrap().abandon_effect_commit();
}

/// (id, key, public id) of the workspace at `index`.
fn workspace_at(mux: &Mux, index: usize) -> (WorkspaceId, String, String) {
    mux.with_state(|state| {
        let workspace = &state.workspaces[index];
        (workspace.id, workspace.key.clone(), workspace.public_id.to_string())
    })
}

/// Public ids of the tabs under the workspace `workspace` (a public id), as the rows hold them.
fn tab_ids(mux: &Mux, workspace: &str) -> BTreeSet<String> {
    let topology = mux.workspace_registry.lock().unwrap().resource_topology_snapshot().unwrap();
    let screens = topology
        .screens
        .iter()
        .filter(|screen| screen.workspace_id.as_str() == workspace)
        .map(|screen| screen.public_id.to_string())
        .collect::<BTreeSet<_>>();
    let panes = topology
        .panes
        .iter()
        .filter(|pane| screens.contains(pane.screen_id.as_str()))
        .map(|pane| pane.public_id.to_string())
        .collect::<BTreeSet<_>>();
    topology
        .tabs
        .iter()
        .filter(|tab| panes.contains(tab.pane_id.as_str()))
        .map(|tab| tab.public_id.to_string())
        .collect()
}

/// (kind, resource, id) of each change the journal recorded after `revision`.
fn changes_after(mux: &Mux, revision: u64) -> Vec<(String, String, String)> {
    let text = |value: &Value| value.as_str().unwrap_or_default().to_string();
    mux.resource_events_after(revision)
        .unwrap()
        .batches
        .iter()
        .flat_map(|batch| batch.changes.as_array().cloned().unwrap_or_default())
        .map(|change| (text(&change["kind"]), text(&change["resource"]), text(&change["id"])))
        .collect()
}

fn full_projections(mux: &Mux) -> u64 {
    mux.resource_projection_stats().full_projections
}

/// A create after a lost fold is scoped, and its record states each tab of its own workspace
/// (the empty fold dropped none) and no tab or workspace value of another workspace.
#[test]
fn a_create_after_a_lost_fold_states_its_own_workspace_and_no_other() {
    let mux = without_crosscheck(|| session_in(test_mux(), 3));
    let ((first, _, first_public), (_, _, other_public)) =
        (workspace_at(&mux, 0), workspace_at(&mux, 2));
    let (first_tabs, other_tabs) = (tab_ids(&mux, &first_public), tab_ids(&mux, &other_public));
    assert_eq!((first_tabs.len(), other_tabs.len()), (1, 1), "one seeded terminal tab each");

    lose_the_fold(&mux);
    let (revision, full) =
        (mux.with_state(|state| state.resource_revision), full_projections(&mux));
    without_crosscheck(|| {
        mux.create_terminal_in_workspace(first, None, None, None, Some((80, 24))).unwrap();
    });
    assert_eq!(full_projections(&mux), full, "the create after a lost fold ran a full projection");
    let changes = changes_after(&mux, revision);
    for tab in &first_tabs {
        assert!(
            changes.contains(&("upsert".into(), "tab".into(), tab.clone())),
            "the record does not state tab {tab} of the create's workspace: {changes:?}"
        );
    }
    for (kind, resource, id) in &changes {
        assert!(
            !(resource == "tab" && other_tabs.contains(id)),
            "the record has a {kind} of tab {id} of another workspace"
        );
        assert!(
            !(resource == "workspace" && *id != first_public),
            "the record has a {kind} of workspace {id}, not the create's"
        );
    }
    assert_journal_states_the_session(&mux);

    // The fold holds what that record stated. The same create again, with the debug cross-check
    // on: it compares the scoped projection with the full one and refuses a difference.
    lose_the_fold(&mux);
    mux.create_terminal_in_workspace(first, None, None, None, Some((80, 24))).unwrap();
    assert_journal_states_the_session(&mux);
    mux.shutdown();
}

/// A workspace close after a lost fold is scoped: the journal deletes the closed workspace and
/// states the one after it at its new index.
#[test]
fn a_workspace_close_after_a_lost_fold_is_scoped_and_the_journal_follows() {
    let mux = without_crosscheck(|| session_in(test_mux(), 4));
    let (_, key, closed) = workspace_at(&mux, 2);
    let (_, _, later) = workspace_at(&mux, 3);

    lose_the_fold(&mux);
    let (revision, full) =
        (mux.with_state(|state| state.resource_revision), full_projections(&mux));
    let mutation = WorkspaceMutation::daemon("close-after-lost-fold", "test").unwrap();
    without_crosscheck(|| {
        mux.close_workspace_ending_terminals(None, Some(&key), None, None, &mutation).unwrap();
    });
    assert_eq!(full_projections(&mux), full, "the close after a lost fold ran a full projection");
    let changes = changes_after(&mux, revision);
    assert!(
        changes.contains(&("delete".into(), "workspace".into(), closed.clone())),
        "the record does not delete the closed workspace {closed}: {changes:?}"
    );
    let stated = journal_workspaces(&mux);
    assert!(!stated.contains_key(&closed), "the journal still states the closed workspace");
    assert_eq!(
        stated[&later]["index"], 2,
        "the workspace after the closed one: {}",
        stated[&later]
    );
    assert_journal_states_the_session(&mux);
    mux.shutdown();
}

/// Only the debug cross-check reads whether the fold holds every live resource: no create,
/// close, workspace commit or full projection does, with the fold held or lost. (The flag is
/// private to public_fold.rs and `stated_topology_value` is its one reader; this counts the
/// reads on this thread, where each commit of an in-memory session runs.)
#[test]
fn no_commit_reads_whether_the_fold_is_complete() {
    let mux = without_crosscheck(|| session_in(test_mux(), 4));
    let (first, _, _) = workspace_at(&mux, 0);
    let (_, key, _) = workspace_at(&mux, 3);
    let reads = WorkspaceRegistry::complete_reads_for_test();
    without_crosscheck(|| {
        for lost in [false, true] {
            if lost {
                lose_the_fold(&mux);
            }
            mux.create_terminal_in_workspace(first, None, None, None, Some((80, 24))).unwrap();
            mux.create_empty_workspace(Some(format!("made {lost}")), None, None).unwrap();
            assert!(mux.rename_workspace(first, format!("renamed {lost}")));
            restate(&mux, &format!("restate-{lost}"));
        }
        lose_the_fold(&mux);
        let mutation = WorkspaceMutation::daemon("close-counted", "test").unwrap();
        mux.close_workspace_ending_terminals(None, Some(&key), None, None, &mutation).unwrap();
    });
    assert_eq!(
        WorkspaceRegistry::complete_reads_for_test(),
        reads,
        "a commit read whether the fold is complete"
    );

    // The counter counts: the cross-check's question about a resource the fold does not hold
    // reads the flag one time.
    let mut registry = mux.workspace_registry.lock().unwrap();
    assert!(registry.stated_workspaces().is_some(), "the fold is not at the journal head");
    let _ = registry.stated_topology_value("workspace", "no-such-workspace");
    assert_eq!(WorkspaceRegistry::complete_reads_for_test(), reads + 1);
    drop(registry);
    mux.shutdown();
}

/// THE REPAIR THAT THE FULL PROJECTION WAS. The open of a registry rewrites a row with no
/// journal record: a default-shaped name (`workspace-9`) that an older daemon stored as the
/// person's goes back to the automatic namer (`migrate_workspace_name_authority`). Then the
/// daemon has no fold, and a create in ANOTHER workspace is scoped. A reader of the journal
/// must still get the name source that the row holds.
#[test]
fn a_create_in_another_workspace_after_a_restart_leaves_the_journal_equal_to_the_rows() {
    let session = "open-rewrite-journal";
    let root = std::env::temp_dir()
        .join(format!("cmux-open-rewrite-journal-{}", crate::workspace_registry::new_uuid_v4()));
    let mux = open_persistent_test_mux(session, &root);
    mux.new_workspace(Some("other".into()), Some((80, 24))).unwrap();
    mux.new_workspace(Some("workspace-9".into()), Some((80, 24))).unwrap();
    let named = mux.with_state(|state| {
        let workspace = state.workspaces.iter().find(|w| w.name == "workspace-9").unwrap();
        workspace.public_id.to_string()
    });
    // As an older daemon stored and journaled it: the person's name, never renamed.
    {
        let registry = mux.workspace_registry.lock().unwrap();
        let changed = registry
            .connection
            .get()
            .execute(
                "UPDATE workspaces SET name_source = 'user'
                 WHERE name = 'workspace-9' AND name_revision = 0",
                [],
            )
            .unwrap();
        assert_eq!(changed, 1, "the row of workspace-9 is not at name revision 0");
    }
    {
        let mut state = mux.state.lock().unwrap();
        let workspace = state.workspaces.iter_mut().find(|w| w.name == "workspace-9").unwrap();
        workspace.name_source = NameSource::User;
    }
    restate(&mux, "older-daemon-values");
    assert_eq!(journal_workspaces(&mux)[&named]["extra"]["name_source"], "user");
    assert_journal_states_the_rows(&mux);
    mux.shutdown();
    drop(mux);

    let reopened = open_persistent_test_mux(session, &root);
    reopened.stop_journal_maintenance();
    let (other, source) = reopened.with_state(|state| {
        let other = state.workspaces.iter().find(|w| w.name == "other").unwrap().id;
        let named = state.workspaces.iter().find(|w| w.name == "workspace-9").unwrap();
        (other, named.name_source)
    });
    assert_eq!(source, NameSource::Auto, "the open did not hand the name to the automatic namer");
    let full = full_projections(&reopened);
    without_crosscheck(|| {
        reopened.create_terminal_in_workspace(other, None, None, None, Some((80, 24))).unwrap();
    });
    assert_eq!(full_projections(&reopened), full, "the create after the restart was not scoped");
    assert_eq!(
        journal_workspaces(&reopened)[&named]["extra"]["name_source"],
        "auto",
        "the journal still states the name source from before the open rewrote the row"
    );
    assert_journal_states_the_rows(&reopened);
    // The same create with the debug cross-check on: it refuses a scoped projection that
    // writes other rows than the full one would.
    reopened.create_terminal_in_workspace(other, None, None, None, Some((80, 24))).unwrap();
    assert_journal_states_the_rows(&reopened);
    reopened.shutdown();
    drop(reopened);
    let _ = std::fs::remove_dir_all(&root);
}
