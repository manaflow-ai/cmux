//! Tests: sidebar plugin sync, remote attach waits, pointer motion against
//! pending surfaces, and focus.

use super::*;

#[test]
fn sidebar_plugin_sync_is_deduped_after_it_is_applied() {
    let mux = Mux::new("sidebar-plugin-sync-test", SurfaceOptions::default());
    let plugin =
        cmux_tui_core::SidebarPluginOptions { command: vec!["/bin/cat".to_string()], cwd: None };
    mux.configure_sidebar_plugin(Some(plugin.clone()));
    let (mut app, events) = test_app_with_events(Session::Local(mux));
    app.config.sidebar.plugin = Some(plugin);

    for _ in 0..1_000 {
        app.session.sidebar_plugin((24, 8), false);
    }

    let mut updates = 0;
    while let Ok(event) = events.recv_timeout(Duration::from_secs(5)) {
        if matches!(event, AppEvent::SidebarPluginUpdated { .. }) {
            updates += 1;
        }
        app.handle(event).unwrap();
        if !app.session.has_pending_mutations() && updates == 1 {
            break;
        }
    }
    assert_eq!(updates, 1);
    assert!(!app.session.has_pending_mutations());
    assert_eq!(app.session.sidebar_plugin_sync.lock().unwrap().applied, Some(((24, 8), 0, 0)));
}

#[test]
fn failed_sidebar_plugin_status_schedules_passive_retry() {
    let mux = Mux::new("sidebar-plugin-retry-test", SurfaceOptions::default());
    let plugin = cmux_tui_core::SidebarPluginOptions {
        command: vec!["/definitely/missing/cmux-sidebar-plugin".to_string()],
        cwd: None,
    };
    mux.configure_sidebar_plugin(Some(plugin.clone()));
    let (mut app, events) = test_app_with_events(Session::Local(mux));
    app.config.sidebar.plugin = Some(plugin);
    app.sidebar_width = 12;
    app.content_area.height = 8;

    app.session.sidebar_plugin((11, 9), false);
    let mut failure_status_seen = false;
    while !failure_status_seen || app.session.has_pending_mutations() {
        let event = events.recv_timeout(Duration::from_secs(5)).unwrap();
        failure_status_seen |= matches!(
            &event,
            AppEvent::SidebarPluginUpdated { status, .. } if status.error.is_some()
        );
        app.handle(event).unwrap();
    }

    assert!(app.sidebar_plugin_error.is_some());
    assert!(app.sidebar_plugin_retry_at.is_some());
    assert!(app.session.sidebar_plugin_sync.lock().unwrap().applied.is_none());
    assert!(!app.sync_sidebar_plugin(false));
    assert!(!app.session.has_pending_mutations());

    app.sidebar_plugin_retry_at = Some(Instant::now() - Duration::from_millis(1));
    app.drag = Some(Drag::PtyMouse {
        surface: 42,
        handle: None,
        reservation_id: 7,
        release_bytes: PtyInputBytes::from_slice(b"release"),
        semantics: None,
        content: Rect { x: 1, y: 1, width: 20, height: 8 },
        button: MouseButton::Left,
        position: (4, 3),
        modifiers: KeyModifiers::NONE,
    });
    app.retry_sidebar_plugin_if_due();
    assert!(matches!(app.drag, Some(Drag::PtyMouse { reservation_id: 7, .. })));
    assert!(!app.session.has_pending_mutations());

    app.drag = None;
    app.sidebar_plugin_retry_at = Some(Instant::now() - Duration::from_millis(1));
    app.retry_sidebar_plugin_if_due();

    assert!(app.sidebar_plugin_retry_at.is_none());
    assert!(app.session.has_pending_mutations());
    assert!(app.session.sidebar_plugin_sync.lock().unwrap().applied.is_none());
}

#[test]
fn terminal_sidebar_failure_settles_passive_sync_claim() {
    let desired = ((24, 8), 0, 0);
    let state = Arc::new(Mutex::new(SidebarPluginSyncState {
        epoch: 0,
        claimed: Some(desired),
        applied: None,
    }));
    let mut claim = SidebarPluginSyncClaim { state: state.clone(), desired, applied: false };
    let status = SidebarPluginSurface {
        surface_id: None,
        error: Some("terminal failure".to_string()),
        retry_after_ms: None,
    };

    assert!(sidebar_plugin_status_settles_passive_claim(&status));
    claim.mark_applied();
    drop(claim);

    let state = state.lock().unwrap();
    assert_eq!(state.applied, Some(desired));
    assert!(state.claimed.is_none());
    drop(state);

    let mux = Mux::new("terminal-sidebar-failure-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.config.sidebar.plugin = Some(cmux_tui_core::SidebarPluginOptions {
        command: vec!["unused".to_string()],
        cwd: None,
    });
    app.sidebar_visible = true;
    app.sidebar_width = 12;
    app.content_area.height = 8;
    app.apply_sidebar_plugin_status(status, false);

    assert!(!app.sync_sidebar_plugin(false));
    assert!(!app.session.has_pending_mutations());
}

#[test]
fn hiding_then_showing_sidebar_rehydrates_same_size_plugin_status() {
    let mux = Mux::new("sidebar-plugin-hide-show-test", SurfaceOptions::default());
    let plugin =
        cmux_tui_core::SidebarPluginOptions { command: vec!["/bin/cat".to_string()], cwd: None };
    mux.configure_sidebar_plugin(Some(plugin.clone()));
    let (mut app, events) = test_app_with_events(Session::Local(mux));
    app.config.sidebar.plugin = Some(plugin);
    app.sidebar_width = 12;
    app.content_area.height = 8;
    app.session.sidebar_plugin((11, 9), false);
    while app.session.has_pending_mutations() {
        app.handle(events.recv_timeout(Duration::from_secs(5)).unwrap()).unwrap();
    }
    assert!(app.session.sidebar_plugin_sync.lock().unwrap().applied.is_some());

    app.sidebar_visible = false;
    assert!(!app.sync_sidebar_plugin(false));
    assert!(app.session.sidebar_plugin_sync.lock().unwrap().applied.is_none());
    app.sidebar_visible = true;

    assert!(app.sync_sidebar_plugin(false));
    assert!(app.session.has_pending_mutations());
}

