//! Inline apps laid out again at the phone's width (compact mode, the
//! default).
//!
//! Leo, 2026-11-25: "we know what a Mac's Claude code pane looks like. And
//! we know it/can know it for any variation/combination at various phone
//! sizes. [...] do everything at parity on the phone".
//!
//! Claude Code (Ink) and Codex (ratatui) lay their transcript and their live
//! frame out for the host's width: paragraphs word-wrapped under a gutter
//! glyph with a hanging indent (`⏺ text`, `• text`, `> text`, `  ⎿  text`),
//! an input box whose borders span the width (`│ > typed │`), a tinted
//! composer bar padded to the edge (` › typed`). Re-wrapped cell by cell, such
//! a paragraph breaks mid-word at the phone's edge, keeps the host's breaks
//! as short rows, and a box row's right border lands on the next row. Here
//! they are laid out the way the app lays them out for the phone's width:
//!
//! - The host rows of one paragraph join: a row that ended because its next
//!   word did not fit the host's width, followed by a row at the same indent
//!   ([`continues`]).
//! - The paragraph's words wrap again at the phone's width under the same
//!   gutter and indent, the way the app wraps them ([`layout`]).
//! - A box keeps its left border, its padding and its right border at the
//!   phone's edges; a bar is padded with its tint to the phone's edge.
//!
//! Every glyph stays (the words move between rows); only the blanks that
//! padded a row to the host's width change. A line holding the cursor is left
//! to the cell-by-cell wrap (a shell prompt, a line being edited).

use crate::project::{ProjectedRow, Wrapped};
use crate::style::Color;
use crate::terminal::{Cell, NARROW, Row, SPACER_HEAD, Terminal, WIDE_TAIL};

/// Glyphs an inline app puts in a paragraph's gutter: Claude Code's message
/// and tool marks (`⏺`, `●`, `⎿`, `✻`), its prompt echo (`>`), Codex's
/// history cells and composer lead (`•`, `›`).
fn is_gutter(ch: u32) -> bool {
    matches!(char::from_u32(ch), Some('⏺' | '●' | '•' | '›' | '>' | '⎿' | '✻' | '✶' | '✳' | '✢'))
}

/// Left and right borders of a box (`│ text │`).
fn is_side(ch: u32) -> bool {
    matches!(char::from_u32(ch), Some('│' | '┃' | '║'))
}

fn is_blank(cell: Cell) -> bool {
    cell.ch == 0 || cell.ch == u32::from(b' ')
}

/// A written space in the default style (what `{text:<width}` pads with).
const SPACE: Cell = Cell { ch: b' ' as u32, style: 0, kind: NARROW };

/// The most blanks before a gutter glyph, and in a continuation's indent.
const MAX_LEAD: usize = 4;
const MAX_INDENT: usize = 8;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Frame {
    /// Text on the terminal's background.
    Plain,
    /// Inside a box's side borders (`│ ` ... ` │`).
    Box,
    /// A row tinted across the whole width (Codex's composer).
    Bar,
}

/// How an app laid a paragraph's row out.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Shape {
    frame: Frame,
    /// Cells before the text on the row (border, gutter, indent).
    indent: usize,
    /// The paragraph's first row (it has the gutter glyph).
    first: bool,
}

impl Shape {
    /// Cells the frame keeps at the row's right end (a box's ` │`).
    fn right(self) -> usize {
        if self.frame == Frame::Box { 2 } else { 0 }
    }
}

fn cell(row: &Row, x: usize) -> Cell {
    row.cells.get(x).copied().unwrap_or_default()
}

/// Columns `from..to` hold blanks only.
fn blanks(row: &Row, from: usize, to: usize) -> bool {
    (from..to).all(|x| is_blank(cell(row, x)))
}

/// The row's frame: a box's side borders at both edges, or one tint across
/// every column.
fn frame_of(term: &Terminal, row: &Row, host_cols: usize) -> Frame {
    let last = host_cols.saturating_sub(1);
    if host_cols >= 6 && is_side(cell(row, 0).ch) && is_side(cell(row, last).ch) {
        return Frame::Box;
    }
    let bg = |x: usize| term.styles.get(cell(row, x).style).bg;
    let tint = bg(0);
    if tint != Color::Default
        && row.cells.len() >= host_cols
        && (1..host_cols).all(|x| bg(x) == tint)
    {
        return Frame::Bar;
    }
    Frame::Plain
}

