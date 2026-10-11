//! Terminal exits across restart: sidecars, keep policy, wait results, and output reads.

use super::*;

#[cfg(unix)]
#[test]
fn restart_marks_reserved_terminal_without_host_record_exited_without_respawn() {
    const TERMINAL: &str = "00000000000040008000000000000001";
    let root = std::env::temp_dir().join(format!(
        "cmux-mux-terminal-crash-window-{}",
        crate::workspace_registry::new_uuid_v4()
    ));
    {
        let mut registry = WorkspaceRegistry::open(&root, "recover-terminal").unwrap();
        registry
            .commit(
                &WorkspaceMutation::daemon("workspace", "test").unwrap(),
                &serde_json::json!({"op":"create-workspace"}),
                None,
                Some(0),
                "workspace-added",
                "workspace-one",
                &[RegistryWorkspace {
                    id: 1,
                    public_id: WorkspacePublicId::random().unwrap(),
                    key: "workspace-one".into(),
                    name: "One".into(),
                    group_key: "recover-terminal".into(),
                }],
                &serde_json::json!({"workspace":1,"key":"workspace-one"}),
            )
            .unwrap();
        registry
            .commit_terminal(
                &WorkspaceMutation::daemon("reserve", "test").unwrap(),
                &serde_json::json!({"op":"create-terminal","terminal_id":TERMINAL}),
                None,
                Some(0),
                "terminal-reserved",
                &RegistryTerminal {
                    terminal_id: TERMINAL.into(),
                    workspace_key: "workspace-one".into(),
                    incarnation: None,
                    lifecycle: TerminalLifecycle::Launching,
                    launch_spec: serde_json::json!({"command_present":true}),
                    exit: None,
                    on_exit: TerminalOnExit::Close,
                },
                &serde_json::json!({"terminal_id":TERMINAL}),
            )
            .unwrap();
    }
    let options = SurfaceOptions {
        terminal_host_root: Some(crate::terminal_host_runtime::terminal_host_root(
            &root,
            "recover-terminal",
        )),
        ..SurfaceOptions::default()
    };
    let mux = Mux::open_persistent("recover-terminal", options, &root).unwrap();
    let resolved = mux.resolve_terminal(TERMINAL).unwrap().unwrap();
    assert_eq!(resolved.surface, None);
    assert_eq!(resolved.terminal.lifecycle, TerminalLifecycle::Exited);
    let exit = resolved.terminal.exit.unwrap();
    assert_eq!(exit["outcome"]["kind"], "unknown");
    assert_eq!(exit["outcome"]["reason"], "missing-host-record");
    assert!(exit["exited_at"].as_str().is_some());
    assert_eq!(exit["revision"], "1");
    assert_eq!(resolved.terminal_revision, 2);
    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}

#[cfg(unix)]
#[test]
fn dead_public_terminal_adoption_wakes_wait_exit() {
    const TERMINAL: &str = "00000000000040008000000000000011";
    const INCARNATION: &str = "10000000000040008000000000000011";
    let mux = test_mux();
    let workspace = mux
        .create_empty_workspace(
            Some("adoption-exit".into()),
            Some("018f6e21-7b70-7e70-8000-000000001011".into()),
            None,
        )
        .unwrap();
    let surface_id =
        mux.seed_running_terminal_for_test(TERMINAL, INCARNATION, &workspace.key).unwrap();
    let surface = mux.surface(surface_id).unwrap();
    assert!(surface.is_dead(), "the adoption fixture must model an already-dead host");
    let public_id = mux
        .workspace_registry
        .lock()
        .unwrap()
        .terminal_resource_id(TERMINAL)
        .unwrap()
        .expect("seeded terminal has a public identity");

    mux.reset_terminal_exit_state_query_count_for_test();
    let waiting_mux = mux.clone();
    let waiting_id = public_id.clone();
    let waiter = std::thread::spawn(move || {
        waiting_mux.wait_for_terminal_exit(&waiting_id, Some(Duration::from_secs(2)))
    });
    let waiting_deadline = Instant::now() + Duration::from_secs(1);
    while mux.terminal_exit_waiter_count_for_test(&public_id) != 1
        || mux.terminal_exit_state_query_count_for_test() != 1
    {
        assert!(Instant::now() < waiting_deadline, "exit wait did not subscribe");
        std::thread::yield_now();
    }

    let error = mux
        .finish_terminal_adoption(TERMINAL, INCARNATION, surface)
        .expect_err("dead adoption must fail after persisting its exit");
    assert!(error.to_string().contains("exited during adoption"));

    let exited = waiter.join().unwrap().unwrap();
    assert_eq!(exited["state"], "exited");
    assert_eq!(
        exited["outcome"],
        serde_json::json!({
            "kind":"unknown",
            "reason":"host-exited-during-adoption",
        })
    );
    assert_eq!(mux.terminal_exit_state_query_count_for_test(), 2);
    assert_eq!(mux.terminal_exit_waiter_count_for_test(&public_id), 0);
}

