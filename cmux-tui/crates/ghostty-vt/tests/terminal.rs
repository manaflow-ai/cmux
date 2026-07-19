use std::sync::{Arc, Mutex};

use ghostty_vt::{Callbacks, Cell, ColorSpec, CursorShape, Dirty, RenderState, Rgb, Terminal};

fn snapshot_cells(term: &mut Terminal) -> Vec<Vec<Cell>> {
    let mut rs = RenderState::new().unwrap();
    rs.update(term).unwrap();
    let mut rows = Vec::new();
    rs.walk_rows(|_, _, cells| rows.push(cells.to_vec())).unwrap();
    rows
}

#[test]
fn writes_and_renders_text() {
    let mut term = Terminal::new(20, 4, 1000, Callbacks::default()).unwrap();
    term.vt_write(b"hello \x1b[1;32mworld\x1b[0m\r\nline2");

    let mut rs = RenderState::new().unwrap();
    rs.update(&mut term).unwrap();
    assert_ne!(rs.dirty(), Dirty::Clean);
    assert_eq!(rs.size(), (20, 4));

    let lines = rs.text_lines().unwrap();
    assert_eq!(lines[0], "hello world");
    assert_eq!(lines[1], "line2");

    // Styled cell: 'w' of "world" is bold with a colored foreground.
    let mut bold_seen = false;
    rs.walk_rows(|row, _, cells| {
        if row == 0 {
            bold_seen = cells.iter().any(|c| c.text == "w" && c.bold);
        }
    })
    .unwrap();
    assert!(bold_seen);
}

#[test]
fn resize_reflows() {
    let mut term = Terminal::new(10, 4, 1000, Callbacks::default()).unwrap();
    term.vt_write(b"abcdefghij");
    term.resize(5, 4, 8, 16).unwrap();
    assert_eq!(term.cols(), 5);
    let mut rs = RenderState::new().unwrap();
    rs.update(&mut term).unwrap();
    let lines = rs.text_lines().unwrap();
    assert_eq!(lines[0], "abcde");
    assert_eq!(lines[1], "fghij");
}

#[test]
fn title_and_pty_callbacks() {
    let title_changed = Arc::new(Mutex::new(false));
    let pty_out: Arc<Mutex<Vec<u8>>> = Arc::new(Mutex::new(Vec::new()));

    let tc = title_changed.clone();
    let po = pty_out.clone();
    let callbacks = Callbacks {
        on_pty_write: Some(Box::new(move |bytes| po.lock().unwrap().extend_from_slice(bytes))),
        on_title_changed: Some(Box::new(move || *tc.lock().unwrap() = true)),
        on_bell: None,
    };
    let mut term = Terminal::new(80, 24, 0, callbacks).unwrap();

    term.vt_write(b"\x1b]2;my title\x07");
    assert!(*title_changed.lock().unwrap());
    assert_eq!(term.title().as_deref(), Some("my title"));

    // DSR cursor position query must produce a pty response.
    term.vt_write(b"\x1b[6n");
    assert!(!pty_out.lock().unwrap().is_empty());
}

#[test]
fn default_colors_answer_osc_queries() {
    let pty_out: Arc<Mutex<Vec<u8>>> = Arc::new(Mutex::new(Vec::new()));

    let po = pty_out.clone();
    let callbacks = Callbacks {
        on_pty_write: Some(Box::new(move |bytes| po.lock().unwrap().extend_from_slice(bytes))),
        on_title_changed: None,
        on_bell: None,
    };
    let mut term = Terminal::new(80, 24, 0, callbacks).unwrap();

    term.vt_write(b"\x1b]11;?\x07");
    assert!(pty_out.lock().unwrap().is_empty());

    term.set_default_colors(None, Some(Rgb { r: 0x13, g: 0x14, b: 0x15 }), None);
    term.vt_write(b"\x1b]11;?\x07");
    assert_eq!(&*pty_out.lock().unwrap(), b"\x1b]11;rgb:1313/1414/1515\x07");

    pty_out.lock().unwrap().clear();
    term.set_default_colors(Some(Rgb { r: 0x01, g: 0x02, b: 0x03 }), None, None);
    term.vt_write(b"\x1b]10;?\x07");
    assert_eq!(&*pty_out.lock().unwrap(), b"\x1b]10;rgb:0101/0202/0303\x07");

    pty_out.lock().unwrap().clear();
    term.set_default_colors(None, None, Some(Rgb { r: 0xc0, g: 0xc1, b: 0xb5 }));
    term.vt_write(b"\x1b]12;?\x07");
    assert_eq!(&*pty_out.lock().unwrap(), b"\x1b]12;rgb:c0c0/c1c1/b5b5\x07");

    pty_out.lock().unwrap().clear();
    term.vt_write(b"\x1b]11;rgb:20/40/60\x07");
    term.vt_write(b"\x1b]11;?\x07");
    assert_eq!(&*pty_out.lock().unwrap(), b"\x1b]11;rgb:2020/4040/6060\x07");
}

