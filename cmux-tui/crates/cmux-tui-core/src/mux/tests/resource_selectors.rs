//! Resource selector resolution: public ids, ancestor scopes, names, and stale or duplicate selectors.

use super::*;

fn selector_fixture()
-> (RestoredResourceState, MachinePublicId, SessionPublicId, ResourceTopologySnapshot) {
    let (snapshot, topology) = resource_restore_fixture();
    let session = snapshot.session_id.clone();
    let restored = restore_resource_state(snapshot, topology.clone()).unwrap();
    (restored, MachinePublicId::random().unwrap(), session, topology)
}

fn routed_selectors(
    machine: &MachinePublicId,
    session: &SessionPublicId,
) -> crate::ResourceSelectors {
    crate::ResourceSelectors {
        machine: Some(machine.to_string()),
        session: Some(session.to_string()),
        ..crate::ResourceSelectors::default()
    }
}

#[test]
fn direct_browser_id_derives_its_complete_path_without_structural_selectors() {
    let (restored, machine, session, topology) = selector_fixture();
    let browser = topology.browsers[0].public_id.clone();
    let tab = topology
        .tabs
        .iter()
        .find(|tab| tab.content_id == ContentPublicId::Browser(browser.clone()))
        .unwrap();
    let pane = topology.panes.iter().find(|pane| pane.public_id == tab.pane_id).unwrap();
    let screen = topology.screens.iter().find(|screen| screen.public_id == pane.screen_id).unwrap();
    let mut selectors = routed_selectors(&machine, &session);
    selectors.browser = Some(browser.to_string());

    let resolved = resolve_resource_selectors(
        &restored.state,
        ResourceSelectorContext {
            machine_id: &machine,
            machine_name: None,
            session_id: &session,
            session_name: "test",
        },
        crate::ResourceTarget::Browser,
        &selectors,
    )
    .unwrap()
    .path;
    assert_eq!(resolved.workspace, Some(screen.workspace_id.clone()));
    assert_eq!(resolved.screen, Some(screen.public_id.clone()));
    assert_eq!(resolved.pane, Some(pane.public_id.clone()));
    assert_eq!(resolved.tab, Some(tab.public_id.clone()));
    assert_eq!(resolved.browser, Some(browser));
}

#[test]
fn terminal_selector_uses_ancestor_scope_and_rejects_scope_after_last_view_closes() {
    let mux = test_mux();
    let source = mux.new_workspace(Some("source".into()), None).unwrap();
    let destination_anchor = mux.new_workspace(Some("destination".into()), None).unwrap();
    let terminal_id = source.terminal_public_id().cloned().unwrap();
    let (source_workspace, source_pane, destination_workspace, destination_pane) =
        mux.with_state(|state| {
            let source_pane = state.pane_of(source.id).unwrap();
            let destination_pane = state.pane_of(destination_anchor.id).unwrap();
            let source_workspace =
                state.workspaces[state.screen_of(source_pane).unwrap().0].public_id.clone();
            let destination_workspace =
                state.workspaces[state.screen_of(destination_pane).unwrap().0].public_id.clone();
            (source_workspace, source_pane, destination_workspace, destination_pane)
        });
    // Keep both workspaces live after every view of `terminal_id` closes.
    mux.new_tab(Some(source_pane), None, None).unwrap();

    let terminal_selectors = crate::ResourceSelectors {
        terminal: Some(terminal_id.to_string()),
        ..Mux::ordinary_resource_selectors()
    };
    mux.resource_project_terminal_selected(
        terminal_selectors.clone(),
        mux.ordinary_pane_selectors(destination_pane).unwrap(),
        usize::MAX,
        Some("second view".into()),
        None,
        &WorkspaceMutation::daemon_local("selector-multiview"),
    )
    .unwrap();

    for expected_workspace in [&source_workspace, &destination_workspace] {
        let mut scoped = terminal_selectors.clone();
        scoped.workspace = Some(expected_workspace.to_string());
        let path = mux.resolve_resource_path(crate::ResourceTarget::Terminal, &scoped).unwrap();
        assert_eq!(path.workspace.as_ref(), Some(expected_workspace));
        assert_eq!(path.terminal.as_ref(), Some(&terminal_id));
    }

    let placements = mux.with_state(|state| {
        state.placements_of_content(&ContentPublicId::Terminal(terminal_id.clone())).to_vec()
    });
    assert_eq!(placements.len(), 2);
    for placement in placements {
        assert!(mux.close_surface(placement).unwrap());
    }

    let path =
        mux.resolve_resource_path(crate::ResourceTarget::Terminal, &terminal_selectors).unwrap();
    assert_eq!(path.workspace, None);
    assert_eq!(path.tab, None);
    assert_eq!(path.terminal, Some(terminal_id));

    let mut scoped = terminal_selectors;
    scoped.workspace = Some(destination_workspace.to_string());
    let error = mux.resolve_resource_path(crate::ResourceTarget::Terminal, &scoped).unwrap_err();
    assert_eq!(error.code, "selector.wrong_parent");
    assert_eq!(error.details["scope"], "terminal");
    assert_eq!(error.details["actual_parent"], "<none>");
}