#[cfg(unix)]
#[test]
fn restart_sidecar_restores_exact_wait_exit_and_emits_one_public_event() {
    use std::fs::{File, OpenOptions};
    use std::io::Write;
    use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};

    const TERMINAL: &str = "0000000000004000800000000000002a";
    const INCARNATION: &str = "1000000000004000800000000000002a";
    let root = std::env::temp_dir().join(format!(
        "cmux-mux-terminal-exit-sidecar-{}",
        crate::workspace_registry::new_uuid_v4()
    ));
    let session = "recover-exact-exit";
    let workspace = RegistryWorkspace {
        id: 1,
        public_id: restore_workspace_id(42),
        key: "workspace-exit".into(),
        name: "Exit".into(),
        group_key: session.into(),
    };
    let screen = restore_screen_id(42);
    let pane = restore_pane_id(42);
    let tab = restore_tab_id(42);
    let terminal_public_id = restore_terminal_id(42);
    let terminal = RegistryTerminal {
        terminal_id: TERMINAL.into(),
        workspace_key: workspace.key.clone(),
        incarnation: None,
        lifecycle: TerminalLifecycle::Launching,
        launch_spec: serde_json::json!({"command":["/bin/sh"]}),
        exit: None,
        on_exit: TerminalOnExit::Close,
    };
    {
        let mut registry = WorkspaceRegistry::open(&root, session).unwrap();
        registry
            .commit_resource_patch(
                &WorkspaceMutation::daemon("seed-terminal-exit", "test").unwrap(),
                "workspace.create",
                &serde_json::json!({"fixture":"terminal-exit"}),
                None,
                Some(0),
                &ResourcePatch {
                    changes: vec![
                        ResourceChange::UpsertWorkspace {
                            workspace: workspace.clone(),
                            position: 0,
                            active_screen: Some(screen.clone()),
                        },
                        ResourceChange::UpsertScreen(RegistryScreen {
                            public_id: screen.clone(),
                            workspace_id: workspace.public_id.clone(),
                            position: 0,
                            name: None,
                            layout: RegistryLayoutNode::Leaf { pane: pane.clone() },
                            active_pane: pane.clone(),
                            zoomed_pane: None,
                            auto_layout: None,
                            viewport: RegistryViewport::default(),
                        }),
                        ResourceChange::UpsertPane(RegistryPane {
                            public_id: pane.clone(),
                            screen_id: screen.clone(),
                            name: None,
                            active_tab: Some(tab.clone()),
                            creation_ordinal: 1,
                        }),
                        ResourceChange::UpsertTerminal {
                            public_id: terminal_public_id.clone(),
                            terminal,
                        },
                        ResourceChange::UpsertTab(RegistryTab {
                            name_source: Default::default(),
                            name_revision: 0,
                            public_id: tab.clone(),
                            pane_id: pane.clone(),
                            position: 0,
                            content_id: ContentPublicId::Terminal(terminal_public_id.clone()),
                            name: None,
                            browser_url: None,
                            terminal_id: Some(TERMINAL.into()),
                        }),
                        ResourceChange::SetWorkspaceOrder {
                            workspace_ids: vec![workspace.public_id.clone()],
                        },
                        ResourceChange::SetScreenOrder {
                            workspace_id: workspace.public_id.clone(),
                            screen_ids: vec![screen],
                        },
                        ResourceChange::SetTabOrder { pane_id: pane, tab_ids: vec![tab.clone()] },
                        ResourceChange::SetActiveWorkspace {
                            workspace_id: Some(workspace.public_id),
                        },
                    ],
                },
                &serde_json::json!({"created":true}),
                &serde_json::json!([{"kind":"fixture.created"}]),
            )
            .unwrap();
        commit_terminal_lifecycle(
            &mut registry,
            "terminal-ready",
            "seed-running-terminal",
            TERMINAL,
            TerminalLifecycle::Running,
            Some(INCARNATION),
            None,
        )
        .unwrap();
    }

    let host_root = crate::terminal_host_runtime::terminal_host_root(&root, session);
    std::fs::create_dir_all(&host_root).unwrap();
    std::fs::set_permissions(&host_root, std::fs::Permissions::from_mode(0o700)).unwrap();
    let exit = TerminalExit {
        outcome: crate::terminal_host_protocol::TerminalExitOutcome::Signal {
            signal: libc::SIGTERM,
            core_dumped: false,
        },
        exited_at_ms: 1_234_567,
    };
    let sidecar = crate::terminal_host_runtime::TerminalHostExitRecord::new(
        &TerminalHostIdentity { terminal_id: TERMINAL.into(), incarnation: INCARNATION.into() },
        exit,
    );
    let sidecar_path = sidecar.record_path(&host_root);
    let mut file =
        OpenOptions::new().write(true).create_new(true).mode(0o600).open(&sidecar_path).unwrap();
    file.write_all(&serde_json::to_vec(&sidecar).unwrap()).unwrap();
    file.sync_all().unwrap();
    File::open(&host_root).unwrap().sync_all().unwrap();

    let options =
        SurfaceOptions { terminal_host_root: Some(host_root), ..SurfaceOptions::default() };
    let failing_registry = {
        let registry = WorkspaceRegistry::open(&root, session).unwrap();
        registry.set_resource_patch_failure(true).unwrap();
        registry
    };
    let failure = Mux::from_workspace_registry(
        session.to_string(),
        options.clone(),
        failing_registry,
        ProviderWorkspaceState::default(),
        false,
    )
    .err()
    .expect("injected resource event failure must abort sidecar recovery");
    assert!(failure.to_string().contains("forced resource patch failure"));
    assert!(sidecar_path.exists(), "a rolled-back SQLite transaction must retain restart evidence");

    let mux = Mux::open_persistent(session, options.clone(), &root).unwrap();
    let waited = mux.wait_for_terminal_exit(&terminal_public_id, Some(Duration::ZERO)).unwrap();
    assert_eq!(waited["state"], "exited");
    assert_eq!(
        waited["outcome"],
        serde_json::json!({
            "kind":"signal",
            "signal":libc::SIGTERM,
            "core_dumped":false,
        })
    );
    assert_eq!(waited["exited_at"], "1234567");
    assert_eq!(waited["revision"], "2");
    assert!(!sidecar_path.exists(), "SQLite commit acknowledges the exact sidecar");
    let events = mux.resource_events_after(1).unwrap();
    assert_eq!(events.batches.len(), 1);
    let changes = events.batches[0].changes.as_array().unwrap();
    assert!(changes.iter().any(|change| {
        change["kind"] == "upsert"
            && change["resource"] == "terminal"
            && change["id"] == terminal_public_id.as_str()
            && change["value"]["lifecycle"] == "exited"
    }));
    assert!(changes.iter().any(|change| {
        change["kind"] == "delete" && change["resource"] == "tab" && change["id"] == tab.as_str()
    }));
    assert!(!changes.iter().any(|change| {
        change["kind"] == "delete"
            && change["resource"] == "terminal"
            && change["id"] == terminal_public_id.as_str()
    }));
    mux.shutdown();
    drop(mux);

    let reopened = Mux::open_persistent(session, options, &root).unwrap();
    assert_eq!(
        reopened.wait_for_terminal_exit(&terminal_public_id, Some(Duration::ZERO)).unwrap(),
        waited
    );
    assert_eq!(reopened.resource_events_after(1).unwrap().batches.len(), 1);
    reopened.shutdown();
    drop(reopened);
    std::fs::remove_dir_all(root).unwrap();
}

