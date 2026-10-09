//! Terminal color tests: attach colors, cursor defaults, live palettes, and
//! color override deltas across host protocol versions.

use super::*;

#[test]
fn attach_colors_preserve_same_valued_authored_palette_override() {
    let color = Rgb { r: 0x44, g: 0x55, b: 0x66 };
    let mut defaults = DefaultColors::default();
    defaults.palette[4] = Some(color);
    let mut term = Terminal::new(5, 1, 0, Callbacks::default()).unwrap();
    term.set_default_palette(&defaults.palette);

    term.vt_write(b"\x1b]4;4;#445566\x07");
    let colors = TerminalColors::from_terminal(&term, defaults);
    assert_eq!(colors.palette[4], Some(color));
    assert!(
        colors.palette.iter().enumerate().all(|(index, entry)| { index == 4 || entry.is_none() })
    );

    term.vt_write(b"\x1b]104;4\x07");
    let colors = TerminalColors::from_terminal(&term, defaults);
    assert_eq!(colors.palette[4], None);
}

#[test]
fn attach_colors_do_not_consume_shared_render_damage() {
    let mut term = Terminal::new(5, 1, 0, Callbacks::default()).unwrap();
    let mut shared_render = RenderState::new().unwrap();
    shared_render.update(&mut term).unwrap();
    shared_render.set_clean();

    term.vt_write(b"changed");
    let _ = TerminalColors::from_terminal(&term, DefaultColors::default());

    shared_render.update(&mut term).unwrap();
    assert_ne!(shared_render.dirty(), Dirty::Clean);
}

#[test]
fn pty_output_colors_do_not_include_cursor_metadata() {
    let mut term = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
    let defaults = DefaultColors {
        cursor_style: Some(CursorShape::Bar),
        cursor_blink: Some(true),
        ..DefaultColors::default()
    };

    term.vt_write(b"\x1b]4;4;#445566\x07");
    let colors = TerminalColors::from_pty_output(&term, defaults);

    assert_eq!(colors.palette[4], Some(Rgb { r: 0x44, g: 0x55, b: 0x66 }));
    assert_eq!(colors.cursor_style, None);
    assert_eq!(colors.cursor_blink, None);
}

#[test]
fn unspecified_ghostty_cursor_blink_stays_mode_12_authoritative_in_local_and_mirror() {
    let defaults = DefaultColors {
        cursor_style: Some(CursorShape::Bar),
        cursor_blink: None,
        ..DefaultColors::default()
    };
    let mut local = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
    replace_ghostty_cursor_defaults(&mut local, defaults);

    assert_eq!(local.effective_cursor_visual().unwrap(), (CursorShape::Bar, true));
    let initial_colors = TerminalColors::from_terminal(&local, defaults);
    assert_eq!(initial_colors.cursor_style, Some(CursorShape::Bar));
    assert_eq!(initial_colors.cursor_blink, Some(true));

    // A process-separated renderer starts from the resolved cursor pair
    // carried beside its replay, then consumes the same subsequent VT
    // bytes as the authoritative parser.
    let mut mirror = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
    replace_ghostty_cursor_defaults(&mut mirror, defaults);
    mirror.vt_write(&terminal_color_override_full_state(&local.color_overrides()));

    let mut local_render = RenderState::new().unwrap();
    let mut mirror_render = RenderState::new().unwrap();
    for (sequence, expected_blink) in
        [(b"".as_slice(), true), (b"\x1b[?12l".as_slice(), false), (b"\x1b[?12h".as_slice(), true)]
    {
        local.vt_write(sequence);
        mirror.vt_write(sequence);
        local_render.update(&mut local).unwrap();
        mirror_render.update(&mut mirror).unwrap();
        let expected = (CursorShape::Bar, expected_blink);
        assert_eq!(local_render.cursor_visual().unwrap(), expected);
        assert_eq!(mirror_render.cursor_visual().unwrap(), expected);
        assert_eq!(
            TerminalColors::from_terminal(&local, defaults).cursor_blink,
            Some(expected_blink)
        );
    }
}