#[test]
fn terminal_projection_event_matches_every_changed_public_snapshot() {
    let mux = test_mux();
    let source = mux.new_workspace(Some("source".into()), None).unwrap();
    let destination = mux.new_workspace(Some("destination".into()), None).unwrap();
    let destination_pane = mux.with_state(|state| state.pane_of(destination.id).unwrap());
    mux.new_tab(Some(destination_pane), None, None).unwrap();
    let terminal_id = source.terminal_public_id().cloned().unwrap();
    let destination_selectors = mux.ordinary_pane_selectors(destination_pane).unwrap();
    let destination_pane_id = destination_selectors.pane.clone().unwrap();
    let before = mux.with_state(|state| state.resource_revision);

    mux.resource_project_terminal_selected(
        crate::ResourceSelectors {
            terminal: Some(terminal_id.to_string()),
            ..Mux::ordinary_resource_selectors()
        },
        destination_selectors,
        0,
        Some("projected".into()),
        None,
        &WorkspaceMutation::daemon_local("projection-complete-delta"),
    )
    .unwrap();

    let batches = mux.resource_events_after(before).unwrap().batches;
    assert_eq!(batches.len(), 1);
    let changes = batches[0].changes.as_array().unwrap();
    let snapshot = crate::resource_api::public_session_snapshot(&mux).unwrap();
    let terminal = snapshot["terminals"]
        .as_array()
        .unwrap()
        .iter()
        .find(|value| value["id"] == terminal_id.as_str())
        .unwrap();
    let terminal_delta = changes
        .iter()
        .find(|change| change["resource"] == "terminal" && change["id"] == terminal_id.as_str())
        .expect("projection changes the terminal's placement list");
    assert_eq!(&terminal_delta["value"], terminal);

    let destination_tabs = snapshot["tabs"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|tab| tab["pane_id"] == destination_pane_id)
        .collect::<Vec<_>>();
    assert_eq!(destination_tabs.len(), 3);
    for tab in destination_tabs {
        let tab_id = tab["id"].as_str().unwrap();
        let delta = changes
            .iter()
            .find(|change| change["resource"] == "tab" && change["id"] == tab_id)
            .unwrap_or_else(|| panic!("projection omitted changed tab {tab_id}"));
        assert_eq!(&delta["value"], tab);
    }
}

#[test]
fn selector_names_preserve_empty_whitespace_and_unicode_and_report_duplicates() {
    let (mut restored, machine, session, _) = selector_fixture();
    let before = restored.state.resource_revision;
    let mut selectors = routed_selectors(&machine, &session);
    selectors.workspace = Some("Duplicate".into());
    let duplicate = resolve_resource_selectors(
        &restored.state,
        ResourceSelectorContext {
            machine_id: &machine,
            machine_name: None,
            session_id: &session,
            session_name: "test",
        },
        crate::ResourceTarget::Workspace,
        &selectors,
    )
    .unwrap_err();
    assert_eq!(duplicate.code, "selector.ambiguous");
    assert_eq!(
        duplicate.details["candidates"],
        serde_json::json!([restore_workspace_id(1), restore_workspace_id(2)])
    );
    assert_eq!(restored.state.resource_revision, before);

    for (index, name) in ["", "  日本語  "].into_iter().enumerate() {
        restored.state.workspaces[index].name = name.into();
        selectors.workspace = Some(format!("name:{name}"));
        let resolved = resolve_resource_selectors(
            &restored.state,
            ResourceSelectorContext {
                machine_id: &machine,
                machine_name: None,
                session_id: &session,
                session_name: "test",
            },
            crate::ResourceTarget::Workspace,
            &selectors,
        )
        .unwrap();
        assert_eq!(
            resolved.path.workspace,
            Some(restored.state.workspaces[index].public_id.clone())
        );
    }
}