/// A keep-policy terminal only retains its views while the in-memory VT
/// is alive. After a daemon restart the surface is gone, so restart
/// reconciliation degrades the kept terminal to the normal detach while
/// preserving the exact durable exit receipt.
#[cfg(unix)]
#[test]
fn restart_degrades_keep_policy_terminal_to_the_normal_detach() {
    use std::fs::{File, OpenOptions};
    use std::io::Write;
    use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};

    const TERMINAL: &str = "0000000000004000800000000000004b";
    const INCARNATION: &str = "1000000000004000800000000000004b";
    let root = std::env::temp_dir()
        .join(format!("cmux-mux-keep-exit-restart-{}", crate::workspace_registry::new_uuid_v4()));
    let session = "recover-keep-exit";
    let workspace = RegistryWorkspace {
        id: 1,
        public_id: restore_workspace_id(43),
        key: "workspace-keep-exit".into(),
        name: "Keep".into(),
        group_key: session.into(),
    };
    let screen = restore_screen_id(43);
    let pane = restore_pane_id(43);
    let tab = restore_tab_id(43);
    let terminal_public_id = restore_terminal_id(43);
    let terminal = RegistryTerminal {
        terminal_id: TERMINAL.into(),
        workspace_key: workspace.key.clone(),
        incarnation: None,
        lifecycle: TerminalLifecycle::Launching,
        launch_spec: serde_json::json!({"command":["/bin/sh"]}),
        exit: None,
        on_exit: TerminalOnExit::Keep,
    };
    {
        let mut registry = WorkspaceRegistry::open(&root, session).unwrap();
        registry
            .commit_resource_patch(
                &WorkspaceMutation::daemon("seed-keep-exit", "test").unwrap(),
                "workspace.create",
                &serde_json::json!({"fixture":"keep-exit"}),
                None,
                Some(0),
                &ResourcePatch {
                    changes: vec![
                        ResourceChange::UpsertWorkspace {
                            workspace: workspace.clone(),
                            position: 0,
                            active_screen: Some(screen.clone()),
                        },
                        ResourceChange::UpsertScreen(RegistryScreen {
                            public_id: screen.clone(),
                            workspace_id: workspace.public_id.clone(),
                            position: 0,
                            name: None,
                            layout: RegistryLayoutNode::Leaf { pane: pane.clone() },
                            active_pane: pane.clone(),
                            zoomed_pane: None,
                            auto_layout: None,
                            viewport: RegistryViewport::default(),
                        }),
                        ResourceChange::UpsertPane(RegistryPane {
                            public_id: pane.clone(),
                            screen_id: screen.clone(),
                            name: None,
                            active_tab: Some(tab.clone()),
                            creation_ordinal: 1,
                        }),
                        ResourceChange::UpsertTerminal {
                            public_id: terminal_public_id.clone(),
                            terminal,
                        },
                        ResourceChange::UpsertTab(RegistryTab {
                            name_source: Default::default(),
                            name_revision: 0,
                            public_id: tab.clone(),
                            pane_id: pane.clone(),
                            position: 0,
                            content_id: ContentPublicId::Terminal(terminal_public_id.clone()),
                            name: None,
                            browser_url: None,
                            terminal_id: Some(TERMINAL.into()),
                        }),
                        ResourceChange::SetWorkspaceOrder {
                            workspace_ids: vec![workspace.public_id.clone()],
                        },
                        ResourceChange::SetScreenOrder {
                            workspace_id: workspace.public_id.clone(),
                            screen_ids: vec![screen],
                        },
                        ResourceChange::SetTabOrder { pane_id: pane, tab_ids: vec![tab.clone()] },
                        ResourceChange::SetActiveWorkspace {
                            workspace_id: Some(workspace.public_id),
                        },
                    ],
                },
                &serde_json::json!({"created":true}),
                &serde_json::json!([{"kind":"fixture.created"}]),
            )
            .unwrap();
        commit_terminal_lifecycle(
            &mut registry,
            "terminal-ready",
            "seed-running-terminal",
            TERMINAL,
            TerminalLifecycle::Running,
            Some(INCARNATION),
            None,
        )
        .unwrap();
    }

    let host_root = crate::terminal_host_runtime::terminal_host_root(&root, session);
    std::fs::create_dir_all(&host_root).unwrap();
    std::fs::set_permissions(&host_root, std::fs::Permissions::from_mode(0o700)).unwrap();
    let exit = TerminalExit {
        outcome: crate::terminal_host_protocol::TerminalExitOutcome::Exit { code: 3 },
        exited_at_ms: 7_654_321,
    };
    let sidecar = crate::terminal_host_runtime::TerminalHostExitRecord::new(
        &TerminalHostIdentity { terminal_id: TERMINAL.into(), incarnation: INCARNATION.into() },
        exit,
    );
    let sidecar_path = sidecar.record_path(&host_root);
    let mut file =
        OpenOptions::new().write(true).create_new(true).mode(0o600).open(&sidecar_path).unwrap();
    file.write_all(&serde_json::to_vec(&sidecar).unwrap()).unwrap();
    file.sync_all().unwrap();
    File::open(&host_root).unwrap().sync_all().unwrap();

    let options =
        SurfaceOptions { terminal_host_root: Some(host_root), ..SurfaceOptions::default() };
    let mux = Mux::open_persistent(session, options, &root).unwrap();
    let waited = mux.wait_for_terminal_exit(&terminal_public_id, Some(Duration::ZERO)).unwrap();
    assert_eq!(waited["state"], "exited");
    assert_eq!(waited["outcome"], serde_json::json!({"kind":"exit","code":3}));
    let resolved = mux.resolve_terminal(TERMINAL).unwrap().unwrap();
    assert_eq!(resolved.terminal.lifecycle, TerminalLifecycle::Exited);
    assert_eq!(resolved.surface, None, "restart must not resurrect the kept screen");
    let events = mux.resource_events_after(1).unwrap();
    let changes = events
        .batches
        .iter()
        .flat_map(|batch| batch.changes.as_array().unwrap().clone())
        .collect::<Vec<_>>();
    assert!(changes.iter().any(|change| {
        change["kind"] == "delete" && change["resource"] == "tab" && change["id"] == tab.as_str()
    }));
    assert!(!changes.iter().any(|change| {
        change["kind"] == "delete"
            && change["resource"] == "terminal"
            && change["id"] == terminal_public_id.as_str()
    }));
    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}