#[test]
fn explicit_ghostty_cursor_blink_defaults_pass_through_unchanged() {
    for configured in [false, true] {
        let defaults = DefaultColors {
            cursor_style: Some(CursorShape::Underline),
            cursor_blink: Some(configured),
            ..DefaultColors::default()
        };
        let mut term = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
        replace_ghostty_cursor_defaults(&mut term, defaults);
        assert_eq!(term.effective_cursor_visual().unwrap(), (CursorShape::Underline, configured));
        term.vt_write(b"\x1b[0 q");
        assert_eq!(term.effective_cursor_visual().unwrap(), (CursorShape::Underline, configured));
    }
}

#[test]
fn attach_colors_use_decscusr_visual_then_restore_cursor_defaults() {
    let mut term = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
    let defaults = DefaultColors {
        cursor_style: Some(CursorShape::Bar),
        cursor_blink: Some(false),
        ..DefaultColors::default()
    };
    term.set_default_cursor(defaults.cursor_style, defaults.cursor_blink);

    term.vt_write(b"\x1b[3 q");
    let colors = TerminalColors::from_terminal(&term, defaults);
    assert_eq!(colors.cursor_style, Some(CursorShape::Underline));
    assert_eq!(colors.cursor_blink, Some(true));

    term.vt_write(b"\x1b[0 q");
    let colors = TerminalColors::from_terminal(&term, defaults);
    assert_eq!(colors.cursor_style, Some(CursorShape::Bar));
    assert_eq!(colors.cursor_blink, Some(false));
}

#[test]
fn live_palette_snapshots_skip_absent_taps_and_coalesce_effective_state() {
    let mux = Mux::new_for_test("palette-coalescing", SurfaceOptions::default());
    let surface =
        Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
    let pty = surface.as_pty().unwrap();

    {
        let mut term = pty.term.lock().unwrap();
        term.vt_write(b"\x1b]4;1;#112233\x07");
        pty.attach_colors_pending.store(true, Ordering::Release);
        assert!(!pty.flush_attach_colors_locked(&term, mux.default_colors()));
        assert!(pty.last_attach_colors.lock().unwrap().is_none());
    }

    let attach = surface.attach_stream().unwrap();
    let attach_two = surface.attach_stream().unwrap();
    {
        let mut term = pty.term.lock().unwrap();
        term.vt_write(b"\x1b]4;1;#223344\x07\x1b]4;1;#334455\x07");
        pty.attach_colors_pending.store(true, Ordering::Release);
        assert!(pty.flush_attach_colors_locked(&term, mux.default_colors()));
    }
    let AttachFrame::ColorsChanged(colors) =
        attach.stream.recv_timeout(Duration::from_secs(1)).unwrap()
    else {
        panic!("expected coalesced colors update");
    };
    let AttachFrame::ColorsChanged(colors_two) =
        attach_two.stream.recv_timeout(Duration::from_secs(1)).unwrap()
    else {
        panic!("expected coalesced colors update for second tap");
    };
    assert!(Arc::ptr_eq(&colors, &colors_two));
    assert_eq!(colors.palette[1], Some(Rgb { r: 0x33, g: 0x44, b: 0x55 }));
    assert!(matches!(attach.stream.try_recv(), Err(TryRecvError::Empty)));
    assert!(matches!(attach_two.stream.try_recv(), Err(TryRecvError::Empty)));

    {
        let mut term = pty.term.lock().unwrap();
        term.vt_write(b"\x1b]4;1;#334455\x07");
        pty.attach_colors_pending.store(true, Ordering::Release);
        assert!(!pty.flush_attach_colors_locked(&term, mux.default_colors()));
    }
    assert!(matches!(attach.stream.try_recv(), Err(TryRecvError::Empty)));
    assert!(matches!(attach_two.stream.try_recv(), Err(TryRecvError::Empty)));

    {
        let term = pty.term.lock().unwrap();
        pty.attach_colors_pending.store(true, Ordering::Release);
        pty.attach_colors_force_pending.store(true, Ordering::Release);
        assert!(pty.flush_attach_colors_locked(&term, mux.default_colors()));
    }
    for stream in [&attach.stream, &attach_two.stream] {
        assert!(matches!(
            stream.recv_timeout(Duration::from_secs(1)),
            Ok(AttachFrame::ColorsChanged(_))
        ));
    }

    {
        let mut term = pty.term.lock().unwrap();
        term.vt_write(b"\x1b]4;1;#445566\x07");
        pty.attach_colors_pending.store(true, Ordering::Release);
    }
    let attach_three = surface.attach_stream().unwrap();
    {
        let term = pty.term.lock().unwrap();
        assert!(pty.flush_attach_colors_locked(&term, mux.default_colors()));
    }
    for stream in [&attach.stream, &attach_two.stream, &attach_three.stream] {
        let AttachFrame::ColorsChanged(colors) =
            stream.recv_timeout(Duration::from_secs(1)).unwrap()
        else {
            panic!("an existing tap missed a palette update during another attach");
        };
        assert_eq!(colors.palette[1], Some(Rgb { r: 0x44, g: 0x55, b: 0x66 }));
    }
}

