//! Unit tests for `batch_close`.

use super::*;
use crate::SurfaceOptions;
use crate::workspace_registry::{RegistryTerminal, ResourceChange};

fn terminal(n: u64) -> (String, String) {
    (format!("00000000000040008000{n:012x}"), format!("10000000000040008000{n:012x}"))
}

fn mux() -> Arc<Mux> {
    Mux::new_for_test("batch-close", SurfaceOptions::default())
}

fn workspace(mux: &Arc<Mux>, n: u64) -> String {
    mux.create_empty_workspace(
        Some(format!("w{n}")),
        Some(format!("018f6e21-7b70-7e70-8000-{n:012x}")),
        None,
    )
    .unwrap()
    .key
}

fn seed(mux: &Arc<Mux>, n: u64, workspace_key: &str) -> SurfaceId {
    let (id, incarnation) = terminal(n);
    mux.seed_running_terminal_for_test(&id, &incarnation, workspace_key).unwrap()
}

fn lifecycle(mux: &Mux, n: u64) -> String {
    mux.resource_terminal_lifecycle_for_test(&terminal(n).0).unwrap().unwrap().0
}

fn resource_revision(mux: &Mux) -> u64 {
    mux.with_state(|state| state.resource_revision)
}

/// The incremental store must hold exactly what a full rewrite of the
/// current state would write: every row the full projection names is
/// stored with the same value, and no stale live row remains (a stale
/// row would appear as a tombstone in the projection).
fn assert_store_matches_full_projection(mux: &Mux) {
    let mut registry = mux.workspace_registry.lock().unwrap();
    let mut state = mux.state.lock().unwrap().clone();
    let projection =
        mux.resource_effect_projection_locked(&registry, &mut state, json!({})).unwrap();
    // Every value the journal states (its pruned public changes, folded)
    // equals what a full projection publishes now; a pruned upsert is
    // therefore a no-op for every consumer. An unstated resource is
    // simply published again.
    for change in projection.changes.as_array().unwrap() {
        if change["kind"] != "upsert" {
            continue;
        }
        let resource = change["resource"].as_str().unwrap();
        let id = change["id"].as_str().unwrap();
        if let Some(Some(stated)) = registry.stated_topology_value_for_test(resource, id) {
            assert_eq!(stated, change["value"], "journal states a stale {resource} {id}");
        }
    }
    let snapshot = registry.resource_topology_snapshot().unwrap();
    let legacy = registry.snapshot().unwrap();
    let terminals = registry.terminal_snapshot().unwrap().terminals;
    let mut screens = Vec::new();
    let mut panes = Vec::new();
    let mut tabs = Vec::new();
    let mut workspaces = Vec::new();
    let mut active_screens = Vec::new();
    let mut workspace_order = None;
    for change in &projection.patch.changes {
        match change {
            ResourceChange::UpsertWorkspace { workspace, position, active_screen } => {
                workspaces.push((*position, workspace.clone()));
                active_screens.push((workspace.public_id.clone(), active_screen.clone()));
            }
            ResourceChange::UpsertScreen(screen) => screens.push(screen.clone()),
            ResourceChange::UpsertPane(pane) => panes.push(pane.clone()),
            ResourceChange::UpsertTab(tab) => tabs.push((
                tab.public_id.clone(),
                tab.pane_id.clone(),
                tab.position,
                tab.content_id.clone(),
                tab.name.clone(),
            )),
            ResourceChange::UpsertTerminal { terminal, .. } => {
                let stored: Vec<&RegistryTerminal> = terminals
                    .iter()
                    .filter(|stored| stored.terminal_id == terminal.terminal_id)
                    .collect();
                assert_eq!(stored, vec![terminal], "terminal row differs");
            }
            ResourceChange::SetWorkspaceOrder { workspace_ids } => {
                workspace_order = Some(workspace_ids.clone());
            }
            ResourceChange::TombstoneWorkspace { .. }
            | ResourceChange::TombstoneScreen { .. }
            | ResourceChange::TombstonePane { .. }
            | ResourceChange::TombstoneTab { .. }
            | ResourceChange::TombstoneTerminal { .. }
            | ResourceChange::TombstoneBrowser { .. } => {
                panic!("store kept a row the live state no longer has: {change:?}")
            }
            _ => {}
        }
    }
    screens.sort_by_key(|screen| screen.public_id.to_string());
    let mut stored_screens = snapshot.screens.clone();
    stored_screens.sort_by_key(|screen| screen.public_id.to_string());
    assert_eq!(stored_screens, screens, "screen rows differ");
    panes.sort_by_key(|pane| pane.public_id.to_string());
    let mut stored_panes = snapshot.panes.clone();
    stored_panes.sort_by_key(|pane| pane.public_id.to_string());
    assert_eq!(stored_panes, panes, "pane rows differ");
    tabs.sort_by_key(|tab| tab.0.to_string());
    let mut stored_tabs = snapshot
        .tabs
        .iter()
        .map(|tab| {
            (
                tab.public_id.clone(),
                tab.pane_id.clone(),
                tab.position,
                tab.content_id.clone(),
                tab.name.clone(),
            )
        })
        .collect::<Vec<_>>();
    stored_tabs.sort_by_key(|tab| tab.0.to_string());
    assert_eq!(stored_tabs, tabs, "tab rows differ");
    workspaces.sort_by_key(|(position, _)| *position);
    let workspaces = workspaces.into_iter().map(|(_, workspace)| workspace).collect::<Vec<_>>();
    assert_eq!(legacy.workspaces, workspaces, "workspace rows differ");
    if let Some(order) = workspace_order {
        let stored = legacy.workspaces.iter().map(|w| w.public_id.clone()).collect::<Vec<_>>();
        assert_eq!(stored, order, "workspace order differs");
    }
    let mut stored_active = snapshot.active_screens;
    stored_active.sort_by_key(|(workspace, _)| workspace.to_string());
    active_screens.sort_by_key(|(workspace, _)| workspace.to_string());
    assert_eq!(stored_active, active_screens, "active screens differ");
}

