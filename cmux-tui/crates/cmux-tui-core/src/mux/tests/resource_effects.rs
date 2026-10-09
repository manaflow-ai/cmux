//! Resource effects and ordinary mutations: one public revision per commit, rollback, idempotency.

use super::*;

fn begin_test_resource_effect(mux: &Mux, idempotency_key: &str, operation: &str) -> Value {
    let fingerprint = serde_json::json!({
        "operation": operation,
        "fixture": idempotency_key,
    });
    let expected_revision = mux.with_state(|state| state.resource_revision);
    assert!(matches!(
        mux.prepare_resource_effect(
            &WorkspaceMutation::daemon(idempotency_key, "test").unwrap(),
            operation,
            &fingerprint,
            &serde_json::json!({}),
            None,
            Some(expected_revision),
        )
        .unwrap(),
        ResourceEffectPreparation::Execute { resumed: false, .. }
    ));
    mux.mark_resource_effect_executing(idempotency_key, operation, &fingerprint).unwrap();
    fingerprint
}

#[test]
fn receipt_only_effect_commit_wakes_journal_subscribers() {
    let mux = test_mux();
    let fingerprint = begin_test_resource_effect(&mux, "receipt-only-effect", "terminal.input");
    let before = mux.journal_event_epoch();
    mux.commit_resource_effect(
        "receipt-only-effect",
        "terminal.input",
        &fingerprint,
        &ResourceEffectOutcome::Success(serde_json::json!({})),
        None,
    )
    .unwrap();
    assert_eq!(mux.journal_event_epoch(), before + 1);
}

#[test]
fn projected_effect_failure_rolls_back_revision_event_and_topology() {
    let mux = test_mux();
    let surface = mux.new_browser_tab("about:blank#rollback".into(), None, Some((80, 24))).unwrap();
    let before_revision = mux.with_state(|state| state.resource_revision);
    let fingerprint =
        begin_test_resource_effect(&mux, "effect-projection-rollback", "test.project");
    let before_epoch = mux.resource_event_epoch();
    mux.workspace_registry.lock().unwrap().set_resource_patch_failure(true).unwrap();

    let error = mux
        .commit_full_resource_effect_projection(
            "effect-projection-rollback",
            "test.project",
            &fingerprint,
            serde_json::json!({"projected":true}),
        )
        .unwrap_err();

    assert!(error.to_string().contains("forced resource patch failure"));
    assert_eq!(mux.resource_event_epoch(), before_epoch);
    mux.with_state(|state| assert_eq!(state.resource_revision, before_revision));
    let registry = mux.workspace_registry.lock().unwrap();
    assert_eq!(registry.resource_topology_snapshot().unwrap().revision, before_revision);
    assert!(registry.resource_events_after(before_revision).unwrap().batches.is_empty());
    registry.set_resource_patch_failure(false).unwrap();
    surface.kill();
}

