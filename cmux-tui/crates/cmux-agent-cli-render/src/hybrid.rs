//! Hybrid: draw the transcript from records, and send only the cells that drawing gets wrong.
//!
//! The records draw most of an agent CLI's screen ([`crate::claude::render`]), but not what
//! only the CLI's screen holds: its permission dialog, the spinner's verb, time and tokens, the
//! finished-turn line, the draft being typed, and whatever the transcript has not caught up
//! with yet. The Mac has both the real screen (the PTY through the terminal) and what the phone
//! draws from the same records, so it can send just the difference. An [`Overlay`] is the
//! phone's set of cells shown over the drawn screen; a [`Delta`] changes it, per row: spans of
//! cells to show as the real ones, and spans whose override goes because the records now draw
//! them right. Each delta names the record seq it was computed against.

use crate::{Cell, Color, Grid, Style};

/// One change to an [`Overlay`] row.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Span {
    /// Show these cells, all of one style, from `col` on, over what the records draw.
    Set { row: u16, col: u16, cells: Vec<Cell> },
    /// Drop the overrides on `len` cells from `col` on: the records draw them right.
    Clear { row: u16, col: u16, len: u16 },
}

/// One frame of changes, computed against the records up to `seq`, `at_ms` into the session.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Delta {
    pub seq: u64,
    pub at_ms: u64,
    /// Rows the shown screen scrolls up before the spans apply (down when negative), the way
    /// the terminal scrolled: a CLI that prints a line moves every row, and a plain cell diff
    /// would resend them all.
    pub shift: i16,
    pub spans: Vec<Span>,
}

/// The cells shown over the drawn screen. The Mac keeps the same overlay the phone has, so it
/// knows what the phone shows.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Overlay {
    cols: u16,
    rows: u16,
    cells: Vec<Vec<Option<Cell>>>,
}

enum Change {
    Keep,
    Clear,
    Set(Cell),
}

fn cell_at(grid: &Grid, y: usize, x: usize) -> Option<&Cell> {
    grid.cells.get(y).and_then(|row| row.get(x))
}

impl Overlay {
    pub fn new(cols: u16, rows: u16) -> Overlay {
        Overlay { cols, rows, cells: vec![vec![None; usize::from(cols)]; usize::from(rows)] }
    }

    /// How many cells the overlay overrides.
    pub fn overrides(&self) -> usize {
        self.cells.iter().flatten().filter(|cell| cell.is_some()).count()
    }

    /// What the phone shows: each override, else the drawn cell.
    pub fn compose(&self, drawn: &Grid) -> Grid {
        let blank = Cell::default();
        let cells = self
            .cells
            .iter()
            .enumerate()
            .map(|(y, row)| {
                row.iter()
                    .enumerate()
                    .map(|(x, over)| {
                        over.as_ref().or_else(|| cell_at(drawn, y, x)).unwrap_or(&blank).clone()
                    })
                    .collect()
            })
            .collect();
        Grid { cols: self.cols, rows: self.rows, cells }
    }

    /// The spans that make the shown screen look like `real`: a cell that already looks right
    /// stays as it is, one the records draw right loses its override, and any other is set to
    /// the real cell.
    pub fn diff(&self, drawn: &Grid, real: &Grid) -> Vec<Span> {
        let blank = Cell::default();
        let mut spans = Vec::new();
        for (y, row) in self.cells.iter().enumerate() {
            let Ok(row_no) = u16::try_from(y) else { break };
            let mut open: Option<Span> = None;
            for (x, over) in row.iter().enumerate() {
                let Ok(col) = u16::try_from(x) else { break };
                let want = cell_at(real, y, x).unwrap_or(&blank);
                let under = cell_at(drawn, y, x).unwrap_or(&blank);
                let shown = over.as_ref().unwrap_or(under);
                let change = if shown.looks_same(want) {
                    Change::Keep
                } else if under.looks_same(want) {
                    Change::Clear
                } else {
                    Change::Set(want.clone())
                };
                match (change, &mut open) {
                    (Change::Clear, Some(Span::Clear { len, .. })) => *len += 1,
                    (Change::Set(cell), Some(Span::Set { cells, .. }))
                        if cells.first().is_some_and(|first| first.style == cell.style) =>
                    {
                        cells.push(cell);
                    }
                    (change, open) => {
                        spans.extend(open.take());
                        *open = match change {
                            Change::Keep => None,
                            Change::Clear => Some(Span::Clear { row: row_no, col, len: 1 }),
                            Change::Set(cell) => {
                                Some(Span::Set { row: row_no, col, cells: vec![cell] })
                            }
                        };
                    }
                }
            }
            spans.extend(open);
        }
        spans
    }