#[test]
fn close_tabs_ends_terminals_in_one_commit_and_spares_kept_ones() {
    let mux = mux();
    let mut surfaces = Vec::new();
    for n in 1..=4 {
        let key = workspace(&mux, n);
        surfaces.push(seed(&mux, n, &key));
    }
    mux.set_terminal_keep(&terminal(4).0, true).unwrap();
    let before = resource_revision(&mux);

    let outcome = mux
        .close_tabs(surfaces.clone(), true, &WorkspaceMutation::daemon_local("batch-close-test"))
        .unwrap();

    assert_eq!(resource_revision(&mux), before + 1, "one durable commit");
    assert_eq!(outcome.closed(), surfaces);
    let ended = outcome.terminals();
    assert_eq!(ended.len(), 3);
    for n in 1..=3 {
        assert_eq!(lifecycle(&mux, n), "tombstoned");
        assert!(ended.iter().any(|terminal| terminal.terminal_id == self::terminal(n).0));
    }
    assert_eq!(lifecycle(&mux, 4), "running", "a kept terminal survives");
    for surface in &surfaces {
        assert_eq!(mux.with_state(|state| state.pane_of(*surface)), None);
    }
    // Every workspace lost its last tab: all four close in the same commit
    // (LAST-TAB-CLOSES-WORKSPACE); the kept terminal outlives them.
    assert_eq!(mux.with_state(|state| state.workspaces.len()), 0, "emptied workspaces close");
    assert_store_matches_full_projection(&mux);
}

#[test]
fn close_tabs_without_end_terminals_detaches_and_rejects_unknown_surfaces_atomically() {
    let mux = mux();
    let key = workspace(&mux, 1);
    let first = seed(&mux, 1, &key);
    let second = seed(&mux, 2, &key);
    let before = resource_revision(&mux);
    let error = mux
        .close_tabs(
            vec![first, 999_999],
            true,
            &WorkspaceMutation::daemon_local("batch-close-test"),
        )
        .unwrap_err();
    assert!(format!("{error:#}").contains("unknown surface"), "{error:#}");
    assert_eq!(resource_revision(&mux), before, "a rejected batch writes nothing");
    assert!(mux.with_state(|state| state.pane_of(first)).is_some());

    let outcome = mux
        .close_tabs(vec![first, first], false, &WorkspaceMutation::daemon_local("batch-close-test"))
        .unwrap();
    assert_eq!(outcome.closed(), vec![first]);
    assert!(outcome.terminals().is_empty());
    assert_eq!(lifecycle(&mux, 1), "running", "a plain close detaches the terminal");
    assert!(mux.with_state(|state| state.pane_of(second)).is_some());
    assert_store_matches_full_projection(&mux);
}

#[test]
fn close_workspace_ending_terminals_commits_once_and_replays() {
    let mux = mux();
    let other = workspace(&mux, 1);
    seed(&mux, 1, &other);
    let key = workspace(&mux, 2);
    seed(&mux, 2, &key);
    seed(&mux, 3, &key);
    let resource_before = resource_revision(&mux);
    let workspace_before = mux.with_state(|state| state.workspace_revision);
    let mutation = WorkspaceMutation::daemon("close-ws-batch", "batch-close-test").unwrap();

    let (result, outcome) =
        mux.close_workspace_ending_terminals(None, Some(&key), None, None, &mutation).unwrap();

    assert_eq!(resource_revision(&mux), resource_before + 1);
    assert_eq!(result.revision, workspace_before + 1);
    assert_eq!(result.key, key);
    assert!(!result.replayed);
    assert_eq!(outcome.terminals().len(), 2);
    assert_eq!(lifecycle(&mux, 2), "tombstoned");
    assert_eq!(lifecycle(&mux, 3), "tombstoned");
    assert_eq!(lifecycle(&mux, 1), "running");
    assert!(mux.with_state(|state| state.workspaces.iter().all(|w| w.key != key)));
    assert_store_matches_full_projection(&mux);

    let (replayed, _) =
        mux.close_workspace_ending_terminals(None, Some(&key), None, None, &mutation).unwrap();
    assert!(replayed.replayed);
    assert_eq!(replayed.revision, result.revision);
    assert_eq!(resource_revision(&mux), resource_before + 1, "a replay writes nothing");
}