#[test]
fn surface_exit_retires_stale_view_until_authoritative_topology_refresh() {
    let (mux, terminal) = test_mux("surface-exit-retires-view-test", None);
    let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
    app.session.remote = true;
    app.replace_tree(app.session.tree());
    while app.session.has_pending_mutations() {
        app.handle(events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();
    }
    let surface = terminal.id;
    app.rendered_terminal_sizes.insert(surface, (12, 5));
    app.rendered_terminal_bounds.insert(surface, Rect { x: 2, y: 3, width: 12, height: 5 });
    app.deferred_input.push_back(queued_input(
        Event::Key(KeyEvent::new(KeyCode::Char('x'), KeyModifiers::NONE)),
        Some(surface),
        1,
    ));

    assert_eq!(
        app.handle(AppEvent::Mux(MuxEvent::SurfaceExited(surface))).unwrap(),
        RenderAction::Draw
    );
    assert!(!app.tab_locations.contains_key(&surface));
    assert!(app.tree.workspaces()[0].screens[0].panes[0].tabs.is_empty());
    assert!(!app.rendered_terminal_sizes.contains_key(&surface));
    assert!(!app.rendered_terminal_bounds.contains_key(&surface));

    // A cached snapshot can predate the authoritative topology refresh.
    // The retired-view guard must not let it reattach the exited surface.
    app.replace_tree(app.session.tree());
    app.session.attach_surface(surface, Some((80, 24)));

    assert!(!app.session.can_attach_surface(surface));
    assert!(!app.session.has_pending_mutations());
    assert_eq!(app.deferred_input.len(), 1);
    assert!(events.try_recv().is_err());
    mux.shutdown();
}

#[test]
fn remote_attach_waits_outside_the_session_mutation_lane() {
    let (session, attach_started, release_attach) = test_remote_session_with_deferred_attach();
    let (app, events) = test_app_with_events(session);
    app.session.attach_surface(7, Some((80, 24)));
    attach_started.recv_timeout(Duration::from_secs(1)).unwrap();

    assert!(!app.session.has_pending_mutations());
    let (mutation_ran_tx, mutation_ran_rx) = std::sync::mpsc::channel();
    app.session.operations.enqueue_session_mutation("probe", true, move || {
        mutation_ran_tx.send(()).unwrap();
        Ok(())
    });
    mutation_ran_rx.recv_timeout(Duration::from_secs(1)).unwrap();

    release_attach.send(()).unwrap();
    assert!(matches!(
        events.recv_timeout(crate::test_wait::EVENT).unwrap(),
        AppEvent::SurfaceAttachSettled { outcome: crate::app::SurfaceAttachOutcome::Attached }
    ));
}

#[test]
fn remote_geometry_authority_waits_for_sized_attach_settlement() {
    let (session, attach_started, release_attach) =
        test_remote_session_with_deferred_sized_attach();
    let (mut app, events) = test_app_with_events(session);
    let surface = 7;
    app.replace_tree(notify_tree(surface, false));
    app.session.attach_surface(surface, Some((80, 24)));
    attach_started.recv_timeout(Duration::from_secs(1)).unwrap();

    assert!(app.session.has_surface(surface));
    assert!(!app.session.surface_is_ready_for_input(surface));
    assert!(!app.session.has_surface_size_report(surface));
    app.claim_active_terminal_geometry(true);
    assert_eq!(app.geometry_authority_surface, None);
    assert!(!app.session.has_pending_mutations());

    release_attach.send(()).unwrap();
    let settled = events.recv_timeout(crate::test_wait::EVENT).unwrap();
    assert!(matches!(
        settled,
        AppEvent::SurfaceAttachSettled { outcome: crate::app::SurfaceAttachOutcome::Attached }
    ));
    assert!(app.session.surface_is_ready_for_input(surface));
    assert!(app.session.has_surface_size_report(surface));
    app.handle(settled).unwrap();

    assert_eq!(app.geometry_authority_surface, Some(surface));
    assert!(app.session.has_pending_mutations());
    while app.session.has_pending_mutations() {
        app.handle(events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();
    }
    assert!(app.status_message.is_none());
}

#[test]
fn remote_surface_attach_concurrency_is_bounded() {
    const ATTACH_WORKER_LIMIT: usize = 4;
    const ATTACH_COUNT: usize = ATTACH_WORKER_LIMIT * 3;

    let mux = Mux::new("bounded-surface-attach-test", SurfaceOptions::default());
    let (mut app, events) = test_app_with_events(Session::Local(mux));
    app.session.remote = true;
    let state = Arc::new((Mutex::new((0_usize, 0_usize, false)), std::sync::Condvar::new()));
    let hook_state = state.clone();
    *app.session.surface_attach_after_obsolete_check.lock().unwrap() = Some(Arc::new(move || {
        let (state, release) = &*hook_state;
        let mut state = state.lock().unwrap();
        state.0 += 1;
        state.1 = state.1.max(state.0);
        release.notify_all();
        while !state.2 {
            state = release.wait(state).unwrap();
        }
        state.0 -= 1;
    }));

    for surface in 1..=ATTACH_COUNT as u64 {
        app.session.attach_surface(surface, None);
    }

    let (lock, release) = &*state;
    let state = lock.lock().unwrap();
    let (mut state, _) = release
        .wait_timeout_while(state, Duration::from_millis(300), |state| {
            state.1 <= ATTACH_WORKER_LIMIT
        })
        .unwrap();
    let maximum_concurrency = state.1;
    state.2 = true;
    release.notify_all();
    drop(state);

    for _ in 0..ATTACH_COUNT {
        assert!(matches!(
            events.recv_timeout(crate::test_wait::EVENT).unwrap(),
            AppEvent::SurfaceAttachSettled { .. }
        ));
    }
    assert!(
        maximum_concurrency <= ATTACH_WORKER_LIMIT,
        "remote attach fanout reached {maximum_concurrency} concurrent workers"
    );
}

#[test]
fn single_remote_attach_worker_is_reserved_for_visible_work() {
    assert_eq!(crate::app::remote_attach_background_limit(1), 0);
    assert_eq!(
        crate::app::remote_attach_background_limit(crate::app::REMOTE_ATTACH_WORKER_LIMIT),
        crate::app::REMOTE_ATTACH_WORKER_LIMIT - 1
    );
}

#[test]
fn visible_remote_attach_promotes_prefetch_into_reserved_capacity() {
    let mux = Mux::new("visible-attach-promotion-test", SurfaceOptions::default());
    let (mut app, events) = test_app_with_events(Session::Local(mux));
    app.session.remote = true;
    let state = Arc::new((Mutex::new((0_usize, false)), std::sync::Condvar::new()));
    let hook_state = state.clone();
    *app.session.surface_attach_after_obsolete_check.lock().unwrap() = Some(Arc::new(move || {
        let (state, changed) = &*hook_state;
        let mut state = state.lock().unwrap();
        state.0 += 1;
        changed.notify_all();
        while !state.1 {
            state = changed.wait(state).unwrap();
        }
    }));

    for surface in 1..=4 {
        app.session.attach_surface(surface, None);
    }

    let (lock, changed) = &*state;
    let state = lock.lock().unwrap();
    let (state, _) =
        changed.wait_timeout_while(state, Duration::from_secs(1), |state| state.0 < 3).unwrap();
    let (mut state, _) = changed
        .wait_timeout_while(state, Duration::from_millis(200), |state| state.0 == 3)
        .unwrap();
    let background_running = state.0;
    if background_running != 3 {
        state.1 = true;
        changed.notify_all();
        drop(state);
        assert_eq!(
            background_running, 3,
            "background prefetch consumed the worker reserved for visible attaches"
        );
    } else {
        drop(state);
    }

    app.session.attach_surface(4, Some((100, 30)));
    let state = lock.lock().unwrap();
    let (mut state, _) =
        changed.wait_timeout_while(state, Duration::from_secs(1), |state| state.0 < 4).unwrap();
    let promoted_running = state.0;
    state.1 = true;
    changed.notify_all();
    drop(state);
    assert_eq!(promoted_running, 4, "the visible attach did not leave the background queue");

    for _ in 0..4 {
        assert!(matches!(
            events.recv_timeout(crate::test_wait::EVENT).unwrap(),
            AppEvent::SurfaceAttachSettled { .. }
        ));
    }
}

#[test]
fn visible_remote_attach_updates_a_running_prefetch_size() {
    let (session, attach_started, release_attach) = test_remote_session_with_deferred_attach();
    let (app, events) = test_app_with_events(session);
    let surface_id = 7;

    app.session.attach_surface(surface_id, None);
    attach_started.recv_timeout(Duration::from_secs(1)).unwrap();
    app.session.attach_surface(surface_id, Some((100, 30)));
    release_attach.send(()).unwrap();

    assert!(matches!(
        events.recv_timeout(crate::test_wait::EVENT).unwrap(),
        AppEvent::SurfaceAttachSettled { outcome: crate::app::SurfaceAttachOutcome::Attached }
    ));
    let surface = app.session.surface(surface_id).unwrap();
    assert!(
        !surface.resize_needed(100, 30, false),
        "the promoted size was not reported by the running attach"
    );
}

#[test]
fn latest_promoted_resize_success_supersedes_an_earlier_failure() {
    let fixture = test_remote_session_with_deferred_attach_and_first_resize_failure();
    let (app, events) = test_app_with_events(fixture.session);
    let surface_id = 7;

    app.session.attach_surface(surface_id, None);
    fixture.attach_started.recv_timeout(Duration::from_secs(1)).unwrap();
    app.session.attach_surface(surface_id, Some((100, 30)));
    fixture.release_attach.send(()).unwrap();
    fixture.resize_started.recv_timeout(Duration::from_secs(1)).unwrap();
    app.session.attach_surface(surface_id, Some((120, 40)));
    fixture.release_resize.send(()).unwrap();

    assert!(matches!(
        events.recv_timeout(crate::test_wait::EVENT).unwrap(),
        AppEvent::SurfaceAttachSettled { outcome: crate::app::SurfaceAttachOutcome::Attached }
    ));
    let surface = app.session.surface(surface_id).unwrap();
    assert!(
        !surface.resize_needed(120, 40, false),
        "the latest promoted size was not reported after recovery"
    );
    assert!(!app.session.surface_resize_failures.lock().unwrap().contains_key(&surface_id));
}

#[test]
fn remote_attach_admission_failure_uses_the_selected_locale() {
    const CHILD_ENV: &str = "CMUX_REMOTE_ATTACH_ADMISSION_LOCALE_CHILD";
    if std::env::var_os(CHILD_ENV).is_none() {
        let output = std::process::Command::new(std::env::current_exe().unwrap())
            .arg("app::tests::remote_attach_admission_failure_uses_the_selected_locale")
            .arg("--exact")
            .arg("--nocapture")
            .env(CHILD_ENV, "1")
            .env("LC_ALL", "ja_JP.UTF-8")
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "Japanese remote attach admission child failed:\nstdout:\n{}\nstderr:\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        return;
    }

    let mux = Mux::new("remote-attach-admission-locale-test", SurfaceOptions::default());
    let (mut app, events) = test_app_with_events(Session::Local(mux));
    app.session.remote = true;
    let executor = crate::app::RemoteSurfaceAttachExecutor::new().unwrap();
    executor.shutdown();
    *app.session.remote_surface_attaches.lock().unwrap() = Some(executor);

    app.session.attach_surface(77, None);
    app.handle(events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();

    assert_eq!(
        app.status_message.as_deref(),
        Some(
            "サーフェス 77 の接続に失敗しました。再試行は制限されています: \
             リモートサーフェス接続キューがいっぱいです"
        )
    );
}

#[test]
fn explicit_sidebar_relaunch_is_a_barrier_before_passive_sync() {
    let mux = Mux::new("sidebar-plugin-relaunch-barrier-test", SurfaceOptions::default());
    let (mut app, events) = test_app_with_events(Session::Local(mux));
    let (started_tx, started_rx) = std::sync::mpsc::channel();
    let (unblock_tx, unblock_rx) = std::sync::mpsc::channel();
    app.session.operations.enqueue_session_mutation("blocker", false, move || {
        started_tx.send(()).unwrap();
        unblock_rx.recv().unwrap();
        Ok(())
    });
    started_rx.recv_timeout(Duration::from_secs(1)).unwrap();

    app.session.sidebar_plugin((24, 8), true);
    app.session.sidebar_plugin((24, 8), false);
    unblock_tx.send(()).unwrap();

    let mut updates = Vec::new();
    while updates.len() < 2 {
        let event = events.recv_timeout(crate::test_wait::EVENT).unwrap();
        if let AppEvent::SidebarPluginUpdated { relaunch, .. } = &event {
            updates.push(*relaunch);
        }
        app.handle(event).unwrap();
    }
    assert_eq!(updates, vec![true, false]);
}

#[test]
fn pending_sidebar_focus_is_fulfilled_by_async_relaunch_success() {
    let mux = Mux::new("sidebar-plugin-focus-intent-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.config.sidebar.plugin = Some(cmux_tui_core::SidebarPluginOptions {
        command: vec!["unused".to_string()],
        cwd: None,
    });
    app.sidebar_width = 12;
    app.content_area.height = 8;

    app.toggle_sidebar_focus();
    assert!(app.sidebar_focus_pending);
    assert!(!app.workspace_sidebar_focused());

    app.handle(AppEvent::SidebarPluginUpdated {
        status: SidebarPluginSurface { surface_id: Some(42), error: None, retry_after_ms: None },
        relaunch: true,
    })
    .unwrap();

    assert!(!app.sidebar_focus_pending);
    assert!(app.workspace_sidebar_focused());
    assert_eq!(app.sidebar_plugin_surface, Some(42));
}

#[test]
fn builtin_sidebar_focus_survives_plugin_sync() {
    let mux = Mux::new("builtin-sidebar-focus-sync-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.sidebar_visible = true;
    app.sidebar_width = 22;
    app.focus = FocusTarget::WorkspaceRail;

    assert!(!app.sync_sidebar_plugin(false));
    assert!(app.workspace_sidebar_focused());
}

#[test]
fn key_typed_during_pending_sidebar_focus_follows_successful_focus() {
    let mux = Mux::new("sidebar-plugin-deferred-key-success-test", SurfaceOptions::default());
    let surface = mux.new_workspace(None, None).unwrap();
    let mut app = test_app(Session::Local(mux));
    app.replace_tree(app.session.tree());
    app.sidebar_focus_pending = true;
    app.session.pending_mutations.store(1, Ordering::Release);

    app.handle(AppEvent::Input(Event::Key(KeyEvent::new(KeyCode::Char('x'), KeyModifiers::NONE))))
        .unwrap();
    assert!(app.deferred_input.front().unwrap().admission.sidebar_focus_intent);

    app.session.pending_mutations.store(0, Ordering::Release);
    app.sidebar_focus_pending = false;
    app.focus = FocusTarget::WorkspaceRail;
    app.sidebar_plugin_surface = Some(surface.id);
    app.replay_deferred_input().unwrap();

    assert!(app.deferred_input.is_empty());
    assert_ne!(
        app.status_message.as_deref(),
        Some(localization::catalog().terminal.deferred_input_destination_changed)
    );
}

#[test]
fn key_typed_during_pending_sidebar_focus_keeps_pane_target_on_failure() {
    let mux = Mux::new("sidebar-plugin-deferred-key-failure-test", SurfaceOptions::default());
    mux.new_workspace(None, None).unwrap();
    let mut app = test_app(Session::Local(mux));
    app.replace_tree(app.session.tree());
    app.sidebar_focus_pending = true;
    app.session.pending_mutations.store(1, Ordering::Release);

    app.handle(AppEvent::Input(Event::Key(KeyEvent::new(KeyCode::Char('x'), KeyModifiers::NONE))))
        .unwrap();

    app.session.pending_mutations.store(0, Ordering::Release);
    app.sidebar_focus_pending = false;
    app.replay_deferred_input().unwrap();

    assert!(app.deferred_input.is_empty());
    assert_ne!(
        app.status_message.as_deref(),
        Some(localization::catalog().terminal.deferred_input_destination_changed)
    );
}

#[test]
fn surface_output_is_paint_only_and_preserves_the_topology_index() {
    let mux = Mux::new("surface-output-paint-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.tab_locations.insert(77, [1, 2, 3, 4]);

    let action = app.handle(AppEvent::Mux(MuxEvent::SurfaceOutput(77))).unwrap();

    assert_eq!(action, RenderAction::Paint);
    assert_eq!(app.tab_locations.get(&77), Some(&[1, 2, 3, 4]));
}

#[test]
fn remote_mutation_timeout_keeps_deferred_routing_state() {
    let mux = Mux::new("mutation-timeout-test", SurfaceOptions::default());
    let (mut app, events) = test_app_with_events(Session::Local(mux));
    app.session.remote = true;
    app.deferred_input.push_back(queued_input(
        Event::Key(KeyEvent::new(KeyCode::Char('x'), KeyModifiers::NONE)),
        None,
        1,
    ));
    app.session.enqueue("timed out mutation", |_| Err(crate::session::test_remote_timeout_error()));
    let settled = events.recv_timeout(crate::test_wait::EVENT).unwrap();
    assert!(matches!(
        settled,
        AppEvent::SessionMutationSettled {
            outcome: crate::app::SessionMutationOutcome::MutationTimedOut(_),
            ..
        }
    ));
    app.handle(settled).unwrap();
    assert_eq!(app.deferred_input.len(), 1);
    assert_eq!(
        app.status_message.as_deref(),
        Some(localization::catalog().session.operation_reconciling)
    );
}

#[test]
fn creation_timeout_without_receipt_fails_only_its_semantic_route() {
    let mux = Mux::new("legacy-creation-timeout-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.session.pending_mutations.store(1, Ordering::Release);
    app.session.pending_pointer_mutations.store(1, Ordering::Release);
    app.semantic_destination_outcomes.insert(7, crate::app::SemanticDestinationOutcome::Pending);

    app.handle(AppEvent::SessionMutationSettled {
        outcome: crate::app::SessionMutationOutcome::SemanticIntent {
            intent: 7,
            outcome: Box::new(crate::app::SessionMutationOutcome::MutationTimedOut(
                "legacy peer timeout".to_string(),
            )),
        },
        impact: MutationImpact::Destination,
    })
    .unwrap();

    assert_eq!(
        app.semantic_destination_outcomes.get(&7),
        Some(&crate::app::SemanticDestinationOutcome::Failed)
    );
}

#[test]
fn receipted_creation_timeout_keeps_its_semantic_route_pending() {
    let mux = Mux::new("receipted-creation-timeout-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.session.pending_mutations.store(1, Ordering::Release);
    app.session.pending_pointer_mutations.store(1, Ordering::Release);
    app.semantic_destination_outcomes.insert(7, crate::app::SemanticDestinationOutcome::Pending);

    app.handle(AppEvent::SessionMutationSettled {
        outcome: crate::app::SessionMutationOutcome::SemanticIntent {
            intent: 7,
            outcome: Box::new(crate::app::SessionMutationOutcome::CreationResponseAmbiguous(
                "receipt response timeout".to_string(),
            )),
        },
        impact: MutationImpact::Destination,
    })
    .unwrap();

    assert_eq!(
        app.semantic_destination_outcomes.get(&7),
        Some(&crate::app::SemanticDestinationOutcome::Pending)
    );
}

#[test]
fn remote_coalesced_resize_timeouts_settle_as_ambiguous() {
    let mux = Mux::new("coalesced-timeout-test", SurfaceOptions::default());
    let (mut app, events) = test_app_with_events(Session::Local(mux));
    app.session.remote = true;
    app.deferred_input.push_back(queued_input(
        Event::Key(KeyEvent::new(KeyCode::Char('x'), KeyModifiers::NONE)),
        None,
        1,
    ));

    for (label, key) in [
        ("resize PTY surface", ("surface resize", 7)),
        ("resize pane split", ("horizontal split ratio", 8)),
    ] {
        app.session.enqueue_coalescing_session_mutation(label, key, |_| {
            Err(crate::session::test_remote_timeout_error())
        });
        let settled = events.recv_timeout(crate::test_wait::EVENT).unwrap();
        assert!(matches!(
            settled,
            AppEvent::SessionMutationSettled {
                outcome: crate::app::SessionMutationOutcome::MutationTimedOut(_),
                ..
            }
        ));
        app.handle(settled).unwrap();
        assert_eq!(app.deferred_input.len(), 1);
    }
}

#[test]
fn queued_mutation_settlement_waits_for_worker_cleanup() {
    let mux = Mux::new("mutation-settlement-barrier-test", SurfaceOptions::default());
    let (mut app, events) = test_app_with_events(Session::Local(mux));
    app.session.remote = true;
    let pause_first = Arc::new(AtomicBool::new(true));
    let (reached_tx, reached_rx) = std::sync::mpsc::sync_channel(1);
    let release = Arc::new((Mutex::new(false), std::sync::Condvar::new()));
    let hook_release = release.clone();
    app.session.operations.set_after_operation_before_cleanup(Some(Arc::new(move || {
        if pause_first.swap(false, Ordering::SeqCst) {
            reached_tx.send(()).unwrap();
            let (lock, ready) = &*hook_release;
            let mut released = lock.lock().unwrap();
            while !*released {
                released = ready.wait(released).unwrap();
            }
        }
    })));

    app.session.enqueue_coalescing_session_mutation(
        "resize PTY surface",
        ("surface resize", 7),
        |_| Err(crate::session::test_remote_timeout_error()),
    );
    reached_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    assert!(events.try_recv().is_err(), "settlement escaped before worker cleanup");
    let (lock, ready) = &*release;
    *lock.lock().unwrap() = true;
    ready.notify_all();

    let timed_out = events.recv_timeout(crate::test_wait::EVENT).unwrap();
    assert!(matches!(
        timed_out,
        AppEvent::SessionMutationSettled {
            outcome: crate::app::SessionMutationOutcome::MutationTimedOut(_),
            ..
        }
    ));
    app.handle(timed_out).unwrap();

    app.session.enqueue_coalescing_session_mutation(
        "resize PTY surface",
        ("surface resize", 7),
        |_| Ok(()),
    );
    let recovered = events.recv_timeout(crate::test_wait::EVENT).unwrap();
    assert!(matches!(
        recovered,
        AppEvent::SessionMutationSettled {
            outcome: crate::app::SessionMutationOutcome::Success { .. },
            ..
        }
    ));
}

#[test]
fn browser_completion_waits_for_its_authoritative_identity_generation() {
    let mux = Mux::new("browser-completion-generation-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    let surface = 41;
    app.pane_areas.push(browser_completion_area(surface));
    app.pending_session_completions.push_back(SessionCompletion {
        mutation_generation: 4,
        semantic_intent: None,
        action: SessionCompletionAction::BrowserTabCreated { surface },
    });
    let tree = browser_completion_tree(surface, surface);

    app.handle(AppEvent::RemoteTreeUpdated {
        refresh_sequence: 1,
        destination_generation: 0,
        result: Ok(tree.clone()),
    })
    .unwrap();
    assert_eq!(app.pending_session_completions.len(), 1);
    assert!(app.omnibar.is_none());

    app.session.pending_mutations.store(1, Ordering::Release);
    app.handle(settled(crate::app::SessionMutationOutcome::Success { tree: None })).unwrap();
    assert_eq!(app.pending_session_completions.len(), 1);
    assert!(app.omnibar.is_none());

    app.session.pending_mutations.store(1, Ordering::Release);
    app.handle(settled(crate::app::SessionMutationOutcome::IdentityRefreshSucceeded {
        tree: tree.clone(),
        authoritative_generation: 3,
        destination_generation: 0,
        refresh_sequence: 2,
    }))
    .unwrap();
    assert_eq!(app.pending_session_completions.len(), 1);
    assert!(app.omnibar.is_none());

    app.session.pending_mutations.store(1, Ordering::Release);
    app.handle(settled(crate::app::SessionMutationOutcome::IdentityRefreshSucceeded {
        tree,
        authoritative_generation: 4,
        destination_generation: 0,
        refresh_sequence: 3,
    }))
    .unwrap();
    assert!(app.pending_session_completions.is_empty());
    assert_eq!(app.omnibar.as_ref().map(|state| state.surface), Some(surface));
}

#[test]
fn browser_completion_selects_the_exact_created_surface() {
    let mux = Mux::new("browser-completion-inactive-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    let created_surface = 41;
    let active_surface = 42;
    app.pane_areas.push(browser_completion_area(active_surface));
    app.pending_session_completions.push_back(SessionCompletion {
        mutation_generation: 4,
        semantic_intent: None,
        action: SessionCompletionAction::BrowserTabCreated { surface: created_surface },
    });
    app.session.pending_mutations.store(1, Ordering::Release);

    app.handle(settled(crate::app::SessionMutationOutcome::IdentityRefreshSucceeded {
        tree: browser_completion_tree(created_surface, active_surface),
        authoritative_generation: 4,
        destination_generation: 0,
        refresh_sequence: 1,
    }))
    .unwrap();

    assert!(app.pending_session_completions.is_empty());
    assert_eq!(app.tree.active_surface(), Some(created_surface));
    assert_eq!(app.omnibar.as_ref().map(|state| state.surface), Some(created_surface));
}

#[test]
fn tab_workspace_completion_selects_the_moved_tab_without_opening_browser_omnibar() {
    let mux = Mux::new("tab-workspace-completion", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.replace_tree(browser_completion_tree(41, 42));
    app.apply_session_completion(SessionCompletion {
        mutation_generation: 1,
        semantic_intent: None,
        action: SessionCompletionAction::SurfaceMoved { surface: 41 },
    });
    assert_eq!(app.tree.active_surface(), Some(41));
    assert!(app.omnibar.is_none());
}

#[test]
fn single_surface_client_ignores_creation_completion_selection() {
    let mux = Mux::new("single-surface-completion-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    let created_surface = 41;
    let attached_surface = 42;
    app.surface_only = Some(attached_surface);
    app.tree = browser_completion_tree(created_surface, attached_surface);
    app.pane_areas.push(browser_completion_area(attached_surface));

    app.apply_session_completion(SessionCompletion {
        mutation_generation: 4,
        semantic_intent: None,
        action: SessionCompletionAction::BrowserTabCreated { surface: created_surface },
    });

    assert_eq!(app.tree.active_surface(), Some(attached_surface));
    assert!(app.omnibar.is_none());
}

#[test]
fn failed_mutation_discards_input_deferred_for_its_destination() {
    let mux = Mux::new("failed-mutation-input-test", SurfaceOptions::default());
    let (mut app, events) = test_app_with_events(Session::Local(mux));
    let (started_tx, started_rx) = std::sync::mpsc::channel();
    let (release_tx, release_rx) = std::sync::mpsc::channel();
    app.session.enqueue_destination_mutation("failing selection", move |_| {
        started_tx.send(()).unwrap();
        release_rx.recv().unwrap();
        anyhow::bail!("selection rejected")
    });
    started_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    app.handle(AppEvent::Input(Event::Key(KeyEvent::new(
        KeyCode::Char('b'),
        KeyModifiers::CONTROL,
    ))))
    .unwrap();
    assert!(app.prefix_armed);
    app.handle(AppEvent::Input(Event::Key(KeyEvent::new(KeyCode::Char('x'), KeyModifiers::NONE))))
        .unwrap();
    assert_eq!(app.deferred_input.len(), 1);
    app.handle(AppEvent::Input(Event::Mouse(MouseEvent {
        kind: MouseEventKind::Moved,
        column: 14,
        row: 6,
        modifiers: KeyModifiers::NONE,
    })))
    .unwrap();
    assert_eq!(app.hover, None);

    release_tx.send(()).unwrap();
    let settled = events.recv_timeout(crate::test_wait::EVENT).unwrap();
    app.handle(settled).unwrap();

    assert!(app.deferred_input.is_empty());
    assert!(!app.prefix_armed);
    assert_eq!(app.pointer_route_phase, PointerRoutePhase::DrawPending);
    assert_eq!(
        app.status_message.as_deref(),
        Some(localization::catalog().session.operation_failed)
    );

    app.pointer_route_phase = PointerRoutePhase::Fresh;
    app.replay_deferred_input().unwrap();
    assert_eq!(app.hover, Some((14, 6)));
}

#[test]
fn pointer_map_mutations_enter_the_routing_lane() {
    let mux = Mux::new("pointer-map-routing-test", SurfaceOptions::default());
    let (app, _events) = test_app_with_events(Session::Local(mux));
    let (started_tx, started_rx) = std::sync::mpsc::channel();
    let (release_tx, release_rx) = std::sync::mpsc::channel();
    app.session.operations.enqueue_session_mutation("block pointer map lane", false, move || {
        started_tx.send(()).unwrap();
        release_rx.recv().unwrap();
        Ok(())
    });
    started_rx.recv_timeout(Duration::from_secs(1)).unwrap();

    app.session.zoom_pane(None);
    app.session.swap_pane(1, 2);
    app.session.move_workspace(1, 0);

    assert_eq!(app.session.pending_pointer_mutations.load(Ordering::Acquire), 3);
    release_tx.send(()).unwrap();
}

#[test]
fn terminal_geometry_mutations_enter_the_pointer_routing_lane() {
    let (mux, surface) = test_mux("terminal-geometry-routing-test", None);
    let (app, _events) = test_app_with_events(Session::Local(mux));
    let (started_tx, started_rx) = std::sync::mpsc::channel();
    let (release_tx, release_rx) = std::sync::mpsc::channel();
    app.session.operations.enqueue_session_mutation(
        "block terminal geometry lane",
        false,
        move || {
            started_tx.send(()).unwrap();
            release_rx.recv().unwrap();
            Ok(())
        },
    );
    started_rx.recv_timeout(Duration::from_secs(1)).unwrap();

    let claim = match app.session.surface_resize_decision(surface.id, (90, 31), true) {
        SurfaceResizeDecision::NeedsQueue(claim) => claim,
        _ => panic!("changed terminal size must queue"),
    };
    app.session.resize_surface(
        surface.id,
        app.session.surface(surface.id).unwrap(),
        90,
        31,
        false,
        claim,
    );
    app.session.use_all_client_sizing(surface.id);
    assert!(app.session.release_surface_size(surface.id));

    assert_eq!(
        app.session.pending_pointer_mutations.load(Ordering::Acquire),
        3,
        "PTY resize, client sizing, and size release all change terminal pointer geometry"
    );
    release_tx.send(()).unwrap();
}

#[test]
fn pointer_motion_waits_for_config_application() {
    let mux = Mux::new("config-pointer-routing-test", SurfaceOptions::default());
    let (mut app, _events) = test_app_with_events(Session::Local(mux));
    let (started_tx, started_rx) = std::sync::mpsc::channel();
    let (release_tx, release_rx) = std::sync::mpsc::channel();
    app.session.operations.enqueue_session_mutation("block config lane", false, move || {
        started_tx.send(()).unwrap();
        release_rx.recv().unwrap();
        Ok(())
    });
    started_rx.recv_timeout(Duration::from_secs(1)).unwrap();

    app.session.apply_config(Config::default());
    app.handle(AppEvent::Input(Event::Mouse(MouseEvent {
        kind: MouseEventKind::Moved,
        column: 14,
        row: 6,
        modifiers: KeyModifiers::NONE,
    })))
    .unwrap();

    let pending_pointer = app.session.has_pending_pointer_mutations();
    let hover = app.hover;
    let retained_motion = app.pending_pointer_motion.is_some();
    release_tx.send(()).unwrap();

    assert!(pending_pointer);
    assert_eq!(hover, None);
    assert!(retained_motion);
}

#[test]
fn pointer_only_mutations_do_not_mint_destination_intent() {
    let mux = Mux::new("pointer-only-destination-intent-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    let (started_tx, started_rx) = std::sync::mpsc::channel();
    let (release_tx, release_rx) = std::sync::mpsc::channel();
    app.session.operations.enqueue_session_mutation(
        "block pointer-only mutations",
        false,
        move || {
            started_tx.send(()).unwrap();
            release_rx.recv().unwrap();
            Ok(())
        },
    );
    started_rx.recv_timeout(Duration::from_secs(1)).unwrap();

    app.session.set_cell_pixel_size(12, 24);
    app.session.apply_config(Config::default());
    app.session.zoom_pane(None);
    app.session.set_split_ratio(1, 0.5);
    app.session.swap_pane(1, 2);
    app.session.move_workspace(1, 0);
    app.handle(AppEvent::Input(Event::Key(KeyEvent::new(KeyCode::Char('x'), KeyModifiers::NONE))))
        .unwrap();
    let destination_intent =
        app.deferred_input.front().and_then(|input| input.admission.destination_intent);
    release_tx.send(()).unwrap();

    assert_eq!(
        destination_intent, None,
        "pointer-only mutations must not authorize keyboard retargeting"
    );
}

#[test]
fn split_drag_updates_the_coalescing_lane_while_a_ratio_is_pending() {
    let mux = Mux::new("pending-split-drag-test", SurfaceOptions::default());
    let (mut app, _events) = test_app_with_events(Session::Local(mux));
    let (started_tx, started_rx) = std::sync::mpsc::channel();
    let (_release_tx, release_rx) = std::sync::mpsc::channel::<()>();
    app.session.enqueue("blocking ratio", move |_| {
        started_tx.send(()).unwrap();
        let _ = release_rx.recv();
        Ok(())
    });
    started_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    app.drag = Some(Drag::ResizeSplit {
        horizontal: Some(PaneResizeDragTarget::ViewportColumn {
            pane: 1,
            edge: PaneEdge::Right,
            column_x: 0,
            viewport_x: 0,
            viewport_width: 1,
            viewport_offset: 0,
        }),
        vertical: None,
    });

    app.handle(AppEvent::Input(Event::Mouse(MouseEvent {
        kind: MouseEventKind::Drag(MouseButton::Left),
        column: 20,
        row: 5,
        modifiers: KeyModifiers::NONE,
    })))
    .unwrap();

    assert!(app.deferred_input.is_empty());
    app.handle(AppEvent::Input(Event::Mouse(MouseEvent {
        kind: MouseEventKind::Up(MouseButton::Left),
        column: 20,
        row: 5,
        modifiers: KeyModifiers::NONE,
    })))
    .unwrap();
    assert!(app.deferred_input.is_empty());
    assert!(app.drag.is_none());
}

#[test]
fn split_ratio_samples_coalesce_without_snapshots_before_final_settlement() {
    let mux = Mux::new("split-ratio-snapshot-test", SurfaceOptions::default());
    mux.new_workspace(None, Some((40, 12))).unwrap();
    let target = Session::Local(mux.clone()).tree().active_screen().unwrap().active_pane;
    mux.split(target, SplitDir::Right, Some((20, 12))).unwrap();
    let split = mux.with_state(|state| {
        let root = &state.workspaces[0].screens[0].root;
        let Node::Split { id, .. } = root else {
            panic!("expected split root");
        };
        *id
    });
    let (app, events) = test_app_with_events(Session::Local(mux));
    let (started_tx, started_rx) = std::sync::mpsc::channel();
    let (release_tx, release_rx) = std::sync::mpsc::channel();
    app.session.operations.enqueue_session_mutation("block ratio lane", false, move || {
        started_tx.send(()).unwrap();
        release_rx.recv().unwrap();
        Ok(())
    });
    started_rx.recv_timeout(Duration::from_secs(1)).unwrap();

    for ratio in [0.2, 0.4, 0.8] {
        app.session.set_split_ratio_deferred(split, ratio);
    }
    app.session.settle_split_ratio();
    release_tx.send(()).unwrap();

    let mut sample_without_tree = 0;
    let mut authoritative_snapshots = 0;
    for _ in 0..2 {
        match events.recv_timeout(crate::test_wait::EVENT).unwrap() {
            AppEvent::SessionMutationSettled {
                outcome: crate::app::SessionMutationOutcome::Success { tree: None },
                impact: MutationImpact::PointerMap,
                ..
            } => sample_without_tree += 1,
            AppEvent::SessionMutationSettled {
                outcome: crate::app::SessionMutationOutcome::AuthoritativeMutationSucceeded { .. },
                impact: MutationImpact::PointerMap,
                ..
            } => authoritative_snapshots += 1,
            _ => panic!("unexpected split ratio settlement"),
        }
    }

    assert_eq!(sample_without_tree, 1, "the retained sample must not build a tree");
    assert_eq!(authoritative_snapshots, 1, "final settlement must snapshot exactly once");
}

#[test]
fn pointer_motion_keeps_only_the_latest_position_until_routing_settles() {
    let mux = Mux::new("deferred-motion-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.session.pending_mutations.store(1, Ordering::Release);
    app.session.pending_pointer_mutations.store(1, Ordering::Release);

    for (column, row) in [(9, 3), (14, 6)] {
        app.handle(AppEvent::Input(Event::Mouse(MouseEvent {
            kind: MouseEventKind::Moved,
            column,
            row,
            modifiers: KeyModifiers::NONE,
        })))
        .unwrap();
    }

    assert!(app.deferred_input.is_empty());
    assert_eq!(app.hover, None);
    assert_eq!(app.status_message, None);

    app.session.pending_mutations.store(0, Ordering::Release);
    app.session.pending_pointer_mutations.store(0, Ordering::Release);
    app.replay_deferred_input().unwrap();

    assert_eq!(app.hover, Some((14, 6)));
    assert_eq!(app.status_message, None);
}

#[test]
fn replay_batches_non_pointer_draws_before_the_next_render_boundary() {
    let mux = Mux::new("batched-non-pointer-replay-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.prompt = Some(Prompt::new("Rename", String::new(), PromptTarget::Surface(77)));
    for character in ['a', 'b', 'c'] {
        app.defer_input(Event::Key(KeyEvent::new(KeyCode::Char(character), KeyModifiers::NONE)));
    }

    let action = app.replay_deferred_input().unwrap();

    assert_eq!(action, RenderAction::Draw);
    assert_eq!(app.prompt.as_ref().unwrap().input.as_str(), "abc");
    assert!(
        app.deferred_input.is_empty(),
        "one replay batch should consume consecutive non-pointer draws"
    );
}

#[test]
fn deferred_key_replays_before_later_pointer_motion() {
    let mux = Mux::new("key-before-pointer-test", SurfaceOptions::default());
    let (mut app, _events) = test_app_with_events(Session::Local(mux));
    app.prefix_armed = true;
    app.session.pending_mutations.store(1, Ordering::Release);
    app.session.pending_pointer_mutations.store(1, Ordering::Release);

    app.handle(AppEvent::Input(Event::Key(KeyEvent::new(KeyCode::Tab, KeyModifiers::NONE))))
        .unwrap();
    app.handle(AppEvent::Input(Event::Mouse(MouseEvent {
        kind: MouseEventKind::Moved,
        column: 14,
        row: 6,
        modifiers: KeyModifiers::NONE,
    })))
    .unwrap();

    app.session.pending_mutations.store(0, Ordering::Release);
    app.session.pending_pointer_mutations.store(0, Ordering::Release);
    app.replay_deferred_input().unwrap();

    assert_eq!(app.hover, None);
    assert!(app.pending_pointer_motion.is_some());
    assert!(!app.session.has_pending_pointer_mutations());
    assert_eq!(app.pointer_route_phase, PointerRoutePhase::DrawPending);
}

#[test]
fn deferred_pointer_waits_for_layout_draw_during_replay() {
    let mux = Mux::new("draw-before-pointer-replay-test", SurfaceOptions::default());
    let plugin = cmux_tui_core::SidebarPluginOptions {
        command: vec!["/definitely/missing/cmux-sidebar-plugin".to_string()],
        cwd: None,
    };
    mux.configure_sidebar_plugin(Some(plugin.clone()));
    let (mut app, events) = test_app_with_events(Session::Local(mux));
    app.config.sidebar.plugin = Some(plugin);
    app.sidebar_visible = false;
    app.sidebar_width = 12;
    app.content_area.height = 8;
    let (started_tx, started_rx) = std::sync::mpsc::channel();
    let (release_tx, release_rx) = std::sync::mpsc::channel();
    app.session.operations.enqueue_session_mutation(
        "block before sidebar plugin",
        false,
        move || {
            started_tx.send(()).unwrap();
            let _ = release_rx.recv();
            Ok(())
        },
    );
    started_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    let prefix = app.config.keys.prefix;
    app.defer_input(TerminalInput::FrontendAction {
        action: Action::FocusSidebar,
        prefix: KeyEvent::new(prefix.code, prefix.mods),
    });
    app.retain_pointer_motion(MouseEvent {
        kind: MouseEventKind::Moved,
        column: 14,
        row: 6,
        modifiers: KeyModifiers::NONE,
    });

    let action = app.replay_deferred_input().unwrap();

    assert_eq!(action, RenderAction::Draw);
    assert!(app.sidebar_visible);
    assert_eq!(app.hover, None);
    assert!(app.pending_pointer_motion.is_some());
    assert!(app.session.has_pending_mutations());
    assert!(
        app.session.has_pending_pointer_mutations(),
        "sidebar plugin attachment can replace the rendered pointer owner"
    );
    assert_eq!(app.pointer_route_phase, PointerRoutePhase::DrawPending);

    release_tx.send(()).unwrap();
    while app.session.has_pending_mutations() {
        app.handle(events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();
    }
    app.pointer_route_phase = PointerRoutePhase::Fresh;
    app.replay_deferred_input().unwrap();

    assert_eq!(app.hover, Some((14, 6)));
    assert!(app.pending_pointer_motion.is_none());
}

#[test]
fn pointer_motion_replays_before_a_later_deferred_key() {
    let mux = Mux::new("pointer-before-key-test", SurfaceOptions::default());
    let (mut app, _events) = test_app_with_events(Session::Local(mux));
    app.session.pending_mutations.store(1, Ordering::Release);
    app.session.pending_pointer_mutations.store(1, Ordering::Release);

    app.handle(AppEvent::Input(Event::Mouse(MouseEvent {
        kind: MouseEventKind::Moved,
        column: 14,
        row: 6,
        modifiers: KeyModifiers::NONE,
    })))
    .unwrap();
    app.prefix_armed = true;
    app.handle(AppEvent::Input(Event::Key(KeyEvent::new(KeyCode::Tab, KeyModifiers::NONE))))
        .unwrap();

    app.session.pending_mutations.store(0, Ordering::Release);
    app.session.pending_pointer_mutations.store(0, Ordering::Release);
    app.replay_deferred_input().unwrap();

    assert_eq!(app.hover, Some((14, 6)));
    assert!(app.pending_pointer_motion.is_none());
    assert!(!app.session.has_pending_pointer_mutations());
    assert_eq!(app.pointer_route_phase, PointerRoutePhase::DrawPending);
}

#[test]
fn newer_live_pointer_motion_supersedes_a_retained_position() {
    let mux = Mux::new("newer-pointer-motion-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.session.pending_mutations.store(1, Ordering::Release);
    app.session.pending_pointer_mutations.store(1, Ordering::Release);

    app.handle(AppEvent::Input(Event::Mouse(MouseEvent {
        kind: MouseEventKind::Moved,
        column: 9,
        row: 3,
        modifiers: KeyModifiers::NONE,
    })))
    .unwrap();

    app.session.pending_mutations.store(0, Ordering::Release);
    app.session.pending_pointer_mutations.store(0, Ordering::Release);
    app.handle(AppEvent::Input(Event::Mouse(MouseEvent {
        kind: MouseEventKind::Moved,
        column: 14,
        row: 6,
        modifiers: KeyModifiers::NONE,
    })))
    .unwrap();

    assert!(app.pending_pointer_motion.is_none());
    assert_eq!(app.hover, Some((14, 6)));
    app.replay_deferred_input().unwrap();
    assert_eq!(app.hover, Some((14, 6)));
}

#[test]
fn session_presentation_reset_clears_retained_pointer_motion() {
    let mux = Mux::new("reset-pointer-motion-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.retain_pointer_motion(MouseEvent {
        kind: MouseEventKind::Moved,
        column: 9,
        row: 3,
        modifiers: KeyModifiers::NONE,
    });

    app.reset_session_presentation(TreeView::default());

    assert!(app.pending_pointer_motion.is_none());
}