    /// Scroll the shown screen up by `by` rows (down when negative), blank rows coming in. A
    /// moved cell that the records draw the same at its new place needs no override.
    pub fn scroll(&mut self, drawn: &Grid, by: i16) {
        if by == 0 {
            return;
        }
        let shown = self.compose(drawn);
        let rows = usize::from(self.rows);
        let n = usize::from(by.unsigned_abs());
        let blank = Cell::default();
        for (y, row) in self.cells.iter_mut().enumerate() {
            let from = if by > 0 {
                y.checked_add(n).filter(|from| *from < rows)
            } else {
                y.checked_sub(n)
            };
            for (x, slot) in row.iter_mut().enumerate() {
                let moved = from.and_then(|from| cell_at(&shown, from, x)).unwrap_or(&blank);
                let under = cell_at(drawn, y, x).unwrap_or(&blank);
                *slot = (!moved.looks_same(under)).then(|| moved.clone());
            }
        }
    }

    /// The smallest delta that makes the shown screen look like `real`: the plain diff, or a
    /// scroll and the diff after it, whichever takes fewer bytes.
    pub fn delta(&self, drawn: &Grid, real: &Grid, seq: u64, at_ms: u64) -> Delta {
        let mut best = Delta { seq, at_ms, shift: 0, spans: self.diff(drawn, real) };
        let mut best_len = best.encode().len();
        if best.spans.is_empty() {
            return best;
        }
        let rows = i16::try_from(self.rows).unwrap_or(i16::MAX);
        for by in (-(rows / 4)..rows).filter(|by| *by != 0) {
            let mut moved = self.clone();
            moved.scroll(drawn, by);
            let candidate = Delta { seq, at_ms, shift: by, spans: moved.diff(drawn, real) };
            let len = candidate.encode().len();
            if len < best_len {
                (best, best_len) = (candidate, len);
            }
        }
        best
    }

    /// Apply a delta: its scroll, then its spans.
    pub fn apply_delta(&mut self, delta: &Delta, drawn: &Grid) {
        self.scroll(drawn, delta.shift);
        self.apply(&delta.spans);
    }

    /// Apply spans.
    pub fn apply(&mut self, spans: &[Span]) {
        for span in spans {
            match span {
                Span::Set { row, col, cells } => {
                    if let Some(slots) = self.cells.get_mut(usize::from(*row)) {
                        for (slot, cell) in slots.iter_mut().skip(usize::from(*col)).zip(cells) {
                            *slot = Some(cell.clone());
                        }
                    }
                }
                Span::Clear { row, col, len } => {
                    if let Some(slots) = self.cells.get_mut(usize::from(*row)) {
                        for slot in slots.iter_mut().skip(usize::from(*col)).take(usize::from(*len))
                        {
                            *slot = None;
                        }
                    }
                }
            }
        }
    }
}

fn put(out: &mut Vec<u8>, mut value: u64) {
    loop {
        let low = (value & 0x7f) as u8;
        value >>= 7;
        if value == 0 {
            out.push(low);
            return;
        }
        out.push(low | 0x80);
    }
}

fn put_color(out: &mut Vec<u8>, color: Color) {
    match color {
        Color::Default => out.push(0),
        Color::Palette(index) => out.extend([1, index]),
        Color::Rgb(r, g, b) => out.extend([2, r, g, b]),
    }
}

/// A cell's text: a printable ASCII byte as itself, an empty cell as 2, anything else as 1,
/// its length and its UTF-8 bytes.
fn put_text(out: &mut Vec<u8>, text: &str) {
    match text.as_bytes() {
        [byte @ 0x20..=0x7e] => out.push(*byte),
        [] => out.push(2),
        bytes => {
            out.push(1);
            put(out, bytes.len() as u64);
            out.extend_from_slice(bytes);
        }
    }
}

