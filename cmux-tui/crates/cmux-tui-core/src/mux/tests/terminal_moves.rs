//! Terminal moves and pending topology callbacks: canonical workspace and commit order.

use super::*;

#[cfg(unix)]
#[test]
fn create_move_during_launch_binds_only_latest_canonical_workspace() {
    const TERMINAL: &str = "0000000000004000800000000000000d";
    const INCARNATION: &str = "1000000000004000800000000000000d";
    let mux = test_mux();
    let first = mux
        .create_empty_workspace(None, Some("018f6e21-7b70-7e70-8000-000000001006".into()), None)
        .unwrap();
    let second = mux
        .create_empty_workspace(None, Some("018f6e21-7b70-7e70-8000-000000001007".into()), None)
        .unwrap();
    commit_terminal_transition(
        &mut mux.workspace_registry.lock().unwrap(),
        "terminal-reserved",
        "reserve-terminal",
        &RegistryTerminal {
            terminal_id: TERMINAL.into(),
            workspace_key: first.key,
            incarnation: None,
            lifecycle: TerminalLifecycle::Launching,
            launch_spec: serde_json::json!({}),
            exit: None,
            on_exit: TerminalOnExit::Close,
        },
    )
    .unwrap();

    // The GUI move commits while process launch has released the writer
    // lock and before the daemon-local surface exists.
    let moved = mux
        .move_terminal_with_mutation(
            TERMINAL,
            &second.key,
            None,
            None,
            Some(1),
            &WorkspaceMutation::daemon("move-during-launch", "browser").unwrap(),
        )
        .unwrap();
    assert_eq!(moved.placement, None);
    let (_, ready_revision) = commit_terminal_lifecycle(
        &mut mux.workspace_registry.lock().unwrap(),
        "terminal-ready",
        "terminal-ready",
        TERMINAL,
        TerminalLifecycle::Running,
        Some(INCARNATION),
        None,
    )
    .unwrap();
    assert_eq!(ready_revision, 3);

    let surface = Surface::exited_terminal_placeholder(
        mux.next_id(),
        mux.surface_options.lock().unwrap().clone(),
        Arc::downgrade(&mux),
        TerminalHostIdentity { terminal_id: TERMINAL.into(), incarnation: INCARNATION.into() },
    )
    .unwrap();
    insert_surface_checked(&mut mux.state.lock().unwrap(), surface.clone()).unwrap();
    let (placement, canonical_workspace, changed, _) =
        mux.bind_running_terminal_to_canonical_workspace(&surface).unwrap();
    assert!(changed);
    assert_eq!(canonical_workspace, second.key);
    assert_eq!(placement.workspace, second.workspace);
    mux.with_state(|state| {
        assert_eq!(state.pane_of(surface.id), Some(placement.pane));
        assert_eq!(
            state
                .surfaces
                .values()
                .filter_map(|surface| surface.terminal_host_identity())
                .filter(|identity| identity.terminal_id == TERMINAL)
                .count(),
            1
        );
    });
}

#[test]
fn late_lifecycle_transition_preserves_latest_canonical_workspace_move() {
    const TERMINAL: &str = "00000000000040008000000000000002";
    const INCARNATION: &str = "10000000000040008000000000000001";
    let mux = test_mux();
    let first = mux
        .create_empty_workspace(None, Some("018f6e21-7b70-7e70-8000-000000001008".into()), None)
        .unwrap();
    let second = mux
        .create_empty_workspace(None, Some("018f6e21-7b70-7e70-8000-000000001009".into()), None)
        .unwrap();
    {
        let mut registry = mux.workspace_registry.lock().unwrap();
        let reserved = RegistryTerminal {
            terminal_id: TERMINAL.into(),
            workspace_key: first.key,
            incarnation: None,
            lifecycle: TerminalLifecycle::Launching,
            launch_spec: serde_json::json!({"command_present":true}),
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
            "terminal-ready",
            "terminal-ready",
            TERMINAL,
            TerminalLifecycle::Running,
            Some(INCARNATION),
            None,
        )
        .unwrap();
        commit_terminal_workspace(&mut registry, TERMINAL, &second.key).unwrap();
    }
    mux.persist_terminal_exit(TERMINAL, Some(INCARNATION), &TerminalEnd::host_lost("test"))
        .unwrap();
    let terminal = mux.resolve_terminal(TERMINAL).unwrap().unwrap().terminal;
    assert_eq!(terminal.workspace_key, second.key);
    assert_eq!(terminal.lifecycle, TerminalLifecycle::Exited);
    assert_eq!(terminal.launch_spec, serde_json::json!({"command_present":true}));
}