#[test]
fn ghostty_config_colors_and_palette_defaults_use_engine_parsers() {
    assert_eq!(ghostty_vt::parse_color("ForestGreen"), Some(Rgb { r: 0x22, g: 0x8b, b: 0x22 }));
    assert_eq!(
        ghostty_vt::parse_palette_entry("0xF = #123456"),
        Some((15, Rgb { r: 0x12, g: 0x34, b: 0x56 }))
    );
    assert_eq!(ghostty_vt::parse_palette_entry("256=#ffffff"), None);

    let mut term = Terminal::new(8, 2, 0, Callbacks::default()).unwrap();
    let mut palette = [None; 256];
    palette[1] = Some(Rgb { r: 0x44, g: 0x55, b: 0x66 });
    term.set_default_palette(&palette);
    term.vt_write(b"\x1b[31mR");

    let mut state = RenderState::new().unwrap();
    state.update(&mut term).unwrap();
    assert_eq!(state.palette_color(1), Rgb { r: 0x44, g: 0x55, b: 0x66 });
    assert!(!state.palette_overridden(1));
    assert_eq!(
        state.build_frame().unwrap().row_runs(0).unwrap()[0].fg,
        Some(Rgb { r: 0x44, g: 0x55, b: 0x66 })
    );
}

#[test]
fn alt_screen_and_modes() {
    let mut term = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
    assert_eq!(term.active_screen(), ghostty_vt::Screen::Primary);
    term.vt_write(b"\x1b[?1049h");
    assert_eq!(term.active_screen(), ghostty_vt::Screen::Alternate);
    assert!(!term.mouse_tracking());
    term.vt_write(b"\x1b[?1000h");
    assert!(term.mouse_tracking());
}

#[test]
fn render_state_cursor_visual_tracks_defaults_and_decscusr() {
    let mut term = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
    term.set_default_cursor(Some(CursorShape::Bar), Some(false));

    let mut rs = RenderState::new().unwrap();
    rs.update(&mut term).unwrap();
    assert!(!term.cursor_overridden());
    assert_eq!(rs.cursor_visual().unwrap(), (CursorShape::Bar, false));

    term.vt_write(b"\x1b[3");
    term.vt_write(b" q");
    rs.update(&mut term).unwrap();
    assert!(term.cursor_overridden());
    assert_eq!(rs.cursor_visual().unwrap(), (CursorShape::Underline, true));

    term.vt_write(b"\x1b[0 q");
    rs.update(&mut term).unwrap();
    assert!(!term.cursor_overridden());
    assert_eq!(rs.cursor_visual().unwrap(), (CursorShape::Bar, false));
}

#[test]
fn cursor_override_tracker_matches_control_string_exits() {
    let mut term = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
    term.vt_write(b"\x1b]2;not-a-sequence \x1b[3 q\x07");
    assert!(term.cursor_overridden(), "ESC exits OSC before the following DECSCUSR");
    term.vt_write(b"\x1bc");
    assert!(!term.cursor_overridden());

    term.vt_write(b"\x1b[3q");
    assert!(!term.cursor_overridden());

    term.vt_write(b"\x1b[5 q");
    assert!(term.cursor_overridden());
    term.vt_write(b"\x1bc");
    assert!(!term.cursor_overridden());
    term.vt_write(b"\x1bPab\x18\x1b[3 q");
    assert!(term.cursor_overridden(), "CAN must abort DCS before the next DECSCUSR");
    term.vt_write(b"\x1bc");
    assert!(!term.cursor_overridden());
    term.vt_write(b"\x1bPab\x1b[5 q");
    assert!(term.cursor_overridden(), "ESC must leave DCS before the next DECSCUSR");
}