struct Reader<'a> {
    bytes: &'a [u8],
    pos: usize,
}

impl<'a> Reader<'a> {
    fn byte(&mut self) -> Option<u8> {
        let byte = *self.bytes.get(self.pos)?;
        self.pos += 1;
        Some(byte)
    }

    fn take(&mut self, len: usize) -> Option<&'a [u8]> {
        let end = self.pos.checked_add(len)?;
        let bytes = self.bytes.get(self.pos..end)?;
        self.pos = end;
        Some(bytes)
    }

    fn varint(&mut self) -> Option<u64> {
        let mut value = 0u64;
        let mut shift = 0;
        loop {
            let byte = self.byte()?;
            value |= u64::from(byte & 0x7f).checked_shl(shift)?;
            if byte & 0x80 == 0 {
                return Some(value);
            }
            shift += 7;
            if shift > 63 {
                return None;
            }
        }
    }

    fn u16(&mut self) -> Option<u16> {
        u16::try_from(self.varint()?).ok()
    }

    fn color(&mut self) -> Option<Color> {
        Some(match self.byte()? {
            0 => Color::Default,
            1 => Color::Palette(self.byte()?),
            2 => Color::Rgb(self.byte()?, self.byte()?, self.byte()?),
            _ => return None,
        })
    }

    fn text(&mut self) -> Option<String> {
        Some(match self.byte()? {
            byte @ 0x20..=0x7e => char::from(byte).to_string(),
            2 => String::new(),
            1 => {
                let len = usize::try_from(self.varint()?).ok()?;
                String::from_utf8(self.take(len)?.to_vec()).ok()?
            }
            _ => return None,
        })
    }
}