#[cfg(unix)]
#[test]
fn pending_topology_accepts_current_host_reconnect_without_advancing_lifecycle() {
    const TERMINAL: &str = "00000000000040008000000000000012";
    const INCARNATION: &str = "10000000000040008000000000000012";
    const PENDING_SURFACE: SurfaceId = 4242;
    let mux = test_mux();
    let workspace = mux
        .create_empty_workspace(None, Some("018f6e21-7b70-7e70-8000-000000001112".into()), None)
        .unwrap();
    let identity =
        TerminalHostIdentity { terminal_id: TERMINAL.into(), incarnation: INCARNATION.into() };
    {
        let mut registry = mux.workspace_registry.lock().unwrap();
        commit_terminal_transition(
            &mut registry,
            "terminal-reserved",
            "reserve-terminal",
            &RegistryTerminal {
                terminal_id: TERMINAL.into(),
                workspace_key: workspace.key,
                incarnation: None,
                lifecycle: TerminalLifecycle::Launching,
                launch_spec: serde_json::json!({}),
                exit: None,
                on_exit: TerminalOnExit::Close,
            },
        )
        .unwrap();
    }
    let _pending = mux.register_pending_terminal_host(PENDING_SURFACE, identity.clone()).unwrap();

    assert!(mux.terminal_host_connection_lost(PENDING_SURFACE, &identity));
    assert!(mux.terminal_host_reconnected(
        PENDING_SURFACE,
        &identity,
        KittyGraphicsLimits::disabled(),
    ));
    assert_eq!(
        mux.workspace_registry
            .lock()
            .unwrap()
            .terminal_record(TERMINAL)
            .unwrap()
            .unwrap()
            .lifecycle,
        TerminalLifecycle::Launching
    );

    mux.transition_terminal_lifecycle(
        "terminal-adopting",
        "test-adoption",
        TERMINAL,
        TerminalLifecycle::Adopting,
        Some(INCARNATION),
    )
    .unwrap();
    assert!(mux.terminal_host_connection_lost(PENDING_SURFACE, &identity));
    assert!(mux.terminal_host_reconnected(
        PENDING_SURFACE,
        &identity,
        KittyGraphicsLimits::disabled(),
    ));
    assert_eq!(
        mux.workspace_registry
            .lock()
            .unwrap()
            .terminal_record(TERMINAL)
            .unwrap()
            .unwrap()
            .lifecycle,
        TerminalLifecycle::Adopting
    );
}

#[cfg(unix)]
#[test]
fn pending_topology_rejects_callback_for_wrong_surface() {
    const TERMINAL: &str = "00000000000040008000000000000013";
    const INCARNATION: &str = "10000000000040008000000000000013";
    const PENDING_SURFACE: SurfaceId = 4243;
    let mux = test_mux();
    let workspace = mux
        .create_empty_workspace(None, Some("018f6e21-7b70-7e70-8000-000000001113".into()), None)
        .unwrap();
    let identity =
        TerminalHostIdentity { terminal_id: TERMINAL.into(), incarnation: INCARNATION.into() };
    {
        let mut registry = mux.workspace_registry.lock().unwrap();
        commit_terminal_transition(
            &mut registry,
            "terminal-reserved",
            "reserve-terminal",
            &RegistryTerminal {
                terminal_id: TERMINAL.into(),
                workspace_key: workspace.key,
                incarnation: None,
                lifecycle: TerminalLifecycle::Launching,
                launch_spec: serde_json::json!({}),
                exit: None,
                on_exit: TerminalOnExit::Close,
            },
        )
        .unwrap();
    }
    let _pending = mux.register_pending_terminal_host(PENDING_SURFACE, identity.clone()).unwrap();

    assert!(!mux.terminal_host_connection_lost(PENDING_SURFACE + 1, &identity));
    assert!(!mux.terminal_host_reconnected(
        PENDING_SURFACE + 1,
        &identity,
        KittyGraphicsLimits::disabled(),
    ));
    assert!(mux.terminal_host_connection_lost(PENDING_SURFACE, &identity));
}

