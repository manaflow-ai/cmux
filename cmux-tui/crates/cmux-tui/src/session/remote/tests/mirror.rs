//! Local terminal mirror replay: cursor, mouse, and color state.

use super::*;

#[test]
fn resolved_output_colors_do_not_author_cursor_style() {
    let (session, surface) = test_unleased_view_surface(12);

    session.handle_line(json!({
        "event": "output",
        "surface": 12,
        "data": base64::engine::general_purpose::STANDARD.encode(b"prompt"),
        "colors": {
            "fg": "#eeeeee",
            "bg": "#171b2e",
            "cursor": "#ffee00",
            "cursor_style": "bar",
            "cursor_blink": true,
            "palette": {},
        },
    }));

    assert!(
        !surface.cursor_style_authored(),
        "daemon-resolved cursor colors must not be treated as inner-PTY authored"
    );
}

#[test]
fn local_mirror_resize_preserves_cursor_authorship() {
    let (_session, surface) = test_unleased_view_surface(9);
    surface.scan_cursor_provenance(b"\x1b[3 q");
    assert!(surface.cursor_style_authored());
    surface.apply_stream_resize(100, 30, None, &[]).unwrap();
    assert!(
        surface.cursor_style_authored(),
        "a client-side resize replays the same application state"
    );
}

#[test]
fn daemon_replay_restores_inner_mouse_tracking_to_the_mirror() {
    let (_session, surface) = test_unleased_view_surface(11);
    assert!(!surface.term.lock().unwrap().mouse_tracking());
    surface
        .apply_stream_resize_with_colors(80, 24, Some(b"\x1b[?1002h"), &[], None, None, &[])
        .unwrap();
    assert!(
        surface.term.lock().unwrap().mouse_tracking(),
        "reattach replay must restore the inner mouse mode that drives host capture mirroring"
    );
}

/// Same contract against the daemon's REAL replay bytes, not a hand-written
/// DECSET: the terminal host serializes attach state with the bounded
/// theme-portable formatter, so this pins that its output still carries the
/// mouse-tracking modes and that they survive the client's replay apply all
/// the way to the pointer-semantics probe the App's host-capture mirroring
/// reads.
#[test]
fn daemon_theme_portable_replay_restores_mouse_tracking_to_the_attach_probe() {
    let mut host = Terminal::new(80, 24, 100, Callbacks::default()).unwrap();
    // btop-shaped inner state: alt screen plus button-motion tracking with
    // SGR and urxvt encodings, entered before any client attached.
    host.vt_write(b"\x1b[?1049h\x1b[?1002h\x1b[?1015h\x1b[?1006h");
    assert!(host.mouse_tracking());
    let replay = host
        .vt_replay_bounded_theme_portable_with_aliases(REMOTE_CONTROL_MESSAGE_MAX_BYTES)
        .unwrap();

    let (_session, surface) = test_unleased_view_surface(12);
    assert!(!surface.term.lock().unwrap().mouse_tracking());
    surface
        .apply_stream_resize_with_colors(
            80,
            24,
            Some(&replay.bytes),
            &replay.kitty_image_aliases,
            Some(replay.kitty_state),
            None,
            &replay.pending_sequence,
        )
        .unwrap();
    match surface.try_pointer_semantics() {
        PointerSemanticProbe::Ready(semantics) => assert!(
            semantics.mouse_tracking,
            "the attach probe must observe the replay-restored mouse modes"
        ),
        PointerSemanticProbe::Contended => panic!("uncontended terminal probe blocked"),
    }
}

fn forwarded_left_press_bytes(surface: &RemoteSurface) -> Vec<u8> {
    let input = MouseInput {
        action: ghostty_vt::MouseAction::Press,
        button: Some(ghostty_vt::MouseButton::Left),
        mods: Mods::default(),
        position: (35.5, 20.5),
        screen_size: (80, 24),
        cell_size: (1, 1),
        any_button_pressed: true,
    };
    let mut out = Vec::new();
    surface.encode_mouse(input, &mut out).expect("uncontended encoders").unwrap();
    out
}