#[cfg(unix)]
#[test]
fn restart_keeps_exited_terminal_as_detached_receipt_until_explicit_close() {
    const TERMINAL: &str = "0000000000004000800000000000000c";
    const INCARNATION: &str = "1000000000004000800000000000000c";
    let root = std::env::temp_dir()
        .join(format!("cmux-mux-exited-placeholder-{}", crate::workspace_registry::new_uuid_v4()));
    {
        let mut registry = WorkspaceRegistry::open(&root, "recover-exited").unwrap();
        registry
            .commit(
                &WorkspaceMutation::daemon("workspace", "test").unwrap(),
                &serde_json::json!({"op":"create-workspace"}),
                None,
                Some(0),
                "workspace-added",
                "workspace-one",
                &[RegistryWorkspace {
                    id: 1,
                    public_id: WorkspacePublicId::random().unwrap(),
                    key: "workspace-one".into(),
                    name: "One".into(),
                    group_key: "recover-exited".into(),
                }],
                &serde_json::json!({"workspace":1,"key":"workspace-one"}),
            )
            .unwrap();
        let reserved = RegistryTerminal {
            terminal_id: TERMINAL.into(),
            workspace_key: "workspace-one".into(),
            incarnation: None,
            lifecycle: TerminalLifecycle::Launching,
            launch_spec: serde_json::json!({}),
            exit: None,
            on_exit: TerminalOnExit::Close,
        };
        commit_terminal_transition(
            &mut registry,
            "terminal-reserved",
            "reserve-terminal",
            &reserved,
        )
        .unwrap();
        commit_terminal_lifecycle(
            &mut registry,
            "terminal-exited",
            "host-exited",
            TERMINAL,
            TerminalLifecycle::Exited,
            Some(INCARNATION),
            Some(serde_json::json!({
                "outcome":{"kind":"unknown","reason":"persisted-exit"},
                "exited_at":"1234567",
                "revision":"0",
            })),
        )
        .unwrap();
    }
    let options = SurfaceOptions {
        terminal_host_root: Some(crate::terminal_host_runtime::terminal_host_root(
            &root,
            "recover-exited",
        )),
        ..SurfaceOptions::default()
    };
    let mux = Mux::open_persistent("recover-exited", options.clone(), &root).unwrap();
    let resolved = mux.resolve_terminal(TERMINAL).unwrap().unwrap();
    assert_eq!(resolved.terminal.lifecycle, TerminalLifecycle::Exited);
    assert_eq!(resolved.terminal.exit.as_ref().unwrap()["outcome"]["reason"], "persisted-exit");
    assert_eq!(resolved.surface, None, "Exited receipt must not rematerialize a tab");

    // Explicit close tombstones the retained receipt and burns its UUID.
    let closed = mux.close_terminal(TERMINAL, INCARNATION).unwrap();
    assert_eq!(closed.surface, None);
    let closed = mux.resolve_terminal(TERMINAL).unwrap().unwrap();
    assert_eq!(closed.surface, None);
    assert_eq!(closed.terminal.lifecycle, TerminalLifecycle::Tombstoned);
    mux.shutdown();
    drop(mux);

    let reopened = Mux::open_persistent("recover-exited", options, &root).unwrap();
    let tombstoned = reopened.resolve_terminal(TERMINAL).unwrap().unwrap();
    assert_eq!(tombstoned.surface, None);
    assert_eq!(tombstoned.terminal.lifecycle, TerminalLifecycle::Tombstoned);
    assert_eq!(tombstoned.terminal.exit.unwrap()["outcome"]["reason"], "persisted-exit");
    reopened.shutdown();
    drop(reopened);
    std::fs::remove_dir_all(root).unwrap();
}