#[cfg(unix)]
#[test]
fn pending_topology_accepts_running_host_before_surface_publication() {
    const TERMINAL: &str = "00000000000040008000000000000016";
    const INCARNATION: &str = "10000000000040008000000000000016";
    const PENDING_SURFACE: SurfaceId = 4246;
    let mux = test_mux();
    let workspace = mux
        .create_empty_workspace(None, Some("018f6e21-7b70-7e70-8000-000000001116".into()), None)
        .unwrap();
    let identity =
        TerminalHostIdentity { terminal_id: TERMINAL.into(), incarnation: INCARNATION.into() };
    {
        let mut registry = mux.workspace_registry.lock().unwrap();
        commit_terminal_transition(
            &mut registry,
            "terminal-reserved",
            "reserve-terminal",
            &RegistryTerminal {
                terminal_id: TERMINAL.into(),
                workspace_key: workspace.key,
                incarnation: None,
                lifecycle: TerminalLifecycle::Launching,
                launch_spec: serde_json::json!({}),
                exit: None,
                on_exit: TerminalOnExit::Close,
            },
        )
        .unwrap();
    }
    let _pending = mux.register_pending_terminal_host(PENDING_SURFACE, identity.clone()).unwrap();
    mux.transition_terminal_lifecycle(
        "terminal-ready",
        "test-running-before-surface-publication",
        TERMINAL,
        TerminalLifecycle::Running,
        Some(INCARNATION),
    )
    .unwrap();

    assert!(mux.terminal_host_connection_lost(PENDING_SURFACE, &identity));
    assert!(mux.terminal_host_reconnected(
        PENDING_SURFACE,
        &identity,
        KittyGraphicsLimits::disabled(),
    ));
    assert_eq!(
        mux.workspace_registry
            .lock()
            .unwrap()
            .terminal_record(TERMINAL)
            .unwrap()
            .unwrap()
            .lifecycle,
        TerminalLifecycle::Running
    );
}

#[cfg(unix)]
#[test]
fn pending_topology_rejects_callback_from_old_incarnation() {
    const TERMINAL: &str = "00000000000040008000000000000014";
    const INCARNATION: &str = "10000000000040008000000000000014";
    const OLD_INCARNATION: &str = "10000000000040008000000000000004";
    const PENDING_SURFACE: SurfaceId = 4244;
    let mux = test_mux();
    let workspace = mux
        .create_empty_workspace(None, Some("018f6e21-7b70-7e70-8000-000000001114".into()), None)
        .unwrap();
    let identity =
        TerminalHostIdentity { terminal_id: TERMINAL.into(), incarnation: INCARNATION.into() };
    let old_identity =
        TerminalHostIdentity { terminal_id: TERMINAL.into(), incarnation: OLD_INCARNATION.into() };
    {
        let mut registry = mux.workspace_registry.lock().unwrap();
        commit_terminal_transition(
            &mut registry,
            "terminal-reserved",
            "reserve-terminal",
            &RegistryTerminal {
                terminal_id: TERMINAL.into(),
                workspace_key: workspace.key,
                incarnation: None,
                lifecycle: TerminalLifecycle::Launching,
                launch_spec: serde_json::json!({}),
                exit: None,
                on_exit: TerminalOnExit::Close,
            },
        )
        .unwrap();
    }
    let pending = mux.register_pending_terminal_host(PENDING_SURFACE, identity.clone()).unwrap();

    assert!(!mux.terminal_host_connection_lost(PENDING_SURFACE, &old_identity));
    assert!(!mux.terminal_host_reconnected(
        PENDING_SURFACE,
        &old_identity,
        KittyGraphicsLimits::disabled(),
    ));
    assert!(mux.terminal_host_connection_lost(PENDING_SURFACE, &identity));
    drop(pending);
    assert!(!mux.terminal_host_connection_lost(PENDING_SURFACE, &identity));
}

