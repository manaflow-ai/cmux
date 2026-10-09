//! Tests: layout undo failures, terminal mouse press and release, scoped host
//! mouse capture, and content changes during resize.

use super::*;

#[test]
fn layout_undo_expected_failures_are_typed_and_localized() {
    assert!(matches!(
        layout_undo_error_completion(&anyhow::Error::new(LayoutUndoError::Stale(
            "layout changed since the last undoable action".to_string()
        ))),
        Some(SessionCompletionAction::LayoutUndoStale)
    ));
    assert!(matches!(
        layout_undo_error_completion(&anyhow::Error::new(LayoutUndoError::Unavailable)),
        Some(SessionCompletionAction::LayoutUndoUnavailable)
    ));
}

#[test]
fn browser_crop_scales_to_downsampled_frame_width() {
    assert_eq!(browser_source_crop(50, 20, 40, 100), Some((10, 20)));
    assert_eq!(browser_source_crop(101, 20, 40, 100), Some((20, 41)));
    assert_eq!(browser_source_crop(50, 90, 20, 100), Some((45, 5)));
    assert_eq!(browser_source_crop(0, 20, 40, 100), None);
}

#[test]
fn browser_crop_uses_the_encoded_frame_width_instead_of_css_width() {
    let frame = BrowserFrame {
        session_id: "test".to_string(),
        data_b64: "frame".to_string(),
        css_width: 200,
        css_height: 100,
        image_width: 50,
        image_height: 25,
        seq: 1,
    };

    assert_eq!(browser_frame_source_crop(&frame, 20, 40, 100), Some((10, 20)));
}