/// Scoped reattach, real daemon serialization: the terminal host encodes
/// attach state with the bounded theme-portable formatter. When the inner
/// app (btop) enabled 1002h, 1015h, 1006h with SGR last, a click forwarded
/// after reattach must still be re-encoded for the inner PTY as SGR, not
/// urxvt. btop parses only SGR responses, so urxvt means dead clicks.
#[test]
fn daemon_replay_keeps_forwarded_clicks_sgr_when_inner_app_set_sgr_last() {
    let mut host = Terminal::new(80, 24, 100, Callbacks::default()).unwrap();
    host.vt_write(b"\x1b[?1049h\x1b[?1002h\x1b[?1015h\x1b[?1006h");
    let replay = host
        .vt_replay_bounded_theme_portable_with_aliases(REMOTE_CONTROL_MESSAGE_MAX_BYTES)
        .unwrap();

    let (_session, surface) = test_unleased_view_surface(13);
    surface
        .apply_stream_resize_with_colors(
            80,
            24,
            Some(&replay.bytes),
            &replay.kitty_image_aliases,
            Some(replay.kitty_state),
            None,
            &replay.pending_sequence,
        )
        .unwrap();

    assert_eq!(
        forwarded_left_press_bytes(&surface),
        b"\x1b[<0;36;21M",
        "reattach replay flipped the forwarded click encoding away from SGR"
    );
}

/// A fixed daemon appends the active selector after its numeric flag dump,
/// so an application that deliberately selected urxvt last keeps it.
#[test]
fn daemon_replay_keeps_a_deliberate_urxvt_choice() {
    let mut host = Terminal::new(80, 24, 100, Callbacks::default()).unwrap();
    host.vt_write(b"\x1b[?1002h\x1b[?1006h\x1b[?1015h");
    let replay = host
        .vt_replay_bounded_theme_portable_with_aliases(REMOTE_CONTROL_MESSAGE_MAX_BYTES)
        .unwrap();

    let (_session, surface) = test_unleased_view_surface(15);
    surface
        .apply_stream_resize_with_colors(
            80,
            24,
            Some(&replay.bytes),
            &replay.kitty_image_aliases,
            Some(replay.kitty_state),
            None,
            &replay.pending_sequence,
        )
        .unwrap();

    assert_eq!(
        forwarded_left_press_bytes(&surface),
        b"\x1b[32;36;21M",
        "an application that chose urxvt last must keep urxvt after reattach"
    );
}

/// Older daemons serialize mouse DECSETs as a numeric flag dump and lose
/// the original last-set order. Both SGR-last and urxvt-last applications
/// can produce these bytes, so the client must apply them as written. A
/// guessed preference would corrupt one of the two valid meanings.
#[test]
fn ambiguous_legacy_flag_dump_preserves_replayed_mouse_format() {
    let (_session, surface) = test_unleased_view_surface(14);
    surface
        .apply_stream_resize_with_colors(
            80,
            24,
            Some(b"\x1b[?1002h\x1b[?1006h\x1b[?1015h"),
            &[],
            None,
            None,
            &[],
        )
        .unwrap();

    assert_eq!(
        forwarded_left_press_bytes(&surface),
        b"\x1b[32;36;21M",
        "ambiguous legacy replay must preserve its last selector instead of guessing SGR"
    );
}

/// The daemon replayed while its parser was inside an SGR. The client
/// writes its color sidecar after the replay, so the incomplete sequence
/// must come last for the next output to complete it.
#[test]
fn daemon_replay_resumes_its_pending_sequence_after_the_colors() {
    let mut host = Terminal::new(80, 24, 100, Callbacks::default()).unwrap();
    host.vt_write(b"before \x1b[1;3");
    let replay = host
        .vt_replay_bounded_theme_portable_with_aliases(REMOTE_CONTROL_MESSAGE_MAX_BYTES)
        .unwrap();
    assert_eq!(replay.pending_sequence, b"\x1b[1;3");
    let colors = RemoteTerminalColors {
        fg: Some(Rgb { r: 1, g: 2, b: 3 }),
        bg: None,
        cursor: None,
        cursor_style: Some(CursorShape::Bar),
        cursor_blink: Some(false),
        palette: [None; 256],
    };

    let (_session, surface) = test_unleased_view_surface(15);
    surface
        .apply_stream_resize_with_colors(
            80,
            24,
            Some(&replay.bytes),
            &replay.kitty_image_aliases,
            Some(replay.kitty_state),
            Some(&colors),
            &replay.pending_sequence,
        )
        .unwrap();
    let mut term = surface.term.lock().unwrap();
    term.vt_write(b"1mred\x1b[0m after");
    assert_eq!(term.viewport_text().unwrap().lines().next(), Some("before red after"));
    assert_eq!(term.effective_colors().0, Some(Rgb { r: 1, g: 2, b: 3 }));
}