#[cfg(unix)]
#[test]
fn local_same_pair_alt_screen_roundtrip_forces_resolved_cursor_colors() {
    let mux = Mux::new_for_test("local-cursor-activity", SurfaceOptions::default());
    let options = SurfaceOptions {
        command: Some(vec![
            "/bin/sh".into(),
            "-c".into(),
            "sleep 0.2; printf '\\033[?1049h\\033[?1049l'; sleep 0.2".into(),
        ]),
        ..SurfaceOptions::default()
    };
    let surface = Surface::spawn(1, options, Arc::downgrade(&mux)).unwrap();
    let attach = surface.attach_stream().unwrap();
    let expected = (attach.colors.cursor_style, attach.colors.cursor_blink);
    let deadline = Instant::now() + Duration::from_secs(2);
    let mut output = Vec::new();
    let colors = loop {
        assert!(Instant::now() < deadline, "local cursor activity was not published");
        match attach.stream.recv_timeout(Duration::from_millis(250)) {
            Ok(AttachFrame::Output(bytes)) => output.extend_from_slice(&bytes),
            Ok(AttachFrame::ColorsChanged(colors)) => break colors,
            Ok(AttachFrame::Resized { .. } | AttachFrame::ResizedWithColors { .. }) => {}
            Ok(AttachFrame::OutputWithColors { .. }) => {
                panic!("local PTYs must use ordered Output then ColorsChanged")
            }
            Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => {
                panic!("local cursor activity stream disconnected")
            }
        }
    };

    assert!(
        output.windows(16).any(|window| window == b"\x1b[?1049h\x1b[?1049l"),
        "same-chunk alt-screen roundtrip was not mirrored"
    );
    assert_eq!((colors.cursor_style, colors.cursor_blink), expected);
    assert!(colors.cursor_style.is_some() && colors.cursor_blink.is_some());
}

#[test]
fn terminal_color_override_delta_sets_and_resets_sparse_state() {
    let mut colors = TerminalColorOverrides {
        foreground: Some(Rgb { r: 1, g: 2, b: 3 }),
        background: Some(Rgb { r: 4, g: 5, b: 6 }),
        cursor: Some(Rgb { r: 7, g: 8, b: 9 }),
        cursor_visual: Some((CursorShape::Underline, true)),
        ..Default::default()
    };
    colors.palette[42] = Some(Rgb { r: 10, g: 11, b: 12 });
    let mut terminal = Terminal::new(10, 2, 0, Callbacks::default()).unwrap();
    terminal.vt_write(&terminal_color_override_delta(&Default::default(), &colors));
    assert_eq!(terminal.color_overrides(), colors);

    let reset = TerminalColorOverrides {
        cursor_visual: Some((CursorShape::Block, false)),
        ..Default::default()
    };
    terminal.vt_write(&terminal_color_override_delta(&colors, &reset));
    assert_eq!(terminal.color_overrides(), reset);
}

#[test]
fn terminal_color_override_full_state_resets_then_applies_resolved_cursor() {
    let colors = TerminalColorOverrides {
        cursor_visual: Some((CursorShape::Bar, true)),
        ..Default::default()
    };
    assert_eq!(terminal_color_override_full_state(&colors), b"\x1b[0 q\x1b[5 q");
    assert_eq!(terminal_color_override_full_state(&TerminalColorOverrides::default()), b"");
}

#[test]
fn legacy_v1_full_state_preserves_cursor_from_portable_replay() {
    let mut terminal = Terminal::new(10, 2, 0, Callbacks::default()).unwrap();
    terminal.vt_write(b"\x1b[3 q\x1b[?12l");
    let mut legacy =
        crate::terminal_host_runtime::decode_terminal_color_overrides(&[1, 0, 0, 0, 0, 0, 0, 0])
            .unwrap();
    legacy.palette[9] = Some(Rgb { r: 9, g: 9, b: 9 });

    let metadata = terminal_color_override_full_state(&legacy);
    assert!(!metadata.windows(5).any(|window| window == b"\x1b[0 q"));
    terminal.vt_write(&metadata);
    assert_eq!(terminal.effective_cursor_visual().unwrap(), (CursorShape::Underline, false));
    assert_eq!(terminal.color_overrides().palette[9], Some(Rgb { r: 9, g: 9, b: 9 }));
}

