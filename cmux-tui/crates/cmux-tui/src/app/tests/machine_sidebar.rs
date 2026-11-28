//! Tests: deferred motion ordering, the machine sidebar, drags and focus
//! during pending mutations, cursor state, and provider rails.

use super::*;

#[test]
fn missing_surface_motion_stays_ahead_of_later_deferred_input() {
    let mux = Mux::new("replayed-missing-motion-order-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    let missing_surface = 77;
    app.pane_areas.push(browser_completion_area(missing_surface));
    app.session.surface_attach_failures.lock().unwrap().insert(
        missing_surface,
        crate::app::SurfaceSyncFailureState {
            attempts: 1,
            retry_after: Some(Instant::now() + Duration::from_secs(30)),
            sticky_until_reconnect: false,
        },
    );
    app.prompt = Some(Prompt::new("Rename", String::new(), PromptTarget::Surface(88)));
    app.pending_pointer_motion = Some(crate::app::PendingPointerMotion {
        event: MouseEvent {
            kind: MouseEventKind::Moved,
            column: 14,
            row: 6,
            modifiers: KeyModifiers::NONE,
        },
        destination: Some(missing_surface),
        focus_generation: 0,
        sequence: 1,
    });
    app.deferred_input.push_back(queued_input(
        Event::Key(KeyEvent::new(KeyCode::Char('x'), KeyModifiers::NONE)),
        None,
        2,
    ));
    app.deferred_input_sequence = 2;

    let replay = app.replay_deferred_input_batch().unwrap();

    assert_eq!(
        app.prompt.as_ref().unwrap().input.as_str(),
        "",
        "later input must not pass motion that is still waiting for its surface"
    );
    assert_eq!(app.pending_pointer_motion.map(|pointer| pointer.sequence), Some(1));
    assert_eq!(app.deferred_input.front().map(|input| input.sequence), Some(2));
    assert_eq!(replay.action, RenderAction::None);
    assert_eq!(replay.disposition, DeferredReplayDisposition::Blocked);
}

#[test]
fn replayed_key_requeue_keeps_its_original_order() {
    let mux = Mux::new("replayed-missing-key-order-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    let missing_surface = 77;
    app.replace_tree(notify_tree(missing_surface, false));
    app.deferred_input.push_back(queued_input(
        Event::Key(KeyEvent::new(KeyCode::Char('y'), KeyModifiers::NONE)),
        Some(missing_surface),
        2,
    ));
    app.deferred_input_sequence = 2;

    app.handle_replayed_input(
        Event::Key(KeyEvent::new(KeyCode::Char('x'), KeyModifiers::NONE)).into(),
        1,
        None,
    )
    .unwrap();

    assert_eq!(
        app.deferred_input
            .iter()
            .map(|input| {
                let TerminalInput::Keyboard(key) = &input.event else {
                    panic!("expected a deferred key")
                };
                (key.ui_key().code, input.sequence)
            })
            .collect::<Vec<_>>(),
        vec![(KeyCode::Char('x'), 1), (KeyCode::Char('y'), 2)]
    );
}

#[test]
fn replayed_discrete_pointer_requeue_keeps_its_original_order() {
    let mux = Mux::new("replayed-missing-pointer-order-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    let missing_surface = 77;
    app.pane_areas.push(browser_completion_area(missing_surface));
    app.deferred_input.push_back(queued_input(
        Event::Key(KeyEvent::new(KeyCode::Char('y'), KeyModifiers::NONE)),
        None,
        2,
    ));
    app.deferred_input_sequence = 2;
    let pointer = MouseEvent {
        kind: MouseEventKind::Down(MouseButton::Right),
        column: 14,
        row: 6,
        modifiers: KeyModifiers::SHIFT,
    };

    app.handle_replayed_input(TerminalInput::Mouse(pointer), 1, None).unwrap();

    assert!(matches!(
        app.deferred_input.front(),
        Some(DeferredInput {
            event: TerminalInput::Mouse(event),
            sequence: 1,
            ..
        }) if *event == pointer
    ));
    assert_eq!(app.deferred_input.back().map(|input| input.sequence), Some(2));
}

#[test]
fn captured_release_ignores_destination_changes_and_clears_ownership() {
    let (mux, surface) = test_mux("captured-release-destination-test", None);
    let mut app = test_app(Session::Local(mux.clone()));
    app.replace_tree(app.session.tree());
    let pane = app.tree.active_screen().unwrap().active_pane;
    let content = Rect { x: 2, y: 3, width: 20, height: 8 };
    app.pane_areas.push(PaneArea {
        pane,
        surface: surface.id,
        rect: Rect { x: 1, y: 2, width: 23, height: 10 },
        bar: Some(Rect { x: 1, y: 2, width: 23, height: 1 }),
        omnibar: None,
        content,
        track: None,
        viewport: None,
    });
    app.rendered_terminal_bounds.insert(surface.id, content);
    app.selection = Some(Selection { surface: surface.id, anchor: (1, 1), head: (3, 2) });
    app.drag = Some(Drag::Select { content, source_x: 0, auto_scroll: None, col: 3 });
    app.active_pointer_buttons.insert(MouseButton::Left);
    let release = MouseEvent {
        kind: MouseEventKind::Up(MouseButton::Left),
        column: content.x + 3,
        row: content.y + 2,
        modifiers: KeyModifiers::NONE,
    };

    app.defer_input(Event::Mouse(release));
    assert_eq!(
        app.deferred_input.front().and_then(|input| input.admission.destination),
        Some(surface.id)
    );
    app.pane_areas.clear();
    app.replay_deferred_input().unwrap();

    assert!(app.deferred_input.is_empty());
    assert!(app.drag.is_none(), "the release must reach its established selection capture");
    assert!(app.active_pointer_buttons.is_empty());
    mux.close_surface(surface.id).unwrap();
}

#[test]
fn replay_without_a_render_action_blocks_instead_of_spinning() {
    let mux = Mux::new("replay-no-render-progress-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.deferred_input.push_back(queued_input(
        TerminalInput::Mouse(MouseEvent {
            kind: MouseEventKind::Down(MouseButton::Left),
            column: 9,
            row: 3,
            modifiers: KeyModifiers::NONE,
        }),
        None,
        1,
    ));
    app.pointer_route_phase = PointerRoutePhase::DrawPending;

    let replay = app.replay_deferred_input_batch().unwrap();

    assert_eq!(replay.action, RenderAction::None);
    assert_eq!(
        replay.disposition,
        DeferredReplayDisposition::Blocked,
        "a replay boundary without a render action cannot make immediate progress"
    );
    assert!(
        !app.replay_can_continue_immediately(replay.disposition),
        "the event loop must wait for a state-changing event instead of spinning"
    );
}

#[test]
fn browser_drag_release_bypasses_a_pending_focus_mutation() {
    let mux = Mux::new("browser-release-barrier-test", SurfaceOptions::default());
    let (mut app, _events) = test_app_with_events(Session::Local(mux));
    let (started_tx, started_rx) = std::sync::mpsc::channel();
    let (_release_tx, release_rx) = std::sync::mpsc::channel::<()>();
    app.session.enqueue("blocking focus", move |_| {
        started_tx.send(()).unwrap();
        let _ = release_rx.recv();
        Ok(())
    });
    started_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    app.drag = Some(Drag::Browser {
        surface: 42,
        content: Rect { x: 2, y: 3, width: 20, height: 8 },
        position: (5, 5),
        frame_seq: 1,
    });

    app.handle(AppEvent::Input(Event::Mouse(MouseEvent {
        kind: MouseEventKind::Up(MouseButton::Left),
        column: 5,
        row: 5,
        modifiers: KeyModifiers::NONE,
    })))
    .unwrap();

    assert!(app.deferred_input.is_empty());
    assert!(app.drag.is_none());
}

#[test]
fn browser_drag_retargets_to_the_animated_pane_geometry() {
    let mux = Mux::new("browser-live-drag-geometry-test", SurfaceOptions::default());
    let surface = mux.new_workspace(None, Some((20, 8))).unwrap();
    let pane = mux.with_state(|state| state.pane_of(surface.id).unwrap());
    let mut app = test_app(Session::Local(mux.clone()));
    let (dispatcher, received) = BrowserInputDispatcher::blocked(1);
    app.browser_input = dispatcher;
    let current = Rect { x: 20, y: 4, width: 10, height: 5 };
    app.pane_areas = vec![PaneArea {
        pane,
        surface: surface.id,
        rect: current,
        bar: None,
        omnibar: None,
        content: current,
        track: None,
        viewport: None,
    }];
    app.drag = Some(Drag::Browser {
        surface: surface.id,
        content: Rect { x: 2, y: 3, width: 10, height: 5 },
        position: (5, 4),
        frame_seq: 1,
    });

    app.handle_left_drag(23, 6).unwrap();

    assert!(matches!(
        app.drag,
        Some(Drag::Browser {
            surface: id,
            content,
            position: (23, 6),
            ..
        }) if id == surface.id && content == current
    ));
    assert!(matches!(
        received.recv_timeout(Duration::from_secs(1)).map(|event| event.kind),
        Some(BrowserInputKind::Mouse { event_type: "mouseMoved", .. })
    ));
    mux.close_surface(surface.id).unwrap();
}

#[test]
fn selection_drag_and_release_bypass_a_pending_focus_mutation() {
    let mux = Mux::new(
        "selection-release-barrier-test",
        SurfaceOptions { command: Some(vec!["/bin/cat".to_string()]), ..SurfaceOptions::default() },
    );
    let surface = mux.new_workspace(None, Some((20, 8))).unwrap();
    let mut app = test_app(Session::Local(mux));
    app.session.pending_mutations.store(1, Ordering::Release);
    let content = Rect { x: 2, y: 3, width: 20, height: 8 };
    app.selection = Some(Selection { surface: surface.id, anchor: (1, 1), head: (1, 1) });
    app.drag = Some(Drag::Select { content, source_x: 0, auto_scroll: None, col: 1 });

    app.handle(AppEvent::Input(Event::Mouse(MouseEvent {
        kind: MouseEventKind::Drag(MouseButton::Left),
        column: 8,
        row: 6,
        modifiers: KeyModifiers::NONE,
    })))
    .unwrap();
    assert!(app.deferred_input.is_empty());
    assert_eq!(app.selection.map(|selection| selection.head), Some((6, 3)));

    app.handle(AppEvent::Input(Event::Mouse(MouseEvent {
        kind: MouseEventKind::Up(MouseButton::Left),
        column: 8,
        row: 6,
        modifiers: KeyModifiers::NONE,
    })))
    .unwrap();
    assert!(app.deferred_input.is_empty());
    assert!(app.drag.is_none());
}

#[test]
fn selection_drag_retargets_to_the_animated_pane_geometry() {
    let mux = Mux::new(
        "selection-live-drag-geometry-test",
        SurfaceOptions { command: Some(vec!["/bin/cat".to_string()]), ..SurfaceOptions::default() },
    );
    let surface = mux.new_workspace(None, Some((20, 8))).unwrap();
    let pane = mux.with_state(|state| state.pane_of(surface.id).unwrap());
    let mut app = test_app(Session::Local(mux.clone()));
    let current = Rect { x: 20, y: 4, width: 10, height: 5 };
    app.pane_areas = vec![PaneArea {
        pane,
        surface: surface.id,
        rect: current,
        bar: None,
        omnibar: None,
        content: current,
        track: None,
        viewport: Some(PaneViewportClip {
            rect_source_x: 7,
            full_rect_width: 20,
            omnibar_source_x: 0,
            full_omnibar_width: 0,
            content_source_x: 7,
            full_content_width: 20,
        }),
    }];
    app.rendered_terminal_bounds.insert(surface.id, current);
    app.selection = Some(Selection { surface: surface.id, anchor: (7, 0), head: (7, 0) });
    app.drag = Some(Drag::Select {
        content: Rect { x: 2, y: 3, width: 10, height: 5 },
        source_x: 0,
        auto_scroll: None,
        col: 1,
    });

    app.handle_left_drag(23, 6).unwrap();

    assert_eq!(app.selection.map(|selection| selection.head), Some((10, 2)));
    assert!(matches!(
        app.drag,
        Some(Drag::Select {
            content,
            source_x: 7,
            col: 10,
            ..
        }) if content == current
    ));
    mux.close_surface(surface.id).unwrap();
}

#[test]
fn pty_drag_motion_and_release_bypass_pending_mutation_with_pinned_surface() {
    let mux = Mux::new("pty-release-barrier-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.session.pending_mutations.store(1, Ordering::Release);
    app.drag = Some(Drag::PtyMouse {
        surface: 42,
        handle: None,
        reservation_id: 1,
        release_bytes: PtyInputBytes::from_slice(b"release"),
        semantics: None,
        content: Rect { x: 2, y: 3, width: 20, height: 8 },
        button: MouseButton::Right,
        position: (5, 5),
        modifiers: KeyModifiers::NONE,
    });

    app.handle(AppEvent::Input(Event::Mouse(MouseEvent {
        kind: MouseEventKind::Drag(MouseButton::Left),
        column: 8,
        row: 6,
        modifiers: KeyModifiers::NONE,
    })))
    .unwrap();
    assert!(app.deferred_input.is_empty());
    assert!(matches!(app.drag, Some(Drag::PtyMouse { surface: 42, position: (8, 6), .. })));

    app.handle(AppEvent::Input(Event::Mouse(MouseEvent {
        kind: MouseEventKind::Up(MouseButton::Right),
        column: 8,
        row: 6,
        modifiers: KeyModifiers::NONE,
    })))
    .unwrap();
    assert!(app.deferred_input.is_empty());
    assert!(app.drag.is_none());
}

#[test]
fn doubled_prefix_is_resolved_before_waiting_for_pending_mutation() {
    let mux = Mux::new("doubled-prefix-barrier-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.session.pending_mutations.store(1, Ordering::Release);
    let prefix = Event::Key(KeyEvent::new(KeyCode::Char('b'), KeyModifiers::CONTROL));

    app.handle(AppEvent::Input(prefix.clone())).unwrap();
    assert!(app.prefix_armed);
    assert!(app.deferred_input.is_empty());

    app.handle(AppEvent::Input(prefix)).unwrap();
    assert!(!app.prefix_armed, "the doubled prefix must not leave mutable parser state behind");
    assert_eq!(app.deferred_input.len(), 1);
}

#[test]
fn committed_mutation_with_stale_refresh_retains_deferred_input() {
    let mux = Mux::new("committed-stale-refresh-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.session.pending_mutations.store(1, Ordering::Release);
    app.deferred_input.push_back(queued_input(
        Event::Key(KeyEvent::new(KeyCode::Char('x'), KeyModifiers::NONE)),
        None,
        1,
    ));

    app.handle(settled(crate::app::SessionMutationOutcome::CommittedTreeStale {
        error: Some("refresh unavailable".to_string()),
        completion: None,
    }))
    .unwrap();

    assert_eq!(app.deferred_input.len(), 1);
    assert_eq!(
        app.status_message.as_deref(),
        Some(
            localization::catalog()
                .sidebar
                .layout_refresh_failed
                .replace("{error}", "refresh unavailable")
                .as_str(),
        )
    );
    assert!(!app.session.has_pending_mutations());
}

#[test]
fn oversized_paste_is_rejected_before_routing_or_text_insertion() {
    let mux = Mux::new("oversized-paste-ingress-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    let text = "x".repeat(
        crate::app::MAX_DEFERRED_INPUT_BYTES - crate::app::BRACKETED_PASTE_MARKER_BYTES + 1,
    );

    app.handle(AppEvent::Input(Event::Paste(text))).unwrap();

    assert!(app.deferred_input.is_empty());
    assert_eq!(app.status_message.as_deref(), Some("Paste exceeds the 4 MiB PTY buffer limit"));
}

#[test]
fn oversized_enhanced_text_is_rejected_before_routing_or_text_insertion() {
    let mux = Mux::new("oversized-enhanced-text-ingress-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    let text = "x".repeat(crate::app::MAX_DEFERRED_INPUT_BYTES + 1);

    app.handle(AppEvent::Input(Event::EnhancedKey(EnhancedKeyEvent {
        key_event: KeyEvent::new(KeyCode::Char('x'), KeyModifiers::NONE),
        shifted_key: None,
        base_layout_key: Some('x'),
        text,
    })))
    .unwrap();

    assert!(app.deferred_input.is_empty());
    assert_eq!(
        app.status_message.as_deref(),
        Some("Keyboard text exceeds the 4 MiB PTY buffer limit")
    );
}

#[test]
fn deferred_paste_budget_counts_bracket_markers() {
    let mux = Mux::new("deferred-paste-budget-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.session.pending_mutations.store(1, Ordering::Release);
    let half = "x".repeat(crate::app::MAX_DEFERRED_INPUT_BYTES / 2);

    app.handle(AppEvent::Input(Event::Paste(half.clone()))).unwrap();
    app.handle(AppEvent::Input(Event::Paste(half))).unwrap();

    assert_eq!(app.deferred_input.len(), 1);
    assert_eq!(
        app.status_message.as_deref(),
        Some(localization::catalog().terminal.deferred_input_queue_full)
    );
}

#[test]
fn deferred_keyboard_budget_counts_associated_text() {
    let mux = Mux::new("deferred-keyboard-budget-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.session.pending_mutations.store(1, Ordering::Release);
    let half = "x".repeat(crate::app::MAX_DEFERRED_INPUT_BYTES / 2);
    let input = |text| {
        Event::EnhancedKey(EnhancedKeyEvent {
            key_event: KeyEvent::new(KeyCode::Char('x'), KeyModifiers::NONE),
            shifted_key: None,
            base_layout_key: Some('x'),
            text,
        })
    };

    app.handle(AppEvent::Input(input(half.clone()))).unwrap();
    app.handle(AppEvent::Input(input(half))).unwrap();

    assert_eq!(app.deferred_input.len(), 1);
    assert_eq!(
        app.status_message.as_deref(),
        Some("Input queue byte limit reached while a session change is pending")
    );
}

#[test]
fn failed_pty_owned_press_does_not_fall_through_to_cmux_mouse_actions() {
    let mux = Mux::new(
        "failed-owned-press-test",
        SurfaceOptions {
            command: Some(vec!["/bin/sh".to_string(), "-c".to_string(), "sleep 30".to_string()]),
            ..Default::default()
        },
    );
    let surface = mux.new_workspace(None, Some((20, 8))).unwrap();
    surface.with_terminal(|terminal| terminal.vt_write(b"\x1b[?1000h\x1b[?1006h"));
    let mut app = test_app(Session::Local(mux.clone()));
    app.replace_tree(app.session.tree());
    let pane = app.tree.active_screen().unwrap().active_pane;
    let content = Rect { x: 2, y: 3, width: 20, height: 8 };
    app.pane_areas.push(PaneArea {
        pane,
        surface: surface.id,
        rect: Rect { x: 1, y: 2, width: 23, height: 10 },
        bar: Some(Rect { x: 1, y: 2, width: 23, height: 1 }),
        omnibar: None,
        content,
        track: None,
        viewport: None,
    });
    app.rendered_terminal_bounds.insert(surface.id, content);
    assert!(app.pty_input.shutdown(Duration::from_secs(1)));
    let event = |button| MouseEvent {
        kind: MouseEventKind::Down(button),
        column: content.x + 4,
        row: content.y + 2,
        modifiers: KeyModifiers::NONE,
    };

    app.handle_mouse(event(MouseButton::Right)).unwrap();
    assert!(app.menu.is_none());
    assert!(app.drag.is_none());
    app.handle_mouse(event(MouseButton::Left)).unwrap();
    assert!(app.selection.is_none());
    assert!(app.drag.is_none());
    assert_eq!(app.status_message.as_deref(), Some("PTY input queue is full; input was not sent"));

    mux.close_surface(surface.id).unwrap();
}

#[test]
fn notify_unread_indicators_render_and_clear() {
    let mux = Mux::new(
        "notify-render-test",
        SurfaceOptions {
            command: Some(vec!["/bin/sh".to_string(), "-c".to_string(), "sleep 30".to_string()]),
            ..Default::default()
        },
    );
    let surface = mux.new_workspace(Some("work".to_string()), Some((20, 8))).unwrap();
    let mut app = test_app(Session::Local(mux.clone()));
    app.sidebar_width = 12;
    app.sidebar_view = SidebarView::Workspaces;
    app.replace_tree(notify_tree(surface.id, true));
    app.pane_areas.push(PaneArea {
        pane: 2,
        surface: surface.id,
        rect: Rect { x: 12, y: 1, width: 26, height: 8 },
        bar: Some(Rect { x: 12, y: 1, width: 26, height: 1 }),
        omnibar: None,
        content: Rect { x: 13, y: 2, width: 23, height: 6 },
        track: None,
        viewport: None,
    });

    let mut terminal = Terminal::new(TestBackend::new(40, 12)).unwrap();
    terminal
        .draw(|frame| {
            crate::ui::draw(&mut app, frame);
        })
        .unwrap();
    let buffer = terminal.backend().buffer();
    assert_eq!(buffer[(12, 2)].symbol(), "│");
    assert_eq!(buffer[(12, 2)].style().fg, Some(app.config.theme.notification_warning));
    assert!(row_contains(buffer, 1, "•"), "tab bar should contain unread dot");
    assert_eq!(buffer[(0, 1)].symbol(), "▎", "sidebar should retain the active rail");
    assert_eq!(buffer[(1, 1)].symbol(), "•", "sidebar should contain unread dot");

    app.replace_tree(notify_tree(surface.id, false));
    let mut terminal = Terminal::new(TestBackend::new(40, 12)).unwrap();
    terminal
        .draw(|frame| {
            crate::ui::draw(&mut app, frame);
        })
        .unwrap();
    let buffer = terminal.backend().buffer();
    assert_eq!(buffer[(12, 2)].style().fg, Some(app.config.theme.border_active));
    assert!(!row_contains(buffer, 1, "•"), "tab bar dot should clear");
    assert_ne!(buffer[(1, 1)].symbol(), "•", "sidebar dot should clear");

    mux.close_surface(surface.id).unwrap();
}

#[test]
fn plugin_sidebar_registers_resize_drag_hit() {
    let mux = Mux::new(
        "plugin-sidebar-drag-test",
        SurfaceOptions {
            command: Some(vec!["/bin/sh".to_string(), "-c".to_string(), "sleep 30".to_string()]),
            ..Default::default()
        },
    );
    let surface = mux.new_workspace(Some("work".to_string()), Some((20, 8))).unwrap();
    let mut app = test_app(Session::Local(mux.clone()));
    app.sidebar_width = 12;
    app.config.sidebar.plugin = Some(cmux_tui_core::SidebarPluginOptions {
        command: vec!["/bin/sh".to_string(), "-c".to_string(), "sleep 30".to_string()],
        cwd: None,
    });
    app.replace_tree(notify_tree(surface.id, false));

    let mut terminal = Terminal::new(TestBackend::new(40, 12)).unwrap();
    terminal
        .draw(|frame| {
            crate::ui::draw(&mut app, frame);
        })
        .unwrap();

    // Regression: with a plugin sidebar the divider column must still be a
    // drag handle, exactly like the built-in sidebar.
    let divider_x = app.sidebar_width - 1;
    assert!(
        app.hits.iter().any(|(rect, hit)| matches!(
            hit,
            crate::app::Hit::RailResize(RailKind::Workspace)
        ) && rect.x == divider_x
            && rect.width == 1),
        "plugin sidebar must register the workspace rail resize hit on the divider column"
    );

    mux.close_surface(surface.id).unwrap();
}

#[test]
fn pane_cursor_and_active_border_yield_to_builtin_and_plugin_sidebars() {
    let mux = Mux::new("sidebar-cursor-focus-test", SurfaceOptions::default());
    let surface = mux.new_workspace(Some("work".to_string()), Some((20, 8))).unwrap();
    let mut app = test_app(Session::Local(mux.clone()));
    app.replace_tree(app.session.tree());
    let pane = app.tree.active_screen().unwrap().active_pane;
    app.pane_areas.push(PaneArea {
        pane,
        surface: surface.id,
        rect: Rect { x: 0, y: 0, width: 22, height: 10 },
        bar: Some(Rect { x: 0, y: 0, width: 22, height: 1 }),
        omnibar: None,
        content: Rect { x: 1, y: 1, width: 20, height: 8 },
        track: None,
        viewport: None,
    });

    for plugin in [false, true] {
        app.config.sidebar.plugin = plugin.then(|| cmux_tui_core::SidebarPluginOptions {
            command: vec!["/bin/sh".to_string()],
            cwd: None,
        });
        app.focus = FocusTarget::Pane;
        app.reset_frame_cursor_spec();
        let mut pane_cursors = crate::ui::pane::DrawCursors::default();
        let mut terminal = Terminal::new(TestBackend::new(30, 12)).unwrap();
        terminal.draw(|frame| pane_cursors = crate::ui::pane::draw_all(&mut app, frame)).unwrap();
        assert!(pane_cursors.terminal.is_some(), "active pane cursor missing for plugin={plugin}");
        assert!(matches!(app.desired_outer_cursor, OuterCursorSpec::Terminal { .. }));
        assert_eq!(
            terminal.backend().buffer()[(0, 1)].fg,
            app.config.theme.border_active,
            "active pane border missing for plugin={plugin}"
        );

        app.focus = FocusTarget::WorkspaceRail;
        app.reset_frame_cursor_spec();
        terminal.draw(|frame| pane_cursors = crate::ui::pane::draw_all(&mut app, frame)).unwrap();
        assert!(pane_cursors.terminal.is_none(), "sidebar leaked pane cursor for plugin={plugin}");
        assert_eq!(app.desired_outer_cursor, OuterCursorSpec::Reset);
        assert_eq!(
            terminal.backend().buffer()[(0, 1)].fg,
            app.config.theme.border_inactive,
            "sidebar focus left pane border active for plugin={plugin}"
        );
    }

    mux.close_surface(surface.id).unwrap();
}

#[test]
fn scoped_frame_cursor_reset_preserves_host_cursor_without_inner_authorship() {
    let surface_id = 7;
    let (session, surface) =
        crate::session::test_remote_session_with_unleased_view_surface(surface_id);
    let mut app = test_app(session);
    app.surface_only = Some(surface_id);
    app.desired_outer_cursor = OuterCursorSpec::Terminal {
        color: Rgb { r: 1, g: 2, b: 3 },
        shape: CursorShape::Bar,
        blinking: true,
    };

    app.reset_frame_cursor_spec();
    assert_eq!(app.desired_outer_cursor, OuterCursorSpec::Reset);

    surface.test_scan_cursor_provenance(b"\x1b[3 q");
    surface.with_terminal(|terminal| terminal.vt_write(b"\x1b[3 q"));
    app.reset_frame_cursor_spec();
    assert_eq!(app.desired_outer_cursor, OuterCursorSpec::Reset);
    surface.test_scan_cursor_provenance(b"\x1b[5 q");
    surface.with_terminal(|terminal| terminal.vt_write(b"\x1b[5 q"));
    app.use_terminal_cursor_spec(Rgb { r: 1, g: 2, b: 3 }, CursorShape::Bar, true);
    surface.test_scan_cursor_provenance(b"\x1b[0 q");
    surface.with_terminal(|terminal| terminal.vt_write(b"\x1b[0 q"));
    app.reset_frame_cursor_spec();
    assert_eq!(app.desired_outer_cursor, OuterCursorSpec::Reset);
    app.use_terminal_cursor_spec(Rgb { r: 1, g: 2, b: 3 }, CursorShape::Bar, true);
    app.reassert_scoped_host_terminal_state();
    assert_eq!(app.desired_outer_cursor, OuterCursorSpec::Reset);
}

#[test]
fn files_sidebar_renders_temp_directory_and_unread_header_badge() {
    let temp = test_temp_dir("draw-files");
    std::fs::write(temp.join("known-sidebar-file.txt"), "hello").unwrap();
    let (mux, surface) = test_mux("files-sidebar-draw-test", Some(&temp));
    let mut app = test_app(Session::Local(mux.clone()));
    app.sidebar_width = 24;
    app.sidebar_files = FileBrowser::new(temp.clone());
    app.tree = notify_tree(surface.id, true);

    let mut terminal = Terminal::new(TestBackend::new(50, 12)).unwrap();
    terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
    let text = buffer_text(terminal.backend().buffer());
    assert!(text.contains("known-sidebar-file"), "{text}");
    assert!(text.lines().next().is_some_and(|line| line.contains("• 1")), "{text}");

    mux.close_surface(surface.id).unwrap();
    std::fs::remove_dir_all(temp).unwrap();
}

#[test]
fn workspace_sidebar_shows_machine_usage_readout_only_when_available() {
    let (mux, surface) = test_mux("machine-usage-readout-test", None);
    let mut app = test_app(Session::Local(mux.clone()));
    app.sidebar_view = SidebarView::Workspaces;
    app.sidebar_width = 24;
    app.tree = notify_tree(surface.id, false);

    let mut terminal = Terminal::new(TestBackend::new(60, 12)).unwrap();
    terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
    let hidden = buffer_text(terminal.backend().buffer());
    assert!(!hidden.contains("/ 30d"), "{hidden}");

    let usage = cmux_tui_core::MachineUsage {
        vm_id: "vm-1".to_string(),
        period_days: 30,
        total_tokens: 184_220,
        api_equivalent_usd: 1.234,
        as_of: None,
    };
    let action =
        app.handle(AppEvent::Mux(MuxEvent::MachineUsageChanged(Some(usage.clone())))).unwrap();
    assert_eq!(action, RenderAction::Draw);
    assert_eq!(app.machine_usage.as_ref(), Some(&usage));
    let repeat = app.handle(AppEvent::Mux(MuxEvent::MachineUsageChanged(Some(usage)))).unwrap();
    assert_eq!(repeat, RenderAction::None, "an unchanged readout does not redraw");

    terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
    let shown = buffer_text(terminal.backend().buffer());
    let expected = localization::catalog().sidebar.machine_usage_readout(1.234, 30);
    assert_eq!(expected, "$1.23 / 30d");
    let first_row = shown.lines().next().unwrap();
    assert!(first_row.contains(&expected), "readout sits on the rail's top pad row: {shown}");
    assert!(
        !shown.lines().skip(1).any(|line| line.contains(&expected)),
        "readout stays out of the body rows: {shown}"
    );
    let readout_end = first_row.find(&expected).unwrap() + expected.len();
    assert!(
        readout_end < usize::from(app.sidebar_width),
        "readout stays inside the rail: {first_row}"
    );

    let cleared = app.handle(AppEvent::Mux(MuxEvent::MachineUsageChanged(None))).unwrap();
    assert_eq!(cleared, RenderAction::Draw);
    terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
    let hidden_again = buffer_text(terminal.backend().buffer());
    assert!(!hidden_again.contains("/ 30d"), "{hidden_again}");

    mux.close_surface(surface.id).unwrap();
}

#[test]
fn machine_usage_readout_is_skipped_when_the_rail_is_too_narrow() {
    let (mux, surface) = test_mux("machine-usage-narrow-test", None);
    let mut app = test_app(Session::Local(mux.clone()));
    app.sidebar_view = SidebarView::Workspaces;
    app.sidebar_width = 8;
    app.tree = notify_tree(surface.id, false);
    app.machine_usage = Some(cmux_tui_core::MachineUsage {
        vm_id: "vm-1".to_string(),
        period_days: 30,
        total_tokens: 0,
        api_equivalent_usd: 12345.0,
        as_of: None,
    });
    let mut terminal = Terminal::new(TestBackend::new(60, 12)).unwrap();
    terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
    let text = buffer_text(terminal.backend().buffer());
    assert!(!text.contains('$'), "a readout that does not fit is not drawn at all: {text}");
    mux.close_surface(surface.id).unwrap();
}

#[test]
fn files_filter_exposes_ratatui_cursor_and_accepts_mouse_cursor_placement() {
    let temp = test_temp_dir("files-filter-cursor");
    let (mux, surface) = test_mux("files-filter-cursor-test", Some(&temp));
    let mut app = test_app(Session::Local(mux.clone()));
    app.sidebar_width = 24;
    app.sidebar_files = FileBrowser::new(temp.clone());
    app.sidebar_view = SidebarView::Files;
    app.focus = FocusTarget::WorkspaceRail;
    app.tree = notify_tree(surface.id, false);
    app.sidebar_files.handle_key(&KeyEvent::new(KeyCode::Char('/'), KeyModifiers::NONE));
    assert!(app.sidebar_files.insert_filter_text("á界b"));

    let mut terminal = Terminal::new(TestBackend::new(50, 12)).unwrap();
    terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
    let input = app
        .hits
        .iter()
        .find_map(|(rect, hit)| (*hit == crate::app::Hit::SidebarFilterInput).then_some(*rect))
        .unwrap();
    terminal.backend_mut().assert_cursor_position((input.x + 4, input.y));

    app.handle_mouse(MouseEvent {
        kind: MouseEventKind::Down(MouseButton::Left),
        column: input.x + 1,
        row: input.y,
        modifiers: KeyModifiers::NONE,
    })
    .unwrap();
    app.handle_key(KeyEvent::new(KeyCode::Delete, KeyModifiers::NONE)).unwrap();
    assert_eq!(app.sidebar_files.query(), "áb");

    mux.close_surface(surface.id).unwrap();
    std::fs::remove_dir_all(temp).unwrap();
}

#[test]
fn focused_sidebar_tab_toggles_builtin_views_and_back() {
    let temp = test_temp_dir("toggle-view");
    std::fs::write(temp.join("toggle-marker.txt"), "hello").unwrap();
    let (mux, surface) = test_mux("sidebar-toggle-test", Some(&temp));
    let mut app = test_app(Session::Local(mux.clone()));
    app.sidebar_width = 24;
    app.sidebar_files = FileBrowser::new(temp.clone());
    app.tree = notify_tree(surface.id, false);
    app.focus = FocusTarget::WorkspaceRail;

    app.handle_key(KeyEvent::new(KeyCode::Tab, KeyModifiers::NONE)).unwrap();
    assert_eq!(app.sidebar_view, SidebarView::Workspaces);
    let mut terminal = Terminal::new(TestBackend::new(50, 12)).unwrap();
    terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
    assert!(buffer_text(terminal.backend().buffer()).contains("+ new workspace"));

    app.handle_key(KeyEvent::new(KeyCode::Tab, KeyModifiers::NONE)).unwrap();
    assert_eq!(app.sidebar_view, SidebarView::Files);
    let mut terminal = Terminal::new(TestBackend::new(50, 12)).unwrap();
    terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
    assert!(buffer_text(terminal.backend().buffer()).contains("toggle-marker"));

    mux.close_surface(surface.id).unwrap();
    std::fs::remove_dir_all(temp).unwrap();
}

#[test]
fn focus_sidebar_focuses_builtin_sidebar() {
    let (mux, surface) = test_mux("focus-builtin-sidebar-test", None);
    let mut app = test_app(Session::Local(mux.clone()));
    app.tree = notify_tree(surface.id, false);
    app.sync_layout((100, 16));
    app.sidebar_visible = false;
    app.sync_layout((100, 16));

    app.run_action(Action::FocusSidebar).unwrap();
    assert!(app.sidebar_visible);
    assert!(app.workspace_sidebar_focused());

    app.run_action(Action::FocusSidebar).unwrap();
    assert!(!app.workspace_sidebar_focused());
    mux.close_surface(surface.id).unwrap();
}

#[test]
fn focus_sidebar_uses_only_visible_rails() {
    let mux = Mux::new("focus-visible-rails-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    let mut machine_ui = provider_machine_ui();
    machine_ui.session_available = true;
    app.machine_ui = Some(machine_ui);
    app.hidden_sidebar_views
        .entry(app.config.sidebar.active_profile.clone())
        .or_default()
        .insert("workspaces".into());
    app.sync_layout((100, 16));
    assert_eq!(app.visible_rail_order(), vec![RailKind::Machine]);

    app.run_action(Action::FocusSidebar).unwrap();

    assert_eq!(app.focus, FocusTarget::MachineRail);
}

#[test]
fn sidebar_context_menu_focus_is_idempotent() {
    let (mux, surface) = test_mux("sidebar-menu-focus-test", None);
    let mut app = test_app(Session::Local(mux.clone()));
    app.tree = notify_tree(surface.id, false);
    app.sidebar_visible = true;
    app.focus = FocusTarget::WorkspaceRail;

    app.activate_menu(MenuAction::FocusSidebar).unwrap();

    assert!(app.workspace_sidebar_focused());
    mux.close_surface(surface.id).unwrap();
}

#[test]
fn builtin_sidebar_registers_resize_hit_in_both_views() {
    let temp = test_temp_dir("resize-hit");
    let (mux, surface) = test_mux("builtin-sidebar-resize-test", Some(&temp));
    let mut app = test_app(Session::Local(mux.clone()));
    app.sidebar_width = 18;
    app.sidebar_files = FileBrowser::new(temp.clone());
    app.tree = notify_tree(surface.id, false);

    for view in [SidebarView::Files, SidebarView::Workspaces] {
        app.sidebar_view = view;
        let mut terminal = Terminal::new(TestBackend::new(50, 12)).unwrap();
        terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
        assert!(
            app.hits.iter().any(|(rect, hit)| {
                matches!(hit, crate::app::Hit::RailResize(RailKind::Workspace))
                    && rect.x == app.sidebar_width - 1
                    && rect.width == 1
            }),
            "missing resize hit in {view:?} view"
        );
    }

    mux.close_surface(surface.id).unwrap();
    std::fs::remove_dir_all(temp).unwrap();
}

#[test]
fn provider_owned_machine_keyboard_actions_use_version_and_confirmation() {
    let mux = Mux::new("managed-machine-keyboard-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.machine_ui = Some(provider_machine_ui_with_machine_lifecycle());
    app.focus = FocusTarget::MachineRail;
    app.sync_layout((100, 14));

    app.handle_key(KeyEvent::new(KeyCode::Char('r'), KeyModifiers::NONE)).unwrap();
    assert!(matches!(
        app.prompt.as_ref().map(|prompt| prompt.target),
        Some(PromptTarget::ManagedMachine(MachineKey(41)))
    ));
    app.prompt.as_mut().unwrap().input.clear();
    app.prompt.as_mut().unwrap().input.insert_str("renamed machine");
    app.commit_prompt();
    assert_eq!(
        app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()),
        Some(&MachineRequest::RenameManagedMachine {
            machine: MachineKey(41),
            expected_version: 7,
            name: "renamed machine".into(),
        })
    );

    app.machine_ui.as_mut().unwrap().request = None;
    app.handle_key(KeyEvent::new(KeyCode::Char('d'), KeyModifiers::NONE)).unwrap();
    assert!(matches!(
        app.prompt.as_ref().map(|prompt| prompt.target),
        Some(PromptTarget::ConfirmDeleteManagedMachine(MachineKey(41)))
    ));
    app.prompt.as_mut().unwrap().input.insert_str("confirm");
    app.commit_prompt();
    assert!(app.machine_ui.as_ref().unwrap().request.is_none());
    assert!(app.prompt.is_some());
    app.prompt.as_mut().unwrap().input.clear();
    app.prompt.as_mut().unwrap().input.insert_str("CONFIRM");
    app.commit_prompt();
    assert_eq!(
        app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()),
        Some(&MachineRequest::DeleteManagedMachine {
            machine: MachineKey(41),
            expected_version: 7,
        })
    );
}

#[test]
fn active_machine_enter_returns_focus_to_pane() {
    let mux = Mux::new("active-machine-enter-focus-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    let mut ui = MachineUiState::new(MachineSnapshot {
        machines: vec![MachineDescriptor {
            key: MachineKey(41),
            id: "machine-41".into(),
            name: "active".into(),
            subtitle: "local".into(),
            status: MachineStatus::Running,
        }],
        active: Some(MachineKey(41)),
        capabilities: MachineCapabilities::default(),
    });
    ui.session_available = true;
    app.machine_ui = Some(ui);
    app.machine_selection_intent = Some(MachineKey(41));
    app.machine_presented = Some(MachineKey(41));
    app.focus = FocusTarget::MachineRail;

    app.handle_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE)).unwrap();

    assert_eq!(app.focus, FocusTarget::Pane);
    assert!(app.machine_ui.as_ref().unwrap().request.is_none());
}

#[test]
fn machine_transition_shows_progress_then_status_aware_default() {
    let mux = Mux::new("machine-transition-progress-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    let mut ui = MachineUiState::new(MachineSnapshot {
        machines: vec![MachineDescriptor {
            key: MachineKey(7),
            id: "vm-7".into(),
            name: "maple".into(),
            subtitle: "freestyle · paused".into(),
            status: MachineStatus::Sleeping,
        }],
        active: None,
        capabilities: MachineCapabilities::default(),
    });
    ui.set_connection_phase(MachineKey(7), MachineConnectionPhase::Connecting);
    app.machine_ui = Some(ui);
    app.machine_selection_intent = Some(MachineKey(7));

    // Status-aware default: a sleeping machine renders as waking, which
    // the interstitial derives from status when no progress arrived.
    let view = app.machine_transition().unwrap();
    assert_eq!(view.progress, None);
    assert_eq!(view.status, MachineStatus::Sleeping);
    assert_eq!(view.phase, MachineConnectionPhase::Connecting);

    // A provider connection_progress event renders live while the switch
    // is still in flight.
    let action = app.apply_connection_progress(
        "vm-7".into(),
        Arc::new(Mutex::new(Some("resuming the machine".into()))),
    );
    assert_eq!(action, RenderAction::Draw);
    let view = app.machine_transition().unwrap();
    assert_eq!(view.progress, Some("resuming the machine"));

    // A failed switch drops the stale message under "unavailable".
    app.fail_machine_action(Some(&MachineRequest::Switch(MachineKey(7))));
    let view = app.machine_transition().unwrap();
    assert_eq!(view.phase, MachineConnectionPhase::Failed);
    assert_eq!(view.progress, None);
}

#[test]
fn paused_machine_is_not_auto_resumed_and_wakes_on_input() {
    let mux = Mux::new("machine-sleep-wake-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    let mut ui = MachineUiState::new(MachineSnapshot {
        machines: vec![MachineDescriptor {
            key: MachineKey(9),
            id: "vm-9".into(),
            name: "maple".into(),
            subtitle: "freestyle · paused".into(),
            status: MachineStatus::Sleeping,
        }],
        active: Some(MachineKey(9)),
        capabilities: MachineCapabilities::default(),
    });
    ui.session_available = true;
    app.machine_ui = Some(ui);
    app.machine_selection_intent = Some(MachineKey(9));
    app.machine_presented = Some(MachineKey(9));

    // Stream death for a machine that is asleep: no auto-resume switch;
    // it presents as sleeping instead, so pause stays paused.
    assert!(app.request_current_machine_session());
    let ui = app.machine_ui.as_ref().unwrap();
    assert!(ui.request.is_none(), "a paused machine must not auto-resume");
    assert!(!ui.session_available);
    let view = app.machine_transition().unwrap();
    assert_eq!(view.phase, MachineConnectionPhase::Disconnected);
    assert_eq!(view.status, MachineStatus::Sleeping);

    // The first keystroke wakes it through the normal switch path with
    // the connecting interstitial.
    app.forward_key(KeyEvent::new(KeyCode::Char('a'), KeyModifiers::NONE).into());
    let ui = app.machine_ui.as_ref().unwrap();
    assert_eq!(ui.request, Some(MachineRequest::Switch(MachineKey(9))));
    assert_eq!(ui.connection_phase(MachineKey(9)), MachineConnectionPhase::Connecting);
    assert!(app.status_message.is_none());
}

#[test]
fn reselecting_a_sleeping_presented_machine_queues_a_wake_switch() {
    let mux = Mux::new("machine-sleep-reselect-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    let mut ui = MachineUiState::new(MachineSnapshot {
        machines: vec![MachineDescriptor {
            key: MachineKey(9),
            id: "vm-9".into(),
            name: "maple".into(),
            subtitle: "freestyle · paused".into(),
            status: MachineStatus::Sleeping,
        }],
        active: Some(MachineKey(9)),
        capabilities: MachineCapabilities::default(),
    });
    ui.session_available = true;
    app.machine_ui = Some(ui);
    app.machine_selection_intent = Some(MachineKey(9));
    app.machine_presented = Some(MachineKey(9));
    assert!(app.request_current_machine_session());

    // Rail click on the same, now-asleep machine: the switch is queued
    // (session_available is false) and the interstitial must not claim
    // Ready while the wake is in flight.
    app.activate_machine(MachineKey(9));
    let ui = app.machine_ui.as_ref().unwrap();
    assert_eq!(ui.request, Some(MachineRequest::Switch(MachineKey(9))));
    assert_eq!(ui.connection_phase(MachineKey(9)), MachineConnectionPhase::Connecting);
}