#[test]
fn projected_effect_holds_writer_fence_through_commit_and_publishes_once() {
    use std::sync::mpsc;

    let mux = test_mux();
    let surface = mux.new_browser_tab("about:blank#race".into(), None, Some((80, 24))).unwrap();
    let original_name = mux.with_state(|state| state.workspaces[0].name.clone());
    let before_revision = mux.with_state(|state| state.resource_revision);
    let before_epoch = mux.resource_event_epoch();
    let fingerprint = begin_test_resource_effect(&mux, "effect-projection-race", "test.project");
    let projection_ready = Arc::new(std::sync::Barrier::new(2));
    let allow_commit = Arc::new(std::sync::Barrier::new(2));
    *mux.resource_projection_before_commit.lock().unwrap() = Some(Arc::new({
        let projection_ready = projection_ready.clone();
        let allow_commit = allow_commit.clone();
        move || {
            projection_ready.wait();
            allow_commit.wait();
        }
    }));

    let commit_thread = {
        let mux = mux.clone();
        std::thread::spawn(move || {
            mux.commit_full_resource_effect_projection(
                "effect-projection-race",
                "test.project",
                &fingerprint,
                serde_json::json!({"projected":true}),
            )
            .unwrap()
        })
    };
    projection_ready.wait();

    let (acquired_tx, acquired_rx) = mpsc::channel();
    let racing_writer = {
        let mux = mux.clone();
        std::thread::spawn(move || {
            let mut state = mux.state.lock().unwrap();
            state.workspaces[0].name = "Raced after capture".into();
            acquired_tx.send(()).unwrap();
        })
    };
    assert!(
        acquired_rx.recv_timeout(Duration::from_millis(50)).is_err(),
        "a topology writer entered between projection capture and durable commit"
    );
    allow_commit.wait();
    let commit = commit_thread.join().unwrap();
    acquired_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    racing_writer.join().unwrap();
    *mux.resource_projection_before_commit.lock().unwrap() = None;

    assert_eq!(commit.revision, before_revision + 1);
    assert_eq!(mux.resource_event_epoch(), before_epoch + 1);
    let registry = mux.workspace_registry.lock().unwrap();
    let snapshot = registry.snapshot().unwrap();
    assert_eq!(snapshot.resource_revision, before_revision + 1);
    assert_eq!(snapshot.workspaces[0].name, original_name);
    let events = registry.resource_events_after(before_revision).unwrap();
    assert_eq!(events.batches.len(), 1);
    let changes = events.batches[0].changes.as_array().unwrap();
    assert!(!changes.is_empty());
    for (sequence, change) in changes.iter().enumerate() {
        assert_eq!(change["sequence"], sequence);
        assert!(matches!(change["kind"].as_str(), Some("upsert" | "delete")));
        assert!(change["resource"].is_string());
        assert!(change["id"].is_string());
        assert!(change.get("event").is_none());
    }
    surface.kill();
}

#[test]
fn ordinary_workspace_mutations_publish_one_immediate_public_revision() {
    fn assert_public_state(
        mux: &Mux,
        revision: u64,
        expected: &[(&str, bool)],
    ) -> Vec<WorkspacePublicId> {
        assert_eq!(mux.resource_event_epoch(), revision);
        mux.with_state(|state| assert_eq!(state.resource_revision, revision));

        let snapshot = crate::resource_api::public_session_snapshot(mux).unwrap();
        assert_eq!(snapshot["session"]["revision"], revision.to_string());
        let workspaces = snapshot["workspaces"].as_array().unwrap();
        assert_eq!(workspaces.len(), expected.len());
        for (index, (workspace, (name, focused))) in
            workspaces.iter().zip(expected.iter()).enumerate()
        {
            assert_eq!(workspace["name"], *name);
            assert_eq!(workspace["index"], u64::try_from(index).unwrap());
            assert_eq!(workspace["focused"], *focused);
        }

        let registry = mux.workspace_registry.lock().unwrap();
        assert_eq!(registry.snapshot().unwrap().resource_revision, revision);
        let events = registry.resource_events_after(0).unwrap();
        assert_eq!(events.batches.len(), usize::try_from(revision).unwrap());
        let batch = events.batches.last().unwrap();
        assert_eq!(batch.previous_revision, revision - 1);
        assert_eq!(batch.revision, revision);
        for (sequence, change) in batch.changes.as_array().unwrap().iter().enumerate() {
            assert_eq!(change["sequence"], sequence);
            // A close also records closed history as a state change.
            assert!(matches!(
                change["kind"].as_str(),
                Some("upsert" | "delete" | "state_upsert" | "state_delete")
            ));
            assert!(change["resource"].is_string());
            assert!(change["id"].is_string());
            assert!(change.get("event").is_none());
        }
        workspaces
            .iter()
            .map(|workspace| WorkspacePublicId::parse(workspace["id"].as_str().unwrap()).unwrap())
            .collect()
    }

    let mux = test_mux();
    let first = mux.create_empty_workspace(Some("One".into()), None, Some(0)).unwrap();
    assert_public_state(&mux, 1, &[("One", true)]);

    let second = mux.create_empty_workspace(Some("Two".into()), None, Some(1)).unwrap();
    let ids = assert_public_state(&mux, 2, &[("One", false), ("Two", true)]);

    assert_eq!(
        mux.rename_workspace_at_revision(first.workspace, "Renamed".into(), Some(2)).unwrap(),
        Some(3)
    );
    assert_public_state(&mux, 3, &[("Renamed", false), ("Two", true)]);

    assert_eq!(
        mux.move_workspace_at_revision(first.workspace, 2, Some(3)).unwrap(),
        Some((4, true))
    );
    let moved_ids = assert_public_state(&mux, 4, &[("Two", true), ("Renamed", false)]);
    assert_eq!(moved_ids, vec![ids[1].clone(), ids[0].clone()]);

    assert_eq!(mux.close_workspace_at_revision(first.workspace, Some(4)).unwrap(), Some(5));
    let remaining = assert_public_state(&mux, 5, &[("Two", true)]);
    assert_eq!(remaining, vec![ids[1].clone()]);
    assert_eq!(second.workspace, mux.with_state(|state| state.workspaces[0].id));
}

