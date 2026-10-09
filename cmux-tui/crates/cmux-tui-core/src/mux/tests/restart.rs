//! Persistent mux restart: public topology, browser tabs, auxiliary resources, and committed closes.

use super::*;

#[test]
fn resource_startup_revalidates_exact_layout_and_viewport_coverage() {
    let (snapshot, mut topology) = resource_restore_fixture();
    topology.panes[3].screen_id = restore_screen_id(2);
    assert_eq!(
        restore_resource_state(snapshot.clone(), topology).err().unwrap().to_string(),
        format!("screen {} layout does not cover its panes exactly once", restore_screen_id(1))
    );

    let (_, mut topology) = resource_restore_fixture();
    topology.screens[0].viewport.columns[1].id = restore_split_id(999);
    assert!(
        restore_resource_state(snapshot, topology)
            .err()
            .unwrap()
            .to_string()
            .contains("unknown projected split")
    );
}

#[test]
fn restore_screen_pane_index_preserves_validation_inputs() {
    let (snapshot, topology) = resource_restore_fixture();
    let first_screen = restore_screen_id(1);
    let second_screen = restore_screen_id(2);

    let mut duplicate_panes = topology.panes.clone();
    duplicate_panes.push(duplicate_panes[0].clone());
    let expected = expected_panes_by_screen(&duplicate_panes);
    assert_eq!(expected.get(&first_screen).map(|panes| panes.len()), Some(4));
    assert_eq!(expected.get(&second_screen).map(|panes| panes.len()), Some(1));
    assert!(!expected.contains_key(&restore_screen_id(999)));

    let mut mismatched = topology;
    mismatched.panes[3].screen_id = second_screen.clone();
    let expected = expected_panes_by_screen(&mismatched.panes);
    assert_eq!(expected.get(&first_screen).map(|panes| panes.len()), Some(3));
    assert_eq!(expected.get(&second_screen).map(|panes| panes.len()), Some(2));
    assert_eq!(
        restore_resource_state(snapshot, mismatched).err().unwrap().to_string(),
        format!("screen {first_screen} layout does not cover its panes exactly once")
    );
}

