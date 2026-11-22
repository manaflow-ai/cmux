//! Resource state restore at startup: durable identities, corrupt selectors, and patch commits.

use super::*;

#[test]
fn resource_startup_restores_nested_columns_selections_and_empty_workspace() {
    let (snapshot, topology) = resource_restore_fixture();
    let expected_tab = topology.tabs[5].public_id.clone();
    let expected_browser = topology.tabs[5].content_id.clone();
    let expected_base_column = topology.screens[0].viewport.columns[0].id.clone();
    let mut restored = restore_resource_state(snapshot, topology).unwrap();
    Mux::rebuild_split_screen_index(&mut restored.state);

    let state = &restored.state;
    assert_eq!(state.workspaces.len(), 2);
    assert_eq!(state.active_workspace, 1);
    assert!(state.workspaces[1].screens.is_empty());
    assert_eq!(state.workspaces[0].active_screen, 1);
    let columns = &state.workspaces[0].screens[0];
    assert_eq!(columns.layout_columns.len(), 2);
    assert_eq!(columns.viewport_base_width, Some(0.8));
    assert_eq!(columns.zoomed_pane, Some(columns.active_pane));
    assert!(matches!(
        &columns.layout_columns[0].root,
        Node::Split { a, .. }
            if matches!(a.as_ref(), Node::Stack { expanded, .. }
                if *expanded == state.resource_indexes.panes[&restore_pane_id(2)])
    ));
    assert!(columns.layout_column_projection_is_consistent());
    assert!(state.resource_indexes.splits.contains_key(&expected_base_column));
    let selected_pane = state.resource_indexes.panes[&restore_pane_id(5)];
    assert_eq!(
        state.panes[&selected_pane].tabs[state.panes[&selected_pane].active_tab],
        state.resource_indexes.tabs[&expected_tab]
    );
    assert_eq!(
        state.resource_indexes.content_placements[&expected_browser][0],
        state.resource_indexes.tabs[&expected_tab]
    );
    assert_eq!(state.surfaces.len(), 0);
    assert_eq!(restored.contents.len(), 6);
    assert!(restored.next_id > 100);
}

#[test]
fn restored_tabs_keep_durable_identity_without_any_live_surface() {
    let (snapshot, topology) = resource_restore_fixture();
    let mut restored = restore_resource_state(snapshot, topology.clone()).unwrap();
    assert!(restored.state.surfaces.is_empty(), "restore must not fabricate runtime");

    restored.state.rebuild_resource_indexes();
    restored.state.ensure_tab_identity_coverage().unwrap();

    for tab in &topology.tabs {
        let slot = restored
            .state
            .resource_indexes
            .tabs
            .get(&tab.public_id)
            .copied()
            .expect("restored tab lost its slot");
        assert_eq!(
            restored.state.resource_indexes.content_ids.get(&slot),
            Some(&tab.content_id),
            "restored tab lost its content identity"
        );
    }
}

#[test]
fn a_tab_without_durable_identity_fails_loudly_instead_of_vanishing() {
    let (snapshot, topology) = resource_restore_fixture();
    let mut restored = restore_resource_state(snapshot, topology).unwrap();
    let slot = *restored
        .state
        .panes
        .values()
        .find(|pane| !pane.tabs.is_empty())
        .expect("fixture has a placed tab")
        .tabs
        .first()
        .expect("checked above");

    restored.state.resource_indexes.tab_ids.remove(&slot);

    let error = restored.state.ensure_tab_identity_coverage().unwrap_err();
    assert!(error.to_string().contains("has no durable identity"), "unexpected error: {error}");
}