#[cfg(unix)]
#[test]
fn hosted_terminal_exit_removes_sole_surface_but_preserves_exact_wait_result() {
    const TERMINAL: &str = "0000000000004000800000000000003c";
    const INCARNATION: &str = "1000000000004000800000000000003c";
    let mux = test_mux();
    let workspace = mux
        .create_empty_workspace(
            Some("sole-exit".into()),
            Some("018f6e21-7b70-7e70-8000-00000000103c".into()),
            None,
        )
        .unwrap();
    let surface =
        mux.seed_running_terminal_for_test(TERMINAL, INCARNATION, &workspace.key).unwrap();
    let terminal =
        mux.workspace_registry.lock().unwrap().terminal_resource_id(TERMINAL).unwrap().unwrap();
    let exit = TerminalExit {
        outcome: crate::terminal_host_protocol::TerminalExitOutcome::Exit { code: 23 },
        exited_at_ms: 7_654_321,
    };
    assert!(mux.persist_terminal_exit_for_test(&terminal, &exit).unwrap());

    mux.surface_exited(surface);

    let resolved = mux.resolve_terminal(TERMINAL).unwrap().unwrap();
    assert_eq!(resolved.surface, None);
    assert_eq!(resolved.terminal.lifecycle, TerminalLifecycle::Exited);
    assert_eq!(
        mux.wait_for_terminal_exit(&terminal, Some(Duration::ZERO)).unwrap(),
        serde_json::json!({
            "state":"exited",
            "terminal_id":terminal,
            "lifecycle":"exited",
            "outcome":{"kind":"exit","code":23},
            "exited_at":"7654321",
            "revision":"3",
        })
    );
    mux.with_state(|state| {
        assert!(!state.surfaces.contains_key(&surface));
        // The exit detached the last tab, so its workspace closed too.
        assert!(state.workspaces.is_empty());
        assert_eq!(state.active_pane(), None);
    });
}

