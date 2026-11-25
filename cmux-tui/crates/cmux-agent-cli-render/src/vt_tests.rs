use super::*;
use crate::Cell;

#[test]
fn a_keyframe_clears_then_writes_its_cells_in_their_style() {
    let cells = |text: &str, style| {
        text.chars().map(|c| Cell { text: c.to_string(), style }).collect::<Vec<_>>()
    };
    let delta = Delta {
        seq: 0,
        at_ms: 0,
        shift: 0,
        spans: vec![
            Span::Set { row: 0, col: 2, cells: cells("hi", Style::fg(174).with(BOLD)) },
            Span::Clear { row: 1, col: 0, len: 3 },
        ],
    };
    let frame = Frame { frame: 1, base: None, data: delta.encode() };
    let bytes = frame_bytes(&frame, 4, Cursor { x: 1, y: 3, visible: true }).unwrap();
    let text = String::from_utf8(bytes).unwrap();
    assert_eq!(
        text,
        "\x1b[?2026h\x1b[?25l\x1b[0m\x1b[H\x1b[2J\x1b[1;3H\x1b[0;1;38;5;174mhi\x1b[0m\
             \x1b[2;1H\x1b[3X\x1b[0m\x1b[4;2H\x1b[?25h\x1b[?2026l"
    );
}

/// A glyph that is not ASCII and the empty cell right of it: that cell is drawn blank
/// first, then the glyph, which covers it when the viewer's terminal makes it wide; the
/// next cell is placed by column (the phone's `AgentCLIHybridFrameTests` expects the same).
#[test]
fn a_wide_glyph_never_depends_on_a_width_table() {
    let style = Style { fg: Color::Rgb(1, 2, 3), bg: Color::Palette(9), attrs: UNDERLINE };
    let cell = |text: &str| Cell { text: text.to_owned(), style };
    let delta = Delta {
        seq: 0,
        at_ms: 0,
        shift: 0,
        spans: vec![Span::Set {
            row: 0,
            col: 0,
            cells: vec![cell("\u{1f680}"), cell(""), cell("a"), cell("\u{e9}"), cell("b")],
        }],
    };
    let frame = Frame { frame: 1, base: None, data: delta.encode() };
    let text = String::from_utf8(frame_bytes(&frame, 4, Cursor::default()).unwrap()).unwrap();
    assert_eq!(
        text,
        "\x1b[?2026h\x1b[?25l\x1b[0m\x1b[H\x1b[2J\x1b[1;1H\x1b[1;2H\x1b[0;4;38;2;1;2;3;101m \
             \x1b[1;1H\u{1f680}\x1b[1;3Ha\u{e9}\x1b[1;5Hb\x1b[0m\x1b[1;1H\x1b[?2026l"
    );
}

#[test]
fn a_scroll_up_is_line_feeds_on_the_last_row() {
    let delta = Delta { seq: 0, at_ms: 0, shift: 2, spans: vec![] };
    let frame = Frame { frame: 2, base: Some(1), data: delta.encode() };
    let text = String::from_utf8(frame_bytes(&frame, 32, Cursor::default()).unwrap()).unwrap();
    assert!(text.contains("\x1b[32;1H\n\n"), "{text:?}");
    assert!(!text.contains("\x1b[2J"));
}
