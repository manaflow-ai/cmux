use std::sync::{Arc, Mutex};

use ghostty_vt::{Callbacks, Dirty, RenderState, Terminal};

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