#[cfg(unix)]
#[test]
fn hosted_terminal_exit_selects_live_tab_and_duplicate_exit_is_idempotent() {
    const TERMINAL: &str = "0000000000004000800000000000003d";
    const INCARNATION: &str = "1000000000004000800000000000003d";
    let mux = test_mux();
    let workspace = mux
        .create_empty_workspace(
            Some("tab-neighbor-exit".into()),
            Some("018f6e21-7b70-7e70-8000-00000000103d".into()),
            None,
        )
        .unwrap();
    let exited = mux.seed_running_terminal_for_test(TERMINAL, INCARNATION, &workspace.key).unwrap();
    let pane = mux.with_state(|state| state.pane_of(exited).unwrap());
    let neighbor = mux.new_tab(Some(pane), None, Some((80, 24))).unwrap();
    let terminal =
        mux.workspace_registry.lock().unwrap().terminal_resource_id(TERMINAL).unwrap().unwrap();
    let exit = TerminalExit {
        outcome: crate::terminal_host_protocol::TerminalExitOutcome::Signal {
            signal: libc::SIGTERM,
            core_dumped: false,
        },
        exited_at_ms: 8_765_432,
    };
    assert!(mux.persist_terminal_exit_for_test(&terminal, &exit).unwrap());

    mux.surface_exited(exited);

    mux.with_state(|state| {
        assert!(!state.surfaces.contains_key(&exited));
        assert_eq!(state.panes[&pane].tabs, vec![neighbor.id]);
        assert_eq!(state.panes[&pane].active_surface(), Some(neighbor.id));
    });
    assert_eq!(mux.active_surface(), Some(neighbor.id));
    let revision = mux.workspace_registry.lock().unwrap().resource_revision().unwrap();
    let waited = mux.wait_for_terminal_exit(&terminal, Some(Duration::ZERO)).unwrap();

    mux.surface_exited(exited);

    assert_eq!(mux.workspace_registry.lock().unwrap().resource_revision().unwrap(), revision);
    assert_eq!(mux.wait_for_terminal_exit(&terminal, Some(Duration::ZERO)).unwrap(), waited);
    mux.with_state(|state| {
        assert_eq!(state.panes[&pane].tabs, vec![neighbor.id]);
    });
    assert_eq!(mux.active_surface(), Some(neighbor.id));
    mux.close_surface(neighbor.id).unwrap();
}

