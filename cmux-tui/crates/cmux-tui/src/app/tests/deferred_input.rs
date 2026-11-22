//! Tests: session presentation reset, deferred pointer input and draws,
//! pairing dialogs, and visible input state.

use super::*;

#[test]
fn session_presentation_reset_clears_rendered_terminal_caches() {
    let mux = Mux::new("reset-rendered-terminal-state-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.rendered_terminal_sizes.insert(77, (12, 5));
    app.rendered_terminal_bounds.insert(77, Rect { x: 2, y: 3, width: 12, height: 5 });
    app.geometry_authority_surface = Some(77);

    app.reset_session_presentation(TreeView::default());

    assert!(app.rendered_terminal_sizes.is_empty());
    assert!(app.rendered_terminal_bounds.is_empty());
    assert_eq!(app.geometry_authority_surface, None);
}

#[test]
fn session_presentation_reset_discards_the_previous_pointer_frame() {
    let mux = Mux::new("reset-rendered-pointer-frame-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.rendered_pointer_frame.pairing = Some((
        41,
        Rect { x: 1, y: 1, width: 20, height: 10 },
        Rect { x: 3, y: 8, width: 6, height: 1 },
        Rect { x: 12, y: 8, width: 6, height: 1 },
    ));

    app.reset_session_presentation(TreeView::default());

    assert!(app.rendered_pointer_frame.pairing.is_none());
}

#[test]
fn session_presentation_reset_preserves_graphics_until_the_clear_is_submitted() {
    let mux = Mux::new("reset-rendered-graphics-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    let previous = GraphicIdentity {
        session_generation: app.session_generation,
        surface: 77,
        rect: Rect { x: 2, y: 3, width: 12, height: 5 },
        seq: 9,
        pointer_frame_seq: Some(9),
    };
    app.last_graphics_snapshot.push(previous);
    app.pending_graphics_submission = Some(4);

    app.reset_session_presentation(TreeView::default());

    assert_eq!(
        app.pending_graphics_submission,
        Some(4),
        "an in-flight old-session graphic must remain tracked until replacement"
    );
    assert_eq!(
        app.last_graphics_snapshot,
        vec![previous],
        "the next empty graphics frame must differ and clear the previous session"
    );
}

