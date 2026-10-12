//! Tests: PTY press failures, mux event forwarding, surface input recovery,
//! tab refresh, and full-tree forwarding.

use super::*;

#[test]
fn old_press_failure_does_not_clear_new_press_on_the_same_surface() {
    let mux = Mux::new("press-reservation-identity-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.drag = Some(Drag::PtyMouse {
        surface: 42,
        handle: None,
        reservation_id: 9,
        release_bytes: PtyInputBytes::from_slice(b"release"),
        semantics: None,
        content: Rect { x: 1, y: 1, width: 20, height: 8 },
        button: MouseButton::Left,
        position: (4, 3),
        modifiers: KeyModifiers::NONE,
    });

    app.handle(AppEvent::PtyOperationFailed(PtyOperationFailure {
        session_generation: 1,
        surface_id: Some(42),
        kind: Some(PtyInputKind::Press),
        reservation_id: Some(8),
        label: "PTY input",
        error: "old press rejected".to_string(),
        lane_failed: false,
        delivery: PtyOperationDelivery::KnownNotDelivered,
    }))
    .unwrap();
    assert!(matches!(app.drag, Some(Drag::PtyMouse { reservation_id: 9, .. })));

    app.handle(AppEvent::PtyOperationFailed(PtyOperationFailure {
        session_generation: 1,
        surface_id: Some(42),
        kind: Some(PtyInputKind::Press),
        reservation_id: Some(9),
        label: "PTY input",
        error: "current press rejected".to_string(),
        lane_failed: false,
        delivery: PtyOperationDelivery::KnownNotDelivered,
    }))
    .unwrap();
    assert!(app.drag.is_none());
}

#[test]
fn input_waits_for_prior_session_mutation_to_settle() {
    let mux = Mux::new("pending-mutation-input-test", SurfaceOptions::default());
    let (mut app, events) = test_app_with_events(Session::Local(mux));
    let (started_tx, started_rx) = std::sync::mpsc::channel();
    let (release_tx, release_rx) = std::sync::mpsc::channel();
    app.session.enqueue("blocking selection", move |_| {
        started_tx.send(()).unwrap();
        release_rx.recv().unwrap();
        Ok(())
    });
    started_rx.recv_timeout(Duration::from_secs(1)).unwrap();

    app.handle(AppEvent::Input(Event::Key(KeyEvent::new(KeyCode::Char('x'), KeyModifiers::NONE))))
        .unwrap();

    assert_eq!(app.deferred_input.len(), 1);
    release_tx.send(()).unwrap();
    let settled = events.recv_timeout(crate::test_wait::EVENT).unwrap();
    assert!(matches!(settled, AppEvent::SessionMutationSettled { .. }));
    app.handle(settled).unwrap();
    assert_eq!(app.pointer_route_phase, PointerRoutePhase::DrawPending);
    app.pointer_route_phase = PointerRoutePhase::Fresh;
    app.replay_deferred_input().unwrap();
    assert!(app.deferred_input.is_empty());
    assert!(!app.session.has_pending_mutations());
}

#[test]
fn input_never_reasserts_a_viewer_size() {
    let mux = Mux::new(
        "input-size-independence-test",
        SurfaceOptions {
            command: Some(vec!["/bin/sh".to_string(), "-c".to_string(), "sleep 30".to_string()]),
            ..Default::default()
        },
    );
    let surface = mux.new_workspace(None, Some((120, 40))).unwrap();
    mux.resize_surface_for_client(surface.id, 0, 120, 40).unwrap();
    mux.resize_surface_for_client(surface.id, 99, 80, 30).unwrap();

    let mut app = test_app(Session::Local(mux.clone()));
    app.replace_tree(app.session.tree());
    let pane = app.tree.active_screen().unwrap().active_pane;
    let content = Rect { x: 1, y: 1, width: 120, height: 40 };
    app.pane_areas.push(PaneArea {
        pane,
        surface: surface.id,
        rect: content,
        bar: None,
        omnibar: None,
        content,
        track: None,
        viewport: None,
    });

    let inputs = [
        Event::Key(KeyEvent::new(KeyCode::Char('x'), KeyModifiers::NONE)),
        Event::Mouse(MouseEvent {
            kind: MouseEventKind::Moved,
            column: 2,
            row: 2,
            modifiers: KeyModifiers::NONE,
        }),
        Event::Paste("pasted".to_string()),
    ];
    for input in inputs {
        mux.record_client_size(99, 33);
        app.handle(AppEvent::Input(input)).unwrap();
        assert_eq!(mux.new_workspace(None, None).unwrap().size(), (99, 33));
    }
}

#[test]
fn canceled_mutation_does_not_block_on_a_full_app_channel() {
    let (events, receiver) = crossbeam_channel::bounded(1);
    events.send(AppEvent::MuxTitlesReady).unwrap();
    let pending_mutations = Arc::new(std::sync::atomic::AtomicUsize::new(1));
    let pending_pointer_mutations = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let cancellation_pending = Arc::new(AtomicBool::new(false));

    drop(PendingSessionMutation(Arc::new(PendingSessionMutationState {
        events: SessionEventSender::unscoped(events),
        pending_mutations: pending_mutations.clone(),
        pending_pointer_mutations,
        impact: MutationImpact::Ordered,
        semantic_intent: None,
        cancellation_pending: cancellation_pending.clone(),
        settled: AtomicBool::new(false),
        deferred_outcome: Mutex::new(None),
        canceled_outcome: Mutex::new(None),
    })));

    assert_eq!(pending_mutations.load(Ordering::Acquire), 0);
    assert!(cancellation_pending.load(Ordering::Acquire));
    assert!(matches!(receiver.try_recv(), Ok(AppEvent::MuxTitlesReady)));
}

#[test]
fn superseded_mutation_settles_without_canceling_session_input() {
    let (events, receiver) = crossbeam_channel::bounded(1);
    let pending_mutations = Arc::new(std::sync::atomic::AtomicUsize::new(1));
    let pending_pointer_mutations = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let cancellation_pending = Arc::new(AtomicBool::new(false));
    let pending = PendingSessionMutation(Arc::new(PendingSessionMutationState {
        events: SessionEventSender::unscoped(events),
        pending_mutations: pending_mutations.clone(),
        pending_pointer_mutations,
        impact: MutationImpact::Ordered,
        semantic_intent: None,
        cancellation_pending: cancellation_pending.clone(),
        settled: AtomicBool::new(false),
        deferred_outcome: Mutex::new(None),
        canceled_outcome: Mutex::new(None),
    }));

    pending.clone().supersede();
    drop(pending);

    assert_eq!(pending_mutations.load(Ordering::Acquire), 0);
    assert!(!cancellation_pending.load(Ordering::Acquire));
    assert!(receiver.try_recv().is_err());
}