fn assert_ordinary_public_revision(mux: &Mux, revision: u64) -> Value {
    assert_eq!(mux.resource_event_epoch(), revision);
    mux.with_state(|state| assert_eq!(state.resource_revision, revision));
    let snapshot = crate::resource_api::public_session_snapshot(mux).unwrap();
    assert_eq!(snapshot["session"]["revision"], revision.to_string());

    let registry = mux.workspace_registry.lock().unwrap();
    assert_eq!(registry.resource_topology_snapshot().unwrap().revision, revision);
    let events = registry.resource_events_after(0).unwrap();
    assert_eq!(events.batches.len(), usize::try_from(revision).unwrap());
    let batch = events.batches.last().unwrap();
    assert_eq!(batch.previous_revision, revision - 1);
    assert_eq!(batch.revision, revision);
    let changes = batch.changes.as_array().unwrap();
    assert!(!changes.is_empty());
    for (sequence, change) in changes.iter().enumerate() {
        assert_eq!(change["sequence"], sequence);
        // A creation also carries the new workspace's personal placement.
        assert!(matches!(
            (change["kind"].as_str(), change["resource"].as_str()),
            (Some("upsert" | "delete"), _) | (Some("state_upsert"), Some("workspace_placement"))
        ));
        assert!(change["resource"].is_string());
        assert!(change["id"].is_string());
        assert!(change.get("event").is_none());
    }
    snapshot
}