#[test]
fn restored_terminal_runtime_materializes_all_durable_views_and_survives_zero_views() {
    let (snapshot, mut topology) = resource_restore_fixture();
    let terminal_id = restore_terminal_id(50);
    let host_id = "00000000000040008000000000000050";
    let replaced_browsers =
        topology.tabs[..2].iter().map(|tab| tab.content_id.clone()).collect::<HashSet<_>>();
    topology.browsers.retain(|browser| {
        !replaced_browsers.contains(&ContentPublicId::Browser(browser.public_id.clone()))
    });
    for tab in &mut topology.tabs[..2] {
        tab.content_id = ContentPublicId::Terminal(terminal_id.clone());
        tab.browser_url = None;
        tab.terminal_id = Some(host_id.into());
    }
    let mut restored = restore_resource_state(snapshot, topology.clone()).unwrap();
    let content_id = ContentPublicId::Terminal(terminal_id.clone());
    let placements = restored.state.placements_of_content(&content_id).to_vec();
    assert_eq!(placements.len(), 2);
    let first_tab = topology.tabs[0].public_id.clone();
    let source = Surface::spawn_for_test_with_resource_identity(
        placements[0],
        SurfaceOptions::default(),
        Weak::new(),
        Some(TabResourceIdentity::new(first_tab, content_id.clone())),
    )
    .unwrap();

    insert_restored_terminal_runtime_checked(&mut restored.state, source.clone()).unwrap();
    assert_eq!(restored.state.terminal_catalog.len(), 1);
    for placement in &placements {
        assert!(
            restored.state.surfaces[placement].shares_terminal_runtime(&source),
            "every durable tab must project the one restored terminal runtime"
        );
    }

    let mux = test_mux();
    for placement in placements {
        let _ = remove_surface(&mux, &mut restored.state, placement);
    }
    assert!(restored.state.surfaces.is_empty());
    assert!(restored.state.placements_of_content(&content_id).is_empty());
    assert!(
        restored
            .state
            .terminal_catalog
            .get(&terminal_id)
            .is_some_and(|catalogued| catalogued.shares_terminal_runtime(&source)),
        "removing the final view must retain the restored runtime owner"
    );
}

#[test]
fn resource_startup_rejects_corrupt_persisted_selectors() {
    let (snapshot, mut topology) = resource_restore_fixture();
    topology.active_screens[0].1 = Some(restore_screen_id(999));
    assert!(
        restore_resource_state(snapshot.clone(), topology)
            .err()
            .unwrap()
            .to_string()
            .contains("unknown active screen")
    );

    let (_, mut topology) = resource_restore_fixture();
    topology.panes[0].active_tab = Some(restore_tab_id(999));
    assert!(
        restore_resource_state(snapshot, topology)
            .err()
            .unwrap()
            .to_string()
            .contains("unknown active tab")
    );
}

#[test]
fn resource_startup_requires_exact_browser_restart_metadata_coverage() {
    let (snapshot, mut topology) = resource_restore_fixture();
    topology.browsers.pop();
    assert!(
        restore_resource_state(snapshot.clone(), topology)
            .err()
            .unwrap()
            .to_string()
            .contains("has no restart metadata")
    );

    let (_, mut topology) = resource_restore_fixture();
    let mut orphan = topology.browsers[0].clone();
    orphan.public_id = restore_browser_id(999);
    topology.browsers.push(orphan);
    assert!(
        restore_resource_state(snapshot.clone(), topology)
            .err()
            .unwrap()
            .to_string()
            .contains("orphan browser metadata")
    );

    let (_, mut topology) = resource_restore_fixture();
    topology.browsers.push(topology.browsers[0].clone());
    assert!(
        restore_resource_state(snapshot, topology)
            .err()
            .unwrap()
            .to_string()
            .contains("duplicate browser metadata")
    );
}

#[test]
fn resource_startup_rejects_missing_required_active_selectors() {
    let (snapshot, mut topology) = resource_restore_fixture();
    topology.panes[0].active_tab = None;
    assert_eq!(
        restore_resource_state(snapshot.clone(), topology).err().unwrap().to_string(),
        format!("pane {} has tabs but no active tab", restore_pane_id(1))
    );

    let (_, mut topology) = resource_restore_fixture();
    topology.active_screens[0].1 = None;
    assert_eq!(
        restore_resource_state(snapshot.clone(), topology).err().unwrap().to_string(),
        format!("workspace {} has screens but no active screen", restore_workspace_id(1))
    );

    let (_, mut topology) = resource_restore_fixture();
    topology.active_workspace = None;
    assert_eq!(
        restore_resource_state(snapshot.clone(), topology).err().unwrap().to_string(),
        "session has workspaces but no active workspace"
    );

    let (_, mut topology) = resource_restore_fixture();
    topology.active_screens.pop();
    assert_eq!(
        restore_resource_state(snapshot, topology).err().unwrap().to_string(),
        "active-screen metadata does not exactly cover the live workspaces"
    );
}