#[cfg(unix)]
#[test]
fn pending_topology_rejects_multiple_different_callbacks() {
    const TERMINAL: &str = "00000000000040008000000000000015";
    const INCARNATION: &str = "10000000000040008000000000000015";
    const PENDING_SURFACE: SurfaceId = 4245;
    let mux = test_mux();
    let workspace = mux
        .create_empty_workspace(None, Some("018f6e21-7b70-7e70-8000-000000001115".into()), None)
        .unwrap();
    let identity =
        TerminalHostIdentity { terminal_id: TERMINAL.into(), incarnation: INCARNATION.into() };
    {
        let mut registry = mux.workspace_registry.lock().unwrap();
        commit_terminal_transition(
            &mut registry,
            "terminal-reserved",
            "reserve-terminal",
            &RegistryTerminal {
                terminal_id: TERMINAL.into(),
                workspace_key: workspace.key,
                incarnation: None,
                lifecycle: TerminalLifecycle::Launching,
                launch_spec: serde_json::json!({}),
                exit: None,
                on_exit: TerminalOnExit::Close,
            },
        )
        .unwrap();
    }
    let _pending = mux.register_pending_terminal_host(PENDING_SURFACE, identity.clone()).unwrap();
    let callbacks = [
        (
            PENDING_SURFACE,
            TerminalHostIdentity {
                terminal_id: TERMINAL.into(),
                incarnation: "10000000000040008000000000000005".into(),
            },
        ),
        (
            PENDING_SURFACE,
            TerminalHostIdentity {
                terminal_id: "00000000000040008000000000000005".into(),
                incarnation: INCARNATION.into(),
            },
        ),
        (PENDING_SURFACE + 1, identity.clone()),
    ];

    for (surface_id, callback) in callbacks {
        assert!(!mux.terminal_host_connection_lost(surface_id, &callback));
        assert!(!mux.terminal_host_reconnected(
            surface_id,
            &callback,
            KittyGraphicsLimits::disabled(),
        ));
    }
    assert!(mux.terminal_host_connection_lost(PENDING_SURFACE, &identity));
    assert!(mux.terminal_host_reconnected(
        PENDING_SURFACE,
        &identity,
        KittyGraphicsLimits::disabled(),
    ));
}

#[test]
fn stale_move_replay_projects_the_latest_canonical_workspace() {
    const TERMINAL: &str = "00000000000040008000000000000003";
    let mux = test_mux();
    let first = mux
        .create_empty_workspace(None, Some("018f6e21-7b70-7e70-8000-000000001010".into()), None)
        .unwrap();
    let second = mux
        .create_empty_workspace(None, Some("018f6e21-7b70-7e70-8000-000000001011".into()), None)
        .unwrap();
    let third = mux
        .create_empty_workspace(None, Some("018f6e21-7b70-7e70-8000-000000001012".into()), None)
        .unwrap();
    {
        let mut registry = mux.workspace_registry.lock().unwrap();
        commit_terminal_transition(
            &mut registry,
            "terminal-reserved",
            "reserve-terminal",
            &RegistryTerminal {
                terminal_id: TERMINAL.into(),
                workspace_key: first.key,
                incarnation: None,
                lifecycle: TerminalLifecycle::Launching,
                launch_spec: serde_json::json!({"command_present":true}),
                exit: None,
                on_exit: TerminalOnExit::Close,
            },
        )
        .unwrap();
    }
    let events = mux.subscribe();
    let first_move = WorkspaceMutation::daemon("move-one", "browser").unwrap();
    let moved = mux
        .move_terminal_with_mutation(TERMINAL, &second.key, None, None, Some(1), &first_move)
        .unwrap();
    assert_eq!(moved.terminal.workspace_key, second.key);
    let MuxEvent::TerminalRegistryChanged { terminal_revision, .. } = events.recv().unwrap() else {
        panic!("expected terminal registry barrier");
    };
    assert_eq!(terminal_revision, 2);
    mux.move_terminal_with_mutation(
        TERMINAL,
        &third.key,
        None,
        None,
        Some(2),
        &WorkspaceMutation::daemon("move-two", "browser").unwrap(),
    )
    .unwrap();
    let replay = mux
        .move_terminal_with_mutation(TERMINAL, &second.key, None, None, Some(1), &first_move)
        .unwrap();
    assert!(replay.replayed);
    assert_eq!(replay.terminal.workspace_key, third.key);
    assert_eq!(mux.resolve_terminal(TERMINAL).unwrap().unwrap().terminal.workspace_key, third.key);
}