#[test]
fn close_pane_ending_terminals_spares_a_terminal_shown_elsewhere_by_keep() {
    let mux = mux();
    let key = workspace(&mux, 1);
    let surface = seed(&mux, 1, &key);
    seed(&mux, 2, &key);
    mux.set_terminal_keep(&terminal(2).0, true).unwrap();
    let pane = mux.with_state(|state| state.pane_of(surface).unwrap());

    let outcome = mux
        .close_container_ending_terminals_as(&Actor::Daemon, BatchCloseTarget::Pane(pane))
        .unwrap();

    assert_eq!(outcome.closed().len(), 2);
    assert_eq!(outcome.terminals().len(), 1);
    assert_eq!(lifecycle(&mux, 1), "tombstoned");
    assert_eq!(lifecycle(&mux, 2), "running");
    assert_store_matches_full_projection(&mux);
}

/// Once the fold is seeded, a close journals only the resources it
/// changes, not every live workspace.
#[test]
fn a_close_journals_only_the_topology_it_changes() {
    let mux = mux();
    let mut surfaces = Vec::new();
    for n in 1..=8 {
        let key = workspace(&mux, n);
        surfaces.push(seed(&mux, n, &key));
        // A second tab keeps the workspace open (LAST-TAB-CLOSES-WORKSPACE).
        seed(&mux, 100 + n, &key);
    }
    mux.close_tabs(vec![surfaces[0]], true, &WorkspaceMutation::daemon_local("seed")).unwrap();
    let before = resource_revision(&mux);
    mux.close_tabs(vec![surfaces[1]], true, &WorkspaceMutation::daemon_local("second")).unwrap();
    let registry = mux.workspace_registry.lock().unwrap();
    let page = registry.resource_events_after(before).unwrap();
    assert_eq!(page.batches.len(), 1);
    let changes = page.batches[0].changes.as_array().unwrap();
    let upserted_workspaces = changes
        .iter()
        .filter(|change| change["kind"] == "upsert" && change["resource"] == "workspace")
        .count();
    assert!(upserted_workspaces <= 1, "{changes:#?}");
    assert!(
        changes.iter().any(|change| change["kind"] == "delete" && change["resource"] == "terminal"),
        "{changes:#?}"
    );
    drop(registry);
    assert_store_matches_full_projection(&mux);
}

/// Mixed ordinary mutations keep the incremental store identical to a
/// full projection of the live state after every step.
#[test]
fn incremental_projection_matches_full_rebuild_under_mixed_mutations() {
    let mux = mux();
    let mut keys = Vec::new();
    for n in 1..=5 {
        let key = workspace(&mux, n);
        seed(&mux, n, &key);
        assert_store_matches_full_projection(&mux);
        keys.push(key);
    }
    let extra = seed(&mux, 10, &keys[0]);
    assert_store_matches_full_projection(&mux);
    let ids = mux.with_state(|state| state.workspaces.iter().map(|w| w.id).collect::<Vec<_>>());
    assert!(mux.rename_workspace(ids[1], "renamed".into()));
    assert_store_matches_full_projection(&mux);
    assert!(mux.move_workspace(ids[4], 0));
    assert_store_matches_full_projection(&mux);
    assert!(mux.rename_surface(extra, "tab name".into()));
    assert_store_matches_full_projection(&mux);
    assert!(mux.close_surface(extra).unwrap());
    assert_store_matches_full_projection(&mux);
    mux.close_terminal(&terminal(2).0, &terminal(2).1).unwrap();
    assert_store_matches_full_projection(&mux);
    assert!(mux.close_workspace(ids[2]));
    assert_store_matches_full_projection(&mux);
    let surface =
        mux.with_state(|state| {
            state.workspaces.iter().find(|w| w.key == keys[3]).and_then(|w| {
                w.screens.first().map(|screen| state.panes[&screen.active_pane].tabs[0])
            })
        });
    mux.close_tabs(vec![surface.unwrap()], true, &WorkspaceMutation::daemon_local("mixed"))
        .unwrap();
    assert_store_matches_full_projection(&mux);
    mux.close_workspace_ending_terminals(
        None,
        Some(&keys[4]),
        None,
        None,
        &WorkspaceMutation::daemon_local("mixed"),
    )
    .unwrap();
    assert_store_matches_full_projection(&mux);
    let fresh = workspace(&mux, 20);
    seed(&mux, 20, &fresh);
    assert_store_matches_full_projection(&mux);
}