#[test]
fn pty_failure_ingress_rearms_after_a_full_app_channel_loses_its_wake() {
    let ingress = PtyFailureIngress::default();
    let (events, receiver) = crossbeam_channel::bounded(1);
    events.send(AppEvent::MuxTitlesReady).unwrap();
    for index in 0..1_000 {
        let wake = ingress.push(PtyOperationFailure {
            session_generation: 1,
            surface_id: Some(42),
            kind: Some(PtyInputKind::Motion),
            reservation_id: None,
            label: "PTY input",
            error: format!("motion {index}"),
            lane_failed: false,
            delivery: PtyOperationDelivery::KnownNotDelivered,
        });
        if wake {
            assert!(matches!(
                events.try_send(AppEvent::PtyFailuresReady),
                Err(crossbeam_channel::TrySendError::Full(_))
            ));
        }
    }

    let failures = ingress.take();
    assert_eq!(failures.len(), 1);
    assert_eq!(failures.front().unwrap().error, "motion 999");
    assert!(matches!(receiver.try_recv(), Ok(AppEvent::MuxTitlesReady)));

    assert!(ingress.push(PtyOperationFailure {
        session_generation: 1,
        surface_id: Some(42),
        kind: Some(PtyInputKind::Motion),
        reservation_id: None,
        label: "PTY input",
        error: "motion after drain".into(),
        lane_failed: false,
        delivery: PtyOperationDelivery::KnownNotDelivered,
    }));
}

#[test]
fn deferred_input_is_discarded_when_its_destination_changes() {
    let mux = Mux::new("deferred-destination-test", SurfaceOptions::default());
    let surface = mux.new_workspace(None, None).unwrap();
    let mut app = test_app(Session::Local(mux));
    app.replace_tree(app.session.tree());
    app.session.pending_mutations.store(1, Ordering::Release);

    app.handle(AppEvent::Input(Event::Key(KeyEvent::new(KeyCode::Char('x'), KeyModifiers::NONE))))
        .unwrap();
    assert_eq!(
        app.deferred_input.front().and_then(|input| input.admission.destination),
        Some(surface.id)
    );

    app.session.pending_mutations.store(0, Ordering::Release);
    app.replace_tree(notify_tree(surface.id + 1, false));
    app.replay_deferred_input().unwrap();

    assert!(app.deferred_input.is_empty());
    assert_eq!(
        app.status_message.as_deref(),
        Some(localization::catalog().terminal.deferred_input_destination_changed)
    );
}

#[test]
fn tab_selection_is_client_local() {
    let mux = Mux::new("client-local-tab-selection-test", SurfaceOptions::default());
    let first = mux.new_workspace(None, None).unwrap();
    let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let second = mux.new_tab(Some(pane), None, None).unwrap();
    mux.select_tab(Some(pane), Some(0), None);
    let mut left = test_app(Session::Local(mux.clone()));
    let mut right = test_app(Session::Local(mux.clone()));
    left.replace_tree(left.session.tree());
    right.replace_tree(right.session.tree());

    left.select_tab_for_client(Some(pane), Some(1), None);
    left.replace_tree(left.session.tree());
    right.replace_tree(right.session.tree());

    assert_eq!(left.active_surface(), Some(second.id));
    assert_eq!(right.active_surface(), Some(first.id));
    assert_eq!(mux.active_surface(), Some(first.id));

    let workspace = mux.with_state(|state| state.workspaces[state.active_workspace].id);
    mux.close_workspace(workspace);
}

#[test]
fn another_clients_creations_keep_this_clients_view() {
    // A phone creating a screen, a tab, or a split moves only the shared
    // tree's active fields. An attached frontend (the laptop) keeps the
    // screen, pane, and tab it shows.
    let mux = Mux::new("foreign-creation-keeps-view-test", SurfaceOptions::default());
    let first = mux.new_workspace(None, Some((80, 24))).unwrap();
    let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let workspace = mux.with_state(|state| state.workspaces[state.active_workspace].id);
    let mut laptop = test_app(Session::Local(mux.clone()));
    laptop.sidebar_visible = false;
    laptop.replace_tree(laptop.session.tree());
    let screen = laptop.tree.active_screen().unwrap().id;

    mux.new_screen(Some(workspace), Some((80, 24))).unwrap();
    laptop.replace_tree(laptop.session.tree());
    assert_ne!(mux.with_state(|state| state.workspaces[0].active_screen), 0);
    assert_eq!(laptop.tree.active_screen().unwrap().id, screen);

    mux.new_tab(Some(pane), None, Some((80, 24))).unwrap();
    laptop.replace_tree(laptop.session.tree());
    assert_eq!(laptop.active_surface(), Some(first.id));

    let split = mux.split(pane, SplitDir::Right, Some((40, 24))).unwrap();
    laptop.replace_tree(laptop.session.tree());
    assert_ne!(mux.active_surface(), Some(first.id));
    assert_ne!(laptop.active_surface(), Some(split.id));
    assert_eq!(laptop.tree.active_screen().unwrap().id, screen);
    assert_eq!(laptop.active_pane(), Some(pane));
    assert_eq!(laptop.active_surface(), Some(first.id));

    mux.close_workspace(workspace);
}