#[cfg(unix)]
#[test]
fn concurrent_terminal_moves_cannot_project_out_of_commit_order() {
    const TERMINAL: &str = "0000000000004000800000000000000a";
    const INCARNATION: &str = "1000000000004000800000000000000a";
    let mux = test_mux();
    let first = mux
        .create_empty_workspace(None, Some("018f6e21-7b70-7e70-8000-000000001013".into()), None)
        .unwrap();
    let second = mux
        .create_empty_workspace(None, Some("018f6e21-7b70-7e70-8000-000000001014".into()), None)
        .unwrap();
    let third = mux
        .create_empty_workspace(None, Some("018f6e21-7b70-7e70-8000-000000001015".into()), None)
        .unwrap();
    let surface = insert_running_terminal_identity_surface(&mux, TERMINAL, INCARNATION, &first.key);

    let calls = Arc::new(AtomicUsize::new(0));
    let (entered_tx, entered_rx) = std::sync::mpsc::channel();
    let (release_tx, release_rx) = std::sync::mpsc::channel();
    let release_rx = Arc::new(Mutex::new(release_rx));
    mux.set_terminal_move_before_projection(Some(Arc::new(move || {
        if calls.fetch_add(1, Ordering::SeqCst) == 0 {
            entered_tx.send(()).unwrap();
            release_rx.lock().unwrap().recv().unwrap();
        }
    })));

    let moving_to_second = {
        let mux = mux.clone();
        let key = second.key.clone();
        std::thread::spawn(move || {
            mux.move_terminal_with_mutation(
                TERMINAL,
                &key,
                None,
                None,
                Some(2),
                &WorkspaceMutation::daemon("move-race-one", "browser").unwrap(),
            )
        })
    };
    entered_rx.recv().unwrap();
    let (second_attempted_tx, second_attempted_rx) = std::sync::mpsc::channel();
    let (second_done_tx, second_done_rx) = std::sync::mpsc::channel();
    let moving_to_third = {
        let mux = mux.clone();
        let key = third.key.clone();
        std::thread::spawn(move || {
            second_attempted_tx.send(()).unwrap();
            let result = mux.move_terminal_with_mutation(
                TERMINAL,
                &key,
                None,
                None,
                None,
                &WorkspaceMutation::daemon("move-race-two", "browser").unwrap(),
            );
            second_done_tx.send(result).unwrap();
        })
    };
    second_attempted_rx.recv().unwrap();
    assert!(second_done_rx.recv_timeout(Duration::from_millis(100)).is_err());
    release_tx.send(()).unwrap();
    assert_eq!(moving_to_second.join().unwrap().unwrap().terminal.workspace_key, second.key);
    assert_eq!(second_done_rx.recv().unwrap().unwrap().terminal.workspace_key, third.key);
    moving_to_third.join().unwrap();
    mux.set_terminal_move_before_projection(None);
    assert_eq!(mux.resolve_terminal(TERMINAL).unwrap().unwrap().terminal.workspace_key, third.key);
    let placement = mux
        .with_state(|state| run_placement_for_surface(state, surface.id))
        .expect("terminal has one final topology binding");
    assert_eq!(placement.workspace, third.workspace);
}