#[cfg(unix)]
#[test]
fn output_read_serves_live_records_and_exit_snapshot_after_close_detach() {
    const TERMINAL: &str = "0000000000004000800000000000004e";
    const INCARNATION: &str = "1000000000004000800000000000004e";
    let root = std::env::temp_dir()
        .join(format!("cmux-mux-output-read-{}", crate::workspace_registry::new_uuid_v4()));
    let mux = Mux::open_persistent("output-read", SurfaceOptions::default(), &root).unwrap();
    let workspace = mux.create_empty_workspace(None, None, None).unwrap();
    let surface_id =
        mux.seed_running_terminal_for_test(TERMINAL, INCARNATION, &workspace.key).unwrap();
    let surface = mux.surface(surface_id).unwrap();
    let terminal =
        mux.workspace_registry.lock().unwrap().terminal_resource_id(TERMINAL).unwrap().unwrap();
    let colored: &[u8] = b"output read \x1b[31mred marker\x1b[0m\r\nsecond line\r\n";
    surface.apply_stream_output_for_test(colored).unwrap();
    {
        let event = crate::journal_ingress::JournalIngressEvent::TerminalOutput {
            terminal_id: Arc::new(terminal.clone()),
            generation: INCARNATION.into(),
            occurred_at_ms: 1,
            bytes: colored.to_vec(),
        };
        mux.workspace_registry.lock().unwrap().append_journal_ingress_events(&[&event]).unwrap();
    }
    let total = u64::try_from(colored.len()).unwrap();

    // Live: the record window renders plain text with a resumable cursor.
    let live = mux.terminal_output_read(&terminal, None, 1 << 20).unwrap();
    let text = live["text"].as_str().unwrap();
    assert!(text.contains("red marker") && text.contains("second line"), "{live}");
    assert!(!text.contains('\u{1b}'), "escape bytes leaked into plain text: {live}");
    assert_eq!(live["start_offset"], "0");
    assert_eq!(live["next_offset"], total.to_string());
    assert_eq!(live["complete"], true);

    // The exit latch (close policy) captures the snapshot around the
    // commit and the detach removes the runtime surface.
    let exit = TerminalExit {
        outcome: crate::terminal_host_protocol::TerminalExitOutcome::Exit { code: 0 },
        exited_at_ms: 1_234,
    };
    assert!(mux.persist_terminal_exit_for_test(&terminal, &exit).unwrap());
    mux.surface_exited(surface_id);
    assert!(mux.terminal_resource_surface(&terminal).is_none());
    let snapshot = mux
        .workspace_registry
        .lock()
        .unwrap()
        .terminal_exit_snapshot(terminal.as_str())
        .unwrap()
        .expect("the exit latch stored a snapshot");
    assert_eq!(snapshot.generation, INCARNATION);
    assert_eq!(snapshot.covered_through, total);

    // Post-exit, surface gone: the snapshot projection answers, stays
    // escape-free, and hands back the exact resume cursor.
    let after_exit = mux.terminal_output_read(&terminal, None, 1 << 20).unwrap();
    let text = after_exit["text"].as_str().unwrap();
    assert!(text.contains("red marker") && text.contains("second line"), "{after_exit}");
    assert!(!text.contains('\u{1b}'), "escape bytes leaked after exit: {after_exit}");
    assert_eq!(after_exit["start_offset"], "0");
    assert_eq!(after_exit["next_offset"], total.to_string());
    assert_eq!(after_exit["complete"], true);

    // Resuming at the snapshot edge is exact: empty and complete.
    let resumed = mux.terminal_output_read(&terminal, Some(total), 1 << 20).unwrap();
    assert_eq!(resumed["text"], "");
    assert_eq!(resumed["start_offset"], total.to_string());
    assert_eq!(resumed["next_offset"], total.to_string());
    assert_eq!(resumed["complete"], true);

    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}

