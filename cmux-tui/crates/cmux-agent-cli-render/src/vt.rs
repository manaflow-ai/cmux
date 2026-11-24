//! A hybrid frame as terminal bytes, so a viewer keeps drawing with its own terminal (its
//! font, theme and scrollback: today's look) and only the wire changes.
//!
//! The viewer's terminal gets no byte the CLI wrote: only cursor moves, SGR, the changed
//! cells' text, line feeds for a scroll up (so scrolled rows reach its scrollback, as they do
//! from the PTY) and `CSI n T` for a scroll down. `tests/parity.rs` feeds these bytes to a
//! fresh ghostty-vt terminal and checks every frame against the real screen. The phone's
//! Swift decoder (`AgentCLIHybridFrame.swift` `terminalBytes`) makes the same bytes.

use std::fmt::Write as _;

use crate::hybrid::{Delta, Span};
use crate::stream::Frame;
use crate::{
    BLINK, BOLD, Color, FAINT, INVERSE, INVISIBLE, ITALIC, STRIKETHROUGH, Style, UNDERLINE,
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

fn set_style(out: &mut String, style: &mut Option<Style>, want: Style) {
    if *style != Some(want) {
        sgr(out, want);
        *style = Some(want);
    }
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
                // Whether the cursor stands at the next cell's column. After a glyph that is
                // not one ASCII character it may not: the viewer's terminal gives it the width
                // its own Unicode tables say (🚀 and ✅ are wide in Ghostty), so the next
                // cell is placed by column.
                let mut placed = true;
                let mut skip = false;
                for (i, cell) in cells.iter().enumerate() {
                    let x = col.saturating_add(u16::try_from(i).unwrap_or(u16::MAX));
                    if std::mem::take(&mut skip) {
                        continue;
                    }
                    let ascii = matches!(cell.text.as_bytes(), [b] if (0x20..=0x7e).contains(b));
                    let next = cells.get(i + 1).filter(|next| next.text.is_empty());
                    if !ascii
                        && !cell.text.is_empty()
                        && let Some(next) = next
                    {
                        // The empty cell right of a glyph first: a wide glyph then covers it,
                        // a narrow one leaves it blank. Which it is is the viewer's to say.
                        let _ = write!(out, "\x1b[{};{}H", row + 1, x.saturating_add(2));
                        set_style(&mut out, &mut style, next.style);
                        out.push(' ');
                        let _ = write!(out, "\x1b[{};{}H", row + 1, x.saturating_add(1));
                        set_style(&mut out, &mut style, cell.style);
                        out.push_str(&cell.text);
                        skip = true;
                        placed = false;
                        continue;
                    }
                    if !placed {
                        let _ = write!(out, "\x1b[{};{}H", row + 1, x.saturating_add(1));
                    }
                    set_style(&mut out, &mut style, cell.style);
                    if cell.text.is_empty() {
                        out.push(' ');
                        placed = true;
                        continue;
                    }
                    out.push_str(&cell.text);
                    placed = ascii;
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
#[path = "vt_tests.rs"]
mod tests;