#[test]
fn cursor_override_tracker_survives_utf8_text() {
    // U+1F44D encodes as f0 9f 91 8d; the 0x9f byte is UTF-8 text in ground
    // state, not a C1 OSC opener. A tracker that misreads it enters a control
    // string it never leaves and misses every later DECSCUSR.
    let mut term = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
    term.vt_write("👍".as_bytes());
    term.vt_write(b"\x1b[5 q");
    assert!(term.cursor_overridden());

    // Same for 0x9d (e.g. in "\u{275d}" = e2 9d 9d), including inside a
    // BEL-terminated OSC title that itself contains emoji.
    let mut term = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
    term.vt_write("❝".as_bytes());
    term.vt_write("\u{1b}]0;title 👍\u{7}".as_bytes());
    term.vt_write(b"\x1b[3 q");
    assert!(term.cursor_overridden());
}

#[test]
fn vt_replay_restores_cursor_position_after_tabstops() {
    // The formatter emits tabstop programming after its cursor restore. The
    // replay wrapper re-asserts the true cursor last so a byte-mode frontend
    // does not end parked on the final tabstop column.
    let mut source = Terminal::new(104, 39, 0, Callbacks::default()).unwrap();
    source.vt_write(b"lawrence in ~ \xce\xbb ");
    let expected = source.cursor_position().unwrap();
    assert_eq!(expected, (16, 0));

    let full = source.vt_replay().unwrap();
    let bounded = source.vt_replay_bounded(8 * 1024 * 1024).unwrap();
    for replay in [&full, &bounded] {
        let mut mirror = Terminal::new(104, 39, 0, Callbacks::default()).unwrap();
        mirror.vt_write(replay);
        assert_eq!(
            mirror.cursor_position().unwrap(),
            expected,
            "mirror cursor diverged after replay"
        );
    }
}

#[test]
fn plain_text_dump() {
    let mut term = Terminal::new(40, 5, 0, Callbacks::default()).unwrap();
    term.vt_write(b"alpha\r\nbeta");
    let text = term.plain_text().unwrap();
    assert!(text.contains("alpha"), "dump was {text:?}");
    assert!(text.contains("beta"));
}

#[test]
fn viewport_text_does_not_clear_render_dirty_state() {
    let mut term = Terminal::new(40, 5, 1000, Callbacks::default()).unwrap();
    let mut rs = RenderState::new().unwrap();

    rs.update(&mut term).unwrap();
    rs.set_clean();

    term.vt_write(b"alpha\r\nbeta");
    let text = term.viewport_text().unwrap();
    assert!(text.contains("alpha"), "viewport was {text:?}");
    assert!(text.contains("beta"), "viewport was {text:?}");

    rs.update(&mut term).unwrap();
    assert_ne!(rs.dirty(), Dirty::Clean);
}

#[test]
fn selection_text_extracts_range() {
    let mut term = Terminal::new(40, 5, 0, Callbacks::default()).unwrap();
    term.vt_write(b"hello world\r\nsecond line");
    // "world" on row 0, columns 6..=10.
    let text = term.selection_text((6, 0), (10, 0)).unwrap();
    assert_eq!(text.trim_end(), "world");
    // Multi-row selection spans the line break.
    let text = term.selection_text((6, 0), (5, 1)).unwrap();
    assert!(text.contains("world"), "{text:?}");
    assert!(text.contains("second"), "{text:?}");
    // Out-of-bounds endpoint is None, not a panic.
    assert!(term.selection_text((0, 0), (0, 200)).is_none());
}

#[test]
fn selection_text_absolute_preserves_soft_wraps() {
    let mut term = Terminal::new(10, 3, 1000, Callbacks::default()).unwrap();
    term.vt_write(b"abcdefghijklmno");

    let text = term.selection_text_absolute((0, 0), (4, 1)).unwrap();
    assert_eq!(text.trim_end(), "abcdefghijklmno");
}

#[test]
fn selection_text_absolute_spans_scrolled_out_rows() {
    let mut term = Terminal::new(20, 3, 1000, Callbacks::default()).unwrap();
    for i in 0..8 {
        term.vt_write(format!("line{i:02}\r\n").as_bytes());
    }
    let sb = term.scrollbar().unwrap();
    assert!(sb.scrolled_back() || sb.offset > 0, "{sb:?}");

    let text = term.selection_text_absolute((0, 0), (5, 1)).unwrap();
    assert!(text.contains("line00"), "{text:?}");
    assert!(text.contains("line01"), "{text:?}");
}