#[test]
fn attached_workspace_mouse_down_uses_both_rendered_rows_and_survives_routing_refresh() {
    let mux = Mux::new(
        "attached-workspace-mouse-test",
        SurfaceOptions {
            command: Some(vec!["/bin/sh".to_string(), "-c".to_string(), "sleep 30".to_string()]),
            ..Default::default()
        },
    );
    mux.new_workspace(Some("Alpha".to_string()), Some((80, 24))).unwrap();
    mux.new_workspace(Some("Beta".to_string()), Some((80, 24))).unwrap();
    let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
    app.sidebar_width = 18;
    app.sidebar_view = SidebarView::Workspaces;
    app.replace_tree(app.session.tree());
    let mut terminal = Terminal::new(TestBackend::new(80, 24)).unwrap();

    for row in 0..2 {
        mux.select_workspace(Some(1), None);
        // Install the owner's reset snapshot directly between subcases.
        app.tree = app.session.tree();
        app.rebuild_tab_locations();
        terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();

        let mut alpha_rows = app
            .hits
            .iter()
            .filter_map(|(rect, hit)| match hit {
                crate::app::Hit::Workspace { index: 0, .. } => Some(*rect),
                _ => None,
            })
            .collect::<Vec<_>>();
        alpha_rows.sort_by_key(|rect| rect.y);
        assert_eq!(alpha_rows.len(), 2, "name and subtitle must both be clickable");
        let hit = alpha_rows[row];
        let event = |kind| {
            AppEvent::Input(Event::Mouse(MouseEvent {
                kind,
                column: hit.x + hit.width.saturating_sub(1) / 2,
                row: hit.y,
                modifiers: KeyModifiers::NONE,
            }))
        };

        app.handle(event(MouseEventKind::Down(MouseButton::Left))).unwrap();
        assert_eq!(app.tree.active_workspace, 0, "a sidebar workspace must activate on mouse-down");
        assert!(matches!(app.drag, Some(Drag::WorkspaceArm { .. })));

        // A concurrent frontend can invalidate routing after the press.
        // The release still belongs to the reorder gesture, but does not
        // own activation.
        app.pointer_route_phase = PointerRoutePhase::DrawPending;
        app.handle(event(MouseEventKind::Up(MouseButton::Left))).unwrap();
        assert_eq!(app.tree.active_workspace, 0);

        while app.session.has_pending_mutations() {
            app.handle(events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();
        }
        app.pointer_route_phase = PointerRoutePhase::Fresh;
        assert_eq!(mux.with_state(|state| state.active_workspace), 1);
    }

    let workspaces: Vec<_> =
        mux.with_state(|state| state.workspaces.iter().map(|workspace| workspace.id).collect());
    for workspace in workspaces {
        mux.close_workspace(workspace);
    }
}

#[test]
fn attached_tab_mouse_click_uses_rendered_hit_and_survives_routing_refresh() {
    let mux = Mux::new(
        "attached-tab-mouse-test",
        SurfaceOptions {
            command: Some(vec!["/bin/sh".to_string(), "-c".to_string(), "sleep 30".to_string()]),
            ..Default::default()
        },
    );
    let first = mux.new_workspace(None, Some((80, 24))).unwrap();
    let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let second = mux.new_tab(Some(pane), None, Some((80, 24))).unwrap();
    let mut app = test_app(Session::Local(mux.clone()));
    app.replace_tree(app.session.tree());

    let rect = Rect { x: 0, y: 0, width: 80, height: 23 };
    let (bar, omnibar, content, track) =
        pane_parts_for_rect(rect, app.config.scrollbar.position, app.config.pane.padding, false);
    app.sidebar_visible = false;
    app.sidebar_width = 0;
    app.content_area = rect;
    app.pane_areas = vec![PaneArea {
        pane,
        surface: second.id,
        rect,
        bar,
        omnibar,
        content,
        track,
        viewport: None,
    }];
    let mut terminal = Terminal::new(TestBackend::new(80, 24)).unwrap();
    terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
    let first_tab = app
        .hits
        .iter()
        .find_map(|(rect, hit)| match hit {
            crate::app::Hit::Tab { pane: hit_pane, index: 0 } if *hit_pane == pane => Some(*rect),
            _ => None,
        })
        .expect("first rendered tab hit");
    let event = |kind| {
        AppEvent::Input(Event::Mouse(MouseEvent {
            kind,
            column: first_tab.x + first_tab.width.saturating_sub(1) / 2,
            row: first_tab.y,
            modifiers: KeyModifiers::NONE,
        }))
    };

    app.handle(event(MouseEventKind::Down(MouseButton::Left))).unwrap();
    assert!(matches!(app.drag, Some(Drag::TabArm { surface, .. }) if surface == first.id));

    app.pointer_route_phase = PointerRoutePhase::DrawPending;
    app.handle(event(MouseEventKind::Up(MouseButton::Left))).unwrap();
    assert_eq!(app.active_surface(), Some(first.id));

    app.pointer_route_phase = PointerRoutePhase::Fresh;
    assert_eq!(mux.active_surface(), Some(second.id));

    let workspace = mux.with_state(|state| state.workspaces[state.active_workspace].id);
    mux.close_workspace(workspace);
}

#[test]
fn admitted_tab_drag_survives_a_pending_pointer_map_refresh() {
    let mux = Mux::new(
        "attached-tab-drag-test",
        SurfaceOptions {
            command: Some(vec!["/bin/sh".to_string(), "-c".to_string(), "sleep 30".to_string()]),
            ..Default::default()
        },
    );
    let first = mux.new_workspace(None, Some((80, 24))).unwrap();
    let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let second = mux.new_tab(Some(pane), None, Some((80, 24))).unwrap();
    let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
    app.replace_tree(app.session.tree());

    let rect = Rect { x: 0, y: 0, width: 80, height: 23 };
    let (bar, omnibar, content, track) =
        pane_parts_for_rect(rect, app.config.scrollbar.position, app.config.pane.padding, false);
    app.sidebar_visible = false;
    app.sidebar_width = 0;
    app.content_area = rect;
    app.pane_areas = vec![PaneArea {
        pane,
        surface: second.id,
        rect,
        bar,
        omnibar,
        content,
        track,
        viewport: None,
    }];
    let mut terminal = Terminal::new(TestBackend::new(80, 24)).unwrap();
    terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
    let mut tabs = app
        .hits
        .iter()
        .filter_map(|(rect, hit)| match hit {
            crate::app::Hit::Tab { pane: hit_pane, index } if *hit_pane == pane => {
                Some((*index, *rect))
            }
            _ => None,
        })
        .collect::<Vec<_>>();
    tabs.sort_by_key(|(index, _)| *index);
    let first_tab = tabs[0].1;
    let second_tab = tabs[1].1;
    let event = |kind, x| {
        AppEvent::Input(Event::Mouse(MouseEvent {
            kind,
            column: x,
            row: first_tab.y,
            modifiers: KeyModifiers::NONE,
        }))
    };

    app.handle(event(MouseEventKind::Down(MouseButton::Left), second_tab.x + second_tab.width / 2))
        .unwrap();
    assert!(matches!(app.drag, Some(Drag::TabArm { surface, .. }) if surface == second.id));

    app.pointer_route_phase = PointerRoutePhase::DrawPending;
    app.handle(event(MouseEventKind::Drag(MouseButton::Left), first_tab.x)).unwrap();
    assert!(app.deferred_input.is_empty());
    assert!(matches!(
        app.drag,
        Some(Drag::Tab {
            surface,
            target: Some((target, 0)),
        }) if surface == second.id && target == pane
    ));

    app.handle(event(MouseEventKind::Up(MouseButton::Left), first_tab.x)).unwrap();
    assert!(app.deferred_input.is_empty());
    while app.session.has_pending_mutations() {
        app.handle(events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();
    }
    let order = mux.with_state(|state| state.panes[&pane].tabs.clone());
    assert_eq!(order, vec![second.id, first.id]);

    let workspace = mux.with_state(|state| state.workspaces[state.active_workspace].id);
    mux.close_workspace(workspace);
}

#[test]
fn emoji_tab_name_fills_its_display_cell_hit_rect() {
    let mux = Mux::new("emoji-tab-width-test", SurfaceOptions::default());
    let first = mux.new_browser_tab("about:blank".to_string(), None, Some((38, 7))).unwrap();
    let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    assert!(mux.rename_surface(first.id, "👩‍💻".to_string()));
    let mut app = test_app(Session::Local(mux.clone()));
    app.sidebar_visible = false;
    app.replace_tree(app.session.tree());
    app.sync_layout((40, 10));

    let mut terminal = Terminal::new(TestBackend::new(40, 10)).unwrap();
    terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
    let tab = app
        .hits
        .iter()
        .find_map(|(rect, hit)| {
            matches!(hit, crate::app::Hit::Tab { pane: hit_pane, index: 0 } if *hit_pane == pane)
                .then_some(*rect)
        })
        .expect("emoji tab hit");
    assert_eq!(
        terminal.backend().buffer()[(tab.x + tab.width - 1, tab.y)].symbol(),
        " ",
        "every visible cell in the tab hit rect must belong to the label"
    );

    mux.shutdown();
}

#[test]
fn attached_workspace_release_without_press_is_a_no_op() {
    let mux = Mux::new(
        "attached-workspace-release-only-test",
        SurfaceOptions {
            command: Some(vec!["/bin/sh".to_string(), "-c".to_string(), "sleep 30".to_string()]),
            ..Default::default()
        },
    );
    mux.new_workspace(Some("Alpha".to_string()), Some((80, 24))).unwrap();
    mux.new_workspace(Some("Beta".to_string()), Some((80, 24))).unwrap();
    let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
    app.session.remote = true;
    app.sidebar_width = 18;
    app.sidebar_view = SidebarView::Workspaces;
    app.replace_tree(app.session.tree());
    let mut terminal = Terminal::new(TestBackend::new(80, 24)).unwrap();
    terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
    let alpha = app
        .hits
        .iter()
        .find_map(|(rect, hit)| match hit {
            crate::app::Hit::Workspace { index: 0, .. } => Some(*rect),
            _ => None,
        })
        .expect("rendered Alpha workspace hit");

    app.handle(AppEvent::Input(Event::Mouse(MouseEvent {
        kind: MouseEventKind::Up(MouseButton::Left),
        column: alpha.x + alpha.width.saturating_sub(1) / 2,
        row: alpha.y,
        modifiers: KeyModifiers::NONE,
    })))
    .unwrap();

    assert_eq!(app.tree.active_workspace, 1);
    assert_eq!(mux.with_state(|state| state.active_workspace), 1);
    assert!(events.try_recv().is_err());

    let workspaces: Vec<_> =
        mux.with_state(|state| state.workspaces.iter().map(|workspace| workspace.id).collect());
    for workspace in workspaces {
        mux.close_workspace(workspace);
    }
}

#[test]
fn tab_switch_moves_size_lease_without_dropping_hidden_surface() {
    let mux = Mux::new("visible-tab-sizing-test", SurfaceOptions::default());
    let first = mux.new_workspace(None, Some((120, 40))).unwrap();
    let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let second = mux.new_tab(Some(pane), None, Some((120, 40))).unwrap();
    mux.select_tab(Some(pane), Some(0), None);
    let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
    app.sync_layout((160, 50));
    while app.session.has_pending_mutations() {
        app.handle(events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();
    }

    assert!(mux.client_surface_size(first.id, 0).is_some());
    assert_eq!(mux.client_surface_size(second.id, 0), None);
    assert!(app.session.has_surface(second.id));

    app.select_tab_for_client(Some(pane), Some(1), None);
    app.sync_layout((160, 50));
    while app.session.has_pending_mutations() {
        app.handle(events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();
    }

    assert_eq!(mux.client_surface_size(first.id, 0), None);
    assert!(mux.client_surface_size(second.id, 0).is_some());
    assert!(app.session.has_surface(first.id));
    let workspace = mux.with_state(|state| state.workspaces[state.active_workspace].id);
    mux.close_workspace(workspace);
}

#[test]
fn stale_remote_snapshot_does_not_mark_pending_route_applied() {
    let mux = Mux::new("stale-routing-snapshot-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.session.remote = true;
    app.session.destination_mutation_started.store(1, Ordering::Release);
    app.session.destination_mutation_committed.store(1, Ordering::Release);
    app.replace_tree(notify_tree(41, false));
    app.pointer_route_phase = PointerRoutePhase::DrawPending;

    app.handle(AppEvent::Input(Event::Key(KeyEvent::new(KeyCode::Char('x'), KeyModifiers::NONE))))
        .unwrap();

    assert_eq!(app.applied_destination_generation, 0);
    assert_eq!(
        app.deferred_input.front().and_then(|input| input.admission.destination_intent),
        Some(1)
    );

    app.handle(AppEvent::RemoteTreeUpdated {
        refresh_sequence: 1,
        destination_generation: 1,
        result: Ok(notify_tree(42, false)),
    })
    .unwrap();
    assert_eq!(app.applied_destination_generation, 1);
}

#[test]
fn identity_refresh_completion_consumes_coalesced_background_refresh() {
    let mux = Mux::new("identity-refresh-dirty-test", SurfaceOptions::default());
    let (mut app, events) = test_app_with_events(Session::Local(mux));
    app.session.remote = true;
    app.session.pending_mutations.store(1, Ordering::Release);
    app.session.remote_background_dirty.store(true, Ordering::Release);

    app.handle(settled(crate::app::SessionMutationOutcome::IdentityRefreshSucceeded {
        tree: TreeView::default(),
        authoritative_generation: 0,
        destination_generation: 0,
        refresh_sequence: 1,
    }))
    .unwrap();

    assert!(!app.session.remote_background_dirty.load(Ordering::Acquire));
    assert!(!app.session.has_pending_mutations());
    assert!(matches!(
        events.recv_timeout(crate::test_wait::EVENT).unwrap(),
        AppEvent::RemoteTreeUpdated { result: Ok(_), .. }
    ));
}

#[test]
fn title_ingress_keeps_latest_per_surface_with_one_app_wake() {
    let mux = Mux::new("title-ingress-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    let updated_surface = 41;
    let untouched_surface = 42;
    app.replace_tree(browser_completion_tree(updated_surface, untouched_surface));
    let (wake_tx, wake_rx) = std::sync::mpsc::channel();

    for index in 0..10_000 {
        if app.mux_titles.push(updated_surface, format!("title-{index}")) {
            wake_tx.send(AppEvent::MuxTitlesReady).unwrap();
        }
        if app.mux_titles.push(99, format!("unknown-{index}")) {
            wake_tx.send(AppEvent::MuxTitlesReady).unwrap();
        }
    }

    let wake = wake_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    assert!(wake_rx.try_recv().is_err(), "title churn must queue one app wake");
    assert!(matches!(app.handle(wake).unwrap(), RenderAction::Paint));
    assert_eq!(app.tree.pane(2).unwrap().tabs[0].title, "title-9999");
    assert_eq!(app.tree.pane(2).unwrap().tabs[1].title, "");
    assert!(app.mux_titles.push(updated_surface, "next".to_string()));
    let dirty = app.mux_titles.take_dirty();
    assert_eq!(dirty.len(), 1);
    assert_eq!(dirty.get(&updated_surface).map(AsRef::as_ref), Some("next"));
    assert_eq!(app.mux_titles.snapshot().len(), 2);
}

#[test]
fn paint_marks_the_pointer_route_stale_until_rendered() {
    let mux = Mux::new("paint-pointer-route-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.replace_tree(notify_tree(41, false));
    assert!(app.mux_titles.push(41, "updated-title".to_string()));

    let action = app.handle(AppEvent::MuxTitlesReady).unwrap();

    assert_eq!(action, RenderAction::Paint);
    assert_eq!(
        app.pointer_route_phase,
        PointerRoutePhase::PaintPending,
        "Paint rebuilds hit regions, so pointer routing must stay blocked until it renders"
    );
}

#[test]
fn title_ingress_reapplies_after_old_and_future_tree_snapshots() {
    let mux = Mux::new("title-snapshot-order-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));

    app.replace_tree(notify_tree(41, false));
    assert!(app.tree.pane(2).is_some());
    let index_before = app.tree.location_index.get().unwrap() as *const _;
    assert!(app.mux_titles.push(41, "live-title".to_string()));
    app.handle(AppEvent::MuxTitlesReady).unwrap();
    let index_after = app.tree.location_index.get().unwrap() as *const _;
    assert!(std::ptr::eq(index_before, index_after));
    assert_eq!(app.tree.pane(2).unwrap().tabs[0].title, "live-title");

    assert!(app.mux_titles.push(41, "live-title".to_string()));
    assert_eq!(app.handle(AppEvent::MuxTitlesReady).unwrap(), RenderAction::None);

    app.replace_tree(notify_tree(41, false));
    assert_eq!(app.tree.pane(2).unwrap().tabs[0].title, "live-title");

    assert!(app.mux_titles.push(42, "future-title".to_string()));
    app.handle(AppEvent::MuxTitlesReady).unwrap();
    app.replace_tree(notify_tree(42, false));
    assert_eq!(app.tree.pane(2).unwrap().tabs[0].title, "future-title");
}

#[test]
fn title_ingress_prunes_all_pre_snapshot_titles_but_keeps_concurrent_updates() {
    let titles = MuxTitleIngress::default();
    titles.push(41, "stale-title");
    let snapshot_epoch = titles.current_epoch();
    titles.push(42, "concurrent-title");

    titles.reconcile_authoritative(snapshot_epoch);

    let retained = titles.snapshot();
    assert!(!retained.contains_key(&41));
    assert_eq!(retained.get(&42).map(AsRef::as_ref), Some("concurrent-title"));
}

#[test]
fn title_ingress_rearms_a_lost_wake_after_failed_recovery() {
    let titles = MuxTitleIngress::default();
    assert!(titles.push(41, "first"));
    assert!(!titles.push(41, "latest"));

    assert!(titles.rearm_wake());
    assert_eq!(titles.take_dirty().get(&41).map(AsRef::as_ref), Some("latest"));
    assert!(!titles.rearm_wake());
    assert!(titles.push(41, "next"));
}

#[test]
fn mux_forwarder_recovers_after_bounded_mailbox_overflow() {
    let mux = Mux::new("mux-forwarder-overflow-test", SurfaceOptions::default());
    let event_source = Session::Local(mux.clone());
    let session_events = event_source.events();
    let stop_receiver = Arc::new(Mutex::new(Some(session_events.clone())));
    for surface in 0..5_000 {
        mux.emit(MuxEvent::Bell(surface));
    }
    let (tx, rx) = crossbeam_channel::bounded(1);
    let titles = Arc::new(MuxTitleIngress::default());
    let destination_generation = Arc::new(AtomicU64::new(0));
    let recovery_generation = Arc::new(AtomicU64::new(0));
    let forwarder_recovery_generation = recovery_generation.clone();
    let forwarder = std::thread::spawn(move || {
        forward_mux_events(
            event_source,
            session_events,
            stop_receiver,
            destination_generation,
            forwarder_recovery_generation,
            SessionEventSender::unscoped(tx),
            titles,
        );
    });

    let first = rx.recv_timeout(Duration::from_secs(1)).unwrap();
    let deadline = Instant::now() + Duration::from_secs(1);
    while recovery_generation.load(Ordering::Acquire) == 0 && Instant::now() < deadline {
        std::thread::yield_now();
    }
    assert!(
        recovery_generation.load(Ordering::Acquire) > 0,
        "the routing barrier must rise before the stale app backlog is drained"
    );

    let mut next = Some(first);
    let mut recovered_generations = HashSet::new();
    let mut preserved_bells = 0;
    let final_generation = loop {
        let event = next.take().unwrap_or_else(|| rx.recv_timeout(Duration::from_secs(1)).unwrap());
        match event {
            AppEvent::MuxSubscriptionRecovered { recovery_generation, result: Ok(_), .. } => {
                recovered_generations.insert(recovery_generation);
            }
            AppEvent::MuxRecoveryComplete { recovery_generation }
                if recovered_generations.contains(&recovery_generation) =>
            {
                break recovery_generation;
            }
            AppEvent::Mux(MuxEvent::Bell(_)) => preserved_bells += 1,
            _ => {}
        }
    };
    assert_eq!(preserved_bells, 4_096);
    assert_eq!(recovery_generation.load(Ordering::Acquire), final_generation);

    mux.emit(MuxEvent::Bell(9_999));
    assert!(matches!(
        rx.recv_timeout(Duration::from_secs(1)).unwrap(),
        AppEvent::Mux(MuxEvent::Bell(9_999))
    ));
    mux.emit(MuxEvent::Empty);
    assert!(matches!(
        rx.recv_timeout(Duration::from_secs(1)).unwrap(),
        AppEvent::Mux(MuxEvent::Empty)
    ));
    drop(rx);
    forwarder.join().unwrap();
}

#[test]
fn mux_forwarder_stop_wakes_after_overflow_replaces_mailbox() {
    let mux = Mux::new("mux-forwarder-overflow-stop-test", SurfaceOptions::default());
    let event_source = Session::Local(mux.clone());
    let session_events = event_source.events();
    let stop_receiver = Arc::new(Mutex::new(Some(session_events.clone())));
    let stop_for_test = stop_receiver.clone();
    for surface in 0..5_000 {
        mux.emit(MuxEvent::Bell(surface));
    }
    let (tx, rx) = crossbeam_channel::bounded(8_192);
    let titles = Arc::new(MuxTitleIngress::default());
    let destination_generation = Arc::new(AtomicU64::new(0));
    let recovery_generation = Arc::new(AtomicU64::new(0));
    let cancellation = EventCancellation::new();
    let forwarder_events = SessionEventSender {
        tx,
        generation: None,
        surface_filter: None,
        cancellation: cancellation.clone(),
    };
    let forwarder_recovery_generation = recovery_generation;
    let forwarder = std::thread::spawn(move || {
        forward_mux_events(
            event_source,
            session_events,
            stop_receiver,
            destination_generation,
            forwarder_recovery_generation,
            forwarder_events,
            titles,
        );
    });

    let deadline = Instant::now() + Duration::from_secs(1);
    let mut recovered = false;
    while Instant::now() < deadline {
        match rx.recv_timeout(Duration::from_millis(50)) {
            Ok(AppEvent::MuxRecoveryComplete { .. }) => {
                recovered = true;
                break;
            }
            Ok(_) => {}
            Err(crossbeam_channel::RecvTimeoutError::Timeout) => {}
            Err(crossbeam_channel::RecvTimeoutError::Disconnected) => break,
        }
    }
    assert!(recovered, "overflow recovery must install a replacement mailbox");

    // The forwarder is blocked on the replacement mailbox here. Closing
    // the currently active receiver must wake it without timer polling.
    cancellation.cancel();
    stop_for_test.lock().unwrap().take().unwrap().close();
    forwarder.join().unwrap();
}

#[test]
fn mux_forwarder_preserves_empty_while_app_channel_is_full() {
    let (tx, rx) = crossbeam_channel::bounded(1);
    tx.send(AppEvent::Mux(MuxEvent::Bell(1))).unwrap();
    let titles = MuxTitleIngress::default();
    let forwarder = std::thread::spawn(move || {
        forward_mux_event(MuxEvent::Empty, &SessionEventSender::unscoped(tx), &titles)
    });

    assert!(matches!(rx.recv().unwrap(), AppEvent::Mux(MuxEvent::Bell(1))));
    assert!(matches!(rx.recv().unwrap(), AppEvent::Mux(MuxEvent::Empty)));
    assert!(matches!(forwarder.join().unwrap(), ForwardMuxOutcome::Stop));
}

#[test]
fn mux_forwarder_preserves_resize_completion_while_app_channel_is_full() {
    let (tx, rx) = crossbeam_channel::bounded(1);
    tx.send(AppEvent::Mux(MuxEvent::Bell(1))).unwrap();
    let titles = MuxTitleIngress::default();
    let forwarder = std::thread::spawn(move || {
        let tx = SessionEventSender::unscoped(tx);
        forward_mux_event(
            MuxEvent::SurfaceResized { surface: 41, cols: 90, rows: 31, reservation_id: Some(7) },
            &tx,
            &titles,
        )
    });

    assert!(matches!(rx.recv().unwrap(), AppEvent::Mux(MuxEvent::Bell(1))));
    assert!(matches!(
        rx.recv().unwrap(),
        AppEvent::Mux(MuxEvent::SurfaceResized { surface: 41, reservation_id: Some(7), .. })
    ));
    assert!(matches!(forwarder.join().unwrap(), ForwardMuxOutcome::Continue));
}

#[test]
fn mux_forwarder_preserves_one_shot_event_while_app_channel_is_full() {
    let (tx, rx) = crossbeam_channel::bounded(1);
    tx.send(AppEvent::Mux(MuxEvent::Bell(1))).unwrap();
    let titles = MuxTitleIngress::default();
    let forwarder = std::thread::spawn(move || {
        forward_mux_event(MuxEvent::Bell(2), &SessionEventSender::unscoped(tx), &titles)
    });

    assert!(matches!(rx.recv().unwrap(), AppEvent::Mux(MuxEvent::Bell(1))));
    assert!(matches!(rx.recv().unwrap(), AppEvent::Mux(MuxEvent::Bell(2))));
    assert!(matches!(forwarder.join().unwrap(), ForwardMuxOutcome::Continue));
}

#[test]
fn single_surface_mux_forwarder_drops_unrelated_output_titles_and_agents() {
    let (tx, rx) = crossbeam_channel::bounded(4);
    let tx = SessionEventSender::filtered(tx, 41);
    let titles = MuxTitleIngress::default();

    assert!(matches!(
        forward_mux_event(
            MuxEvent::TitleChanged { surface: 42, title: "other".into() },
            &tx,
            &titles,
        ),
        ForwardMuxOutcome::Continue
    ));
    assert!(matches!(
        forward_mux_event(MuxEvent::SurfaceOutput(42), &tx, &titles),
        ForwardMuxOutcome::Continue
    ));
    assert!(matches!(
        forward_mux_event(
            MuxEvent::AgentChanged {
                surface: 42,
                state: "working".into(),
                source: "hook".into(),
                session: None,
                agent: None,
                updated_at_ms: 1,
            },
            &tx,
            &titles,
        ),
        ForwardMuxOutcome::Continue
    ));
    assert!(rx.try_recv().is_err());
    assert!(titles.take_dirty().is_empty());

    assert!(matches!(
        forward_mux_event(MuxEvent::SurfaceOutput(41), &tx, &titles),
        ForwardMuxOutcome::Continue
    ));
    assert!(matches!(rx.try_recv().unwrap(), AppEvent::Mux(MuxEvent::SurfaceOutput(41))));
    assert!(matches!(
        forward_mux_event(
            MuxEvent::AgentChanged {
                surface: 41,
                state: "working".into(),
                source: "hook".into(),
                session: None,
                agent: None,
                updated_at_ms: 2,
            },
            &tx,
            &titles,
        ),
        ForwardMuxOutcome::Continue
    ));
    assert!(matches!(
        rx.try_recv().unwrap(),
        AppEvent::Mux(MuxEvent::AgentChanged { surface: 41, .. })
    ));
}

#[test]
fn title_wake_waits_for_app_capacity_without_triggering_recovery() {
    let (tx, rx) = crossbeam_channel::bounded(1);
    tx.send(AppEvent::Mux(MuxEvent::Bell(1))).unwrap();
    let titles = Arc::new(MuxTitleIngress::default());
    let forwarded_titles = titles.clone();
    let forwarder = std::thread::spawn(move || {
        let tx = SessionEventSender::unscoped(tx);
        forward_mux_event(
            MuxEvent::TitleChanged { surface: 41, title: "latest".into() },
            &tx,
            &forwarded_titles,
        )
    });

    assert!(matches!(rx.recv().unwrap(), AppEvent::Mux(MuxEvent::Bell(1))));
    assert!(matches!(rx.recv().unwrap(), AppEvent::MuxTitlesReady));
    assert!(matches!(forwarder.join().unwrap(), ForwardMuxOutcome::Continue));
    assert_eq!(titles.take_dirty().get(&41).map(AsRef::as_ref), Some("latest"));
}

#[test]
fn mux_recovery_barrier_defers_input_until_authoritative_tree_is_applied() {
    let mux = Mux::new("mux-recovery-barrier-test", SurfaceOptions::default());
    mux.new_workspace(None, None).unwrap();
    let mut app = test_app(Session::Local(mux));
    app.replace_tree(app.session.tree());
    app.mux_recovery_generation.store(1, Ordering::Release);

    app.handle(AppEvent::Input(Event::Paste("queued".to_string()))).unwrap();
    assert_eq!(app.deferred_input.len(), 1);
    let client_refresh_generation = app.session.client_refresh_generation();

    app.handle(AppEvent::MuxSubscriptionRecovered {
        recovery_generation: 1,
        destination_generation: 0,
        result: Ok(app.session.tree()),
    })
    .unwrap();
    assert_eq!(app.mux_recovery_generation.load(Ordering::Acquire), 1);
    assert_eq!(app.deferred_input.len(), 1);
    assert!(app.session.client_refresh_generation() > client_refresh_generation);
    assert_eq!(
        app.status_message.as_deref(),
        Some(localization::catalog().session.mux_subscription_recovered)
    );

    app.handle(AppEvent::MuxRecoveryComplete { recovery_generation: 1 }).unwrap();
    assert_eq!(app.mux_recovery_generation.load(Ordering::Acquire), 0);
    assert_eq!(app.pointer_route_phase, PointerRoutePhase::DrawPending);
}

#[test]
fn remote_subscription_recovery_signal_refreshes_client_snapshot() {
    let mux = Mux::new("client-list-recovery-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    let before = app.session.client_refresh_generation();

    app.handle(AppEvent::Mux(MuxEvent::ClientListInvalidated)).unwrap();

    assert!(app.session.client_refresh_generation() > before);
}

#[test]
fn failed_mux_recovery_releases_barrier_and_discards_ambiguous_input() {
    let mux = Mux::new("mux-recovery-failure-test", SurfaceOptions::default());
    mux.new_workspace(None, None).unwrap();
    let mut app = test_app(Session::Local(mux));
    app.replace_tree(app.session.tree());
    app.mux_recovery_generation.store(1, Ordering::Release);
    app.handle(AppEvent::Input(Event::Paste("queued".to_string()))).unwrap();

    app.handle(AppEvent::MuxSubscriptionRecovered {
        recovery_generation: 1,
        destination_generation: 0,
        result: Err("refresh failed".to_string()),
    })
    .unwrap();

    assert_eq!(app.mux_recovery_generation.load(Ordering::Acquire), 0);
    assert!(app.deferred_input.is_empty());
    let expected =
        localization::catalog().session.mux_subscription_recovery_failed("refresh failed");
    assert_eq!(app.status_message.as_deref(), Some(expected.as_str()));
}

#[test]
fn stale_mux_recovery_completion_cannot_release_a_newer_barrier() {
    let mux = Mux::new("stale-mux-recovery-completion-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.mux_recovery_generation.store(2, Ordering::Release);

    app.handle(AppEvent::MuxRecoveryComplete { recovery_generation: 1 }).unwrap();

    assert_eq!(app.mux_recovery_generation.load(Ordering::Acquire), 2);
    assert_eq!(app.pointer_route_phase, PointerRoutePhase::Fresh);
}

#[test]
fn authoritative_recovery_prunes_render_state_for_missed_surface_exit() {
    let mux = Mux::new("authoritative-prune-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.replace_tree(notify_tree(42, false));
    app.render_states.insert(42, RenderState::new().unwrap());
    app.mux_titles.push(42, "stale-title".to_string());

    app.replace_authoritative_tree(TreeView::default(), 0);

    assert!(!app.render_states.contains_key(&42));
    assert!(!app.tab_locations.contains_key(&42));
    assert!(!app.mux_titles.snapshot().contains_key(&42));
}

#[test]
fn cached_surface_exit_updates_tab_index_without_rebuilding_unrelated_tabs() {
    let mux = Mux::new("cached-surface-exit-index-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    let mut tree = notify_tree(41, false);
    let pane = &mut tree.workspaces_mut()[0].screens[0].panes[0];
    let mut second = pane.tabs[0].clone();
    second.surface = 41;
    let mut third = pane.tabs[0].clone();
    third.surface = 43;
    pane.tabs[0].surface = 40;
    pane.tabs.push(second);
    pane.tabs.push(third);
    pane.active_tab = 1;
    app.replace_tree(tree);
    assert_eq!(app.tree.surface(40).map(|tab| tab.surface), Some(40));

    app.remove_surface_from_cached_tree(40);

    let pane = &app.tree.workspaces()[0].screens[0].panes[0];
    assert_eq!(pane.tabs.iter().map(|tab| tab.surface).collect::<Vec<_>>(), vec![41, 43]);
    assert_eq!(pane.active_tab, 0);
    assert!(!app.tab_locations.contains_key(&40));
    assert_eq!(app.tab_locations.get(&41), Some(&[0, 0, 0, 0]));
    assert_eq!(app.tab_locations.get(&43), Some(&[0, 0, 0, 1]));
    assert!(app.tree.surface(40).is_none());
    assert_eq!(app.tree.surface(41).map(|tab| tab.surface), Some(41));
    assert_eq!(app.tree.surface(43).map(|tab| tab.surface), Some(43));
}

#[test]
fn stale_surface_exit_index_falls_back_to_tree_scan_and_rebuilds_locations() {
    let mux = Mux::new("stale-surface-exit-index-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    let mut tree = notify_tree(41, false);
    let pane = &mut tree.workspaces_mut()[0].screens[0].panes[0];
    let mut second = pane.tabs[0].clone();
    second.surface = 41;
    let mut third = pane.tabs[0].clone();
    third.surface = 43;
    pane.tabs[0].surface = 40;
    pane.tabs.push(second);
    pane.tabs.push(third);
    pane.active_tab = 2;
    app.replace_tree(tree);

    // Force the defensive dispatch path by making the cached location stale.
    app.tab_locations.insert(40, [0, 0, 0, 1]);
    app.remove_surface_from_cached_tree(40);

    let pane = &app.tree.workspaces()[0].screens[0].panes[0];
    assert_eq!(pane.tabs.iter().map(|tab| tab.surface).collect::<Vec<_>>(), vec![41, 43]);
    assert_eq!(pane.active_tab, 1);
    assert_eq!(app.tab_locations.get(&41), Some(&[0, 0, 0, 0]));
    assert_eq!(app.tab_locations.get(&43), Some(&[0, 0, 0, 1]));
    assert!(!app.tab_locations.contains_key(&40));

    // The fallback must repair the index so the next exit uses the
    // indexed path instead of scanning the whole tree again.
    app.remove_surface_from_cached_tree(41);
    let pane = &app.tree.workspaces()[0].screens[0].panes[0];
    assert_eq!(pane.tabs.iter().map(|tab| tab.surface).collect::<Vec<_>>(), vec![43]);
    assert_eq!(app.tab_locations.get(&43), Some(&[0, 0, 0, 0]));
    assert!(!app.tab_locations.contains_key(&41));
}

#[test]
fn resize_claims_skip_identical_work_and_replace_a_b_a_reversions() {
    let mux = Mux::new("resize-claim-test", SurfaceOptions::default());
    let app = test_app(Session::Local(mux));
    assert!(matches!(
        app.session.surface_resize_decision(7, (80, 24), false),
        SurfaceResizeDecision::Noop
    ));
    let first = match app.session.surface_resize_decision(7, (100, 30), true) {
        SurfaceResizeDecision::NeedsQueue(claim) => claim,
        _ => panic!("first changed size must queue"),
    };
    for _ in 0..1_000 {
        assert!(matches!(
            app.session.surface_resize_decision(7, (100, 30), true),
            SurfaceResizeDecision::AlreadyClaimed
        ));
    }
    let reverted = match app.session.surface_resize_decision(7, (80, 24), false) {
        SurfaceResizeDecision::NeedsQueue(claim) => claim,
        _ => panic!("different outstanding size must be replaced even when server is current"),
    };
    drop(first);
    assert!(matches!(
        app.session.surface_resize_decision(7, (80, 24), false),
        SurfaceResizeDecision::AlreadyClaimed
    ));
    drop(reverted);
    assert!(matches!(
        app.session.surface_resize_decision(7, (80, 24), false),
        SurfaceResizeDecision::Noop
    ));

    let old_a = match app.session.surface_resize_decision(9, (80, 24), true) {
        SurfaceResizeDecision::NeedsQueue(claim) => claim,
        _ => panic!("first A must queue"),
    };
    let b = match app.session.surface_resize_decision(9, (100, 30), true) {
        SurfaceResizeDecision::NeedsQueue(claim) => claim,
        _ => panic!("B must replace A"),
    };
    let new_a = match app.session.surface_resize_decision(9, (80, 24), true) {
        SurfaceResizeDecision::NeedsQueue(claim) => claim,
        _ => panic!("new A must replace B"),
    };
    drop(old_a);
    drop(b);
    assert!(matches!(
        app.session.surface_resize_decision(9, (80, 24), true),
        SurfaceResizeDecision::AlreadyClaimed
    ));
    drop(new_a);
}

#[test]
fn browser_resize_claim_survives_queue_and_input_barrier_until_drop() {
    let mux = Mux::new("browser-resize-claim-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    let (dispatcher, blocked) = BrowserInputDispatcher::blocked(2);
    app.browser_input = dispatcher;
    let claim = match app.session.surface_resize_decision(7, (100, 30), true) {
        SurfaceResizeDecision::NeedsQueue(claim) => claim,
        _ => panic!("browser resize must queue"),
    };
    app.enqueue_surface_resize(
        7,
        SurfaceHandle::RemoteBrowserUnsupported,
        100,
        30,
        false,
        Some(claim),
    );
    assert!(app.session.surface_resize_ownership.lock().unwrap().get(&7).is_none());
    let _ = app.browser_input.enqueue(BrowserInputEvent {
        surface_id: 7,
        surface: SurfaceHandle::RemoteBrowserUnsupported,
        kind: BrowserInputKind::Mouse {
            event_type: "mouseMoved",
            x: 1.0,
            y: 1.0,
            button: Some("none"),
            click_count: None,
            frame_seq: 1,
        },
    });

    assert!(matches!(
        app.session.surface_resize_decision(7, (100, 30), true),
        SurfaceResizeDecision::AlreadyClaimed
    ));
    drop(blocked);
    assert!(matches!(
        app.session.surface_resize_decision(7, (100, 30), true),
        SurfaceResizeDecision::NeedsQueue(_)
    ));
}

#[test]
fn browser_resize_ownership_tracks_only_accepted_dispatches() {
    let ownership = Mutex::new(HashMap::new());

    record_surface_resize_dispatch_result(&ownership, 7, (100, 30), None);
    assert!(ownership.lock().unwrap().is_empty());

    record_surface_resize_dispatch_result(&ownership, 7, (100, 30), Some(41));
    assert_eq!(
        ownership.lock().unwrap().get(&7),
        Some(&SurfaceResizeOwnership { desired: (100, 30), reservation_id: Some(41) })
    );

    record_surface_resize_dispatch_result(&ownership, 7, (100, 30), None);
    assert!(ownership.lock().unwrap().contains_key(&7));
}

#[test]
fn resize_events_do_not_refresh_clients_on_the_event_loop() {
    let mux = Mux::new("resize-client-refresh-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));

    let action = app
        .handle(AppEvent::Mux(MuxEvent::SurfaceResized {
            surface: 7,
            cols: 80,
            rows: 24,
            reservation_id: None,
        }))
        .unwrap();

    assert_eq!(action, RenderAction::Paint);
    assert!(!app.session.client_refresh_queued.load(Ordering::Acquire));
}