#[cfg(unix)]
#[test]
fn keep_policy_exit_latches_the_receipt_but_retains_tab_and_screen_surface() {
    const TERMINAL: &str = "0000000000004000800000000000004a";
    const INCARNATION: &str = "1000000000004000800000000000004a";
    let mux = test_mux();
    let workspace = mux
        .create_empty_workspace(
            Some("keep-exit".into()),
            Some("018f6e21-7b70-7e70-8000-00000000104a".into()),
            None,
        )
        .unwrap();
    let surface = mux
        .seed_running_terminal_with_on_exit_for_test(
            TERMINAL,
            INCARNATION,
            &workspace.key,
            TerminalOnExit::Keep,
        )
        .unwrap();
    let pane = mux.with_state(|state| state.pane_of(surface).unwrap());
    let terminal =
        mux.workspace_registry.lock().unwrap().terminal_resource_id(TERMINAL).unwrap().unwrap();
    let exit = TerminalExit {
        outcome: crate::terminal_host_protocol::TerminalExitOutcome::Exit { code: 7 },
        exited_at_ms: 9_999_999,
    };
    assert!(mux.persist_terminal_exit_for_test(&terminal, &exit).unwrap());

    mux.surface_exited(surface);

    // The durable latch is identical to the close policy.
    let waited = mux.wait_for_terminal_exit(&terminal, Some(Duration::ZERO)).unwrap();
    assert_eq!(waited["state"], "exited");
    assert_eq!(waited["outcome"], serde_json::json!({"kind":"exit","code":7}));
    let resolved = mux.resolve_terminal(TERMINAL).unwrap().unwrap();
    assert_eq!(resolved.terminal.lifecycle, TerminalLifecycle::Exited);
    // The views and the runtime screen surface stay behind it.
    assert_eq!(resolved.surface, Some(surface));
    mux.with_state(|state| {
        assert!(state.surfaces.contains_key(&surface));
        assert_eq!(state.panes[&pane].tabs, vec![surface]);
    });

    // Re-observed exits stay first-writer-wins, and detach reconciliation
    // is a no-op while the runtime surface lives.
    let revision = mux.workspace_registry.lock().unwrap().resource_revision().unwrap();
    mux.surface_exited(surface);
    assert!(!mux.detach_exited_terminal_topology(TERMINAL).unwrap());
    assert_eq!(mux.workspace_registry.lock().unwrap().resource_revision().unwrap(), revision);
    mux.with_state(|state| {
        assert_eq!(state.panes[&pane].tabs, vec![surface]);
    });

    // Explicit close still cleans the kept terminal up completely.
    mux.close_terminal(TERMINAL, INCARNATION).unwrap();
    let closed = mux.resolve_terminal(TERMINAL).unwrap().unwrap();
    assert_eq!(closed.terminal.lifecycle, TerminalLifecycle::Tombstoned);
    assert_eq!(closed.surface, None);
    mux.with_state(|state| assert!(!state.surfaces.contains_key(&surface)));
}

#[cfg(unix)]
#[test]
fn failed_exit_detach_retry_does_not_keep_mux_alive() {
    const TERMINAL: &str = "0000000000004000800000000000003e";
    const INCARNATION: &str = "1000000000004000800000000000003e";
    let mux = test_mux();
    let workspace = mux
        .create_empty_workspace(
            Some("failed-exit-detach".into()),
            Some("018f6e21-7b70-7e70-8000-00000000103e".into()),
            None,
        )
        .unwrap();
    let surface =
        mux.seed_running_terminal_for_test(TERMINAL, INCARNATION, &workspace.key).unwrap();
    mux.workspace_registry.lock().unwrap().set_resource_patch_failure(true).unwrap();

    mux.surface_exited(surface);

    assert!(mux.terminal_exit_detaches.active.lock().unwrap().contains(TERMINAL));
    let weak = Arc::downgrade(&mux);
    drop(mux);
    let deadline = Instant::now() + Duration::from_secs(1);
    while weak.upgrade().is_some() {
        assert!(Instant::now() < deadline, "detach retry retained the mux after its owner left");
        std::thread::sleep(Duration::from_millis(1));
    }
}
