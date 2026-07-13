use std::sync::{Arc, Mutex};

use ghostty_vt::{Callbacks, Cell, ColorSpec, Dirty, RenderState, Rgb, Terminal};

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

    term.set_default_colors(None, Some(Rgb { r: 0x13, g: 0x14, b: 0x15 }));
    term.vt_write(b"\x1b]11;?\x07");
    assert_eq!(&*pty_out.lock().unwrap(), b"\x1b]11;rgb:1313/1414/1515\x07");

    pty_out.lock().unwrap().clear();
    term.set_default_colors(Some(Rgb { r: 0x01, g: 0x02, b: 0x03 }), None);
    term.vt_write(b"\x1b]10;?\x07");
    assert_eq!(&*pty_out.lock().unwrap(), b"\x1b]10;rgb:0101/0202/0303\x07");

    pty_out.lock().unwrap().clear();
    term.vt_write(b"\x1b]11;rgb:20/40/60\x07");
    term.vt_write(b"\x1b]11;?\x07");
    assert_eq!(&*pty_out.lock().unwrap(), b"\x1b]11;rgb:2020/4040/6060\x07");
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