#[test]
fn selector_rejects_incomplete_name_chain_wrong_type_stale_id_and_wrong_parent() {
    let (restored, machine, session, topology) = selector_fixture();
    let context = ResourceSelectorContext {
        machine_id: &machine,
        machine_name: None,
        session_id: &session,
        session_name: "test",
    };

    let mut incomplete = routed_selectors(&machine, &session);
    incomplete.screen = Some(topology.screens[0].public_id.to_string());
    incomplete.pane = Some("one".into());
    let error = resolve_resource_selectors(
        &restored.state,
        context.clone(),
        crate::ResourceTarget::Pane,
        &incomplete,
    )
    .unwrap_err();
    assert_eq!(error.code, "selector.invalid");
    assert_eq!(error.details["scope"], "pane");
    assert!(error.details["reason"].as_str().is_some_and(|reason| reason.contains("workspace")));

    let mut wrong_type = routed_selectors(&machine, &session);
    wrong_type.workspace = Some(topology.browsers[0].public_id.to_string());
    assert_eq!(
        resolve_resource_selectors(
            &restored.state,
            context.clone(),
            crate::ResourceTarget::Workspace,
            &wrong_type,
        )
        .unwrap_err()
        .code,
        "selector.invalid"
    );

    let mut stale = routed_selectors(&machine, &session);
    stale.workspace = Some(WorkspacePublicId::random().unwrap().to_string());
    assert_eq!(
        resolve_resource_selectors(
            &restored.state,
            context.clone(),
            crate::ResourceTarget::Workspace,
            &stale,
        )
        .unwrap_err()
        .code,
        "selector.not_found"
    );

    let mut wrong_parent = routed_selectors(&machine, &session);
    wrong_parent.workspace = Some(restore_workspace_id(2).to_string());
    wrong_parent.browser = Some(topology.browsers[0].public_id.to_string());
    let error = resolve_resource_selectors(
        &restored.state,
        context,
        crate::ResourceTarget::Browser,
        &wrong_parent,
    )
    .unwrap_err();
    assert_eq!(error.code, "selector.wrong_parent");
    assert!(error.details["expected_parent"].as_str().unwrap().starts_with("ws_"));
    assert!(error.details["actual_parent"].as_str().unwrap().starts_with("ws_"));
    let encoded = serde_json::to_string(&error).unwrap();
    for private in ["workspace_key", "surface", "numeric_id", "short_id", "\"slot\""] {
        assert!(!encoded.contains(private));
    }
}

#[test]
fn selector_rename_and_concurrent_rename_share_one_locked_snapshot() {
    let mux = test_mux();
    let first = mux
        .resource_create_empty_workspace(
            Some("target".into()),
            None,
            Some(0),
            &WorkspaceMutation::daemon("selector-race-first", "test").unwrap(),
        )
        .unwrap();
    let second = mux
        .resource_create_empty_workspace(
            Some("other".into()),
            None,
            Some(1),
            &WorkspaceMutation::daemon("selector-race-second", "test").unwrap(),
        )
        .unwrap();
    let first_id = WorkspacePublicId::parse(first.result["workspace"].as_str().unwrap()).unwrap();
    let second_id = WorkspacePublicId::parse(second.result["workspace"].as_str().unwrap()).unwrap();
    let (machine, session) = {
        let registry = mux.workspace_registry.lock().unwrap();
        (registry.machine_id().clone(), registry.session_id().clone())
    };
    let mut selectors = routed_selectors(&machine, &session);
    selectors.workspace = Some("target".into());

    let (resolved_tx, resolved_rx) = std::sync::mpsc::sync_channel(1);
    let overlap = Arc::new(std::sync::Barrier::new(2));
    *mux.resource_rename_after_selector_resolution.lock().unwrap() = Some(Arc::new({
        let overlap = overlap.clone();
        move |resolved| {
            resolved_tx.send(resolved.clone()).unwrap();
            overlap.wait();
        }
    }));
    let selected = {
        let mux = mux.clone();
        std::thread::spawn(move || {
            mux.resource_rename_workspace_selected(
                selectors,
                "renamed".into(),
                None,
                Some(2),
                &WorkspaceMutation::daemon("selector-race-selected", "test").unwrap(),
            )
        })
    };
    assert_eq!(resolved_rx.recv().unwrap(), first_id);
    let concurrent = {
        let mux = mux.clone();
        let second_id = second_id.clone();
        std::thread::spawn(move || {
            overlap.wait();
            mux.resource_rename_workspace(
                &second_id,
                "target".into(),
                None,
                None,
                &WorkspaceMutation::daemon("selector-race-direct", "test").unwrap(),
            )
        })
    };
    selected.join().unwrap().unwrap();
    concurrent.join().unwrap().unwrap();
    *mux.resource_rename_after_selector_resolution.lock().unwrap() = None;

    mux.with_state(|state| {
        let first = state.resource_indexes.workspaces[&first_id];
        let second = state.resource_indexes.workspaces[&second_id];
        assert_eq!(state.workspaces[state.workspace_index(first).unwrap()].name, "renamed");
        assert_eq!(state.workspaces[state.workspace_index(second).unwrap()].name, "target");
    });
}