#[test]
fn resolved_cursor_colors_force_the_active_screen_across_alt_screen_modes() {
    for mode in [47, 1047, 1049] {
        let mut terminal = Terminal::new(12, 3, 100, Callbacks::default()).unwrap();
        terminal.vt_write(b"\x1b[5 q");
        terminal.vt_write(format!("\x1b[?{mode}h\x1b[4 q").as_bytes());
        assert_eq!(terminal.effective_cursor_visual().unwrap(), (CursorShape::Underline, false));

        let colors = RemoteTerminalColors {
            fg: None,
            bg: None,
            cursor: None,
            cursor_style: Some(CursorShape::Bar),
            cursor_blink: Some(false),
            palette: [None; 256],
        };
        apply_terminal_colors(&mut terminal, &colors);
        assert_eq!(
            terminal.effective_cursor_visual().unwrap(),
            (CursorShape::Bar, false),
            "resolved cursor did not replace the active screen for mode {mode}"
        );

        terminal.vt_write(format!("\x1b[?{mode}l").as_bytes());
        let primary_colors = RemoteTerminalColors {
            cursor_style: Some(CursorShape::Underline),
            cursor_blink: Some(true),
            ..colors
        };
        apply_terminal_colors(&mut terminal, &primary_colors);
        assert_eq!(
            terminal.effective_cursor_visual().unwrap(),
            (CursorShape::Underline, true),
            "resolved cursor did not replace the restored primary screen for mode {mode}"
        );
    }
}

#[test]
fn legacy_cursor_absence_preserves_raw_decscusr_and_mode_12() {
    let mut terminal = Terminal::new(12, 3, 100, Callbacks::default()).unwrap();
    terminal.vt_write(b"\x1b[3 q\x1b[?12l");
    let legacy = RemoteTerminalColors {
        fg: None,
        bg: None,
        cursor: None,
        cursor_style: None,
        cursor_blink: None,
        palette: [None; 256],
    };

    apply_terminal_colors(&mut terminal, &legacy);
    assert_eq!(terminal.effective_cursor_visual().unwrap(), (CursorShape::Underline, false));
}

#[cfg(unix)]
#[test]
fn initial_attach_resolves_sparse_source_palette_before_rendering() {
    let (client, _server) = UnixStream::pair().unwrap();
    let session = socket_test_session(client);
    let surface = Arc::new(RemoteSurface {
        id: 7,
        kind: SurfaceKind::Pty,
        term: Mutex::new(Terminal::new(12, 4, 100, Callbacks::default()).unwrap()),
        mouse_encoders: Mutex::new(MouseEncoders::new().unwrap()),
        cursor_provenance: Mutex::new(CursorStyleProvenance::default()),
        dirty: AtomicBool::new(false),
        geometry_lifecycle: Mutex::new(()),
        cell_pixels: Mutex::new((8, 16)),
        geometry_test_hook: Mutex::new(None),
        content_generation: AtomicU64::new(1),
        reported_size: Mutex::new(None),
        browser: Mutex::new(RemoteBrowserState::default()),
    });
    session.surfaces.lock().unwrap().insert(7, surface.clone());

    session.handle_line(json!({
        "event": "vt-state",
        "surface": 7,
        "cols": 12,
        "rows": 4,
        "data": base64::engine::general_purpose::STANDARD.encode(b"\x1b[31mX"),
        "colors": {
            "fg": "#eeeeee",
            "bg": "#101010",
            "cursor": "#eeeeee",
            "cursor_style": "block",
            "cursor_blink": true,
            "palette": {"1": "#ff3562"},
        },
    }));

    let mut terminal = surface.term.lock().unwrap();
    assert_eq!(terminal.color_overrides().palette[1], Some(Rgb { r: 0xff, g: 0x35, b: 0x62 }));
    let mut render = RenderState::new().unwrap();
    render.update(&mut terminal).unwrap();
    assert!(render.palette_overridden(1));
    assert_eq!(render.palette_color(1), Rgb { r: 0xff, g: 0x35, b: 0x62 });
    let frame = render.build_frame().unwrap();
    let cell = &frame.styled_row(0).unwrap()[0];
    assert_eq!(cell.fg, ColorSpec::Palette(1));
    assert_eq!(cell.resolved_fg, Some(Rgb { r: 0xff, g: 0x35, b: 0x62 }));
}