#[test]
fn scrollbar_tracks_scrollback() {
    let mut term = Terminal::new(20, 4, 1000, Callbacks::default()).unwrap();
    for i in 0..20 {
        term.vt_write(format!("line{i}\r\n").as_bytes());
    }
    let sb = term.scrollbar().unwrap();
    assert_eq!(sb.len, 4);
    assert!(sb.total > sb.len, "{sb:?}");
    assert!(!sb.scrolled_back(), "{sb:?}");
    term.scroll_delta(-5);
    let sb = term.scrollbar().unwrap();
    assert!(sb.scrolled_back(), "{sb:?}");
}

#[test]
fn wide_chars_have_spacer_cells() {
    let mut term = Terminal::new(10, 2, 0, Callbacks::default()).unwrap();
    term.vt_write("世界".as_bytes());
    let mut rs = RenderState::new().unwrap();
    rs.update(&mut term).unwrap();
    rs.walk_rows(|row, _, cells| {
        if row == 0 {
            assert_eq!(cells[0].text, "世");
            assert_eq!(cells[1].text, "");
            assert_eq!(cells[2].text, "界");
        }
    })
    .unwrap();
}

#[test]
fn cell_colors_preserve_palette_specs() {
    let mut term = Terminal::new(10, 2, 0, Callbacks::default()).unwrap();
    term.vt_write(b"\x1b[31mA\x1b[38;5;196mB\x1b[48;5;236m \x1b[38;2;1;2;3mC\x1b[0m");

    let rows = snapshot_cells(&mut term);
    let row = &rows[0];
    assert_eq!(row[0].text, "A");
    assert_eq!(row[0].fg, ColorSpec::Palette(1));
    assert_eq!(row[0].bg, ColorSpec::Default);
    assert_eq!(row[1].text, "B");
    assert_eq!(row[1].fg, ColorSpec::Palette(196));
    assert_eq!(row[1].bg, ColorSpec::Default);
    assert_eq!(row[2].text, " ");
    assert_eq!(row[2].fg, ColorSpec::Palette(196));
    assert_eq!(row[2].bg, ColorSpec::Palette(236));
    assert_eq!(row[3].text, "C");
    assert_eq!(row[3].fg, ColorSpec::Rgb(Rgb { r: 1, g: 2, b: 3 }));
    assert_eq!(row[3].bg, ColorSpec::Palette(236));
    assert_eq!(row[4].fg, ColorSpec::Default);
    assert_eq!(row[4].bg, ColorSpec::Default);
}

#[test]
fn erased_cells_preserve_indexed_and_rgb_background_specs() {
    let mut indexed = Terminal::new(5, 1, 0, Callbacks::default()).unwrap();
    indexed.vt_write(b"\x1b[48;5;100m\x1b[K");
    let rows = snapshot_cells(&mut indexed);
    assert!(rows[0].iter().all(|cell| cell.text.is_empty()));
    assert!(rows[0].iter().all(|cell| cell.bg == ColorSpec::Palette(100)));

    let mut rgb = Terminal::new(5, 1, 0, Callbacks::default()).unwrap();
    rgb.vt_write(b"\x1b[48;2;1;2;3m\x1b[K");
    let rows = snapshot_cells(&mut rgb);
    assert!(rows[0].iter().all(|cell| cell.text.is_empty()));
    assert!(rows[0].iter().all(|cell| cell.bg == ColorSpec::Rgb(Rgb { r: 1, g: 2, b: 3 })));
}

#[test]
fn render_state_reports_palette_overrides() {
    let mut term = Terminal::new(5, 1, 0, Callbacks::default()).unwrap();
    term.vt_write(b"\x1b]4;1;#010203\x07");

    let mut rs = RenderState::new().unwrap();
    rs.update(&mut term).unwrap();
    assert!(rs.palette_overridden(1));
    assert_eq!(rs.palette_color(1), Rgb { r: 1, g: 2, b: 3 });
    assert!(!rs.palette_overridden(2));
}