#[test]
fn ordinary_topology_creates_renames_and_focus_publish_one_revision_each() {
    let mux = test_mux();
    let first = mux.new_workspace(Some("One".into()), None).unwrap();
    assert_ordinary_public_revision(&mux, 1);
    let (first_workspace, first_screen, first_pane) = mux.with_state(|state| {
        let pane = state.pane_of(first.id).unwrap();
        let (workspace, screen) = state.screen_of(pane).unwrap();
        (state.workspaces[workspace].id, state.workspaces[workspace].screens[screen].id, pane)
    });

    let second_tab = mux.new_tab(Some(first_pane), None, None).unwrap();
    assert_ordinary_public_revision(&mux, 2);
    let browser =
        mux.new_browser_tab("about:blank#ordinary-public".into(), Some(first_pane), None).unwrap();
    assert_ordinary_public_revision(&mux, 3);

    let second_screen_surface = mux.new_screen(Some(first_workspace), None).unwrap();
    assert_ordinary_public_revision(&mux, 4);
    let second_pane = mux.with_state(|state| state.pane_of(second_screen_surface.id).unwrap());
    let split_surface = mux.split(second_pane, SplitDir::Right, None).unwrap();
    assert_ordinary_public_revision(&mux, 5);
    let split_pane = mux.with_state(|state| state.pane_of(split_surface.id).unwrap());
    let distributed_surface = mux.new_pane(split_pane, None).unwrap();
    assert_ordinary_public_revision(&mux, 6);
    let distributed_pane = mux.with_state(|state| state.pane_of(distributed_surface.id).unwrap());

    assert!(mux.rename_pane(distributed_pane, "Worker".into()));
    assert_ordinary_public_revision(&mux, 7);
    assert!(mux.rename_surface(browser.id, "Docs".into()));
    assert_ordinary_public_revision(&mux, 8);
    let second_screen = mux.with_state(|state| {
        let (workspace, screen) = state.screen_of(second_pane).unwrap();
        state.workspaces[workspace].screens[screen].id
    });
    assert!(mux.rename_screen(second_screen, "Build".into()));
    let snapshot = assert_ordinary_public_revision(&mux, 9);
    let pane_public =
        mux.with_state(|state| state.resource_indexes.pane_ids[&distributed_pane].to_string());
    let tab_public =
        mux.with_state(|state| state.resource_indexes.tab_ids[&browser.id].to_string());
    let screen_public =
        mux.with_state(|state| state.resource_indexes.screen_ids[&second_screen].to_string());
    assert_eq!(
        snapshot["panes"]
            .as_array()
            .unwrap()
            .iter()
            .find(|pane| pane["id"] == pane_public)
            .unwrap()["name"],
        "Worker"
    );
    assert_eq!(
        snapshot["tabs"].as_array().unwrap().iter().find(|tab| tab["id"] == tab_public).unwrap()["name"],
        "Docs"
    );
    assert_eq!(
        snapshot["screens"]
            .as_array()
            .unwrap()
            .iter()
            .find(|screen| screen["id"] == screen_public)
            .unwrap()["name"],
        "Build"
    );

    assert!(mux.focus_pane(second_pane));
    assert_ordinary_public_revision(&mux, 10);
    mux.select_tab(Some(first_pane), Some(0), None);
    assert_ordinary_public_revision(&mux, 11);
    mux.with_state(|state| assert_eq!(state.active_pane(), Some(second_pane)));
    mux.select_screen(Some(0), None);
    assert_ordinary_public_revision(&mux, 12);
    mux.with_state(|state| {
        assert_eq!(state.workspaces[0].screens[state.workspaces[0].active_screen].id, first_screen);
    });

    mux.new_workspace(Some("Two".into()), None).unwrap();
    assert_ordinary_public_revision(&mux, 13);
    mux.select_workspace(Some(0), None);
    let snapshot = assert_ordinary_public_revision(&mux, 14);
    assert_eq!(
        snapshot["workspaces"]
            .as_array()
            .unwrap()
            .iter()
            .find(|workspace| workspace["name"] == "One")
            .unwrap()["focused"],
        true
    );

    assert_eq!(second_tab.id, mux.with_state(|state| state.panes[&first_pane].tabs[1]));
}

#[test]
fn durable_workspace_creation_supports_the_in_process_terminal_runtime() {
    // A child that writes nothing: a live shell's OSC 7 cwd report can
    // commit a second revision before the snapshot below (1 of 3 full runs).
    let quiet = vec!["/bin/sh".into(), "-c".into(), "IFS= read -r line".into()];
    let options = SurfaceOptions { command: Some(quiet), ..SurfaceOptions::default() };
    let mux =
        Mux::new(format!("in-process-resource-{}", WorkspacePublicId::random().unwrap()), options);

    let surface = mux.new_workspace(Some("headless".into()), Some((80, 24))).unwrap();
    let identity = mux
        .resource_terminal_host_identity(&surface)
        .expect("reserved in-process terminal has a durable lifecycle identity");
    assert!(
        mux.reserved_in_process_terminals.lock().unwrap().contains_key(&surface.id),
        "in-process reservation must remain available to close and exit paths"
    );
    let snapshot = mux.workspace_registry.lock().unwrap().resource_topology_snapshot().unwrap();
    assert_eq!(snapshot.revision, 1);
    assert_eq!(snapshot.active_screens.len(), 1);
    assert_eq!(snapshot.tabs.len(), 1);
    assert_eq!(snapshot.tabs[0].terminal_id.as_deref(), Some(identity.terminal_id.as_str()));

    let workspace = mux.with_state(|state| state.workspaces[0].id);
    assert!(mux.close_workspace(workspace));
    mux.shutdown();
}