#[cfg(unix)]
#[test]
fn colors_changed_replaces_complete_sparse_palette_state() {
    let (client, _server) = UnixStream::pair().unwrap();
    let session = socket_test_session(client);
    let surface = Arc::new(RemoteSurface {
        id: 7,
        kind: SurfaceKind::Pty,
        term: Mutex::new(Terminal::new(12, 4, 100, Callbacks::default()).unwrap()),
        mouse_encoders: Mutex::new(MouseEncoders::new().unwrap()),
        cursor_provenance: Mutex::new(CursorStyleProvenance::default()),
        dirty: AtomicBool::new(false),
        geometry_lifecycle: Mutex::new(()),
        cell_pixels: Mutex::new((8, 16)),
        geometry_test_hook: Mutex::new(None),
        content_generation: AtomicU64::new(1),
        reported_size: Mutex::new(None),
        browser: Mutex::new(RemoteBrowserState::default()),
    });
    {
        let mut terminal = surface.term.lock().unwrap();
        terminal.replace_default_colors(
            Some(Rgb { r: 0xaa, g: 0xbb, b: 0xcc }),
            Some(Rgb { r: 0x11, g: 0x22, b: 0x33 }),
            Some(Rgb { r: 0xdd, g: 0xee, b: 0xff }),
        );
        terminal.vt_write(b"\x1b]4;1;rgb:ff/35/62\x1b\\");
    }
    session.surfaces.lock().unwrap().insert(7, surface.clone());

    session.handle_line(json!({
        "event": "colors-changed",
        "surface": 7,
        "palette": {"196": "#010203"},
    }));

    let terminal = surface.term.lock().unwrap();
    assert_eq!(terminal.effective_colors(), (None, None, None));
    let palette = terminal.color_overrides().palette;
    assert_eq!(palette[1], None);
    assert_eq!(palette[196], Some(Rgb { r: 1, g: 2, b: 3 }));
    assert!(surface.dirty.load(Ordering::Acquire));
}