#[test]
fn pointer_motion_continues_during_non_routing_background_mutation() {
    let mux = Mux::new("background-pointer-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.session.pending_mutations.store(1, Ordering::Release);

    app.handle(AppEvent::Input(Event::Mouse(MouseEvent {
        kind: MouseEventKind::Moved,
        column: 9,
        row: 3,
        modifiers: KeyModifiers::NONE,
    })))
    .unwrap();

    assert!(app.deferred_input.is_empty());
    assert_eq!(app.hover, Some((9, 3)));
    assert_eq!(app.status_message, None);
}

#[test]
fn pointer_motion_waits_for_pending_cell_pixel_geometry() {
    let mux = Mux::new("cell-pixel-pointer-barrier-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    let (started_tx, started_rx) = std::sync::mpsc::channel();
    let (release_tx, release_rx) = std::sync::mpsc::channel();
    app.session.operations.enqueue_session_mutation(
        "block before cell pixel geometry",
        false,
        move || {
            started_tx.send(()).unwrap();
            release_rx.recv().unwrap();
            Ok(())
        },
    );
    started_rx.recv_timeout(Duration::from_secs(1)).unwrap();

    // refresh_cell_pixels publishes this scale before its ordered session
    // mutation updates browser geometry.
    app.cell_pixels = (12, 24);
    app.session.set_cell_pixel_size(12, 24);
    let motion = MouseEvent {
        kind: MouseEventKind::Moved,
        column: 9,
        row: 3,
        modifiers: KeyModifiers::NONE,
    };
    app.handle(AppEvent::Input(Event::Mouse(motion))).unwrap();
    let hover = app.hover;
    let pending_motion = app.pending_pointer_motion.map(|pending| pending.event);
    let pointer_pending = app.session.has_pending_pointer_mutations();
    release_tx.send(()).unwrap();

    assert_eq!(hover, None, "motion must not use the new scale before geometry settles");
    assert_eq!(pending_motion, Some(motion));
    assert!(pointer_pending, "cell pixel geometry must participate in pointer routing");
}

#[test]
fn discrete_pointer_waits_behind_earlier_deferred_input() {
    let mux = Mux::new("ordered-discrete-pointer-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.session.pending_mutations.store(1, Ordering::Release);

    app.handle(AppEvent::Input(Event::Paste("first".to_string()))).unwrap();
    app.handle(AppEvent::Input(Event::Mouse(MouseEvent {
        kind: MouseEventKind::Down(MouseButton::Left),
        column: 14,
        row: 6,
        modifiers: KeyModifiers::NONE,
    })))
    .unwrap();

    assert_eq!(app.deferred_input.len(), 2);
    assert!(matches!(
        app.deferred_input.front().map(|input| &input.event),
        Some(TerminalInput::Paste(text)) if text == "first"
    ));
    assert!(matches!(
        app.deferred_input.back().map(|input| &input.event),
        Some(TerminalInput::Mouse(MouseEvent {
            kind: MouseEventKind::Down(MouseButton::Left),
            ..
        }))
    ));
}

#[test]
fn pointer_motion_waits_behind_earlier_deferred_pointer_input() {
    let mux = Mux::new("ordered-pointer-motion-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.session.pending_mutations.store(1, Ordering::Release);
    assert!(!app.session.has_pending_pointer_mutations());

    app.handle(AppEvent::Input(Event::Mouse(MouseEvent {
        kind: MouseEventKind::Down(MouseButton::Left),
        column: 14,
        row: 6,
        modifiers: KeyModifiers::NONE,
    })))
    .unwrap();
    let motion = MouseEvent {
        kind: MouseEventKind::Moved,
        column: 18,
        row: 7,
        modifiers: KeyModifiers::NONE,
    };
    app.handle(AppEvent::Input(Event::Mouse(motion))).unwrap();

    let deferred_sequence = app.deferred_input.front().map(|input| input.sequence).unwrap();
    let pending_motion = app.pending_pointer_motion.expect(
        "motion must stay behind an earlier deferred press during an ordered-only mutation",
    );
    assert_eq!(app.hover, None);
    assert_eq!(pending_motion.event, motion);
    assert!(pending_motion.sequence > deferred_sequence);
}

#[test]
fn event_loop_drains_replay_draw_before_receiving_more_input() {
    let mux = Mux::new("event-loop-draw-replay-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    let prefix = app.config.keys.prefix;
    app.defer_input(TerminalInput::FrontendAction {
        action: Action::ToggleSidebar,
        prefix: KeyEvent::new(prefix.code, prefix.mods),
    });
    app.retain_pointer_motion(MouseEvent {
        kind: MouseEventKind::Moved,
        column: 14,
        row: 6,
        modifiers: KeyModifiers::NONE,
    });
    app.pointer_route_phase = PointerRoutePhase::DrawPending;
    let (events, receiver) = crossbeam_channel::unbounded();
    events.send(AppEvent::Mux(MuxEvent::SurfaceOutput(999))).unwrap();
    drop(events);
    let mut terminal = Terminal::new(TestBackend::new(100, 12)).unwrap();

    app.event_loop(&mut terminal, receiver).unwrap();

    assert!(!app.sidebar_visible);
    assert_eq!(app.hover, Some((14, 6)));
    assert!(app.pending_pointer_motion.is_none());
    assert_eq!(app.pointer_route_phase, PointerRoutePhase::Fresh);
}

#[test]
fn event_loop_replays_retained_batches_before_new_channel_input() {
    let mux = Mux::new("event-loop-replay-order-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.prompt = Some(Prompt::new("Rename", String::new(), PromptTarget::Surface(77)));
    for _ in 0..257 {
        app.defer_input(Event::Key(KeyEvent::new(KeyCode::Char('a'), KeyModifiers::NONE)));
    }
    let (events, receiver) = crossbeam_channel::unbounded();
    events
        .send(AppEvent::Input(Event::Key(KeyEvent::new(KeyCode::Char('z'), KeyModifiers::NONE))))
        .unwrap();
    drop(events);
    let mut terminal = Terminal::new(TestBackend::new(100, 12)).unwrap();

    app.event_loop(&mut terminal, receiver).unwrap();

    assert_eq!(
        app.prompt.as_ref().unwrap().input.as_str(),
        format!("{}z", "a".repeat(257)),
        "older retained input must finish replaying before newer channel input"
    );
}

#[test]
fn event_loop_renders_paint_before_following_pointer_input() {
    let mux = Mux::new("event-loop-paint-pointer-test", SurfaceOptions::default());
    mux.new_workspace(None, Some((80, 24))).unwrap();
    let (mut app, mutation_events) = test_app_with_events(Session::Local(mux));
    app.sidebar_visible = false;
    // Keep this admission test on the terminal paint path. Graphics
    // completion is asynchronous and can otherwise race the pointer
    // event when the full suite starts from a cold cache. SurfaceOutput
    // below is intentionally a paint-only stimulus for this contract.
    app.graphics_supported = false;
    app.sync_layout((100, 12));
    while app.session.has_pending_mutations() {
        app.handle(mutation_events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();
    }
    let (events, receiver) = crossbeam_channel::unbounded();
    events.send(AppEvent::Mux(MuxEvent::SurfaceOutput(999))).unwrap();
    events
        .send(AppEvent::Input(Event::Mouse(MouseEvent {
            kind: MouseEventKind::Down(MouseButton::Right),
            column: 14,
            row: 6,
            modifiers: KeyModifiers::SHIFT,
        })))
        .unwrap();
    drop(events);
    let mut terminal = Terminal::new(TestBackend::new(100, 12)).unwrap();

    app.event_loop(&mut terminal, receiver).unwrap();

    assert!(
        app.menu.is_some(),
        "the pointer input after a routine paint must open its context menu: status={:?}, \
         deferred={}, panes={:?}",
        app.status_message,
        app.deferred_input.len(),
        app.pane_areas
    );
}

#[test]
fn pointer_captured_before_pairing_dialog_render_cannot_approve_it() {
    let mux = Mux::new("pairing-render-pointer-route-test", SurfaceOptions::default());
    let (challenge, decision) = mux.begin_pairing("127.0.0.1".parse().unwrap()).unwrap();
    let mut app = test_app(Session::Local(mux));
    let width = 48;
    let dialog_x = (100 - width) / 2;
    let dialog_y = (20 - 10) / 2;
    let approve_width = localization::catalog().pairing.approve.chars().count() as u16;
    let approve_x = dialog_x + width - 2 - approve_width;
    let (events, receiver) = crossbeam_channel::unbounded();
    events.send(AppEvent::Mux(MuxEvent::PairingRequested(challenge.clone()))).unwrap();
    events
        .send(AppEvent::Input(Event::Mouse(MouseEvent {
            kind: MouseEventKind::Down(MouseButton::Left),
            column: approve_x,
            row: dialog_y + 8,
            modifiers: KeyModifiers::NONE,
        })))
        .unwrap();
    drop(events);
    let mut terminal = Terminal::new(TestBackend::new(100, 20)).unwrap();

    app.event_loop(&mut terminal, receiver).unwrap();

    assert_eq!(
        app.pairing_dialog.as_ref().map(|dialog| dialog.challenge.id),
        Some(challenge.id),
        "a click from the previous frame must not activate a newly rendered trusted dialog"
    );
    assert!(decision.try_recv().is_err(), "the unseen pairing request must remain unresolved");
    assert!(
        app.status_message.as_deref().is_none_or(|message| !message.contains("discarded")),
        "stale pointer samples should be dropped without noisy user-facing warnings"
    );
}

#[test]
fn focus_loss_purges_pointer_press_waiting_for_a_paint() {
    let mux = Mux::new(
        "focus-loss-deferred-pointer-test",
        SurfaceOptions {
            command: Some(vec!["/bin/sh".to_string(), "-c".to_string(), "sleep 30".to_string()]),
            ..Default::default()
        },
    );
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    surface.with_terminal(|terminal| terminal.vt_write(b"\x1b[?1002h\x1b[?1006h"));
    let (mut app, mutation_events) = test_app_with_events(Session::Local(mux.clone()));
    app.sidebar_visible = false;
    app.sync_layout((100, 12));
    while app.session.has_pending_mutations() {
        app.handle(mutation_events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();
    }
    let content = app.pane_areas[0].content;
    let (events, receiver) = crossbeam_channel::unbounded();
    events.send(AppEvent::Mux(MuxEvent::SurfaceOutput(surface.id))).unwrap();
    events
        .send(AppEvent::Input(Event::Mouse(MouseEvent {
            kind: MouseEventKind::Down(MouseButton::Left),
            column: content.x + 4,
            row: content.y + 2,
            modifiers: KeyModifiers::NONE,
        })))
        .unwrap();
    events.send(AppEvent::Input(Event::FocusLost)).unwrap();
    drop(events);
    let mut terminal = Terminal::new(TestBackend::new(100, 12)).unwrap();

    app.event_loop(&mut terminal, receiver).unwrap();

    assert!(
        app.drag.is_none(),
        "focus loss must not allow an earlier retained PTY press to start a new drag"
    );
    assert!(app.deferred_input.is_empty());
    assert!(app.pending_pointer_motion.is_none());
    mux.close_surface(surface.id).unwrap();
}

#[test]
fn routine_paint_and_draw_do_not_defer_key_or_paste_input() {
    let mux = Mux::new("paint-key-latency-test", SurfaceOptions::default());
    let mut paint_app = test_app(Session::Local(mux));
    paint_app.prompt = Some(Prompt::new("Rename", String::new(), PromptTarget::Surface(77)));

    assert_eq!(
        paint_app.handle(AppEvent::Mux(MuxEvent::SurfaceOutput(77))).unwrap(),
        RenderAction::Paint
    );
    paint_app
        .handle(AppEvent::Input(Event::Key(KeyEvent::new(KeyCode::Char('k'), KeyModifiers::NONE))))
        .unwrap();

    assert_eq!(paint_app.prompt.as_ref().unwrap().input.as_str(), "k");
    assert!(
        paint_app.deferred_input.is_empty(),
        "routine Paint must not put key input on the replay queue"
    );

    let mux = Mux::new("draw-paste-latency-test", SurfaceOptions::default());
    let mut draw_app = test_app(Session::Local(mux));
    draw_app.prompt = Some(Prompt::new("Rename", String::new(), PromptTarget::Surface(77)));

    assert_eq!(
        draw_app.handle(AppEvent::Mux(MuxEvent::Status("notice".to_string()))).unwrap(),
        RenderAction::Draw
    );
    draw_app.handle(AppEvent::Input(Event::Paste("paste".to_string()))).unwrap();

    assert_eq!(draw_app.prompt.as_ref().unwrap().input.as_str(), "paste");
    assert!(
        draw_app.deferred_input.is_empty(),
        "routine Draw must not put paste input on the replay queue"
    );
}

#[test]
fn deferred_wheel_cannot_retarget_a_new_blank_machine_rail() {
    let mux = Mux::new("blank-rail-pointer-route-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.sidebar_visible = false;
    app.sync_layout((100, 10));
    app.commit_rendered_pointer_frame();
    app.pointer_route_phase = PointerRoutePhase::Fresh;

    app.machine_ui = Some(MachineUiState::new(MachineSnapshot {
        machines: vec![MachineDescriptor {
            key: MachineKey(1),
            id: "machine-1".to_string(),
            name: "machine-1".to_string(),
            subtitle: "cloud".to_string(),
            status: MachineStatus::Running,
        }],
        active: Some(MachineKey(1)),
        capabilities: MachineCapabilities::default(),
    }));
    app.sidebar_visible = true;
    app.sync_layout((100, 10));
    let rail = app.sidebar_layout.machine.expect("machine rail should be pending");
    app.pointer_route_phase = PointerRoutePhase::DrawPending;
    app.handle(AppEvent::Input(Event::Mouse(MouseEvent {
        kind: MouseEventKind::ScrollDown,
        column: rail.x + 1,
        row: rail.y + rail.height.saturating_sub(2),
        modifiers: KeyModifiers::NONE,
    })))
    .unwrap();

    assert_eq!(app.deferred_input.len(), 1);
    app.commit_rendered_pointer_frame();
    app.pointer_route_phase = PointerRoutePhase::Fresh;
    app.replay_deferred_input().unwrap();

    assert_eq!(
        app.machine_rail_scroll, 0,
        "a wheel event captured outside the old frame must not scroll a newly drawn rail"
    );
    assert_eq!(app.machine_footer_scroll, 0);
}

#[test]
fn deferred_wheel_cannot_retarget_a_new_blank_workspace_rail() {
    let mux = Mux::new("blank-workspace-rail-pointer-route-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.sidebar_visible = false;
    app.sync_layout((100, 10));
    app.commit_rendered_pointer_frame();
    app.pointer_route_phase = PointerRoutePhase::Fresh;

    app.sidebar_view = SidebarView::Workspaces;
    app.sidebar_visible = true;
    app.sync_layout((100, 10));
    let rail = app.sidebar_layout.workspace.expect("workspace rail should be pending");
    app.pointer_route_phase = PointerRoutePhase::DrawPending;
    app.handle(AppEvent::Input(Event::Mouse(MouseEvent {
        kind: MouseEventKind::ScrollDown,
        column: rail.x + 1,
        row: rail.y + rail.height.saturating_sub(2),
        modifiers: KeyModifiers::NONE,
    })))
    .unwrap();

    assert_eq!(app.deferred_input.len(), 1);
    app.commit_rendered_pointer_frame();
    app.pointer_route_phase = PointerRoutePhase::Fresh;
    app.replay_deferred_input().unwrap();

    assert_eq!(
        app.workspace_rail_scroll, 0,
        "a wheel event captured outside the old frame must not scroll a newly drawn rail"
    );
    assert_eq!(app.workspace_footer_scroll, 0);
}

#[test]
fn timeout_draw_marks_pointer_route_stale_before_channel_drain() {
    let mux = Mux::new("timeout-pointer-route-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.prompt = Some(Prompt::new("Rename", String::new(), PromptTarget::Surface(77)));
    app.shake_frames = 2;
    let (timeout_started_tx, timeout_started_rx) = std::sync::mpsc::channel();
    let (pointer_queued_tx, pointer_queued_rx) = std::sync::mpsc::channel();
    app.timeout_drain_hook = Some(Box::new(move |_| {
        timeout_started_tx.send(()).unwrap();
        pointer_queued_rx.recv().unwrap();
    }));
    let (events, receiver) = crossbeam_channel::unbounded();
    let sender = std::thread::spawn(move || {
        timeout_started_rx.recv().unwrap();
        events
            .send(AppEvent::Input(Event::Mouse(MouseEvent {
                kind: MouseEventKind::ScrollDown,
                column: 1,
                row: 1,
                modifiers: KeyModifiers::NONE,
            })))
            .unwrap();
        pointer_queued_tx.send(()).unwrap();
    });
    let mut terminal = Terminal::new(TestBackend::new(100, 20)).unwrap();

    app.event_loop(&mut terminal, receiver).unwrap();
    sender.join().unwrap();

    assert_eq!(
        app.deferred_input_sequence, 1,
        "pointer input drained after a timeout-triggered draw must cross the rendered-frame barrier"
    );
}

#[test]
fn event_loop_expires_toast_on_idle_timeout() {
    let mux = Mux::new("toast-timeout-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.toast = Some(Toast {
        text: "expired".to_string(),
        deadline: Instant::now() - Duration::from_millis(1),
    });
    let timeout_seen = Arc::new(AtomicBool::new(false));
    let timeout_seen_in_hook = timeout_seen.clone();
    let (events, receiver) = crossbeam_channel::unbounded();
    app.timeout_drain_hook = Some(Box::new(move |app| {
        timeout_seen_in_hook.store(true, Ordering::Relaxed);
        app.toast = Some(Toast {
            text: "reintroduced".to_string(),
            deadline: Instant::now() - Duration::from_millis(1),
        });
        drop(events);
    }));
    let mut terminal = Terminal::new(TestBackend::new(100, 20)).unwrap();

    app.event_loop(&mut terminal, receiver).unwrap();

    assert!(timeout_seen.load(Ordering::Relaxed));
    assert_eq!(app.toast.as_ref().map(|toast| toast.text.as_str()), Some("reintroduced"));
}

#[test]
fn focus_loss_cancels_non_pty_pointer_interaction() {
    let mux = Mux::new("focus-loss-selection-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.drag = Some(Drag::Select {
        content: Rect { x: 2, y: 3, width: 20, height: 8 },
        source_x: 0,
        auto_scroll: Some(1),
        col: 4,
    });
    app.active_pointer_buttons.insert(MouseButton::Left);

    app.handle(AppEvent::Input(Event::FocusLost)).unwrap();

    assert!(app.drag.is_none(), "focus loss must stop selection and its auto-scroll tick");
    assert!(app.active_pointer_buttons.is_empty());
}

#[test]
fn visible_state_direct_keyboard_requests_draw_after_selection_clear() {
    let (mux, surface) = test_mux("visible-state-key-selection-test", None);
    surface.with_terminal(|terminal| {
        for line in 0..32 {
            terminal.vt_write(format!("history-{line:02}\r\n").as_bytes());
        }
        terminal.vt_write(b"bottom");
    });
    let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
    app.sidebar_visible = false;
    app.sync_layout((100, 12));
    while app.session.has_pending_mutations() {
        app.handle(events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();
    }
    app.status_message = Some("old failure".to_string());
    let mut terminal = Terminal::new(TestBackend::new(100, 12)).unwrap();
    app.render_action(&mut terminal, RenderAction::Paint).unwrap();
    let visible = app.session.surface(surface.id).unwrap();
    assert_eq!(visible.scroll_delta(-5), Some(true));
    let offset = app.surface_scroll_offset(surface.id);
    assert!(offset > 0);
    app.replace_selection(Some(Selection {
        surface: surface.id,
        anchor: (0, offset),
        head: (4, offset),
    }));
    app.render_action(&mut terminal, RenderAction::Paint).unwrap();
    assert!(app.selection.is_some(), "the setup frame must retain the visible selection");
    assert_eq!(
        app.rendered_status_message.as_ref().map(|message| message.text.as_str()),
        Some("old failure"),
        "the setup frame must retain the semantic status message"
    );

    let action = app
        .handle(AppEvent::Input(Event::Key(KeyEvent::new(KeyCode::Char('x'), KeyModifiers::NONE))))
        .unwrap();

    assert_eq!(action, RenderAction::Draw, "clearing a painted selection needs a new frame");
    assert!(app.selection.is_none());
    assert!(app.status_message.is_none());
    let scrollbar = app
        .session
        .surface(surface.id)
        .and_then(|surface| surface.scrollbar())
        .expect("the visible PTY must expose viewport geometry");
    assert_eq!(
        scrollbar.offset,
        scrollbar.total.saturating_sub(scrollbar.len),
        "ordinary PTY input must return the viewport to the live bottom (offset is absolute)"
    );
    app.render_action(&mut terminal, action).unwrap();
    assert!(
        app.rendered_status_message.is_none(),
        "the input frame must remove the semantic status message"
    );

    let unchanged = app
        .handle(AppEvent::Input(Event::Key(KeyEvent::new(KeyCode::Char('y'), KeyModifiers::NONE))))
        .unwrap();
    assert_eq!(unchanged, RenderAction::None, "a key with no visible mutation needs no draw");
    assert!(app.pty_input.shutdown(Duration::from_secs(1)));
    mux.close_surface(surface.id).unwrap();
}

#[test]
fn visible_state_paste_requests_draw_after_status_clear() {
    let (mux, surface) = test_mux("visible-state-paste-status-test", None);
    let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
    app.sidebar_visible = false;
    app.sync_layout((100, 12));
    while app.session.has_pending_mutations() {
        app.handle(events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();
    }
    app.status_message = Some("old failure".to_string());
    let mut terminal = Terminal::new(TestBackend::new(100, 12)).unwrap();
    app.render_action(&mut terminal, RenderAction::Paint).unwrap();
    assert_eq!(
        app.rendered_status_message.as_ref().map(|message| message.text.as_str()),
        Some("old failure"),
        "the setup frame must retain the semantic status message"
    );

    let action = app.handle(AppEvent::Input(Event::Paste("text".to_string()))).unwrap();

    assert_eq!(action, RenderAction::Draw, "removing a painted status needs a new frame");
    assert!(app.status_message.is_none());
    app.render_action(&mut terminal, action).unwrap();
    assert!(
        app.rendered_status_message.is_none(),
        "the paste frame must remove the semantic status message"
    );

    let unchanged = app.handle(AppEvent::Input(Event::Paste("more".to_string()))).unwrap();
    assert_eq!(unchanged, RenderAction::None, "paste with no visible mutation needs no draw");
    assert!(app.pty_input.shutdown(Duration::from_secs(1)));
    mux.close_surface(surface.id).unwrap();
}

#[test]
fn visible_state_keyboard_requests_draw_after_status_clear_for_browser_surface() {
    let mux = Mux::new("visible-state-browser-status-test", SurfaceOptions::default());
    let surface = mux.new_browser_tab("about:blank".to_string(), None, Some((40, 8))).unwrap();
    let mut app = test_app(Session::Local(mux.clone()));
    app.sidebar_visible = false;
    app.replace_tree(app.session.tree());

    let mut terminal = Terminal::new(TestBackend::new(40, 12)).unwrap();
    app.status_message = Some("old failure".to_string());
    app.render_action(&mut terminal, RenderAction::Draw).unwrap();
    assert!(
        app.rendered_status_message.as_ref().is_some_and(|message| !message.text.is_empty()),
        "the setup frame must retain a visible status message"
    );

    let action = app.handle_key(KeyEvent::new(KeyCode::Char('x'), KeyModifiers::NONE)).unwrap();

    assert_eq!(
        action,
        RenderAction::Draw,
        "a browser key that clears a painted status still needs a new frame"
    );
    assert!(app.status_message.is_none());
    app.render_action(&mut terminal, action).unwrap();
    assert!(
        app.rendered_status_message.is_none(),
        "the input frame must remove the semantic status message"
    );

    mux.close_surface(surface.id).unwrap();
}

#[test]
fn visible_state_keyboard_requests_draw_after_selection_clear_on_other_surface() {
    let mux = Mux::new("visible-state-split-selection-test", SurfaceOptions::default());
    let first = mux.new_workspace(None, Some((80, 12))).unwrap();
    let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let second = mux.split(first_pane, SplitDir::Right, Some((40, 12))).unwrap();
    let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
    app.sidebar_visible = false;
    app.replace_tree(app.session.tree());
    app.sync_layout((80, 12));
    while app.session.has_pending_mutations() {
        app.handle(events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();
    }
    assert_eq!(app.active_surface(), Some(second.id));

    app.replace_selection(Some(Selection { surface: first.id, anchor: (0, 0), head: (3, 0) }));
    let mut terminal = Terminal::new(TestBackend::new(80, 12)).unwrap();
    app.render_action(&mut terminal, RenderAction::Draw).unwrap();

    let action = app.handle_key(KeyEvent::new(KeyCode::Char('x'), KeyModifiers::NONE)).unwrap();

    assert_eq!(
        action,
        RenderAction::Draw,
        "typing in the active pane must repaint a selection cleared from another pane"
    );
    assert!(app.selection.is_none());
    app.render_action(&mut terminal, action).unwrap();
    assert!(app.selection.is_none());
    assert!(app.pty_input.shutdown(Duration::from_secs(1)));
    mux.close_surface(first.id).unwrap();
    mux.close_surface(second.id).unwrap();
}

#[test]
fn visible_state_browser_input_requests_draw_after_selection_clear_on_pty_surface() {
    let mux = Mux::new("visible-state-browser-selection-test", SurfaceOptions::default());
    let first = mux.new_workspace(None, Some((80, 12))).unwrap();
    let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let second = mux.split(first_pane, SplitDir::Right, Some((40, 12))).unwrap();
    let second_pane = mux.with_state(|state| state.pane_of(second.id).unwrap());
    let browser =
        mux.new_browser_tab("about:blank".to_string(), Some(second_pane), Some((40, 12))).unwrap();
    let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
    app.sidebar_visible = false;
    app.replace_tree(app.session.tree());
    app.sync_layout((80, 12));
    while app.session.has_pending_mutations() {
        app.handle(events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();
    }
    assert_eq!(app.active_surface(), Some(browser.id));

    app.replace_selection(Some(Selection { surface: first.id, anchor: (0, 0), head: (3, 0) }));
    let mut terminal = Terminal::new(TestBackend::new(80, 12)).unwrap();
    app.render_action(&mut terminal, RenderAction::Draw).unwrap();

    let action = app.handle_key(KeyEvent::new(KeyCode::Char('x'), KeyModifiers::NONE)).unwrap();

    assert_eq!(
        action,
        RenderAction::Draw,
        "browser input must repaint a selection cleared from a visible PTY pane"
    );
    assert!(app.selection.is_none());
    app.render_action(&mut terminal, action).unwrap();
    assert!(app.selection.is_none());
    assert!(app.pty_input.shutdown(Duration::from_secs(1)));
    mux.close_surface(browser.id).unwrap();
    mux.close_surface(first.id).unwrap();
    mux.close_surface(second.id).unwrap();
}

#[test]
fn visible_state_clear_history_fallback_requests_draw_after_selection_clear() {
    let mux = Mux::new("visible-state-clear-history-fallback-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.tree = notify_tree(11, false);
    app.replace_selection(Some(Selection { surface: 11, anchor: (1, 1), head: (4, 1) }));

    let action = app
        .run_clear_history_shortcut(KeyEvent::new(KeyCode::Char('k'), KeyModifiers::SUPER).into());

    assert_eq!(
        action,
        RenderAction::Draw,
        "the unclaimed PTY fallback clears the visible selection before forwarding the key"
    );
    assert!(app.selection.is_none());

    let unchanged = app
        .run_clear_history_shortcut(KeyEvent::new(KeyCode::Char('k'), KeyModifiers::SUPER).into());
    assert_eq!(unchanged, RenderAction::None, "fallback with no selection needs no draw");
}

#[test]
fn visible_state_focus_loss_requests_draw_after_pointer_cancel() {
    let mux = Mux::new("visible-state-focus-loss-test", SurfaceOptions::default());
    let first = mux.new_workspace(None, Some((40, 10))).unwrap();
    let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let second = mux.new_tab(Some(pane), None, Some((40, 10))).unwrap();
    let mut app = test_app(Session::Local(mux.clone()));
    app.sidebar_visible = false;
    app.replace_tree(app.session.tree());
    app.drag = Some(Drag::Tab { surface: second.id, target: Some((pane, 0)) });
    app.active_pointer_buttons.insert(MouseButton::Left);
    let mut terminal = Terminal::new(TestBackend::new(40, 12)).unwrap();
    app.render_action(&mut terminal, RenderAction::Draw).unwrap();
    assert!(
        buffer_text(terminal.backend().buffer()).contains('▌'),
        "the setup frame must contain the tab drop marker"
    );

    let action = app.handle(AppEvent::Input(Event::FocusLost)).unwrap();

    assert_eq!(action, RenderAction::Draw, "canceling painted pointer state needs a new frame");
    assert!(app.drag.is_none());
    assert!(app.active_pointer_buttons.is_empty());
    app.render_action(&mut terminal, action).unwrap();
    assert!(
        !buffer_text(terminal.backend().buffer()).contains('▌'),
        "the focus-loss frame must remove the old tab drop marker"
    );

    let unchanged = app.handle(AppEvent::Input(Event::FocusLost)).unwrap();
    assert_eq!(unchanged, RenderAction::None, "idle focus loss needs no draw");
    let workspace = mux.with_state(|state| state.workspaces[state.active_workspace].id);
    mux.close_workspace(workspace);
}

#[test]
fn focus_loss_settles_an_active_split_resize() {
    let mux = Mux::new("focus-loss-split-settle-test", SurfaceOptions::default());
    let (mut app, _events) = test_app_with_events(Session::Local(mux));
    let (started_tx, started_rx) = std::sync::mpsc::channel();
    let (release_tx, release_rx) = std::sync::mpsc::channel();
    app.session.operations.enqueue_session_mutation("block split settle", false, move || {
        started_tx.send(()).unwrap();
        release_rx.recv().unwrap();
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

    app.handle(AppEvent::Input(Event::FocusLost)).unwrap();
    let pending_pointer = app.session.pending_pointer_mutations.load(Ordering::Acquire);
    release_tx.send(()).unwrap();

    assert_eq!(
        pending_pointer, 1,
        "canceling a split drag must enqueue its final authoritative settlement"
    );
    assert!(app.drag.is_none());
}

#[test]
fn focus_loss_releases_an_active_browser_press() {
    let mux = Mux::new("focus-loss-browser-release-test", SurfaceOptions::default());
    let surface = mux.new_browser_tab("about:blank".to_string(), None, Some((20, 8))).unwrap();
    let mut app = test_app(Session::Local(mux.clone()));
    let (dispatcher, blocked) = BrowserInputDispatcher::blocked(1);
    app.browser_input = dispatcher;
    assert!(app.browser_input.enqueue(BrowserInputEvent {
        surface_id: surface.id,
        surface: app.session.surface(surface.id).unwrap(),
        kind: BrowserInputKind::Mouse {
            event_type: "mousePressed",
            x: 3.0,
            y: 2.0,
            button: Some("left"),
            click_count: Some(1),
            frame_seq: 1,
        },
    }));
    assert_eq!(blocked.drain_mouse_lifetimes(), vec![("mousePressed", false)]);
    app.drag = Some(Drag::Browser {
        surface: surface.id,
        content: Rect { x: 2, y: 3, width: 20, height: 8 },
        position: (5, 5),
        frame_seq: 1,
    });

    app.handle(AppEvent::Input(Event::FocusLost)).unwrap();

    assert_eq!(
        blocked.drain_mouse_lifetimes(),
        vec![("mouseReleased", false)],
        "focus loss must enqueue a terminal mouseReleased for the browser that owns the press"
    );
    assert!(app.drag.is_none());
    mux.close_surface(surface.id).unwrap();
}

#[test]
fn right_button_capture_cannot_cross_a_new_pairing_dialog() {
    let mux = Mux::new("pairing-menu-capture-test", SurfaceOptions::default());
    mux.new_workspace(None, Some((80, 24))).unwrap();
    let (mut app, mutation_events) = test_app_with_events(Session::Local(mux.clone()));
    app.sidebar_visible = false;
    app.sync_layout((100, 20));
    while app.session.has_pending_mutations() {
        app.handle(mutation_events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();
    }
    let mut terminal = Terminal::new(TestBackend::new(100, 20)).unwrap();
    app.render_action(&mut terminal, RenderAction::Draw).unwrap();
    let content = app.pane_areas[0].content;
    let press = (content.x + 4, content.y + 2);
    let select = (press.0 + 1, press.1);
    let action = app
        .handle(AppEvent::Input(Event::Mouse(MouseEvent {
            kind: MouseEventKind::Down(MouseButton::Right),
            column: press.0,
            row: press.1,
            modifiers: KeyModifiers::SHIFT,
        })))
        .unwrap();
    app.render_action(&mut terminal, action).unwrap();
    assert!(app.menu.is_some());
    assert!(app.active_pointer_buttons.contains(&MouseButton::Right));

    let (challenge, decision) = mux.begin_pairing("127.0.0.1".parse().unwrap()).unwrap();
    app.handle(AppEvent::Mux(MuxEvent::PairingRequested(challenge.clone()))).unwrap();
    for kind in [MouseEventKind::Drag(MouseButton::Right), MouseEventKind::Up(MouseButton::Right)] {
        app.handle(AppEvent::Input(Event::Mouse(MouseEvent {
            kind,
            column: select.0,
            row: select.1,
            modifiers: KeyModifiers::SHIFT,
        })))
        .unwrap();
    }
    let (events, receiver) = crossbeam_channel::unbounded();
    drop(events);
    app.event_loop(&mut terminal, receiver).unwrap();

    assert_eq!(app.pairing_dialog.as_ref().map(|dialog| dialog.challenge.id), Some(challenge.id));
    assert!(
        app.prompt.is_none(),
        "the old right-button capture must not activate its menu behind a trusted dialog"
    );
    assert!(decision.try_recv().is_err());
}

#[test]
fn pairing_dialog_captures_live_non_left_pointer_input() {
    let mux = Mux::new("pairing-live-pointer-capture-test", SurfaceOptions::default());
    mux.new_workspace(None, Some((80, 24))).unwrap();
    let (challenge, decision) = mux.begin_pairing("127.0.0.1".parse().unwrap()).unwrap();
    let (mut app, mutation_events) = test_app_with_events(Session::Local(mux));
    app.sidebar_visible = false;
    app.sync_layout((100, 20));
    while app.session.has_pending_mutations() {
        app.handle(mutation_events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();
    }
    let mut terminal = Terminal::new(TestBackend::new(100, 20)).unwrap();
    let action = app.handle(AppEvent::Mux(MuxEvent::PairingRequested(challenge))).unwrap();
    app.render_action(&mut terminal, action).unwrap();
    let content = app.pane_areas[0].content;

    app.handle(AppEvent::Input(Event::Mouse(MouseEvent {
        kind: MouseEventKind::Down(MouseButton::Right),
        column: content.x + 4,
        row: content.y + 2,
        modifiers: KeyModifiers::SHIFT,
    })))
    .unwrap();

    assert!(app.menu.is_none(), "right-click must not reach panes behind a pairing dialog");
    assert!(app.active_pointer_buttons.is_empty());
    assert!(decision.try_recv().is_err());
}

#[test]
fn enter_cannot_approve_a_pairing_dialog_before_it_is_rendered() {
    let mux = Mux::new("pairing-key-render-barrier-test", SurfaceOptions::default());
    let (challenge, decision) = mux.begin_pairing("127.0.0.1".parse().unwrap()).unwrap();
    let mut app = test_app(Session::Local(mux));
    let (events, receiver) = crossbeam_channel::unbounded();
    events.send(AppEvent::Mux(MuxEvent::PairingRequested(challenge.clone()))).unwrap();
    events
        .send(AppEvent::Input(Event::Key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE))))
        .unwrap();
    drop(events);
    let mut terminal = Terminal::new(TestBackend::new(100, 20)).unwrap();

    app.event_loop(&mut terminal, receiver).unwrap();

    assert_eq!(app.pairing_dialog.as_ref().map(|dialog| dialog.challenge.id), Some(challenge.id));
    assert!(decision.try_recv().is_err(), "Enter must not approve an unseen trusted dialog");
}

#[test]
fn enter_cannot_approve_an_unrendered_replacement_pairing_dialog() {
    let mux = Mux::new("pairing-key-replacement-barrier-test", SurfaceOptions::default());
    let (first, first_decision) = mux.begin_pairing("127.0.0.1".parse().unwrap()).unwrap();
    let (second, second_decision) = mux.begin_pairing("127.0.0.2".parse().unwrap()).unwrap();
    let mut app = test_app(Session::Local(mux.clone()));
    let mut terminal = Terminal::new(TestBackend::new(100, 20)).unwrap();
    let action = app.handle(AppEvent::Mux(MuxEvent::PairingRequested(first.clone()))).unwrap();
    app.render_action(&mut terminal, action).unwrap();
    let action = app.handle(AppEvent::Mux(MuxEvent::PairingRequested(second.clone()))).unwrap();
    app.render_action(&mut terminal, action).unwrap();
    assert!(mux.respond_pairing(first.id, false));
    assert!(first_decision.recv_timeout(Duration::from_secs(1)).is_ok());

    app.handle(AppEvent::Mux(MuxEvent::PairingResolved { request: first.id })).unwrap();
    app.handle(AppEvent::Input(Event::Key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE))))
        .unwrap();

    assert_eq!(app.pairing_dialog.as_ref().map(|dialog| dialog.challenge.id), Some(second.id));
    assert!(
        second_decision.try_recv().is_err(),
        "Enter must not approve the queued dialog until that identity is rendered"
    );
    assert!(mux.respond_pairing(second.id, false));
}

#[test]
fn deferred_key_cannot_approve_a_pairing_request_that_arrived_later() {
    let mux = Mux::new("pairing-deferred-key-identity-test", SurfaceOptions::default());
    let (challenge, decision) = mux.begin_pairing("127.0.0.1".parse().unwrap()).unwrap();
    let mut app = test_app(Session::Local(mux.clone()));
    let mut terminal = Terminal::new(TestBackend::new(100, 20)).unwrap();
    app.session.pending_mutations.store(1, Ordering::Release);

    app.handle(AppEvent::Input(Event::Key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE))))
        .unwrap();
    assert_eq!(app.deferred_input.len(), 1);

    let action = app.handle(AppEvent::Mux(MuxEvent::PairingRequested(challenge.clone()))).unwrap();
    app.render_action(&mut terminal, action).unwrap();
    app.session.pending_mutations.store(0, Ordering::Release);
    app.replay_deferred_input().unwrap();

    assert_eq!(app.pairing_dialog.as_ref().map(|dialog| dialog.challenge.id), Some(challenge.id));
    assert!(
        decision.try_recv().is_err(),
        "input captured before this pairing identity existed must not approve it"
    );
    assert!(mux.respond_pairing(challenge.id, false));
}

#[test]
fn key_cannot_reach_underlay_while_a_resolved_pairing_dialog_is_still_rendered() {
    let mux = Mux::new("pairing-key-removal-barrier-test", SurfaceOptions::default());
    let (challenge, decision) = mux.begin_pairing("127.0.0.1".parse().unwrap()).unwrap();
    let mut app = test_app(Session::Local(mux.clone()));
    app.prompt = Some(Prompt::new("Rename", String::new(), PromptTarget::Surface(77)));
    let mut terminal = Terminal::new(TestBackend::new(100, 20)).unwrap();
    let action = app.handle(AppEvent::Mux(MuxEvent::PairingRequested(challenge.clone()))).unwrap();
    app.render_action(&mut terminal, action).unwrap();
    assert!(mux.respond_pairing(challenge.id, false));
    assert!(decision.recv_timeout(Duration::from_secs(1)).is_ok());

    app.handle(AppEvent::Mux(MuxEvent::PairingResolved { request: challenge.id })).unwrap();
    app.handle(AppEvent::Input(Event::Key(KeyEvent::new(KeyCode::Char('x'), KeyModifiers::NONE))))
        .unwrap();

    assert_eq!(app.prompt.as_ref().unwrap().input.as_str(), "");
}

#[test]
fn key_after_retained_pointer_keeps_physical_input_order() {
    let mux = Mux::new("retained-pointer-key-order-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.prompt = Some(Prompt::new("Rename", "ab".to_string(), PromptTarget::Surface(77)));
    let prompt_x = (100 - 42) / 2;
    let prompt_y = (20 - 9) / 2;
    let (events, receiver) = crossbeam_channel::unbounded();
    events.send(AppEvent::Mux(MuxEvent::SurfaceOutput(77))).unwrap();
    events
        .send(AppEvent::Input(Event::Mouse(MouseEvent {
            kind: MouseEventKind::Down(MouseButton::Left),
            column: prompt_x + 2,
            row: prompt_y + 4,
            modifiers: KeyModifiers::NONE,
        })))
        .unwrap();
    events
        .send(AppEvent::Input(Event::Key(KeyEvent::new(KeyCode::Char('x'), KeyModifiers::NONE))))
        .unwrap();
    drop(events);
    let mut terminal = Terminal::new(TestBackend::new(100, 20)).unwrap();

    app.event_loop(&mut terminal, receiver).unwrap();

    assert_eq!(
        app.prompt.as_ref().unwrap().input.as_str(),
        "xab",
        "the later key must not overtake the retained click that moved the cursor"
    );
}

#[test]
fn retained_right_button_capture_crosses_the_menu_frame_it_opens() {
    let mux = Mux::new("retained-menu-capture-test", SurfaceOptions::default());
    mux.new_workspace(None, Some((80, 24))).unwrap();
    let (mut app, mutation_events) = test_app_with_events(Session::Local(mux));
    app.sidebar_visible = false;
    app.sync_layout((100, 40));
    while app.session.has_pending_mutations() {
        app.handle(mutation_events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();
    }
    let mut terminal = Terminal::new(TestBackend::new(100, 40)).unwrap();
    app.render_action(&mut terminal, RenderAction::Draw).unwrap();
    while app.session.has_pending_mutations() {
        let action =
            app.handle(mutation_events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();
        app.render_action(&mut terminal, action).unwrap();
    }
    let content = app.pane_areas[0].content;
    let press = (content.x + 4, content.y + 2);
    let select = (press.0 + 1, press.1);
    let (events, receiver) = crossbeam_channel::unbounded();
    events.send(AppEvent::Mux(MuxEvent::SurfaceOutput(999))).unwrap();
    events
        .send(AppEvent::Input(Event::Mouse(MouseEvent {
            kind: MouseEventKind::Down(MouseButton::Right),
            column: press.0,
            row: press.1,
            modifiers: KeyModifiers::SHIFT,
        })))
        .unwrap();
    events
        .send(AppEvent::Input(Event::Mouse(MouseEvent {
            kind: MouseEventKind::Drag(MouseButton::Right),
            column: select.0,
            row: select.1,
            modifiers: KeyModifiers::SHIFT,
        })))
        .unwrap();
    events
        .send(AppEvent::Input(Event::Mouse(MouseEvent {
            kind: MouseEventKind::Up(MouseButton::Right),
            column: select.0,
            row: select.1,
            modifiers: KeyModifiers::SHIFT,
        })))
        .unwrap();
    drop(events);

    app.event_loop(&mut terminal, receiver).unwrap();

    assert!(
        app.prompt.is_some(),
        "the accepted right press must keep ownership through menu render, drag, and release"
    );
    assert!(app.menu.is_none());
}

#[test]
fn right_menu_capture_cannot_close_a_replacement_active_tab() {
    let mux = Mux::new("right-menu-owner-test", SurfaceOptions::default());
    let first = mux.new_browser_tab("about:blank#first".to_string(), None, Some((80, 24))).unwrap();
    let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let second =
        mux.new_browser_tab("about:blank#second".to_string(), Some(pane), Some((80, 24))).unwrap();
    mux.select_tab(Some(pane), Some(0), None);
    let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
    app.replace_tree(app.session.tree());
    app.sidebar_visible = false;
    app.sync_layout((100, 20));
    while app.session.has_pending_mutations() {
        app.handle(events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();
    }
    let mut terminal = Terminal::new(TestBackend::new(100, 20)).unwrap();
    app.render_action(&mut terminal, RenderAction::Draw).unwrap();
    let content = app.pane_areas[0].content;
    let press = (content.x + 4, content.y + 2);
    let action = app
        .handle(AppEvent::Input(Event::Mouse(MouseEvent {
            kind: MouseEventKind::Down(MouseButton::Right),
            column: press.0,
            row: press.1,
            modifiers: KeyModifiers::SHIFT,
        })))
        .unwrap();
    app.render_action(&mut terminal, action).unwrap();
    let close = app
        .menu
        .as_ref()
        .and_then(|menu| {
            let level = menu.levels.first()?;
            let item = level
                .items
                .iter()
                .position(|item| item.action() == Some(MenuAction::CloseTab(pane)))?;
            Some((
                level.rect.x + 1,
                level.rect.y + 1 + item.saturating_sub(level.scroll_offset) as u16,
            ))
        })
        .expect("close-tab menu row");

    app.select_tab_for_client(Some(pane), Some(1), None);
    assert_eq!(app.active_surface(), Some(second.id));
    assert_eq!(mux.active_surface(), Some(first.id));
    let event = |kind| {
        AppEvent::Input(Event::Mouse(MouseEvent {
            kind,
            column: close.0,
            row: close.1,
            modifiers: KeyModifiers::SHIFT,
        }))
    };
    let drag_action = app.handle(event(MouseEventKind::Drag(MouseButton::Right))).unwrap();
    assert_eq!(
        app.menu.as_ref().and_then(ContextMenu::selected_action),
        Some(MenuAction::CloseTab(pane))
    );
    app.render_action(&mut terminal, drag_action).unwrap();
    app.handle_right_up(close.0, close.1).unwrap();
    assert!(app.menu.is_none());
    while app.session.has_pending_mutations() {
        let settled = events.recv_timeout(crate::test_wait::EVENT).unwrap();
        app.handle(settled).unwrap();
    }

    assert!(
        mux.with_state(|state| state.surfaces.contains_key(&second.id)),
        "a menu captured for the first tab must not close its replacement"
    );
    let _ = mux.close_surface(first.id);
    let _ = mux.close_surface(second.id);
}

#[test]
fn older_replayed_pointer_does_not_erase_newer_retained_motion() {
    let mux = Mux::new("replayed-pointer-motion-order-test", SurfaceOptions::default());
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
    let newer_motion = MouseEvent {
        kind: MouseEventKind::Moved,
        column: 14,
        row: 6,
        modifiers: KeyModifiers::NONE,
    };
    app.pending_pointer_motion = Some(crate::app::PendingPointerMotion {
        event: newer_motion,
        destination: None,
        focus_generation: 0,
        sequence: 2,
    });

    app.replay_deferred_input().unwrap();

    assert_eq!(
        app.hover,
        Some((newer_motion.column, newer_motion.row)),
        "newer retained motion must replay after the older click"
    );
}

#[test]
fn retained_motion_replays_through_ordered_mutation_without_overtaking_discrete_input() {
    let mux = Mux::new("ordered-mutation-pointer-replay-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    let motion = MouseEvent {
        kind: MouseEventKind::Moved,
        column: 14,
        row: 6,
        modifiers: KeyModifiers::NONE,
    };
    app.pending_pointer_motion = Some(crate::app::PendingPointerMotion {
        event: motion,
        destination: None,
        focus_generation: 0,
        sequence: 1,
    });
    app.deferred_input.push_back(queued_input(
        Event::Key(KeyEvent::new(KeyCode::Char('x'), KeyModifiers::NONE)),
        None,
        2,
    ));
    app.deferred_input_sequence = 2;
    app.session.pending_mutations.store(1, Ordering::Release);
    assert!(
        !app.session.has_pending_pointer_mutations(),
        "the synthetic mutation must model MutationImpact::Ordered"
    );

    let replay = app.replay_deferred_input_batch().unwrap();

    app.session.pending_mutations.store(0, Ordering::Release);
    assert_eq!(
        app.hover,
        Some((motion.column, motion.row)),
        "retained passive motion should replay through an ordered-only mutation"
    );
    assert!(app.pending_pointer_motion.is_none());
    assert_eq!(
        app.deferred_input.front().map(|input| input.sequence),
        Some(2),
        "later discrete input must remain behind the pending ordered mutation"
    );
    assert_eq!(replay.disposition, DeferredReplayDisposition::Blocked);
}

#[test]
fn retained_motion_coalesces_only_within_discrete_input_segments() {
    let mux = Mux::new("segmented-pointer-motion-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.session.pending_mutations.store(1, Ordering::Release);
    app.session.pending_pointer_mutations.store(1, Ordering::Release);
    let first = MouseEvent {
        kind: MouseEventKind::Moved,
        column: 8,
        row: 3,
        modifiers: KeyModifiers::NONE,
    };
    let second = MouseEvent {
        kind: MouseEventKind::Moved,
        column: 18,
        row: 7,
        modifiers: KeyModifiers::NONE,
    };

    app.handle(AppEvent::Input(Event::Mouse(first))).unwrap();
    app.handle(AppEvent::Input(Event::Key(KeyEvent::new(KeyCode::Char('x'), KeyModifiers::NONE))))
        .unwrap();
    app.handle(AppEvent::Input(Event::Mouse(second))).unwrap();

    assert!(matches!(
        app.deferred_input.front(),
        Some(DeferredInput {
            event: TerminalInput::Mouse(event),
            sequence: 1,
            ..
        }) if *event == first
    ));
    assert!(matches!(
        app.deferred_input.get(1),
        Some(DeferredInput { event: TerminalInput::Keyboard(_), sequence: 2, .. })
    ));
    assert!(matches!(
        app.pending_pointer_motion,
        Some(crate::app::PendingPointerMotion {
            event,
            sequence: 3,
            ..
        }) if event == second
    ));
}