#[test]
fn persistent_mux_restart_keeps_public_topology_and_browser_tabs() {
    let root = std::env::temp_dir()
        .join(format!("cmux-resource-restart-{}", WorkspacePublicId::random().unwrap()));
    let (fixture_snapshot, fixture_topology) = resource_restore_fixture();
    {
        let mut registry = WorkspaceRegistry::open(&root, "restart").unwrap();
        registry
            .commit_resource_patch(
                &WorkspaceMutation::daemon("seed-restart", "test").unwrap(),
                "session.restore_fixture",
                &serde_json::json!({"fixture":"nested-columns"}),
                None,
                Some(0),
                &resource_restore_patch(&fixture_snapshot, &fixture_topology),
                &serde_json::json!({"restored":true}),
                &serde_json::json!([{"event":"session.restored"}]),
            )
            .unwrap();
    }

    let registry = WorkspaceRegistry::open(&root, "restart").unwrap();
    let mux = Mux::from_workspace_registry(
        "restart".into(),
        SurfaceOptions::default(),
        registry,
        ProviderWorkspaceState::default(),
        true,
    )
    .unwrap();
    mux.with_state(|state| {
        assert_eq!(state.workspaces.len(), 2);
        assert_eq!(state.active_workspace, 1);
        assert!(state.workspaces[1].screens.is_empty());
        assert_eq!(state.workspaces[0].active_screen, 1);
        assert_eq!(state.workspaces[0].screens[0].layout_columns.len(), 2);
        assert!(state.workspaces[0].screens[0].layout_column_projection_is_consistent());
        assert_eq!(state.surfaces.len(), fixture_topology.tabs.len());
        for tab in &fixture_topology.tabs {
            let slot = state.resource_indexes.tabs[&tab.public_id];
            let surface = &state.surfaces[&slot];
            let ContentPublicId::Browser(browser_id) = &tab.content_id else {
                unreachable!("restart fixture uses browser tabs");
            };
            let expected_browser = fixture_topology
                .browsers
                .iter()
                .find(|browser| &browser.public_id == browser_id)
                .unwrap();
            assert_eq!(surface.resource_identity().unwrap().tab_id, tab.public_id);
            assert_eq!(surface.resource_identity().unwrap().content_id, tab.content_id);
            assert_eq!(surface.name(), tab.name);
            assert_eq!(surface.browser_url().as_deref(), Some(expected_browser.url.as_str()));
            assert_eq!(surface.size(), (expected_browser.cols, expected_browser.rows));
        }
    });
    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn restart_finishes_a_close_committed_before_live_state_detach() {
    let root = std::env::temp_dir()
        .join(format!("cmux-resource-close-crash-{}", WorkspacePublicId::random().unwrap()));
    let session = "resource-close-crash";
    let session_selectors = serde_json::json!({"machine":"current","session":"current"});
    let registry = WorkspaceRegistry::open(&root, session).unwrap();
    let mux = Mux::from_workspace_registry(
        session.into(),
        SurfaceOptions::default(),
        registry,
        ProviderWorkspaceState::default(),
        true,
    )
    .unwrap();
    let created = public_request(
        &mux,
        "create-workspace",
        "workspace.create",
        serde_json::json!({
            "machine":"current",
            "session":"current",
            "name":"close crash",
            "initial_content":"empty",
        }),
        Some("close-crash-create"),
    );
    let workspace = created["result"]["value"]["workspace_id"].as_str().unwrap().to_string();
    let before_revision = created["result"]["revision"].as_str().unwrap().parse::<u64>().unwrap();
    mux.set_resource_close_after_commit_hook_for_test(Some(Arc::new(|| {
        panic!("simulated daemon crash after close commit")
    })));
    let crashed = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        public_request(
            &mux,
            "close-workspace",
            "workspace.close",
            serde_json::json!({
                "machine":"current",
                "session":"current",
                "workspace":workspace,
            }),
            Some("close-crash-effect"),
        )
    }));
    assert!(crashed.is_err());
    drop(mux);

    let registry = WorkspaceRegistry::open(&root, session).unwrap();
    let reopened = Mux::from_workspace_registry(
        session.into(),
        SurfaceOptions::default(),
        registry,
        ProviderWorkspaceState::default(),
        true,
    )
    .unwrap();
    let snapshot = crate::resource_api::public_session_snapshot(&reopened).unwrap();
    assert!(snapshot["workspaces"].as_array().unwrap().is_empty());
    let events = reopened.resource_events_after(before_revision).unwrap();
    assert_eq!(events.batches.len(), 1);
    assert_eq!(events.batches[0].revision, before_revision + 1);
    let replay = public_request(
        &reopened,
        "close-replay",
        "workspace.close",
        serde_json::json!({
            "machine":"current",
            "session":"current",
            "workspace":workspace,
        }),
        Some("close-crash-effect"),
    );
    assert_eq!(replay["result"]["replayed"], true);
    assert_eq!(replay["result"]["revision"], (before_revision + 1).to_string());
    assert_eq!(reopened.resource_events_after(before_revision).unwrap().batches.len(), 1);
    assert_eq!(
        public_request(&reopened, "snapshot", "session.snapshot", session_selectors, None,)["result"]
            ["workspaces"],
        serde_json::json!([])
    );
    reopened.shutdown();
    drop(reopened);
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn terminal_close_runs_runtime_cleanup_outside_creation_fence() {
    let mux = test_mux();
    let created = public_request(
        &mux,
        "create-terminal-workspace",
        "workspace.create",
        serde_json::json!({
            "machine":"current",
            "session":"current",
            "name":"close fence",
            "initial_content":"terminal",
        }),
        Some("create-terminal-workspace"),
    );
    let terminal = created["result"]["value"]["terminal_id"].clone();
    let cleanup_held_creation_fence = Arc::new(AtomicBool::new(false));
    mux.set_resource_close_cleanup_hook_for_test(Some(Arc::new({
        let cleanup_held_creation_fence = cleanup_held_creation_fence.clone();
        let mux = Arc::downgrade(&mux);
        move || {
            cleanup_held_creation_fence.store(
                mux.upgrade()
                    .is_some_and(|mux| mux.resource_creation_execution.try_lock().is_err()),
                Ordering::Release,
            );
        }
    })));
    public_request(
        &mux,
        "close-terminal",
        "terminal.close",
        serde_json::json!({
            "machine":"current",
            "session":"current",
            "terminal":terminal,
        }),
        Some("close-terminal"),
    );
    assert!(
        !cleanup_held_creation_fence.load(Ordering::Acquire),
        "terminal cleanup ran while holding the global creation fence"
    );
}