#[test]
fn legacy_v1_host_stream_preserves_raw_cursor_and_sparse_color_contract() {
    let mut terminal = Terminal::new(10, 2, 0, Callbacks::default()).unwrap();
    terminal.set_default_cursor(Some(CursorShape::Bar), Some(false));
    let applied =
        crate::terminal_host_runtime::decode_terminal_color_overrides(&[1, 0, 0, 0, 0, 0, 0, 0])
            .unwrap();

    terminal.vt_write(b"ordinary output");
    assert!(terminal_color_overrides_match_applied(terminal.color_overrides(), &applied));

    // Version 1 carries cursor changes only in ordinary VT output. Both
    // DECSCUSR and mode 12 must survive without looking like an undeclared
    // sparse-color mutation that disconnects the host stream.
    terminal.vt_write(b"\x1b[3 q\x1b[?12l");
    assert_eq!(terminal.effective_cursor_visual().unwrap(), (CursorShape::Underline, false));
    assert!(terminal_color_overrides_match_applied(terminal.color_overrides(), &applied));

    // A later coupled v1 color frame has no cursor pair. Its absence means
    // unknown/preserve, while all legacy sparse colors remain authoritative.
    let next = crate::terminal_host_runtime::decode_terminal_color_overrides(&[
        1, 0, 1, 0, 0, 0, 0, 0, 1, 2, 3,
    ])
    .unwrap();
    terminal.vt_write(b"\x1b]10;#010203\x07");
    let delta = terminal_color_override_delta(&applied, &next);
    assert!(!delta.windows(5).any(|window| window == b"\x1b[0 q"));
    terminal.vt_write(&delta);
    assert_eq!(
        terminal.effective_cursor_visual().unwrap(),
        (CursorShape::Underline, false),
        "legacy v1 cursor absence must preserve raw VT cursor state"
    );
    assert!(terminal_color_overrides_match_applied(terminal.color_overrides(), &next));

    terminal.vt_write(b"stream remains live");
    assert!(terminal_color_overrides_match_applied(terminal.color_overrides(), &next));
}

#[test]
fn legacy_v1_applied_state_ignores_only_cursor_metadata() {
    let applied =
        TerminalColorOverrides { foreground: Some(Rgb { r: 1, g: 2, b: 3 }), ..Default::default() };
    let observed = TerminalColorOverrides {
        foreground: applied.foreground,
        cursor_visual: Some((CursorShape::Block, true)),
        ..Default::default()
    };

    assert!(terminal_color_overrides_match_applied(observed.clone(), &applied));

    let mut mismatched = observed;
    mismatched.background = Some(Rgb { r: 4, g: 5, b: 6 });
    assert!(!terminal_color_overrides_match_applied(mismatched, &applied));
}

#[test]
fn terminal_color_override_delta_maps_every_v2_cursor_visual_and_preserves_v1_absence() {
    let cases = [
        ((CursorShape::Block, true), b"\x1b[1 q".as_slice()),
        ((CursorShape::Block, false), b"\x1b[2 q".as_slice()),
        ((CursorShape::Underline, true), b"\x1b[3 q".as_slice()),
        ((CursorShape::Underline, false), b"\x1b[4 q".as_slice()),
        ((CursorShape::Bar, true), b"\x1b[5 q".as_slice()),
        ((CursorShape::Bar, false), b"\x1b[6 q".as_slice()),
    ];
    let mut previous = TerminalColorOverrides::default();
    for (cursor_visual, expected) in cases {
        let next =
            TerminalColorOverrides { cursor_visual: Some(cursor_visual), ..Default::default() };
        assert_eq!(terminal_color_override_delta(&previous, &next), expected);
        previous = next;
    }
    assert_eq!(
        terminal_color_override_delta(&previous, &previous),
        b"\x1b[6 q",
        "same-pair v2 metadata must force cursor reapplication"
    );
    assert_eq!(terminal_color_override_delta(&previous, &TerminalColorOverrides::default()), b"");
}