#[cfg(unix)]
#[test]
fn reused_render_state_observes_complete_special_color_reset() {
    let (client, _server) = UnixStream::pair().unwrap();
    let session = socket_test_session(client);
    let surface = Arc::new(RemoteSurface {
        id: 7,
        kind: SurfaceKind::Pty,
        term: Mutex::new(Terminal::new(12, 4, 100, Callbacks::default()).unwrap()),
        mouse_encoders: Mutex::new(MouseEncoders::new().unwrap()),
        cursor_provenance: Mutex::new(CursorStyleProvenance::default()),
        dirty: AtomicBool::new(false),
        geometry_lifecycle: Mutex::new(()),
        cell_pixels: Mutex::new((8, 16)),
        geometry_test_hook: Mutex::new(None),
        content_generation: AtomicU64::new(1),
        reported_size: Mutex::new(None),
        browser: Mutex::new(RemoteBrowserState::default()),
    });
    session.surfaces.lock().unwrap().insert(7, surface.clone());

    session.handle_line(json!({
        "event": "vt-state",
        "surface": 7,
        "cols": 12,
        "rows": 4,
        "data": base64::engine::general_purpose::STANDARD.encode(b"prompt"),
        "colors": {
            "fg": "#fdfff1",
            "bg": "#272822",
            "cursor": "#c0c1b5",
            "cursor_style": "bar",
            "cursor_blink": true,
            "palette": {},
        },
    }));

    let mut render = RenderState::new().unwrap();
    {
        let mut terminal = surface.term.lock().unwrap();
        render.update(&mut terminal).unwrap();
        let frame = render.build_frame().unwrap();
        assert_eq!(frame.default_colors.0, Rgb { r: 0x27, g: 0x28, b: 0x22 });
    }

    session.handle_line(json!({
        "event": "output",
        "surface": 7,
        "data": base64::engine::general_purpose::STANDARD
            .encode(
                b"\x1b]4;1;#112233\x1b\\\x1b]10;#eeeeee\x1b\\\x1b]11;#171b2e\x1b\\\x1b]12;#ffee00\x1b\\"
            ),
        "colors": {
            "fg": "#eeeeee",
            "bg": "#171b2e",
            "cursor": "#ffee00",
            "cursor_style": "bar",
            "cursor_blink": true,
            "palette": {"1": "#112233"},
        },
    }));
    {
        let mut terminal = surface.term.lock().unwrap();
        render.update(&mut terminal).unwrap();
        let frame = render.build_frame().unwrap();
        assert_eq!(frame.default_colors.0, Rgb { r: 0x17, g: 0x1b, b: 0x2e });
    }

    session.handle_line(json!({
        "event": "output",
        "surface": 7,
        "data": base64::engine::general_purpose::STANDARD
            .encode(b"\x1b]104\x1b\\\x1b]110\x1b\\\x1b]111\x1b\\\x1b]112\x1b\\"),
        "colors": {
            "fg": "#fdfff1",
            "bg": "#272822",
            "cursor": "#c0c1b5",
            "cursor_style": "bar",
            "cursor_blink": true,
            "palette": {},
        },
    }));
    {
        let mut terminal = surface.term.lock().unwrap();
        assert_eq!(
            terminal.effective_colors(),
            (
                Some(Rgb { r: 0xfd, g: 0xff, b: 0xf1 }),
                Some(Rgb { r: 0x27, g: 0x28, b: 0x22 }),
                Some(Rgb { r: 0xc0, g: 0xc1, b: 0xb5 }),
            )
        );
        let overrides = terminal.color_overrides();
        assert_eq!(overrides.foreground, None);
        assert_eq!(overrides.background, None);
        assert_eq!(overrides.cursor, None);
        assert_eq!(overrides.palette[1], None);
        render.update(&mut terminal).unwrap();
        let frame = render.build_frame().unwrap();
        assert_eq!(
            frame.default_colors,
            (Rgb { r: 0x27, g: 0x28, b: 0x22 }, Rgb { r: 0xfd, g: 0xff, b: 0xf1 },)
        );
        assert_eq!(frame.cursor_color, Some(Rgb { r: 0xc0, g: 0xc1, b: 0xb5 }));
        let cell = &frame.styled_row(0).unwrap()[0];
        assert_eq!(cell.fg, ColorSpec::Default);
        assert_eq!(cell.bg, ColorSpec::Default);
    }
}

#[test]
fn remote_surface_resize_and_cell_pixel_update_are_one_geometry_transaction() {
    let surface = test_remote_pty_surface(1, 80, 24, (8, 16));
    let (resize_entered_tx, resize_entered_rx) = channel();
    let (release_resize_tx, release_resize_rx) = channel();
    let (cell_started_tx, cell_started_rx) = channel();
    let release_resize_rx = Arc::new(Mutex::new(release_resize_rx));
    *surface.geometry_test_hook.lock().unwrap() = Some(Arc::new({
        move |step| match step {
            RemoteGeometryTestStep::StreamResizeCommitBoundary => {
                resize_entered_tx.send(()).unwrap();
                release_resize_rx.lock().unwrap().recv().unwrap();
            }
            RemoteGeometryTestStep::CellPixelStarted => {
                cell_started_tx.send(()).unwrap();
            }
            _ => {}
        }
    }));

    let resizing_surface = surface.clone();
    let resizing = std::thread::spawn(move || {
        resizing_surface.apply_stream_resize(100, 30, None, &[]).unwrap();
    });
    resize_entered_rx.recv().unwrap();

    let updating_surface = surface.clone();
    let (cell_done_tx, cell_done_rx) = channel();
    let updating = std::thread::spawn(move || {
        updating_surface.set_cell_pixel_size(9, 18).unwrap();
        cell_done_tx.send(()).unwrap();
    });
    cell_started_rx.recv().unwrap();
    let cell_completed_while_resize_was_uncommitted =
        cell_done_rx.recv_timeout(Duration::from_millis(100)).is_ok();

    release_resize_tx.send(()).unwrap();
    resizing.join().unwrap();
    updating.join().unwrap();

    assert!(
        !cell_completed_while_resize_was_uncommitted,
        "cell pixels committed while the ordered stream resize was paused"
    );
    assert_eq!(*surface.cell_pixels.lock().unwrap(), (9, 18));
    let term = surface.term.lock().unwrap();
    assert_eq!((term.cols(), term.rows()), (100, 30));
}