#[test]
fn focus_loss_settles_an_active_split_resize_transaction() {
    let mux = Mux::new("focus-lost-split-resize-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    let transaction = app.session.layout_resize_transaction.load(Ordering::Acquire);
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

    assert!(app.drag.is_none());
    assert_ne!(app.session.layout_resize_transaction.load(Ordering::Acquire), transaction);
}

#[test]
fn a_new_left_press_settles_an_abandoned_split_resize_transaction() {
    let mux = Mux::new("new-press-split-resize-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    let transaction = app.session.layout_resize_transaction.load(Ordering::Acquire);
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

    app.handle_left_down(0, 0, KeyModifiers::NONE).unwrap();

    assert_ne!(app.session.layout_resize_transaction.load(Ordering::Acquire), transaction);
}

#[test]
fn horizontal_clip_projects_virtual_coordinates_after_u16_extent() {
    assert_eq!(
        clip_horizontal_rect(
            VirtualRect { x: 131_070, y: 3, width: 65_535, height: 20 },
            131_100,
            80,
            5,
        ),
        Some((Rect { x: 5, y: 3, width: 80, height: 20 }, 30))
    );
}

#[test]
fn clipped_terminal_input_uses_the_logical_source_column() {
    let mux = Mux::new(
        "clipped-terminal-input-test",
        SurfaceOptions {
            command: Some(vec!["/bin/sh".to_string(), "-c".to_string(), "sleep 30".to_string()]),
            ..Default::default()
        },
    );
    let surface = mux.new_workspace(None, Some((20, 8))).unwrap();
    surface.with_terminal(|terminal| terminal.vt_write(b"\x1b[?1002h\x1b[?1006h"));
    let mut app = test_app(Session::Local(mux.clone()));
    app.replace_tree(app.session.tree());
    let pane = app.tree.active_screen().unwrap().active_pane;
    let content = Rect { x: 2, y: 3, width: 5, height: 8 };
    app.pane_areas.push(PaneArea {
        pane,
        surface: surface.id,
        rect: Rect { x: 1, y: 2, width: 8, height: 10 },
        bar: Some(Rect { x: 1, y: 2, width: 8, height: 1 }),
        omnibar: None,
        content,
        track: None,
        viewport: Some(PaneViewportClip {
            rect_source_x: 10,
            full_rect_width: 23,
            omnibar_source_x: 0,
            full_omnibar_width: 0,
            content_source_x: 10,
            full_content_width: 20,
        }),
    });
    app.rendered_terminal_bounds.insert(surface.id, content);
    app.rendered_terminal_sizes.insert(surface.id, (20, 8));
    let event =
        |kind, modifiers| MouseEvent { kind, column: content.x + 2, row: content.y + 2, modifiers };

    app.handle_mouse(event(MouseEventKind::Down(MouseButton::Left), KeyModifiers::NONE)).unwrap();
    assert_eq!(app.encode_buf, b"\x1b[<0;13;3M");
    app.handle_mouse(event(MouseEventKind::Up(MouseButton::Left), KeyModifiers::NONE)).unwrap();
    assert_eq!(app.encode_buf, b"\x1b[<0;13;3m");

    app.handle_mouse(event(MouseEventKind::Down(MouseButton::Left), KeyModifiers::SHIFT)).unwrap();
    assert_eq!(app.selection.map(|selection| selection.anchor.0), Some(12));

    mux.close_surface(surface.id).unwrap();
}

#[test]
fn pty_mouse_uses_the_canonical_rendered_grid_during_resize_margins() {
    let mux = Mux::new(
        "mouse-canonical-grid-test",
        SurfaceOptions {
            command: Some(vec!["/bin/sh".to_string(), "-c".to_string(), "sleep 30".to_string()]),
            ..Default::default()
        },
    );
    let surface = mux.new_workspace(Some("work".to_string()), Some((20, 8))).unwrap();
    surface.with_terminal(|terminal| terminal.vt_write(b"\x1b[?1003h\x1b[?1006h"));

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
    // The pane has already grown, but the only frame visible to the user
    // is still 12x5. The remaining cells are renderer-owned margins.
    app.rendered_terminal_sizes.insert(surface.id, (12, 5));
    app.handle(AppEvent::Input(Event::Resize(40, 12))).unwrap();
    assert_eq!(
        app.rendered_terminal_sizes.get(&surface.id),
        Some(&(12, 5)),
        "outer resize must retain the dimensions of the still-visible frame"
    );

    let outside = (content.x + 15, content.y + 2);
    assert_eq!(
        app.begin_pty_mouse_drag(outside.0, outside.1, MouseButton::Left, KeyModifiers::NONE,),
        PtyMousePressResult::NotOwned
    );
    assert!(app.drag.is_none());
    assert!(app.encode_buf.is_empty());
    assert_eq!(
        app.handle_scroll(outside.0, outside.1, true, KeyModifiers::NONE).unwrap(),
        RenderAction::None
    );
    assert!(app.encode_buf.is_empty());
    assert_eq!(
        app.handle_horizontal_scroll(outside.0, outside.1, true, KeyModifiers::NONE).unwrap(),
        RenderAction::None
    );
    assert!(app.encode_buf.is_empty());

    // Leaving through a blank margin suppresses no-button motion, then
    // clears Ghostty's cell dedupe so the same edge cell reports on reentry.
    let edge = (content.x + 11, content.y + 2);
    assert!(app.forward_pty_mouse_at(
        edge.0,
        edge.1,
        MouseAction::Motion,
        None,
        KeyModifiers::NONE,
        false,
    ));
    assert_eq!(app.encode_buf, b"\x1b[<35;12;3M");
    assert!(!app.forward_pty_mouse_at(
        outside.0,
        outside.1,
        MouseAction::Motion,
        None,
        KeyModifiers::NONE,
        false,
    ));
    assert!(app.encode_buf.is_empty());
    assert!(app.forward_pty_mouse_at(
        edge.0,
        edge.1,
        MouseAction::Motion,
        None,
        KeyModifiers::NONE,
        false,
    ));
    assert_eq!(app.encode_buf, b"\x1b[<35;12;3M");

    // A press that starts inside keeps capture while crossing the margin;
    // Ghostty reports the edge cell and, critically, always emits release.
    let inside = (content.x + 4, content.y + 2);
    assert_eq!(
        app.begin_pty_mouse_drag(inside.0, inside.1, MouseButton::Left, KeyModifiers::NONE,),
        PtyMousePressResult::Started
    );
    assert_eq!(app.encode_buf, b"\x1b[<0;5;3M");
    assert!(app.forward_pty_mouse_drag(
        outside.0,
        outside.1,
        MouseButton::Left,
        KeyModifiers::NONE,
    ));
    assert_eq!(app.encode_buf, b"\x1b[<32;12;3M");
    assert!(
        app.finish_pty_mouse_drag(outside.0, outside.1, MouseButton::Left, KeyModifiers::NONE,)
    );
    assert_eq!(app.encode_buf, b"\x1b[<0;12;3m");
    assert!(app.drag.is_none());

    mux.close_surface(surface.id).unwrap();
}

#[test]
fn canonical_terminal_content_clamps_to_the_visible_pane() {
    let content = Rect { x: 7, y: 11, width: 20, height: 8 };
    assert_eq!(canonical_terminal_content(content, None), content);
    assert_eq!(
        canonical_terminal_content(content, Some((12, 5))),
        Rect { x: 7, y: 11, width: 12, height: 5 }
    );
    assert_eq!(
        canonical_terminal_content(content, Some((40, 30))),
        content,
        "a stale larger frame must never claim cells outside its pane"
    );
}

#[test]
fn outer_cursor_escapes_cover_color_shape_blink_and_reset() {
    let color = Rgb { r: 0x12, g: 0x34, b: 0x56 };
    let terminal = |shape, blinking| OuterCursorSpec::Terminal { color, shape, blinking };
    assert_eq!(
        outer_cursor_escape(terminal(CursorShape::Block, true)),
        "\x1b]12;#123456\x07\x1b[1 q"
    );
    assert_eq!(
        outer_cursor_escape(terminal(CursorShape::Block, false)),
        "\x1b]12;#123456\x07\x1b[2 q"
    );
    assert_eq!(
        outer_cursor_escape(terminal(CursorShape::Underline, true)),
        "\x1b]12;#123456\x07\x1b[3 q"
    );
    assert_eq!(
        outer_cursor_escape(terminal(CursorShape::Underline, false)),
        "\x1b]12;#123456\x07\x1b[4 q"
    );
    assert_eq!(
        outer_cursor_escape(terminal(CursorShape::Bar, true)),
        "\x1b]12;#123456\x07\x1b[5 q"
    );
    assert_eq!(
        outer_cursor_escape(terminal(CursorShape::Bar, false)),
        "\x1b]12;#123456\x07\x1b[6 q"
    );
    assert_eq!(
        outer_cursor_escape(terminal(CursorShape::BlockHollow, true)),
        "\x1b]12;#123456\x07\x1b[2 q",
        "DECSCUSR has no hollow block, so it degrades to steady block"
    );
    assert_eq!(outer_cursor_escape(OuterCursorSpec::Reset), "\x1b]112\x07\x1b[0 q");
}

#[test]
fn outer_cursor_state_suppresses_redundant_global_terminal_writes() {
    let desired = OuterCursorSpec::Terminal {
        color: Rgb { r: 1, g: 2, b: 3 },
        shape: CursorShape::Bar,
        blinking: false,
    };
    assert!(outer_cursor_escape_if_changed(None, desired).is_some());
    assert!(outer_cursor_escape_if_changed(Some(desired), desired).is_none());
    assert!(outer_cursor_escape_if_changed(Some(desired), OuterCursorSpec::Reset).is_some());
    assert!(
        outer_cursor_escape_if_changed(Some(OuterCursorSpec::Reset), OuterCursorSpec::Reset)
            .is_none()
    );
}

#[test]
fn scoped_attach_startup_asserts_no_unrequested_host_modes() {
    // attach --terminal is a transparent passthrough. Before the inner
    // terminal requests anything, the client must not put the host into
    // any mouse-tracking mode or change the shift-bypass report; the
    // host terminal owns clicks and selection. Focus reporting and
    // bracketed paste stay on because the client consumes them and
    // re-encodes for the inner terminal per its actual modes.
    let scoped = host_startup_input_modes(true);
    for mode in ["1000", "1002", "1003", "1006", "1015", "9"] {
        assert!(
            !scoped.contains(&format!("\x1b[?{mode}h")),
            "scoped attach asserted unrequested host mouse mode {mode}: {scoped:?}"
        );
    }
    assert!(!scoped.contains("\x1b[>1s"), "scoped attach changed shift-bypass: {scoped:?}");
    assert!(!scoped.contains(" q"), "scoped attach wrote DECSCUSR at startup: {scoped:?}");
    assert!(scoped.contains("\x1b[?1004h"), "focus reporting is client-consumed and stays");
    assert!(scoped.contains("\x1b[?2004h"), "bracketed paste is client-normalized and stays");

    let full = host_startup_input_modes(false);
    assert!(full.contains("\x1b[?1000h") && full.contains("\x1b[?1006h"));
    assert!(full.contains("\x1b[>1s"));
}

#[test]
fn host_mouse_capture_transitions_mirror_inner_tracking() {
    let enable = host_mouse_capture_escape_if_changed(Some(false), true)
        .expect("enabling capture must emit");
    assert!(enable.contains("\x1b[?1000h"));
    assert!(enable.contains("\x1b[?1006h"));
    assert!(enable.contains("\x1b[>1s"));

    let disable = host_mouse_capture_escape_if_changed(Some(true), false)
        .expect("disabling capture must emit");
    assert!(disable.contains("\x1b[?1000l"));
    assert!(disable.contains("\x1b[>0s"), "shift-bypass must be restored with capture");

    assert!(host_mouse_capture_escape_if_changed(Some(true), true).is_none());
    assert!(host_mouse_capture_escape_if_changed(Some(false), false).is_none());
}

#[test]
fn scoped_attach_initial_cursor_state_emits_nothing() {
    // The scoped client starts from an applied Reset, so the first frame
    // emits no OSC 12 / OSC 112 / DECSCUSR unless the inner application
    // authored a cursor style; the full TUI keeps restoring defaults.
    assert_eq!(initial_applied_outer_cursor(true), Some(OuterCursorSpec::Reset));
    assert!(
        outer_cursor_escape_if_changed(initial_applied_outer_cursor(true), OuterCursorSpec::Reset)
            .is_none(),
        "scoped attach must not write host cursor state at startup"
    );
    assert_eq!(initial_applied_outer_cursor(false), None);
    assert!(
        outer_cursor_escape_if_changed(initial_applied_outer_cursor(false), OuterCursorSpec::Reset)
            .is_some()
    );
    assert_eq!(initial_host_mouse_capture(true), Some(false));
    assert_eq!(initial_host_mouse_capture(false), Some(true));
}

#[test]
fn desired_host_mouse_capture_follows_scoped_inner_terminal() {
    let mux = Mux::new("scoped-mouse-capture-test", crate::test_wait::quiet_surface());
    let surface = mux.new_workspace(Some("work".to_string()), Some((20, 8))).unwrap();
    let mut app = test_app(Session::Local(mux.clone()));
    assert!(app.desired_host_mouse_capture(), "full TUI always captures host mouse");

    app.surface_only = Some(surface.id);
    assert!(
        !app.desired_host_mouse_capture(),
        "scoped attach must not capture before the inner terminal requests mouse"
    );

    surface.with_terminal(|terminal| terminal.vt_write(b"\x1b[?1002h"));
    assert!(app.desired_host_mouse_capture(), "scoped attach mirrors inner mouse tracking on");
    surface.with_terminal(|terminal| terminal.vt_write(b"\x1b[?1002l"));
    assert!(!app.desired_host_mouse_capture(), "scoped attach mirrors inner mouse tracking off");
    mux.close_surface(surface.id).unwrap();
}

/// A reattach restores the inner terminal's mouse modes through the
/// daemon replay before any frame renders, and a later frame whose pane
/// render fails or is skipped (contended terminal lock while the network
/// thread applies output, zero-sized pane during layout churn) leaves no
/// rendered pointer semantics either. Host mouse capture must follow the
/// terminal's canonical mode state in both situations; deriving it from
/// the rendered projection writes capture-off to the host exactly when
/// the inner application still owns the mouse.
#[test]
fn scoped_host_mouse_capture_follows_canonical_state_without_a_rendered_frame() {
    let mux = Mux::new("scoped-canonical-capture-test", crate::test_wait::quiet_surface());
    let surface = mux.new_workspace(Some("work".to_string()), Some((20, 8))).unwrap();
    let mut app = test_app(Session::Local(mux.clone()));
    app.surface_only = Some(surface.id);

    surface.with_terminal(|terminal| terminal.vt_write(b"\x1b[?1002h\x1b[?1006h"));
    assert_eq!(surface.with_terminal(|terminal| terminal.mouse_tracking()), Some(true));
    assert!(
        app.rendered_terminal_pointer_semantics.is_empty(),
        "precondition: no frame has rendered this surface"
    );
    assert!(
        app.desired_host_mouse_capture(),
        "host capture must follow the inner terminal's canonical mouse-tracking \
         state, not the rendered-frame projection"
    );

    surface.with_terminal(|terminal| terminal.vt_write(b"\x1b[?1002l\x1b[?1006l"));
    assert_eq!(surface.with_terminal(|terminal| terminal.mouse_tracking()), Some(false));
    assert!(
        !app.desired_host_mouse_capture(),
        "capture releases when the inner application disables tracking"
    );
    mux.close_surface(surface.id).unwrap();
}

/// When the canonical state is momentarily unknowable (the scoped surface
/// is gone from the session during attach teardown or handoff), the client
/// must keep the capture it last applied instead of toggling the host.
#[test]
fn scoped_host_mouse_capture_keeps_last_applied_when_state_is_unknowable() {
    let mux = Mux::new("scoped-capture-unknowable-test", SurfaceOptions::default());
    let surface = mux.new_workspace(Some("work".to_string()), Some((20, 8))).unwrap();
    let mut app = test_app(Session::Local(mux.clone()));
    let missing: SurfaceId = surface.id + 1000;
    app.surface_only = Some(missing);

    app.host_mouse_capture_applied = Some(true);
    assert!(
        app.desired_host_mouse_capture(),
        "an unknowable surface must not release capture the client already applied"
    );
    app.host_mouse_capture_applied = Some(false);
    assert!(
        !app.desired_host_mouse_capture(),
        "an unknowable surface must not assert capture the client never applied"
    );
    mux.close_surface(surface.id).unwrap();
}

/// Round-5 dogfood: btop in a reattached bridge tab renders but loses all
/// mouse after Keep-quit + reopen. The client correctly asserts capture on
/// reattach (proven byte-level against the real app), so the only way the
/// tab can end up dead is a host-side loss the client cannot observe: the
/// Ghostty surface silently drops the mouse-tracking modes (a reset written
/// into it by app-side session restore, or the host re-initializing on
/// relaunch) after the client's capture-on burst. The per-frame capture
/// sync is edge-triggered on `host_mouse_capture_applied`, so once the
/// client believes capture is applied it never re-emits, and btop never
/// toggles modes to trigger a change. A focus-in (Ghostty sends `\e[I` on
/// every window re-activation and app reopen, observed in the real path)
/// must force the client to re-derive and re-assert the canonical host
/// state so the dropped modes come back.
#[test]
fn scoped_focus_gained_reasserts_host_mouse_capture_after_invisible_host_reset() {
    let mux = Mux::new("scoped-focus-reassert-test", SurfaceOptions::default());
    let surface = mux.new_workspace(Some("work".to_string()), Some((20, 8))).unwrap();
    let mut app = test_app(Session::Local(mux.clone()));
    app.surface_only = Some(surface.id);

    // The inner application (btop) holds mouse tracking, and the client has
    // already asserted capture-on to the host once.
    surface.with_terminal(|terminal| terminal.vt_write(b"\x1b[?1002h\x1b[?1006h"));
    assert_eq!(surface.with_terminal(|terminal| terminal.mouse_tracking()), Some(true));
    app.host_mouse_capture_applied = Some(true);

    // The host silently dropped the modes. The client cannot see host
    // state: applied still says true and desired is true, so the per-frame
    // sync emits nothing and clicks stay dead. This is the latch.
    assert_eq!(
        host_mouse_capture_escape_if_changed(
            app.host_mouse_capture_applied,
            app.desired_host_mouse_capture(),
        ),
        None,
        "precondition: with stale applied state the per-frame sync re-emits nothing"
    );

    app.handle(AppEvent::Input(Event::FocusGained)).unwrap();

    // Focus-in must clear the applied bookkeeping so the next frame
    // re-derives the canonical state and re-emits capture.
    assert_eq!(
        app.host_mouse_capture_applied, None,
        "focus-in must reset the applied host-capture bookkeeping so the next frame re-asserts"
    );
    let reasserted = host_mouse_capture_escape_if_changed(
        app.host_mouse_capture_applied,
        app.desired_host_mouse_capture(),
    )
    .expect("the re-derived frame must re-emit host mouse capture");
    assert!(
        reasserted.contains("\x1b[?1002h"),
        "the re-asserted host state must re-enable mouse capture the inner app still holds"
    );
    mux.close_surface(surface.id).unwrap();
}

/// A resize is the other moment a host can re-initialize the surface and
/// drop the client's asserted input modes (window geometry changes across
/// a quit+reopen, so the reattached surface is resized). The scoped client
/// must re-assert host mouse capture on resize for the same reason it does
/// on focus-in.
#[test]
fn scoped_resize_reasserts_host_mouse_capture_after_invisible_host_reset() {
    let mux = Mux::new("scoped-resize-reassert-test", SurfaceOptions::default());
    let surface = mux.new_workspace(Some("work".to_string()), Some((20, 8))).unwrap();
    let mut app = test_app(Session::Local(mux.clone()));
    app.surface_only = Some(surface.id);

    surface.with_terminal(|terminal| terminal.vt_write(b"\x1b[?1002h\x1b[?1006h"));
    assert_eq!(surface.with_terminal(|terminal| terminal.mouse_tracking()), Some(true));
    app.host_mouse_capture_applied = Some(true);

    app.handle(AppEvent::Input(Event::Resize(120, 40))).unwrap();

    assert_eq!(
        app.host_mouse_capture_applied, None,
        "resize must reset the applied host-capture bookkeeping so the next frame re-asserts"
    );
    let reasserted = host_mouse_capture_escape_if_changed(
        app.host_mouse_capture_applied,
        app.desired_host_mouse_capture(),
    )
    .expect("the re-derived frame must re-emit host mouse capture");
    assert!(reasserted.contains("\x1b[?1002h"));
    mux.close_surface(surface.id).unwrap();
}

/// A full TUI owns the entire host surface and re-emits its input modes
/// through its normal lifecycle; the focus-in re-assert is scoped-only, so
/// it must not disturb a full-TUI client's capture bookkeeping.
#[test]
fn full_tui_focus_gained_does_not_reset_host_capture_bookkeeping() {
    let mux = Mux::new("full-tui-focus-reassert-test", SurfaceOptions::default());
    let _surface = mux.new_workspace(Some("work".to_string()), Some((20, 8))).unwrap();
    let mut app = test_app(Session::Local(mux));
    app.surface_only = None;
    app.host_mouse_capture_applied = Some(true);

    app.handle(AppEvent::Input(Event::FocusGained)).unwrap();

    assert_eq!(
        app.host_mouse_capture_applied,
        Some(true),
        "full-TUI focus-in must not touch host-capture bookkeeping"
    );
}

#[test]
fn pointer_motion_does_not_wait_for_terminal_parsing() {
    let mux = Mux::new(
        "mouse-motion-lock-test",
        SurfaceOptions {
            command: Some(vec!["/bin/sh".to_string(), "-c".to_string(), "sleep 30".to_string()]),
            ..Default::default()
        },
    );
    let surface = mux.new_workspace(None, Some((20, 8))).unwrap();
    surface.with_terminal(|terminal| terminal.vt_write(b"\x1b[?1003h\x1b[?1006h"));
    let held_surface = surface.clone();
    let (locked_tx, locked_rx) = std::sync::mpsc::channel();
    let (release_tx, release_rx) = std::sync::mpsc::channel();
    let holder = std::thread::spawn(move || {
        held_surface.with_terminal(|_| {
            locked_tx.send(()).unwrap();
            release_rx.recv().unwrap();
        });
    });
    locked_rx.recv().unwrap();

    let mut app = test_app(Session::Local(mux.clone()));
    assert!(app.forward_pty_mouse_motion_if_uncontended(
        (surface.id, Rect { x: 2, y: 3, width: 20, height: 8 }),
        (6, 5),
        None,
        KeyModifiers::NONE,
        false,
        None,
    ));
    assert!(app.forward_pty_mouse_motion_if_uncontended(
        (surface.id, Rect { x: 2, y: 3, width: 20, height: 8 }),
        (7, 5),
        Some(GhosttyMouseButton::Left),
        KeyModifiers::NONE,
        true,
        None,
    ));

    release_tx.send(()).unwrap();
    holder.join().unwrap();
    mux.close_surface(surface.id).unwrap();
}

#[test]
fn pty_mouse_press_does_not_wait_for_terminal_parsing() {
    let mux = Mux::new(
        "mouse-press-lock-test",
        SurfaceOptions {
            command: Some(vec!["/bin/sh".to_string(), "-c".to_string(), "sleep 30".to_string()]),
            ..Default::default()
        },
    );
    let surface = mux.new_workspace(None, Some((20, 8))).unwrap();
    surface.with_terminal(|terminal| terminal.vt_write(b"\x1b[?1002h\x1b[?1006h"));
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

    let held_surface = surface.clone();
    let (locked_tx, locked_rx) = std::sync::mpsc::channel();
    let (release_tx, release_rx) = std::sync::mpsc::channel();
    let holder = std::thread::spawn(move || {
        held_surface.with_terminal(|_| {
            locked_tx.send(()).unwrap();
            release_rx.recv().unwrap();
        });
    });
    locked_rx.recv().unwrap();

    let (result_tx, result_rx) = std::sync::mpsc::channel();
    let input = std::thread::spawn(move || {
        result_tx
            .send(app.begin_pty_mouse_drag(
                content.x + 4,
                content.y + 2,
                MouseButton::Left,
                KeyModifiers::NONE,
            ))
            .unwrap();
    });
    let result = result_rx.recv_timeout(Duration::from_millis(250));
    release_tx.send(()).unwrap();
    holder.join().unwrap();
    input.join().unwrap();

    assert_eq!(result.unwrap(), PtyMousePressResult::Started);
    mux.close_surface(surface.id).unwrap();
}

#[test]
fn disabled_mouse_snapshot_does_not_consume_press() {
    let mux = Mux::new("disabled-mouse-press-test", SurfaceOptions::default());
    let surface = mux.new_workspace(None, Some((20, 8))).unwrap();
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
    app.focus = FocusTarget::WorkspaceRail;

    assert_eq!(
        app.begin_pty_mouse_drag(
            content.x + 4,
            content.y + 2,
            MouseButton::Left,
            KeyModifiers::NONE,
        ),
        PtyMousePressResult::NotOwned
    );
    assert!(app.workspace_sidebar_focused());
    assert!(app.drag.is_none());
    assert!(app.encode_buf.is_empty());
    mux.close_surface(surface.id).unwrap();
}

#[test]
fn deferred_terminal_press_fails_closed_when_live_mouse_ownership_changes() {
    let (mux, surface) = test_mux("deferred-mouse-ownership-test", None);
    let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
    app.replace_tree(app.session.tree());
    app.sidebar_visible = false;
    app.sync_layout((40, 15));
    while app.session.has_pending_mutations() {
        app.handle(events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();
    }
    let mut terminal = Terminal::new(TestBackend::new(40, 15)).unwrap();
    app.render_action(&mut terminal, RenderAction::Draw).unwrap();
    let content = app.pane_areas[0].content;
    let press = MouseEvent {
        kind: MouseEventKind::Down(MouseButton::Left),
        column: content.x + 4,
        row: content.y + 2,
        modifiers: KeyModifiers::NONE,
    };

    app.pointer_route_phase = PointerRoutePhase::DrawPending;
    app.handle(AppEvent::Input(Event::Mouse(press))).unwrap();
    assert_eq!(app.deferred_input.len(), 1);
    assert!(app.drag.is_none());
    assert!(app.selection.is_none());

    surface.with_terminal(|terminal| terminal.vt_write(b"\x1b[?1000h\x1b[?1006h"));
    app.pointer_route_phase = PointerRoutePhase::Fresh;
    app.replay_deferred_input().unwrap();

    assert!(app.deferred_input.is_empty());
    assert!(
        app.drag.is_none(),
        "a press rendered for selection must not become PTY mouse input after mode changes"
    );
    assert!(app.selection.is_none());
    assert!(app.encode_buf.is_empty());
    mux.close_surface(surface.id).unwrap();
}

#[test]
fn deferred_terminal_press_cannot_retarget_repainted_content() {
    let mux = Mux::new(
        "deferred-terminal-content-generation-test",
        SurfaceOptions {
            command: Some(vec![
                "/bin/sh".to_string(),
                "-c".to_string(),
                "IFS= read -r _; printf replacement; sleep 30".to_string(),
            ]),
            ..Default::default()
        },
    );
    let surface = mux.new_workspace(Some("work".to_string()), Some((20, 8))).unwrap();
    let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
    app.replace_tree(app.session.tree());
    app.sidebar_visible = false;
    app.sync_layout((40, 15));
    while app.session.has_pending_mutations() {
        app.handle(events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();
    }
    let mut terminal = Terminal::new(TestBackend::new(40, 15)).unwrap();
    app.render_action(&mut terminal, RenderAction::Draw).unwrap();
    let content = app.pane_areas[0].content;
    let press = MouseEvent {
        kind: MouseEventKind::Down(MouseButton::Left),
        column: content.x + 4,
        row: content.y + 2,
        modifiers: KeyModifiers::NONE,
    };

    app.pointer_route_phase = PointerRoutePhase::DrawPending;
    app.handle(AppEvent::Input(Event::Mouse(press))).unwrap();
    assert_eq!(app.deferred_input.len(), 1);
    assert!(app.drag.is_none());

    let rendered_generation =
        match app.rendered_pointer_frame.pane_content_generations.get(&surface.id) {
            Some(PaneContentGeneration::Terminal(generation)) => *generation,
            generation => panic!("expected rendered terminal generation, got {generation:?}"),
        };
    surface.write_bytes(b"repaint\n").unwrap();
    let deadline = Instant::now() + Duration::from_secs(1);
    loop {
        let generation = match surface.try_pointer_snapshot() {
            Some(PointerSnapshotProbe::Ready(snapshot)) => snapshot.content_generation,
            Some(PointerSnapshotProbe::Contended) => rendered_generation,
            None => panic!("expected PTY pointer snapshot"),
        };
        if generation != rendered_generation {
            break;
        }
        assert!(Instant::now() < deadline, "replacement output did not advance the frame");
        std::thread::yield_now();
    }
    let repaint = app.handle(AppEvent::Mux(MuxEvent::SurfaceOutput(surface.id))).unwrap();
    app.render_action(&mut terminal, repaint).unwrap();
    assert_eq!(app.pointer_route_phase, PointerRoutePhase::Fresh);
    app.replay_deferred_input().unwrap();

    assert!(
        app.drag.is_none(),
        "a press rendered for old terminal content must not arm selection on its replacement"
    );
    assert!(app.selection.is_none());
    mux.close_surface(surface.id).unwrap();
}

#[test]
fn deferred_untracked_wheel_fails_closed_when_screen_semantics_change() {
    for (name, initial, transition, expected_screen) in [
        ("deferred-wheel-primary-to-alternate", None, b"\x1b[?1049h".as_slice(), Screen::Primary),
        (
            "deferred-wheel-alternate-to-primary",
            Some(b"\x1b[?1049h".as_slice()),
            b"\x1b[?1049l".as_slice(),
            Screen::Alternate,
        ),
    ] {
        let (mux, surface) = test_mux(name, None);
        if let Some(initial) = initial {
            surface.with_terminal(|terminal| terminal.vt_write(initial));
        }
        let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
        app.replace_tree(app.session.tree());
        app.sidebar_visible = false;
        app.sync_layout((40, 15));
        while app.session.has_pending_mutations() {
            app.handle(events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();
        }
        let mut terminal = Terminal::new(TestBackend::new(40, 15)).unwrap();
        app.render_action(&mut terminal, RenderAction::Draw).unwrap();
        let content = app.pane_areas[0].content;
        let wheel = MouseEvent {
            kind: MouseEventKind::ScrollUp,
            column: content.x + 4,
            row: content.y + 2,
            modifiers: KeyModifiers::NONE,
        };
        assert_eq!(
            surface.with_terminal(|terminal| terminal.active_screen()),
            Some(expected_screen)
        );

        app.pointer_route_phase = PointerRoutePhase::DrawPending;
        app.handle(AppEvent::Input(Event::Mouse(wheel))).unwrap();
        assert_eq!(app.deferred_input.len(), 1);

        surface.with_terminal(|terminal| terminal.vt_write(transition));
        app.pointer_route_phase = PointerRoutePhase::Fresh;
        assert_eq!(
            app.replay_deferred_input().unwrap(),
            RenderAction::None,
            "a wheel rendered for one screen's semantics must not run against the other"
        );
        assert!(app.deferred_input.is_empty());
        mux.close_surface(surface.id).unwrap();
    }
}

#[test]
fn immediate_terminal_press_fails_closed_before_surface_output_marks_route_stale() {
    let (mux, surface) = test_mux("immediate-mouse-semantics-test", None);
    let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
    app.replace_tree(app.session.tree());
    app.sidebar_visible = false;
    app.sync_layout((40, 15));
    while app.session.has_pending_mutations() {
        app.handle(events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();
    }
    let mut terminal = Terminal::new(TestBackend::new(40, 15)).unwrap();
    app.render_action(&mut terminal, RenderAction::Draw).unwrap();
    let content = app.pane_areas[0].content;
    assert_eq!(app.pointer_route_phase, PointerRoutePhase::Fresh);
    assert_eq!(surface.with_terminal(|terminal| terminal.mouse_tracking()), Some(false));

    // Change only the mouse protocol. Reporting remains disabled, so the
    // event-specific route still looks cmux-owned even though its encoder
    // semantics no longer match the committed frame.
    surface.with_terminal(|terminal| terminal.vt_write(b"\x1b[?1006h"));
    assert_eq!(surface.with_terminal(|terminal| terminal.mouse_tracking()), Some(false));
    assert_eq!(
        app.pointer_route_phase,
        PointerRoutePhase::Fresh,
        "the queued SurfaceOutput has not marked the rendered route stale yet"
    );

    let action = app
        .handle(AppEvent::Input(Event::Mouse(MouseEvent {
            kind: MouseEventKind::Down(MouseButton::Left),
            column: content.x + 4,
            row: content.y + 2,
            modifiers: KeyModifiers::NONE,
        })))
        .unwrap();

    assert_eq!(
        action,
        RenderAction::None,
        "an immediate press must fail closed when its rendered semantic token changed"
    );
    assert!(app.drag.is_none());
    assert!(app.selection.is_none());
    assert!(app.encode_buf.is_empty());
    mux.close_surface(surface.id).unwrap();
}

#[test]
fn immediate_terminal_press_rejects_content_changed_before_surface_output() {
    let (mux, surface) = test_mux("immediate-mouse-content-test", None);
    surface.with_terminal(|terminal| {
        for index in 0..100 {
            terminal.vt_write(format!("line {index}\r\n").as_bytes());
        }
    });
    let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
    app.replace_tree(app.session.tree());
    app.sidebar_visible = false;
    app.sync_layout((40, 15));
    while app.session.has_pending_mutations() {
        app.handle(events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();
    }
    let mut terminal = Terminal::new(TestBackend::new(40, 15)).unwrap();
    app.render_action(&mut terminal, RenderAction::Draw).unwrap();
    let content = app.pane_areas[0].content;
    assert_eq!(app.pointer_route_phase, PointerRoutePhase::Fresh);

    surface.scroll_delta(-3).unwrap();
    assert_eq!(
        app.pointer_route_phase,
        PointerRoutePhase::Fresh,
        "the queued output event has not marked the rendered route stale yet"
    );

    let action = app
        .handle(AppEvent::Input(Event::Mouse(MouseEvent {
            kind: MouseEventKind::Down(MouseButton::Left),
            column: content.x + 4,
            row: content.y + 2,
            modifiers: KeyModifiers::NONE,
        })))
        .unwrap();

    assert_eq!(
        action,
        RenderAction::None,
        "a click must not select terminal content that has changed since the rendered frame"
    );
    assert!(app.drag.is_none());
    assert!(app.selection.is_none());
    mux.close_surface(surface.id).unwrap();
}

#[test]
fn immediate_menu_press_survives_content_changed_before_surface_output() {
    let (mux, surface) = test_mux("immediate-menu-content-test", None);
    surface.with_terminal(|terminal| {
        for index in 0..100 {
            terminal.vt_write(format!("line {index}\r\n").as_bytes());
        }
    });
    let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
    app.replace_tree(app.session.tree());
    app.sidebar_visible = false;
    app.sync_layout((40, 15));
    while app.session.has_pending_mutations() {
        app.handle(events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();
    }
    let mut terminal = Terminal::new(TestBackend::new(40, 15)).unwrap();
    app.render_action(&mut terminal, RenderAction::Draw).unwrap();
    let content = app.pane_areas[0].content;
    assert_eq!(app.pointer_route_phase, PointerRoutePhase::Fresh);

    // Terminal content moves after the frame committed, exactly like PTY
    // output landing between a paint and the user's press.
    surface.scroll_delta(-3).unwrap();
    assert_eq!(
        app.pointer_route_phase,
        PointerRoutePhase::Fresh,
        "the queued output event has not marked the rendered route stale yet"
    );

    app.handle(AppEvent::Input(Event::Mouse(MouseEvent {
        kind: MouseEventKind::Down(MouseButton::Right),
        column: content.x + 4,
        row: content.y + 2,
        modifiers: KeyModifiers::SHIFT,
    })))
    .unwrap();

    assert!(
        app.menu.is_some(),
        "a cmux-owned context menu press must not be swallowed by terminal content \
         admission: it never forwards bytes to the terminal application"
    );
    assert!(app.deferred_input.is_empty());
    mux.close_surface(surface.id).unwrap();
}

#[test]
fn deferred_menu_press_survives_content_repaint_before_replay() {
    let (mux, surface) = test_mux("deferred-menu-content-test", None);
    surface.with_terminal(|terminal| {
        for index in 0..100 {
            terminal.vt_write(format!("line {index}\r\n").as_bytes());
        }
    });
    let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
    app.replace_tree(app.session.tree());
    app.sidebar_visible = false;
    app.sync_layout((40, 15));
    while app.session.has_pending_mutations() {
        app.handle(events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();
    }
    let mut terminal = Terminal::new(TestBackend::new(40, 15)).unwrap();
    app.render_action(&mut terminal, RenderAction::Draw).unwrap();
    let content = app.pane_areas[0].content;

    app.pointer_route_phase = PointerRoutePhase::DrawPending;
    app.handle(AppEvent::Input(Event::Mouse(MouseEvent {
        kind: MouseEventKind::Down(MouseButton::Right),
        column: content.x + 4,
        row: content.y + 2,
        modifiers: KeyModifiers::SHIFT,
    })))
    .unwrap();
    assert_eq!(app.deferred_input.len(), 1);
    assert!(app.menu.is_none());

    // Content changes while the press waits for its paint, so the
    // repainted frame carries a newer terminal content generation than
    // the one recorded when the press was deferred.
    surface.scroll_delta(-3).unwrap();
    let repaint = app.handle(AppEvent::Mux(MuxEvent::SurfaceOutput(surface.id))).unwrap();
    app.render_action(&mut terminal, repaint).unwrap();
    assert_eq!(app.pointer_route_phase, PointerRoutePhase::Fresh);
    app.replay_deferred_input().unwrap();

    assert!(app.deferred_input.is_empty());
    assert!(
        app.menu.is_some(),
        "a replayed cmux-owned context menu press must not be dropped because terminal \
         content changed under it while it waited for the paint"
    );
    mux.close_surface(surface.id).unwrap();
}

#[test]
fn immediate_untracked_wheel_fails_closed_before_surface_output_marks_route_stale() {
    let (mux, surface) = test_mux("immediate-wheel-semantics-test", None);
    let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
    app.replace_tree(app.session.tree());
    app.sidebar_visible = false;
    app.sync_layout((40, 15));
    while app.session.has_pending_mutations() {
        app.handle(events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();
    }
    let mut terminal = Terminal::new(TestBackend::new(40, 15)).unwrap();
    app.render_action(&mut terminal, RenderAction::Draw).unwrap();
    let content = app.pane_areas[0].content;
    assert_eq!(app.pointer_route_phase, PointerRoutePhase::Fresh);

    surface.with_terminal(|terminal| terminal.vt_write(b"\x1b[?1049h"));
    assert_eq!(
        app.pointer_route_phase,
        PointerRoutePhase::Fresh,
        "the queued SurfaceOutput has not marked the rendered route stale yet"
    );

    let action = app
        .handle(AppEvent::Input(Event::Mouse(MouseEvent {
            kind: MouseEventKind::ScrollUp,
            column: content.x + 4,
            row: content.y + 2,
            modifiers: KeyModifiers::NONE,
        })))
        .unwrap();

    assert_eq!(
        action,
        RenderAction::None,
        "an immediate wheel must not cross from host scrollback into alternate-screen arrows"
    );
    assert!(app.encode_buf.is_empty());
    mux.close_surface(surface.id).unwrap();
}

#[test]
fn contended_terminal_semantics_retain_discrete_press_for_replay() {
    let (mux, surface) = test_mux("contended-mouse-semantics-test", None);
    surface.with_terminal(|terminal| terminal.vt_write(b"\x1b[?1000h\x1b[?1006h"));
    let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
    app.replace_tree(app.session.tree());
    app.sidebar_visible = false;
    app.sync_layout((40, 15));
    while app.session.has_pending_mutations() {
        app.handle(events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();
    }
    let mut terminal = Terminal::new(TestBackend::new(40, 15)).unwrap();
    app.render_action(&mut terminal, RenderAction::Draw).unwrap();
    let content = app.pane_areas[0].content;
    let press = MouseEvent {
        kind: MouseEventKind::Down(MouseButton::Left),
        column: content.x + 4,
        row: content.y + 2,
        modifiers: KeyModifiers::NONE,
    };

    let held_surface = surface.clone();
    let (locked_tx, locked_rx) = std::sync::mpsc::channel();
    let (release_tx, release_rx) = std::sync::mpsc::channel();
    let holder = std::thread::spawn(move || {
        held_surface.with_terminal(|_| {
            locked_tx.send(()).unwrap();
            release_rx.recv().unwrap();
        });
    });
    locked_rx.recv_timeout(Duration::from_secs(1)).unwrap();

    let action = app.handle(AppEvent::Input(Event::Mouse(press))).unwrap();
    let queued = app.deferred_input.len();
    release_tx.send(()).unwrap();
    holder.join().unwrap();
    assert_eq!(queued, 1, "ordinary terminal lock contention must retain a discrete press");
    assert_eq!(
        action,
        RenderAction::None,
        "lock contention must schedule replay without synchronously repainting the locked terminal"
    );

    app.render_action(&mut terminal, action).unwrap();
    app.replay_deferred_input().unwrap();

    assert!(app.deferred_input.is_empty());
    assert!(
        matches!(app.drag, Some(Drag::PtyMouse { surface: id, .. }) if id == surface.id),
        "the retained press must replay against the same rendered terminal"
    );
    app.cancel_pty_mouse_drag();
    mux.close_surface(surface.id).unwrap();
}

#[test]
fn physical_release_queues_behind_a_contended_terminal_press() {
    let (mux, surface) = test_mux("contended-mouse-release-order-test", None);
    surface.with_terminal(|terminal| terminal.vt_write(b"\x1b[?1000h\x1b[?1006h"));
    let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
    app.replace_tree(app.session.tree());
    app.sidebar_visible = false;
    app.sync_layout((40, 15));
    while app.session.has_pending_mutations() {
        app.handle(events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();
    }
    let mut terminal = Terminal::new(TestBackend::new(40, 15)).unwrap();
    app.render_action(&mut terminal, RenderAction::Draw).unwrap();
    let content = app.pane_areas[0].content;
    let press = MouseEvent {
        kind: MouseEventKind::Down(MouseButton::Left),
        column: content.x + 4,
        row: content.y + 2,
        modifiers: KeyModifiers::NONE,
    };

    let held_surface = surface.clone();
    let (locked_tx, locked_rx) = std::sync::mpsc::channel();
    let (release_tx, release_rx) = std::sync::mpsc::channel();
    let holder = std::thread::spawn(move || {
        held_surface.with_terminal(|_| {
            locked_tx.send(()).unwrap();
            release_rx.recv().unwrap();
        });
    });
    locked_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    app.handle(AppEvent::Input(Event::Mouse(press))).unwrap();
    release_tx.send(()).unwrap();
    holder.join().unwrap();
    assert_eq!(app.deferred_input.len(), 1);

    app.handle(AppEvent::Input(Event::Mouse(MouseEvent {
        kind: MouseEventKind::Up(MouseButton::Left),
        ..press
    })))
    .unwrap();

    assert_eq!(
        app.deferred_input.len(),
        2,
        "the physical release must retain its order behind the deferred press"
    );
    assert!(app.drag.is_none());
    let replay_action = app.replay_deferred_input().unwrap();
    app.render_action(&mut terminal, replay_action).unwrap();
    app.replay_deferred_input().unwrap();
    assert!(app.deferred_input.is_empty());
    assert!(app.drag.is_none(), "the replayed release must close the replayed press");
    assert!(!app.active_pointer_buttons.contains(&MouseButton::Left));
    mux.close_surface(surface.id).unwrap();
}

#[test]
fn guarded_mouse_encoding_rejects_a_changed_terminal_snapshot() {
    let (mux, surface) = test_mux("atomic-mouse-semantics-test", None);
    let app = test_app(Session::Local(mux.clone()));
    let handle = app.session.surface(surface.id).expect("local PTY handle");
    let expected = surface
        .with_terminal(|terminal| terminal.pointer_semantic_snapshot())
        .expect("PTY terminal snapshot");
    surface.with_terminal(|terminal| terminal.vt_write(b"\x1b[?1003h\x1b[?1006h"));

    let mut output = Vec::new();
    let encoded = handle.encode_mouse_if_semantics(expected, test_mouse_motion(), &mut output);

    assert!(
        matches!(encoded, Some(GuardedMouseEncode::SemanticsChanged)),
        "a stale rendered token must fail at the encoding boundary"
    );
    assert!(output.is_empty());
    mux.close_surface(surface.id).unwrap();
}

#[test]
fn guarded_mouse_encoding_rejects_changed_terminal_geometry() {
    let (mux, surface) = test_mux("atomic-mouse-geometry-test", None);
    let app = test_app(Session::Local(mux.clone()));
    let handle = app.session.surface(surface.id).expect("local PTY handle");
    let expected = surface
        .with_terminal(|terminal| terminal.pointer_semantic_snapshot())
        .expect("PTY terminal snapshot");
    surface
        .with_terminal(|terminal| {
            terminal.resize(terminal.cols().saturating_add(1), terminal.rows(), 1, 1)
        })
        .expect("PTY terminal")
        .expect("terminal resize");

    let mut output = Vec::new();
    let encoded = handle.encode_mouse_if_semantics(expected, test_mouse_motion(), &mut output);

    assert!(
        matches!(encoded, Some(GuardedMouseEncode::SemanticsChanged)),
        "a pointer event must not use cell geometry from an older rendered frame"
    );
    assert!(output.is_empty());
    mux.close_surface(surface.id).unwrap();
}

#[test]
fn captured_pty_motion_rejects_geometry_changed_since_press() {
    let (mux, surface) = test_mux("captured-mouse-geometry-test", None);
    surface.with_terminal(|terminal| terminal.vt_write(b"\x1b[?1003h\x1b[?1006h"));
    let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
    app.replace_tree(app.session.tree());
    app.sidebar_visible = false;
    app.sync_layout((40, 15));
    while app.session.has_pending_mutations() {
        app.handle(events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();
    }
    let mut terminal = Terminal::new(TestBackend::new(40, 15)).unwrap();
    app.render_action(&mut terminal, RenderAction::Draw).unwrap();
    let content = app.pane_areas[0].content;
    let press = MouseEvent {
        kind: MouseEventKind::Down(MouseButton::Left),
        column: content.x + 4,
        row: content.y + 2,
        modifiers: KeyModifiers::NONE,
    };
    app.handle(AppEvent::Input(Event::Mouse(press))).unwrap();
    assert!(matches!(app.drag, Some(Drag::PtyMouse { .. })));

    app.encode_buf.clear();
    surface
        .with_terminal(|terminal| {
            terminal.resize(terminal.cols().saturating_add(1), terminal.rows(), 1, 1)
        })
        .expect("PTY terminal")
        .expect("terminal resize");
    app.handle(AppEvent::Input(Event::Mouse(MouseEvent {
        kind: MouseEventKind::Drag(MouseButton::Left),
        column: press.column + 1,
        ..press
    })))
    .unwrap();

    assert!(
        app.encode_buf.is_empty(),
        "captured motion must retain the press frame's terminal geometry guard"
    );
    assert!(matches!(app.drag, Some(Drag::PtyMouse { .. })));
    app.cancel_pty_mouse_drag();
    mux.close_surface(surface.id).unwrap();
}

#[test]
fn terminal_pointer_motion_encoding_stays_inline() {
    let (mux, surface) = test_mux("inline-mouse-motion-test", None);
    surface.with_terminal(|terminal| terminal.vt_write(b"\x1b[?1003h\x1b[?1006h"));
    let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
    app.replace_tree(app.session.tree());
    app.sidebar_visible = false;
    app.sync_layout((40, 15));
    while app.session.has_pending_mutations() {
        app.handle(events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();
    }
    let mut terminal = Terminal::new(TestBackend::new(40, 15)).unwrap();
    app.render_action(&mut terminal, RenderAction::Draw).unwrap();
    let content = app.pane_areas[0].content;
    let motion = MouseEvent {
        kind: MouseEventKind::Moved,
        column: content.x + 4,
        row: content.y + 2,
        modifiers: KeyModifiers::NONE,
    };
    let route = app.rendered_pointer_frame.route_for_mouse(&motion);
    let TerminalPointerAdmissionResult::Ready(TerminalPointerAdmission {
        encoding: TerminalPointerEncoding::Single(bytes),
        ..
    }) = app.terminal_pointer_admission_for_route(&route, &motion, None)
    else {
        panic!("tracked motion should produce terminal bytes");
    };

    assert!(!bytes.is_empty());
    assert!(!bytes.spilled(), "ordinary terminal motion must stay in the inline PTY buffer");
    mux.close_surface(surface.id).unwrap();
}
