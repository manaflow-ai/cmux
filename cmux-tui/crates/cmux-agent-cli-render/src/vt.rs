//! A hybrid frame as terminal bytes, so a viewer keeps drawing with its own terminal (its
//! font, theme and scrollback: today's look) and only the wire changes.
//!
//! The viewer's terminal gets no byte the CLI wrote: only cursor moves, SGR, the changed
//! cells' text, line feeds for a scroll up (so scrolled rows reach its scrollback, as they do
//! from the PTY) and `CSI n T` for a scroll down. `tests/parity.rs` feeds these bytes to a
//! fresh ghostty-vt terminal and checks every frame against the real screen. The phone's
//! Swift decoder (`AgentCLIHybridScreen.swift`) does the same steps.

use std::fmt::Write as _;

use crate::hybrid::{Delta, Span};
use crate::stream::Frame;
use crate::{
    BLINK, BOLD, Color, FAINT, INVERSE, INVISIBLE, ITALIC, STRIKETHROUGH, Style, UNDERLINE,
    str_width,
};

/// Where the viewer's cursor goes after a frame.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Cursor {
    pub x: u16,
    pub y: u16,
    pub visible: bool,
}

fn sgr(out: &mut String, style: Style) {
    out.push_str("\x1b[0");
    for (bit, code) in [
        (BOLD, "1"),
        (FAINT, "2"),
        (ITALIC, "3"),
        (UNDERLINE, "4"),
        (BLINK, "5"),
        (INVERSE, "7"),
        (INVISIBLE, "8"),
        (STRIKETHROUGH, "9"),
    ] {
        if style.attrs & bit != 0 {
            out.push(';');
            out.push_str(code);
        }
    }
    let color = |out: &mut String, color: Color, base: u8, bright: u8, extended: u8| match color {
        Color::Default => {}
        Color::Palette(i) if i < 8 => {
            let _ = write!(out, ";{}", base + i);
        }
        Color::Palette(i) if i < 16 => {
            let _ = write!(out, ";{}", bright + i - 8);
        }
        Color::Palette(i) => {
            let _ = write!(out, ";{extended};5;{i}");
        }
        Color::Rgb(r, g, b) => {
            let _ = write!(out, ";{extended};2;{r};{g};{b}");
        }
    };
    color(out, style.fg, 30, 90, 38);
    color(out, style.bg, 40, 100, 48);
    out.push('m');
}

/// The bytes that apply `frame` to a terminal of `rows` rows showing the frame's base (a
/// blank one for a keyframe), then put the cursor at `cursor`. `None` when `frame.data` is
/// not a delta.
pub fn frame_bytes(frame: &Frame, rows: u16, cursor: Cursor) -> Option<Vec<u8>> {
    let delta = Delta::decode(&frame.data)?;
    // Synchronized output (mode 2026): the viewer draws the frame as one update.
    let mut out = String::from("\x1b[?2026h\x1b[?25l\x1b[0m");
    if frame.base.is_none() {
        out.push_str("\x1b[H\x1b[2J");
    }
    match delta.shift {
        0 => {}
        up if up > 0 => {
            // Line feeds on the last row: the rows that leave the top go to scrollback.
            let _ = write!(out, "\x1b[{rows};1H");
            for _ in 0..up {
                out.push('\n');
            }
        }
        down => {
            let _ = write!(out, "\x1b[{}T", down.unsigned_abs());
        }
    }
    let mut style: Option<Style> = None;
    for span in &delta.spans {
        match span {
            Span::Set { row, col, cells } => {
                let _ = write!(out, "\x1b[{};{}H", row + 1, col + 1);
                let mut after_wide = false;
                for cell in cells {
                    if style != Some(cell.style) {
                        sgr(&mut out, cell.style);
                        style = Some(cell.style);
                    }
                    if cell.text.is_empty() {
                        // The trailing half of a wide glyph: the cursor is past it already.
                        if !after_wide {
                            out.push(' ');
                        }
                        after_wide = false;
                        continue;
                    }
                    out.push_str(&cell.text);
                    after_wide = str_width(&cell.text) == 2;
                }
            }
            Span::Clear { row, col, len } => {
                // The drawn screen under the overlay is blank: these cells go back to blank.
                if style != Some(Style::PLAIN) {
                    out.push_str("\x1b[0m");
                    style = Some(Style::PLAIN);
                }
                let _ = write!(out, "\x1b[{};{}H\x1b[{len}X", row + 1, col + 1);
            }
        }
    }
    let _ = write!(out, "\x1b[0m\x1b[{};{}H", cursor.y + 1, cursor.x + 1);
    if cursor.visible {
        out.push_str("\x1b[?25h");
    }
    out.push_str("\x1b[?2026l");
    Some(out.into_bytes())
}

#[cfg(test)]
mod tests {
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

    #[test]
    fn a_scroll_up_is_line_feeds_on_the_last_row() {
        let delta = Delta { seq: 0, at_ms: 0, shift: 2, spans: vec![] };
        let frame = Frame { frame: 2, base: Some(1), data: delta.encode() };
        let text = String::from_utf8(frame_bytes(&frame, 32, Cursor::default()).unwrap()).unwrap();
        assert!(text.contains("\x1b[32;1H\n\n"), "{text:?}");
        assert!(!text.contains("\x1b[2J"));
    }
}