#[test]
fn ordinary_topology_projection_failure_keeps_memory_and_public_state_unchanged() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, None).unwrap();
    let pane = mux.with_state(|state| state.pane_of(surface.id).unwrap());
    mux.workspace_registry.lock().unwrap().set_resource_patch_failure(true).unwrap();

    assert!(!mux.rename_pane(pane, "Never visible".into()));

    assert_eq!(mux.resource_event_epoch(), 1);
    mux.with_state(|state| {
        assert_eq!(state.resource_revision, 1);
        assert_eq!(state.panes[&pane].name, None);
    });
    let registry = mux.workspace_registry.lock().unwrap();
    assert_eq!(registry.resource_topology_snapshot().unwrap().revision, 1);
    assert_eq!(registry.resource_events_after(0).unwrap().batches.len(), 1);
    registry.set_resource_patch_failure(false).unwrap();
}

#[test]
fn ordinary_workspace_projection_failure_rolls_back_both_registries_and_memory() {
    let mux = test_mux();
    mux.workspace_registry.lock().unwrap().set_resource_patch_failure(true).unwrap();

    let error =
        mux.create_empty_workspace(Some("Never visible".into()), None, Some(0)).unwrap_err();
    assert!(error.to_string().contains("forced resource patch failure"));
    assert_eq!(mux.resource_event_epoch(), 0);
    mux.with_state(|state| {
        assert!(state.workspaces.is_empty());
        assert_eq!(state.workspace_revision, 0);
        assert_eq!(state.resource_revision, 0);
    });
    let registry = mux.workspace_registry.lock().unwrap();
    let snapshot = registry.snapshot().unwrap();
    assert_eq!(snapshot.revision, 0);
    assert_eq!(snapshot.resource_revision, 0);
    assert!(snapshot.workspaces.is_empty());
    assert!(registry.resource_events_after(0).unwrap().batches.is_empty());
    registry.set_resource_patch_failure(false).unwrap();
}

#[test]
fn resource_idempotency_is_session_global_and_rejects_changed_input() {
    let mux = test_mux();
    let first = WorkspaceMutation::daemon("global-key", "client-a").unwrap();
    mux.resource_create_empty_workspace(Some("One".into()), None, Some(0), &first).unwrap();
    let reused = WorkspaceMutation::daemon("global-key", "client-b").unwrap();
    let error = mux
        .resource_create_empty_workspace(Some("Two".into()), None, Some(1), &reused)
        .unwrap_err();
    assert!(error.to_string().contains("idempotency.conflict"));
    mux.with_state(|state| {
        assert_eq!(state.workspaces.len(), 1);
        assert_eq!(state.workspaces[0].name, "One");
    });
}

#[test]
fn resource_results_never_expose_numeric_workspace_slots() {
    let mux = test_mux();
    let result = mux
        .resource_create_empty_workspace(
            Some("Public".into()),
            None,
            Some(0),
            &WorkspaceMutation::daemon("public-only", "test").unwrap(),
        )
        .unwrap()
        .result;
    let object = result.as_object().unwrap();
    assert_eq!(
        object.keys().map(String::as_str).collect::<HashSet<_>>(),
        HashSet::from(["workspace", "name", "index"])
    );
    assert!(WorkspacePublicId::parse(object["workspace"].as_str().unwrap()).is_ok());
    let encoded = serde_json::to_string(&result).unwrap();
    for forbidden in ["key", "workspace_key", "slot", "numeric_id", "short_id", "surface"] {
        assert!(!encoded.contains(forbidden), "leaked {forbidden}: {encoded}");
    }
}