impl Delta {
    /// The delta on the wire: varints for numbers, a span's style once, then its cells' text.
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        put(&mut out, self.seq);
        put(&mut out, self.at_ms);
        // Zigzag, so a small scroll either way is one byte.
        let shift = i32::from(self.shift);
        put(&mut out, ((shift << 1) ^ (shift >> 31)) as u64);
        put(&mut out, self.spans.len() as u64);
        for span in &self.spans {
            match span {
                Span::Set { row, col, cells } => {
                    put(&mut out, u64::from(*row));
                    put(&mut out, u64::from(*col));
                    put(&mut out, ((cells.len() as u64) << 1) | 1);
                    let style = cells.first().map(|cell| cell.style).unwrap_or_default();
                    put_color(&mut out, style.fg);
                    put_color(&mut out, style.bg);
                    put(&mut out, u64::from(style.attrs));
                    for cell in cells {
                        put_text(&mut out, &cell.text);
                    }
                }
                Span::Clear { row, col, len } => {
                    put(&mut out, u64::from(*row));
                    put(&mut out, u64::from(*col));
                    put(&mut out, u64::from(*len) << 1);
                }
            }
        }
        out
    }

    /// A delta [`Delta::encode`] wrote, or `None` when the bytes aren't one.
    pub fn decode(bytes: &[u8]) -> Option<Delta> {
        let mut r = Reader { bytes, pos: 0 };
        let seq = r.varint()?;
        let at_ms = r.varint()?;
        let zigzag = r.u16()?;
        let shift = ((zigzag >> 1) as i16) ^ -((zigzag & 1) as i16);
        let count = r.varint()?;
        let mut spans = Vec::new();
        for _ in 0..count {
            let row = r.u16()?;
            let col = r.u16()?;
            let len = r.varint()?;
            let n = u16::try_from(len >> 1).ok()?;
            if len & 1 == 0 {
                spans.push(Span::Clear { row, col, len: n });
                continue;
            }
            let style = Style { fg: r.color()?, bg: r.color()?, attrs: r.u16()? };
            let cells =
                (0..n).map(|_| Some(Cell { text: r.text()?, style })).collect::<Option<_>>()?;
            spans.push(Span::Set { row, col, cells });
        }
        (r.pos == bytes.len()).then_some(Delta { seq, at_ms, shift, spans })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{BOLD, Line};

    fn grid(rows: &[&[(&str, Style)]]) -> Grid {
        let mut grid = Grid::blank(20, 4);
        for (slot, parts) in grid.cells.iter_mut().zip(rows) {
            let mut line = Line::new();
            for (text, style) in *parts {
                line.push(text, *style);
            }
            *slot = line.into_row(20);
        }
        grid
    }

    #[test]
    fn a_delta_turns_the_drawn_screen_into_the_real_one() {
        let drawn = grid(&[&[("> hi", Style::PLAIN)], &[("hello", Style::fg(174))]]);
        let real = grid(&[
            &[("> hi", Style::PLAIN)],
            &[("hello", Style::fg(174))],
            &[("Do you want", Style::PLAIN.with(BOLD))],
            &[("✻ Misting…", Style::fg(174))],
        ]);
        let mut overlay = Overlay::new(20, 4);
        let spans = overlay.diff(&drawn, &real);
        // Only the two rows the records lack. The space after the spinner draws the same pixels
        // as the drawn blank, so it splits that row's span in two.
        let at: Vec<(u16, u16)> = spans
            .iter()
            .map(|s| match s {
                Span::Set { row, col, .. } | Span::Clear { row, col, .. } => (*row, *col),
            })
            .collect();
        assert_eq!(at, [(2, 0), (3, 0), (3, 2)]);
        overlay.apply(&spans);
        assert_eq!(real.parity(&overlay.compose(&drawn)), (80, 80));
        assert!(overlay.diff(&drawn, &real).is_empty());
    }

    #[test]
    fn an_override_goes_when_the_screen_moves_on_to_what_the_records_draw() {
        let drawn = grid(&[&[("> hi", Style::PLAIN)]]);
        let dialog = grid(&[&[("Allow? y/n", Style::PLAIN)]]);
        let mut overlay = Overlay::new(20, 4);
        overlay.apply(&overlay.diff(&drawn, &dialog));
        assert!(overlay.overrides() > 0);
        // The dialog closes and the screen is what the records draw again.
        let spans = overlay.diff(&drawn, &drawn);
        assert!(spans.iter().all(|s| matches!(s, Span::Clear { row: 0, .. })), "{spans:?}");
        overlay.apply(&spans);
        assert_eq!(drawn.parity(&overlay.compose(&drawn)), (80, 80));
    }

    #[test]
    fn a_scrolled_screen_moves_the_overlay_instead_of_resending_it() {
        let drawn = Grid::blank(20, 4);
        let line = |text| (text, Style::fg(246));
        let before = grid(&[&[line("one")], &[line("two")], &[line("three")], &[line("four")]]);
        let after = grid(&[&[line("three")], &[line("four")], &[line("five")], &[line("six")]]);
        let mut overlay = Overlay::new(20, 4);
        overlay.apply_delta(&overlay.delta(&drawn, &before, 1, 0), &drawn);
        let delta = overlay.delta(&drawn, &after, 1, 10);
        // Two lines printed: a scroll of two and the two new rows, nothing else.
        assert_eq!(delta.shift, 2);
        assert!(delta.spans.iter().all(|s| matches!(s, Span::Set { row: 2 | 3, .. })), "{delta:?}");
        overlay.apply_delta(&delta, &drawn);
        assert_eq!(after.parity(&overlay.compose(&drawn)), (80, 80));
    }

    #[test]
    fn a_delta_round_trips_through_its_bytes() {
        let delta = Delta {
            seq: 300,
            at_ms: 25_000,
            shift: -3,
            spans: vec![
                Span::Set {
                    row: 3,
                    col: 7,
                    cells: ["✻", "a", "", "字", " "]
                        .into_iter()
                        .map(|text| Cell {
                            text: text.into(),
                            style: Style {
                                fg: Color::Rgb(1, 2, 3),
                                bg: Color::Palette(237),
                                attrs: BOLD,
                            },
                        })
                        .collect(),
                },
                Span::Clear { row: 31, col: 99, len: 1 },
            ],
        };
        let bytes = delta.encode();
        assert_eq!(Delta::decode(&bytes), Some(delta));
        assert_eq!(Delta::decode(&bytes[..bytes.len() - 1]), None);
    }
}