/// The paragraph shape of one host row, when an app laid it out: a gutter
/// glyph then text (a paragraph's first row), or an indent then text (a row
/// that goes on with it).
fn shape_of(term: &Terminal, row: &Row, host_cols: usize) -> Option<Shape> {
    if row.wrapped {
        return None;
    }
    let frame = frame_of(term, row, host_cols);
    // Where the text area starts and ends (exclusive).
    let (from, to) = match frame {
        Frame::Box => {
            if !is_blank(cell(row, 1)) || !is_blank(cell(row, host_cols - 2)) {
                return None;
            }
            (2, host_cols - 2)
        }
        Frame::Bar | Frame::Plain => (0, host_cols),
    };
    let lead = (from..to).take_while(|&x| is_blank(cell(row, x))).count();
    let at = from + lead;
    let glyph = cell(row, at);
    if lead <= MAX_LEAD && glyph.kind == NARROW && is_gutter(glyph.ch) {
        // The gutter: one or two blanks after the glyph, then the text (or
        // nothing yet, an empty input box).
        let gap = (at + 1..to).take_while(|&x| is_blank(cell(row, x))).count();
        let empty = at + 1 + gap >= to || blanks(row, at + 1, to);
        if gap >= 1 && (gap <= 2 || empty) {
            let indent = if empty { at + 2 } else { at + 1 + gap };
            return Some(Shape { frame, indent, first: true });
        }
        return None;
    }
    let text = cell(row, at);
    if lead == 0 || lead > MAX_INDENT || at >= to || is_blank(text) || is_gutter(text.ch) {
        return None;
    }
    if frame == Frame::Plain && row.cells.len() <= at {
        return None;
    }
    Some(Shape { frame, indent: at, first: false })
}

/// Where the text of a row ends (exclusive), inside the frame.
fn text_end(row: &Row, shape: Shape, host_cols: usize) -> usize {
    let to = host_cols.saturating_sub(shape.right()).min(row.cells.len());
    let mut end = to;
    while end > shape.indent && is_blank(cell(row, end - 1)) {
        end -= 1;
    }
    end
}

/// The width of the row's first word.
fn first_word(row: &Row, shape: Shape, host_cols: usize) -> usize {
    let to = host_cols.saturating_sub(shape.right()).min(row.cells.len());
    (shape.indent..to).take_while(|&x| !is_blank(cell(row, x))).count()
}

/// `next` goes on with the paragraph `prev` is in: it is a paragraph row of
/// the same frame and indent, and `prev` ended because `next`'s first word
/// did not fit the host's width (an app's word wrap, not a hard line).
pub fn continues(term: &Terminal, prev: &Row, next: &Row, host_cols: usize) -> bool {
    let Some(shape) = shape_of(term, prev, host_cols) else { return false };
    let Some(after) = shape_of(term, next, host_cols) else { return false };
    if after.first || after.frame != shape.frame || after.indent != shape.indent {
        return false;
    }
    let end = text_end(prev, shape, host_cols);
    if end <= shape.indent {
        return false;
    }
    end + 1 + first_word(next, after, host_cols) > host_cols - shape.right()
}

/// `row` may go on in a row not written yet (a line that settles waits for
/// the row after it).
pub fn may_continue(term: &Terminal, row: &Row, host_cols: usize) -> bool {
    shape_of(term, row, host_cols).is_some()
}

/// Glyph cells of `row` in columns `from..to` (a wide glyph's tail and the
/// host's spacer heads go).
fn glyphs(row: &Row, from: usize, to: usize) -> Vec<Cell> {
    row.cells
        .iter()
        .take(to)
        .skip(from)
        .copied()
        .filter(|c| c.kind != WIDE_TAIL && c.kind != SPACER_HEAD)
        .collect()
}

fn width(cells: &[Cell]) -> usize {
    cells.iter().map(|c| c.width()).sum()
}