#[test]
fn resource_large_workspace_mutations_are_targeted_and_query_bounded() {
    const WORKSPACE_COUNT: usize = 1_000;
    let mux = test_mux();
    let mut durable = Vec::with_capacity(WORKSPACE_COUNT);
    let mut memory = Vec::with_capacity(WORKSPACE_COUNT);
    let mut order = Vec::with_capacity(WORKSPACE_COUNT);
    for index in 0..WORKSPACE_COUNT {
        let public_id = restore_workspace_id(index as u128 + 1);
        let key = format!("00000000-0000-4000-8000-{index:012x}");
        let slot = mux.next_id();
        let name = format!("Workspace {}", index + 1);
        durable.push(ResourceChange::UpsertWorkspace {
            workspace: RegistryWorkspace {
                id: slot,
                public_id: public_id.clone(),
                key: key.clone(),
                name: name.clone(),
                group_key: mux.session.clone(),
            },
            position: index,
            active_screen: None,
        });
        memory.push(Workspace {
            id: slot,
            public_id: public_id.clone(),
            key,
            name,
            screens: Vec::new(),
            active_screen: 0,
        });
        order.push(public_id);
    }
    durable.push(ResourceChange::SetWorkspaceOrder { workspace_ids: order.clone() });
    durable.push(ResourceChange::SetActiveWorkspace { workspace_id: order.first().cloned() });
    {
        let mut registry = mux.workspace_registry.lock().unwrap();
        let commit = registry
            .commit_resource_patch(
                &WorkspaceMutation::daemon("seed-thousand", "test").unwrap(),
                "session.seed",
                &serde_json::json!({"count":WORKSPACE_COUNT}),
                None,
                Some(0),
                &ResourcePatch { changes: durable },
                &serde_json::json!({"count":WORKSPACE_COUNT}),
                &serde_json::json!([{"kind":"session.seeded"}]),
            )
            .unwrap();
        let mut state = mux.state.lock().unwrap();
        state.workspaces.reserve(WORKSPACE_COUNT);
        state.workspace_index_by_id.reserve(WORKSPACE_COUNT);
        state.workspace_id_by_key.reserve(WORKSPACE_COUNT);
        state.resource_indexes.workspaces.reserve(WORKSPACE_COUNT);
        state.resource_indexes.workspace_ids.reserve(WORKSPACE_COUNT);
        for workspace in memory {
            state.push_workspace(workspace);
        }
        state.active_workspace = 0;
        state.resource_revision = commit.revision;
    }

    let target = order[499].clone();
    let renamed = mux
        .resource_rename_workspace(
            &target,
            "Renamed".into(),
            None,
            Some(1),
            &WorkspaceMutation::daemon("rename-thousand", "test").unwrap(),
        )
        .unwrap();
    assert_eq!(renamed.revision, 2);
    assert_eq!(
        mux.last_resource_mutation_metrics(),
        ResourceMutationMetrics {
            touched_resources: 1,
            order_entries: 0,
            terminal_queries: 0,
            changed_rows: 1,
        }
    );
    mux.with_state(|state| {
        assert_eq!(state.workspace_by_public_id(&target).unwrap().name, "Renamed");
    });

    let moved = mux
        .resource_move_workspace(
            &target,
            WORKSPACE_COUNT - 1,
            None,
            Some(2),
            &WorkspaceMutation::daemon("move-thousand", "test").unwrap(),
        )
        .unwrap();
    assert_eq!(moved.revision, 3);
    assert_eq!(
        mux.last_resource_mutation_metrics(),
        ResourceMutationMetrics {
            touched_resources: 1,
            order_entries: WORKSPACE_COUNT,
            terminal_queries: 0,
            changed_rows: WORKSPACE_COUNT,
        }
    );
    mux.with_state(|state| {
        assert_eq!(state.workspaces.last().unwrap().public_id, target);
        assert_eq!(state.workspaces.len(), WORKSPACE_COUNT);
    });
    let registry = mux.workspace_registry.lock().unwrap().snapshot().unwrap();
    assert_eq!(registry.resource_revision, 3);
    assert_eq!(registry.workspaces.last().unwrap().public_id, target);
    assert_eq!(registry.workspaces.last().unwrap().name, "Renamed");
}