#[test]
fn terminal_tracks_same_valued_osc_palette_overrides_and_resets() {
    let mut term = Terminal::new(5, 1, 0, Callbacks::default()).unwrap();
    let mut defaults = [None; 256];
    defaults[1] = Some(Rgb { r: 0x44, g: 0x55, b: 0x66 });
    term.set_default_palette(&defaults);

    assert!(!term.palette_overridden(1));
    term.vt_write(b"\x1b]4;1;#445566\x07");
    assert!(term.palette_overridden(1));

    let mut state = RenderState::new().unwrap();
    state.update(&mut term).unwrap();
    assert_eq!(state.palette_color(1), Rgb { r: 0x44, g: 0x55, b: 0x66 });
    assert!(!state.palette_overridden(1), "value equality cannot identify authored state");

    term.vt_write(b"\x1b]4;2;rgb:01/");
    term.vt_write(b"02/03\x1b\\");
    assert!(term.palette_overridden(2));
    term.vt_write(b"\x1b]4;5;#050505;;6;#060606\x1b\\");
    assert!(term.palette_overridden(5));
    assert!(term.palette_overridden(6));
    term.vt_write(b"\x1b]4;3;?\x07");
    assert!(!term.palette_overridden(3));

    term.vt_write(b"\x1b]21;7=#070707;8=rgb:08/08/08;foreground=#ffffff\x1b\\");
    assert!(term.palette_overridden(7));
    assert!(term.palette_overridden(8));
    term.vt_write(b"\x1b]21;7=;8=?\x1b\\");
    assert!(!term.palette_overridden(7));
    assert!(term.palette_overridden(8), "query must not alter authored state");

    term.vt_write(b"\x1b]21;1_8=#112233;_19=#ffffff;20_=#ffffff\x1b\\");
    assert!(term.palette_overridden(18), "OSC 21 must accept Zig's embedded underscores");
    assert!(!term.palette_overridden(19), "OSC 21 must reject a leading underscore");
    assert!(!term.palette_overridden(20), "OSC 21 must reject a trailing underscore");
    state.update(&mut term).unwrap();
    assert_eq!(state.palette_color(18), Rgb { r: 0x11, g: 0x22, b: 0x33 });

    term.vt_write(b"\x1b]4;+19;#223344;-0;#001122;20_;#ffffff\x1b\\");
    assert!(term.palette_overridden(19), "OSC 4 must accept Zig's positive sign grammar");
    assert!(term.palette_overridden(0), "OSC 4 must accept Zig's negative zero grammar");
    assert!(!term.palette_overridden(20), "OSC 4 must reject a trailing underscore");
    state.update(&mut term).unwrap();
    assert_eq!(state.palette_color(19), Rgb { r: 0x22, g: 0x33, b: 0x44 });
    assert_eq!(state.palette_color(0), Rgb { r: 0x00, g: 0x11, b: 0x22 });
    let original_nine = state.palette_color(9);
    term.vt_write(b"\x9d4;9;#090909\x07");
    assert!(!term.palette_overridden(9), "raw C1 is not dispatched by Ghostty's VT stream");
    term.vt_write(b"\xc2\x9d4;9;#090909\x07");
    assert!(!term.palette_overridden(9), "UTF-8 C1 is printable text, not an OSC opener");
    state.update(&mut term).unwrap();
    assert_eq!(state.palette_color(9), original_nine);

    term.vt_write(b"\x1bPab\x18\x1b]4;10;#0a0a0a\x07");
    assert!(term.palette_overridden(10), "CAN must abort a non-OSC control string");
    term.vt_write(b"\x1bPab\x1b\x1a\x1b]4;11;#0b0b0b\x07");
    assert!(term.palette_overridden(11), "SUB must abort after an escape in a control string");
    term.vt_write(b"\x1b]4;12;#0c0c0c\x1b");
    assert!(term.palette_overridden(12), "OSC must commit at a split ST's ESC boundary");
    term.vt_write(b"\\");
    assert!(term.palette_overridden(12));
    term.vt_write(b"\x1b]4;13;#0d\x000d0d\x07");
    assert!(term.palette_overridden(13), "OSC must ignore embedded C0 bytes like Ghostty");
    state.update(&mut term).unwrap();
    assert_eq!(state.palette_color(13), Rgb { r: 13, g: 13, b: 13 });

    term.vt_write(b"\x1b\x07]4;14;#0e0e0e\x07");
    assert!(term.palette_overridden(14), "C0 controls must preserve Ghostty's ESC state");
    state.update(&mut term).unwrap();
    assert_eq!(state.palette_color(14), Rgb { r: 14, g: 14, b: 14 });

    let mut oversized = b"\x1b]4;16;#101010".to_vec();
    oversized.extend(std::iter::repeat_n(b';', 2048));
    oversized.push(0x07);
    term.vt_write(&oversized);
    assert!(!term.palette_overridden(16), "Ghostty rejects fixed OSC capture overflow");
    state.update(&mut term).unwrap();
    assert_ne!(state.palette_color(16), Rgb { r: 16, g: 16, b: 16 });

    term.vt_write(b"\x1b]4;15;#0f0f0f;bad;#010101\x07");
    assert!(term.palette_overridden(15), "valid OSC 4 prefix must survive a malformed pair");
    state.update(&mut term).unwrap();
    assert_eq!(state.palette_color(15), Rgb { r: 15, g: 15, b: 15 });

    term.vt_write(b"\x1b]4;21;#212121\x07");
    term.vt_write(b"\x1b]104;21\x9d4;22;#222222\x07");
    assert!(term.palette_overridden(21), "Ghostty treats raw C1 as OSC payload in OSC state");
    assert!(!term.palette_overridden(22), "raw C1 must not begin a nested OSC in OSC state");
    term.vt_write(b"\x1bPq\x9d4;22;#222222\x07");
    assert!(term.palette_overridden(22), "C1 OSC must leave DCS and begin an OSC");
    state.update(&mut term).unwrap();
    assert_eq!(state.palette_color(22), Rgb { r: 0x22, g: 0x22, b: 0x22 });

    term.vt_write(b"\x1b]4;23;#232323\x07");
    term.vt_write(b"\x1b]21;23=\xff\x07");
    assert!(term.palette_overridden(23), "invalid UTF-8 Kitty values must not become resets");
    state.update(&mut term).unwrap();
    assert_eq!(state.palette_color(23), Rgb { r: 0x23, g: 0x23, b: 0x23 });

    term.vt_write(b"\x1b]4;0;#101010\x07");
    let mut too_many_kitty_requests = b"\x1b]21;".to_vec();
    for request in 0..527 {
        if request > 0 {
            too_many_kitty_requests.push(b';');
        }
        too_many_kitty_requests.extend_from_slice(b"0=");
    }
    too_many_kitty_requests.extend_from_slice(b"\x1b\\");
    term.vt_write(&too_many_kitty_requests);
    assert!(term.palette_overridden(0), "Ghostty rejects OSC 21 beyond 526 requests");
    state.update(&mut term).unwrap();
    assert_eq!(state.palette_color(0), Rgb { r: 0x10, g: 0x10, b: 0x10 });

    term.vt_write(b"\x1b]4;16;#161616\x18");
    assert!(term.palette_overridden(16), "CAN dispatches Ghostty's valid OSC prefix");
    state.update(&mut term).unwrap();
    assert_eq!(state.palette_color(16), Rgb { r: 0x16, g: 0x16, b: 0x16 });
    term.vt_write(b"\x1bPab\x1b]4;17;#171717\x07");
    assert!(term.palette_overridden(17), "ESC must leave DCS before the next OSC");
    state.update(&mut term).unwrap();
    assert_eq!(state.palette_color(17), Rgb { r: 0x17, g: 0x17, b: 0x17 });

    term.vt_write(b"\x1b]104;1\x1b\\");
    assert!(!term.palette_overridden(1));
    assert!(term.palette_overridden(2));
    term.vt_write(b"\x1b]104\x07");
    assert!(!term.palette_overridden(2));

    term.vt_write(b"\x1b]4;4;#010203\x07");
    assert!(term.palette_overridden(4));
    term.vt_write(b"\x1b]104;260\x1b\\");
    assert!(
        term.palette_overridden(4),
        "resetting Ghostty's italic special color must not clear palette overrides"
    );
    let revision_before_ris = term.color_revision();
    let reapply_before_ris = term.color_reapply_revision();
    term.vt_write(b"\x1bc");
    assert!(term.palette_overridden(4), "Ghostty RIS preserves palette overrides");
    assert_ne!(term.color_revision(), revision_before_ris, "RIS must trigger frontend reapply");
    assert_ne!(
        term.color_reapply_revision(),
        reapply_before_ris,
        "RIS must advance the forced palette-reapply revision"
    );
    state.update(&mut term).unwrap();
    assert_eq!(state.palette_color(4), Rgb { r: 1, g: 2, b: 3 });
}