/// Words wrapped at `width` cells, the way the app wraps a paragraph: words
/// split at blanks (two blanks keep an empty word, so the spacing stays), a
/// word longer than the width split at it.
fn wrap_words(text: &[Cell], width_cols: usize) -> Vec<Vec<Cell>> {
    let w = width_cols.max(1);
    let mut lines: Vec<Vec<Cell>> = Vec::new();
    let mut line: Vec<Cell> = Vec::new();
    // Words with the blank before each (the first has none).
    let mut words: Vec<(Option<Cell>, Vec<Cell>)> = vec![(None, Vec::new())];
    for &c in text {
        if is_blank(c) {
            words.push((Some(c), Vec::new()));
        } else if let Some((_, word)) = words.last_mut() {
            word.push(c);
        }
    }
    for (sep, mut word) in words {
        while width(&word) > w {
            if !line.is_empty() {
                lines.push(std::mem::take(&mut line));
            }
            let mut cut = 0;
            let mut used = 0;
            while let Some(c) = word.get(cut) {
                if used + c.width() > w {
                    break;
                }
                used += c.width();
                cut += 1;
            }
            let rest = word.split_off(cut.max(1));
            lines.push(word);
            word = rest;
        }
        if line.is_empty() {
            line = word;
        } else if width(&line) + 1 + width(&word) <= w {
            line.push(sep.unwrap_or(SPACE));
            line.extend(word);
        } else {
            lines.push(std::mem::replace(&mut line, word));
        }
    }
    if !line.is_empty() {
        lines.push(line);
    }
    lines
}

/// One paragraph (the host rows of one line, see [`continues`]) laid out at
/// `cols` as the app lays it out at that width. None: not an app's
/// paragraph, or the cursor is in it; the cell-by-cell wrap lays it out.
pub fn layout(
    term: &Terminal,
    rows: &[&Row],
    host_cols: usize,
    cols: usize,
    cursor: Option<(usize, usize)>,
) -> Option<Wrapped> {
    if cursor.is_some() {
        return None;
    }
    let (first_row, rest) = rows.split_first()?;
    let shape = shape_of(term, first_row, host_cols)?;
    if !shape.first {
        return None;
    }
    let end = text_end(first_row, shape, host_cols);
    if rest.is_empty() && shape.frame == Frame::Plain && end <= cols {
        // It fits as it is.
        return None;
    }
    let right = shape.right();
    if shape.indent + right + 1 > cols {
        return None;
    }
    // The text: each row's, joined by one blank (the one the app's wrap took).
    let mut text = glyphs(first_row, shape.indent, end);
    for row in rest {
        let row_shape = shape_of(term, row, host_cols)?;
        let row_end = text_end(row, row_shape, host_cols);
        let words = glyphs(row, row_shape.indent, row_end);
        let joint = match (text.last(), words.first()) {
            (Some(a), Some(b)) if a.style == b.style => Cell { ch: b' ' as u32, ..*a },
            _ => SPACE,
        };
        if !text.is_empty() && !words.is_empty() {
            text.push(joint);
        }
        text.extend(words);
    }
    let lead = glyphs(first_row, 0, shape.indent);
    let indent: Vec<Cell> = match shape.frame {
        Frame::Plain => vec![SPACE; shape.indent],
        Frame::Box => {
            let mut v = glyphs(first_row, 0, 2);
            v.extend(std::iter::repeat_n(SPACE, shape.indent.saturating_sub(2)));
            v
        }
        Frame::Bar => {
            let tint = Cell { ch: b' ' as u32, ..cell(first_row, 0) };
            vec![tint; shape.indent]
        }
    };
    let pad = match shape.frame {
        Frame::Bar => {
            let last = cell(first_row, host_cols.saturating_sub(1));
            Some(Cell { ch: b' ' as u32, kind: NARROW, ..last })
        }
        Frame::Box => Some(SPACE),
        Frame::Plain => None,
    };
    let edge = if right > 0 { glyphs(first_row, host_cols - right, host_cols) } else { Vec::new() };
    let mut lines = wrap_words(&text, cols - shape.indent - right);
    if lines.is_empty() {
        lines.push(Vec::new());
    }
    let out = lines
        .into_iter()
        .enumerate()
        .map(|(i, line)| {
            let mut cells = if i == 0 { lead.clone() } else { indent.clone() };
            cells.extend(line);
            if let Some(pad) = pad {
                let to = cols - right;
                while width(&cells) < to {
                    cells.push(pad);
                }
            }
            cells.extend(edge.iter().copied());
            ProjectedRow { cells, wrapped: false }
        })
        .collect();
    Some(Wrapped { rows: out, cursor: None, empty: false })
}

#[cfg(test)]
#[path = "relayout_tests.rs"]
mod tests;