#[cfg(unix)]
#[test]
fn terminal_move_and_destination_close_detach_view_in_one_registry_order() {
    const TERMINAL: &str = "0000000000004000800000000000000b";
    const INCARNATION: &str = "1000000000004000800000000000000b";
    let mux = test_mux();
    let first = mux
        .create_empty_workspace(None, Some("018f6e21-7b70-7e70-8000-000000001016".into()), None)
        .unwrap();
    let second = mux
        .create_empty_workspace(None, Some("018f6e21-7b70-7e70-8000-000000001017".into()), None)
        .unwrap();
    let surface = insert_running_terminal_identity_surface(&mux, TERMINAL, INCARNATION, &first.key);

    let (entered_tx, entered_rx) = std::sync::mpsc::channel();
    let (release_tx, release_rx) = std::sync::mpsc::channel();
    let release_rx = Arc::new(Mutex::new(release_rx));
    mux.set_terminal_move_before_projection(Some(Arc::new(move || {
        entered_tx.send(()).unwrap();
        release_rx.lock().unwrap().recv().unwrap();
    })));
    let move_thread = {
        let mux = mux.clone();
        let key = second.key.clone();
        std::thread::spawn(move || {
            mux.move_terminal_with_mutation(
                TERMINAL,
                &key,
                None,
                None,
                Some(2),
                &WorkspaceMutation::daemon("move-before-close", "browser").unwrap(),
            )
        })
    };
    entered_rx.recv().unwrap();
    let (close_attempted_tx, close_attempted_rx) = std::sync::mpsc::channel();
    let (close_done_tx, close_done_rx) = std::sync::mpsc::channel();
    let close_thread = {
        let mux = mux.clone();
        std::thread::spawn(move || {
            close_attempted_tx.send(()).unwrap();
            close_done_tx.send(mux.close_workspace_at_revision(second.workspace, Some(2))).unwrap();
        })
    };
    close_attempted_rx.recv().unwrap();
    assert!(close_done_rx.recv_timeout(Duration::from_millis(100)).is_err());
    release_tx.send(()).unwrap();
    assert_eq!(move_thread.join().unwrap().unwrap().terminal.workspace_key, second.key);
    assert_eq!(close_done_rx.recv().unwrap().unwrap(), Some(3));
    close_thread.join().unwrap();
    mux.set_terminal_move_before_projection(None);
    assert_eq!(
        mux.workspace_registry
            .lock()
            .unwrap()
            .terminal_record(TERMINAL)
            .unwrap()
            .unwrap()
            .lifecycle,
        TerminalLifecycle::Running
    );
    assert!(mux.with_state(|state| state.workspace_by_key(&second.key).is_none()));
    assert_eq!(mux.resolve_terminal(TERMINAL).unwrap().unwrap().surface, None);
    assert!(mux.surface(surface.id).is_some());
}

#[test]
fn move_terminal_to_missing_workspace_fails_without_changing_placement() {
    const TERMINAL: &str = "00000000000040008000000000000004";
    let mux = test_mux();
    let first = mux
        .create_empty_workspace(None, Some("018f6e21-7b70-7e70-8000-000000001018".into()), None)
        .unwrap();
    {
        let mut registry = mux.workspace_registry.lock().unwrap();
        commit_terminal_transition(
            &mut registry,
            "terminal-reserved",
            "reserve-terminal",
            &RegistryTerminal {
                terminal_id: TERMINAL.into(),
                workspace_key: first.key.clone(),
                incarnation: None,
                lifecycle: TerminalLifecycle::Launching,
                launch_spec: serde_json::json!({}),
                exit: None,
                on_exit: TerminalOnExit::Close,
            },
        )
        .unwrap();
    }
    let error = mux
        .move_terminal_with_mutation(
            TERMINAL,
            "missing-workspace",
            None,
            None,
            Some(1),
            &WorkspaceMutation::daemon("move-missing", "browser").unwrap(),
        )
        .unwrap_err();
    assert!(error.to_string().contains("workspace is missing or closed"));
    assert_eq!(mux.resolve_terminal(TERMINAL).unwrap().unwrap().terminal.workspace_key, first.key);
}

#[test]
fn remote_terminal_projection_restores_unrelated_tui_focus() {
    let mux = test_mux();
    let moving = mux.new_workspace(Some("source".into()), None).unwrap();
    let destination = mux.new_workspace(Some("destination".into()), None).unwrap();
    let focused = mux.new_workspace(Some("focused".into()), None).unwrap();
    let (destination_pane, focused_pane) = mux.with_state(|state| {
        (state.pane_of(destination.id).unwrap(), state.pane_of(focused.id).unwrap())
    });
    assert!(mux.focus_pane(focused_pane));
    let before = mux.with_state(current_focus_identity);
    {
        let mut state = mux.state.lock().unwrap();
        let preserved = current_focus_identity(&state);
        assert!(move_tab_in_state(&mux, &mut state, moving.id, destination_pane, usize::MAX,).0);
        restore_focus_identity(&mut state, preserved);
    }
    assert_eq!(mux.with_state(current_focus_identity), before);
    assert_eq!(mux.with_state(|state| state.pane_of(moving.id)), Some(destination_pane));
}
