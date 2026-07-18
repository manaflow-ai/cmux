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
fn cursor_override_tracker_ignores_control_text() {
    let mut term = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
    term.vt_write(b"\x1b]2;not-a-sequence \x1b[3 q\x07");
    assert!(!term.cursor_overridden());

    term.vt_write(b"\x1b[3q");
    assert!(!term.cursor_overridden());

    term.vt_write(b"\x1b[5 q");
    assert!(term.cursor_overridden());
    term.vt_write(b"\x1bc");
    assert!(!term.cursor_overridden());
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
    // The formatter emits tabstop programming after its cursor restore;
    // vt_replay re-asserts the true cursor last so a fresh mirror doesn't
    // end parked on the final tabstop column (issue seen as a mid-line
    // cursor beam in byte-mode frontends).
    let mut source = Terminal::new(104, 39, 0, Callbacks::default()).unwrap();
    source.vt_write(b"lawrence in ~ \xce\xbb ");
    let (sx, sy) = source.cursor_position().unwrap();
    assert_eq!((sx, sy), (16, 0));

    let replay = source.vt_replay().unwrap();
    let mut mirror = Terminal::new(104, 39, 0, Callbacks::default()).unwrap();
    mirror.vt_write(&replay);
    assert_eq!(mirror.cursor_position().unwrap(), (sx, sy), "mirror cursor diverged after replay");
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
fn color_overrides_are_sparse_and_resets_return_to_embedder_defaults() {
    let mut term = Terminal::new(5, 1, 0, Callbacks::default()).unwrap();
    term.set_default_colors(
        Some(Rgb { r: 220, g: 221, b: 222 }),
        Some(Rgb { r: 10, g: 11, b: 12 }),
        Some(Rgb { r: 30, g: 31, b: 32 }),
    );
    let mut palette = [None; 256];
    palette[3] = Some(Rgb { r: 40, g: 41, b: 42 });
    term.set_default_palette(&palette);
    assert_eq!(term.color_overrides(), Default::default());

    term.vt_write(b"\x1b]4;3;#010203\x07\x1b]10;#111213\x07\x1b]11;#212223\x07\x1b]12;#313233\x07");
    let colors = term.color_overrides();
    assert_eq!(colors.palette[3], Some(Rgb { r: 1, g: 2, b: 3 }));
    assert_eq!(colors.foreground, Some(Rgb { r: 17, g: 18, b: 19 }));
    assert_eq!(colors.background, Some(Rgb { r: 33, g: 34, b: 35 }));
    assert_eq!(colors.cursor, Some(Rgb { r: 49, g: 50, b: 51 }));

    term.vt_write(b"\x1b]104;3\x07\x1b]110\x07\x1b]111\x07\x1b]112\x07");
    assert_eq!(term.color_overrides(), Default::default());
}

#[test]
fn color_override_authorship_survives_equal_defaults_fragmentation_and_queries() {
    let foreground = Rgb { r: 17, g: 18, b: 19 };
    let palette_color = Rgb { r: 1, g: 2, b: 3 };
    let mut term = Terminal::new(5, 1, 0, Callbacks::default()).unwrap();
    term.set_default_colors(Some(foreground), None, None);
    let mut palette = [None; 256];
    palette[3] = Some(palette_color);
    term.set_default_palette(&palette);

    // Queries do not author state, even when split across writes.
    term.vt_write(b"\x1b]10;");
    term.vt_write(b"?\x1b\\\x1b]4;3;?\x07");
    assert_eq!(term.color_overrides(), Default::default());

    // Setting exactly the embedder default is still application-authored.
    term.vt_write(b"\x1b]10;#111213\x1b");
    term.vt_write(b"\\\x1b]4;3;#010203");
    term.vt_write(b"\x07");
    let colors = term.color_overrides();
    assert_eq!(colors.foreground, Some(foreground));
    assert_eq!(colors.palette[3], Some(palette_color));

    term.vt_write(b"\x1b]110\x1b\\\x1b]104;3\x07");
    assert_eq!(term.color_overrides(), Default::default());
}

#[test]
fn color_override_tracker_handles_c1_osc_and_st_without_misreading_utf8() {
    let mut term = Terminal::new(5, 1, 0, Callbacks::default()).unwrap();
    term.vt_write("❝👍".as_bytes());
    assert_eq!(term.color_overrides(), Default::default());

    term.vt_write(b"\x9d10;#010203");
    term.vt_write(b"\x9c\x1b]4;7;#040506");
    term.vt_write(b"\x9c");
    let colors = term.color_overrides();
    assert_eq!(colors.foreground, Some(Rgb { r: 1, g: 2, b: 3 }));
    assert_eq!(colors.palette[7], Some(Rgb { r: 4, g: 5, b: 6 }));

    term.vt_write(b"\x9d110\x9c\x9d104;7\x9c");
    assert_eq!(term.color_overrides(), Default::default());
}

#[test]
fn theme_portable_replay_omits_terminal_color_osc_state() {
    let mut source = Terminal::new(20, 2, 100, Callbacks::default()).unwrap();
    source.vt_write(
        b"\x1b]4;3;#010203\x07\x1b]10;#111213\x07\x1b]11;#212223\x07\
          \x1b]12;#313233\x07hello",
    );
    let portable = source.vt_replay_bounded_theme_portable(1024 * 1024).unwrap();
    let replay_text = String::from_utf8_lossy(&portable);
    for color_osc in ["\x1b]4;", "\x1b]10;", "\x1b]11;", "\x1b]12;"] {
        assert!(!replay_text.contains(color_osc), "portable replay leaked {color_osc:?}");
    }

    let mut target = Terminal::new(20, 2, 100, Callbacks::default()).unwrap();
    target.set_default_colors(
        Some(Rgb { r: 240, g: 241, b: 242 }),
        Some(Rgb { r: 4, g: 5, b: 6 }),
        Some(Rgb { r: 7, g: 8, b: 9 }),
    );
    target.vt_write(&portable);
    assert_eq!(target.color_overrides(), Default::default());
    assert!(target.viewport_text().unwrap().contains("hello"));
}