#[test]
fn persistent_mux_restart_restores_auxiliary_resources_and_exact_replay() {
    let root = std::env::temp_dir()
        .join(format!("cmux-resource-auxiliary-restart-{}", WorkspacePublicId::random().unwrap()));
    let session = "auxiliary-restart";
    let selectors = serde_json::json!({"machine":"current","session":"current"});
    let create_params = serde_json::json!({
        "machine":"current",
        "session":"current",
        "name":"Durable resources",
        "initial_content":"terminal",
    });
    let registry = WorkspaceRegistry::open(&root, session).unwrap();
    let mux = Mux::from_workspace_registry(
        session.into(),
        SurfaceOptions::default(),
        registry,
        ProviderWorkspaceState::default(),
        true,
    )
    .unwrap();

    let created = public_request(
        &mux,
        "create",
        "workspace.create",
        create_params.clone(),
        Some("auxiliary-restart-create"),
    );
    let created_value = created["result"]["value"].clone();
    let terminal_id = created_value["terminal_id"].as_str().unwrap().to_string();
    let terminal_public_id = TerminalPublicId::parse(&terminal_id).unwrap();
    let notification_params = serde_json::json!({
        "machine":"current",
        "session":"current",
        "title":"Durable build",
        "body":"All checks passed",
        "level":"warning",
        "terminal_id":terminal_id,
    });
    let notification = public_request(
        &mux,
        "notification",
        "notification.create",
        notification_params.clone(),
        Some("auxiliary-restart-notification"),
    );
    let notification_value = notification["result"]["value"].clone();
    let agent_params = serde_json::json!({
        "machine":"current",
        "session":"current",
        "terminal_id":terminal_id,
        "state":"working",
        "source":"hook",
        "source_session":"worker-7",
    });
    let agent = public_request(
        &mux,
        "agent",
        "agent.report",
        agent_params.clone(),
        Some("auxiliary-restart-agent"),
    );
    let agent_value = agent["result"]["value"].clone();
    let defaults_params = serde_json::json!({
        "machine":"current",
        "session":"current",
        "foreground":"#123456",
        "background":"#654321",
        "cursor_style":"bar",
        "cursor_blink":true,
        "palette":{"1":"#abcdef"},
        "complete":true,
    });
    let defaults = public_request(
        &mux,
        "defaults",
        "session.terminal_defaults.update",
        defaults_params.clone(),
        Some("auxiliary-restart-defaults"),
    );
    let defaults_value = defaults["result"]["value"].clone();
    let projection_id = "projection_00000000000000000000000000000001";
    let projection_params = serde_json::json!({
        "machine":"current",
        "session":"current",
        "frontend_projection":projection_id,
        "frontend_id":"cmux-test",
        "window_id":"window-restart",
        "generation":"launch-restart",
        "projection":{
            "schema":"cmux.sidebar.test/1",
            "revision":"7",
            "rows":[{"label":"build","state":"working"}],
        },
    });
    let projection = public_request(
        &mux,
        "projection",
        "frontend_projection.put",
        projection_params.clone(),
        Some("auxiliary-restart-projection"),
    );
    let projection_value = projection["result"]["value"].clone();

    let before = crate::resource_api::public_session_snapshot(&mux).unwrap();
    assert!(before["notifications"].as_array().unwrap().contains(&notification_value));
    assert!(before["agents"].as_array().unwrap().contains(&agent_value));
    assert!(before["frontend_projections"].as_array().unwrap().contains(&projection_value));
    let durable_colors = mux.default_colors();
    assert_eq!(defaults_value["foreground"], "#123456");
    assert_eq!(defaults_value["background"], "#654321");
    assert_eq!(defaults_value["cursor_style"], "bar");
    assert_eq!(defaults_value["cursor_blink"], true);
    assert_eq!(defaults_value["palette"]["1"], "#abcdef");
    mux.shutdown();
    drop(mux);

    let registry = WorkspaceRegistry::open(&root, session).unwrap();
    let reopened = Mux::from_workspace_registry(
        session.into(),
        SurfaceOptions::default(),
        registry,
        ProviderWorkspaceState::default(),
        true,
    )
    .unwrap();
    assert_eq!(reopened.default_colors(), durable_colors);
    let config_colors =
        DefaultColors { fg: Some(crate::Rgb { r: 0xee, g: 0xdd, b: 0xcc }), ..Default::default() };
    reopened.seed_default_colors_if_no_durable_override(config_colors);
    assert_eq!(
        reopened.default_colors(),
        durable_colors,
        "startup config must not overwrite an explicit durable update"
    );

    let after = crate::resource_api::public_session_snapshot(&reopened).unwrap();
    assert!(after["notifications"].as_array().unwrap().contains(&notification_value));
    assert!(after["agents"].as_array().unwrap().contains(&agent_value));
    assert!(after["frontend_projections"].as_array().unwrap().contains(&projection_value));
    let terminals = after["terminals"].as_array().unwrap();
    assert_eq!(terminals.len(), 1);
    let terminal = &terminals[0];
    assert_eq!(terminal["id"], terminal_public_id.as_str());
    assert_eq!(terminal["lifecycle"], "exited");
    assert_eq!(terminal["exit"]["outcome"]["kind"], "unknown");
    assert_eq!(terminal["exit"]["outcome"]["reason"], "missing-host-record");
    assert_eq!(reopened.resource_surface_for_terminal(&terminal_public_id), None);
    let exited =
        reopened.wait_for_terminal_exit(&terminal_public_id, Some(Duration::ZERO)).unwrap();
    assert_eq!(exited["state"], "exited");
    assert_eq!(exited["outcome"]["kind"], "unknown");
    assert_eq!(exited["outcome"]["reason"], "missing-host-record");
    let notifications =
        public_request(&reopened, "notifications", "notification.list", selectors.clone(), None);
    assert_eq!(notifications["result"], serde_json::json!([notification_value]));
    let agents = public_request(&reopened, "agents", "agent.list", selectors.clone(), None);
    assert_eq!(agents["result"], serde_json::json!([agent_value]));
    let snapshot = public_request(&reopened, "snapshot", "session.snapshot", selectors, None);
    assert_eq!(snapshot["result"]["notifications"], after["notifications"]);
    assert_eq!(snapshot["result"]["agents"], after["agents"]);
    assert_eq!(snapshot["result"]["frontend_projections"], after["frontend_projections"]);

    for (id, operation, params, key, original) in [
        (
            "create-replay",
            "workspace.create",
            create_params,
            "auxiliary-restart-create",
            created_value,
        ),
        (
            "notification-replay",
            "notification.create",
            notification_params,
            "auxiliary-restart-notification",
            notification_value,
        ),
        ("agent-replay", "agent.report", agent_params, "auxiliary-restart-agent", agent_value),
        (
            "defaults-replay",
            "session.terminal_defaults.update",
            defaults_params,
            "auxiliary-restart-defaults",
            defaults_value,
        ),
        (
            "projection-replay",
            "frontend_projection.put",
            projection_params,
            "auxiliary-restart-projection",
            projection_value,
        ),
    ] {
        let replay = public_request(&reopened, id, operation, params, Some(key));
        assert_eq!(replay["result"]["value"], original, "{operation}");
        assert_eq!(replay["result"]["replayed"], true, "{operation}");
    }
    assert_eq!(reopened.resource_notifications(256).len(), 1);
    assert!(
        reopened.list_agents(None, None).is_empty(),
        "the legacy live-surface cache must not retain a detached terminal"
    );
    assert_eq!(
        reopened.workspace_registry.lock().unwrap().public_frontend_projections().unwrap().len(),
        1
    );

    reopened.shutdown();
    drop(reopened);

    let registry = WorkspaceRegistry::open(&root, session).unwrap();
    registry.insert_corrupt_terminal_defaults_for_test();
    let error = Mux::from_workspace_registry(
        session.into(),
        SurfaceOptions::default(),
        registry,
        ProviderWorkspaceState::default(),
        true,
    )
    .err()
    .expect("corrupt durable terminal defaults must fail startup");
    assert!(
        error.to_string().contains("omitted background"),
        "unexpected startup error: {error:#}"
    );
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn resource_layout_undo_confirmation_is_restart_safe() {
    let root = std::env::temp_dir()
        .join(format!("cmux-resource-undo-restart-{}", WorkspacePublicId::random().unwrap()));
    let (fixture_snapshot, fixture_topology) = resource_restore_fixture();
    {
        let mut registry = WorkspaceRegistry::open(&root, "undo-restart").unwrap();
        registry
            .commit_resource_patch(
                &WorkspaceMutation::daemon("seed-undo-restart", "test").unwrap(),
                "session.restore_fixture",
                &serde_json::json!({"fixture":"layout-undo-restart"}),
                None,
                Some(0),
                &resource_restore_patch(&fixture_snapshot, &fixture_topology),
                &serde_json::json!({"restored":true}),
                &serde_json::json!([{"event":"session.restored"}]),
            )
            .unwrap();
    }

    let registry = WorkspaceRegistry::open(&root, "undo-restart").unwrap();
    let mux = Mux::from_workspace_registry(
        "undo-restart".into(),
        SurfaceOptions::default(),
        registry,
        ProviderWorkspaceState::default(),
        true,
    )
    .unwrap();
    let base_pane = mux.with_state(|state| state.workspaces[0].screens[0].active_pane);
    let created_terminal = mux.new_pane_right(base_pane, 0.5, Some((38, 22))).unwrap();
    let created_pane = mux.with_state(|state| state.pane_of(created_terminal.id).unwrap());
    let created = mux
        .new_browser_tab(
            "about:blank#layout-undo-restart".into(),
            Some(created_pane),
            Some((38, 22)),
        )
        .unwrap();
    assert!(mux.close_surface(created_terminal.id).unwrap());
    drop(created_terminal);
    let (selectors, screen_id) = {
        let registry = mux.workspace_registry.lock().unwrap();
        let state = mux.state.lock().unwrap();
        let (workspace, screen) = state.screen_of(created_pane).unwrap();
        (
            crate::ResourceSelectors {
                machine: Some(registry.machine_id().to_string()),
                session: Some(registry.session_id().to_string()),
                workspace: Some(state.workspaces[workspace].public_id.to_string()),
                screen: Some(state.workspaces[workspace].screens[screen].public_id.to_string()),
                ..crate::ResourceSelectors::default()
            },
            state.workspaces[workspace].screens[screen].public_id.clone(),
        )
    };
    let preview_fields = serde_json::json!({"confirm_close":false}).as_object().unwrap().clone();
    let durable_before =
        mux.workspace_registry.lock().unwrap().resource_topology_snapshot().unwrap();
    let preview_error = mux
        .resource_topology_operation(
            ResourceOperation::ScreenLayoutUndo,
            selectors.clone(),
            preview_fields,
            Some(durable_before.revision),
            &WorkspaceMutation::daemon("restart-undo-preview", "test").unwrap(),
        )
        .unwrap_err();
    let preview_revision = preview_error
        .downcast_ref::<ResourceError>()
        .and_then(|error| error.details["revision"].as_str())
        .and_then(|revision| revision.parse::<u64>().ok())
        .unwrap();
    let confirmation_token = preview_error
        .downcast_ref::<ResourceError>()
        .and_then(|error| error.details["confirmation_token"].as_str())
        .unwrap()
        .to_string();
    assert_eq!(preview_revision, durable_before.revision);
    drop(created);
    mux.shutdown();
    let shutdown_deadline = Instant::now() + Duration::from_secs(10);
    while Arc::strong_count(&mux) > 1 && Instant::now() < shutdown_deadline {
        std::thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(
        Arc::strong_count(&mux),
        1,
        "restored browser bootstrap workers must release the mux before restart"
    );
    drop(mux);

    let registry = WorkspaceRegistry::open(&root, "undo-restart").unwrap();
    let reopened = Mux::from_workspace_registry(
        "undo-restart".into(),
        SurfaceOptions::default(),
        registry,
        ProviderWorkspaceState::default(),
        true,
    )
    .unwrap();
    let reopened_before =
        reopened.workspace_registry.lock().unwrap().resource_topology_snapshot().unwrap();
    // Restart may reconcile terminal liveness into a later public
    // revision. The confirmation token is fenced by generation, screen,
    // layout revision, and pane/tab membership rather than that unrelated
    // liveness revision.
    assert!(reopened_before.revision >= durable_before.revision);
    assert_eq!(reopened_before.screens, durable_before.screens);
    assert_eq!(reopened_before.panes, durable_before.panes);
    assert_eq!(reopened_before.tabs, durable_before.tabs);
    assert!(reopened_before.screens.iter().any(|screen| screen.public_id == screen_id));
    let state_before = reopened.with_state(state_topology_fingerprint);
    let confirm_fields = serde_json::json!({
        "confirm_close":true,
        "confirmation_token":confirmation_token,
    })
    .as_object()
    .unwrap()
    .clone();
    let confirm_fingerprint = serde_json::json!({
        "operation":"screen.layout.undo",
        "selectors":selectors,
        "fields":confirm_fields,
    });
    let confirm_mutation = WorkspaceMutation::daemon("restart-undo-confirm", "test").unwrap();

    let error = reopened
        .resource_topology_operation(
            ResourceOperation::ScreenLayoutUndo,
            selectors,
            confirm_fields,
            Some(reopened_before.revision),
            &confirm_mutation,
        )
        .unwrap_err();

    assert!(matches!(error.downcast_ref::<LayoutUndoError>(), Some(LayoutUndoError::Unavailable)));
    assert_eq!(reopened.with_state(state_topology_fingerprint), state_before);
    let registry = reopened.workspace_registry.lock().unwrap();
    assert_eq!(registry.resource_topology_snapshot().unwrap(), reopened_before);
    assert!(registry.resource_events_after(reopened_before.revision).unwrap().batches.is_empty());
    assert!(
        registry
            .lookup_resource_effect(
                &confirm_mutation.id,
                "screen.layout.undo",
                &confirm_fingerprint,
            )
            .unwrap()
            .is_none()
    );
    drop(registry);
    reopened.shutdown();
    drop(reopened);
    std::fs::remove_dir_all(root).unwrap();
}