#[test]
fn resource_startup_accepts_none_only_for_empty_containers() {
    let (snapshot, mut topology) = resource_restore_fixture();
    let empty_pane = topology.panes[0].public_id.clone();
    topology.tabs.retain(|tab| tab.pane_id != empty_pane);
    let retained_browsers = topology
        .tabs
        .iter()
        .filter_map(|tab| match &tab.content_id {
            ContentPublicId::Browser(browser) => Some(browser.clone()),
            ContentPublicId::Terminal(_) => None,
        })
        .collect::<HashSet<_>>();
    topology.browsers.retain(|browser| retained_browsers.contains(&browser.public_id));
    topology.panes[0].active_tab = None;
    let restored = restore_resource_state(snapshot, topology).unwrap();
    assert!(
        restored.state.panes[&restored.state.resource_indexes.panes[&empty_pane]].tabs.is_empty()
    );

    let (mut snapshot, mut topology) = resource_restore_fixture();
    snapshot.workspaces.clear();
    topology.active_workspace = None;
    topology.active_screens.clear();
    topology.screens.clear();
    topology.panes.clear();
    topology.tabs.clear();
    topology.browsers.clear();
    assert!(restore_resource_state(snapshot, topology).unwrap().state.workspaces.is_empty());
}

#[test]
fn resource_state_patch_commits_before_infallible_projection_and_replays_once() {
    let mux = test_mux();
    let mutation = WorkspaceMutation::daemon("create-once", "test-client").unwrap();
    let first =
        mux.resource_create_empty_workspace(Some("API".into()), None, Some(0), &mutation).unwrap();
    assert_eq!(first.revision, 1);
    assert!(!first.replayed);
    let public_id = WorkspacePublicId::parse(first.result["workspace"].as_str().unwrap()).unwrap();
    mux.with_state(|state| {
        assert_eq!(state.resource_revision, 1);
        assert_eq!(state.workspaces.len(), 1);
        assert_eq!(state.workspaces[0].public_id, public_id);
        assert_eq!(state.workspaces[0].name, "API");
    });
    let durable = mux.workspace_registry.lock().unwrap().resource_topology_snapshot().unwrap();
    assert_eq!(durable.revision, 1);
    assert_eq!(durable.active_workspace, Some(public_id));

    let replay =
        mux.resource_create_empty_workspace(Some("API".into()), None, Some(0), &mutation).unwrap();
    assert!(replay.replayed);
    assert_eq!(replay.revision, 1);
    assert_eq!(replay.result, first.result);
    mux.with_state(|state| {
        assert_eq!(state.resource_revision, 1);
        assert_eq!(state.workspaces.len(), 1);
    });
}

#[test]
fn resource_state_patch_failure_leaves_memory_and_database_unchanged() {
    let mux = test_mux();
    mux.workspace_registry.lock().unwrap().set_resource_patch_failure(true).unwrap();
    let error = mux
        .resource_create_empty_workspace(
            Some("Never visible".into()),
            None,
            Some(0),
            &WorkspaceMutation::daemon("fail-create", "test-client").unwrap(),
        )
        .unwrap_err();
    assert!(error.to_string().contains("forced resource patch failure"));
    mux.with_state(|state| {
        assert!(state.workspaces.is_empty());
        assert_eq!(state.resource_revision, 0);
    });
    let registry = mux.workspace_registry.lock().unwrap();
    assert_eq!(registry.resource_topology_snapshot().unwrap().revision, 0);
    assert!(registry.snapshot().unwrap().workspaces.is_empty());
    registry.set_resource_patch_failure(false).unwrap();
}
