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

use std::hash::{Hash, Hasher};

use crate::{Cell, Color, Grid, INVERSE, Style};

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
            let mut changes: Vec<Change> = row
                .iter()
                .enumerate()
                .map(|(x, over)| {
                    let want = cell_at(real, y, x).unwrap_or(&blank);
                    let under = cell_at(drawn, y, x).unwrap_or(&blank);
                    let shown = over.as_ref().unwrap_or(under);
                    if shown.looks_same(want) {
                        Change::Keep
                    } else if under.looks_same(want) {
                        Change::Clear
                    } else {
                        Change::Set(want.clone())
                    }
                })
                .collect();
            // A glyph that is not one ASCII character and the empty cell right of it (the right
            // half of a wide glyph): a blank written or erased over the right half erases the
            // glyph in the viewer's terminal (a right half that looks blank, as one with only a
            // foreground does, would otherwise go as a clear). So a right half that changes goes
            // as a set, and its glyph is set with it. A glyph set over a right half that already
            // looks right needs nothing more.
            // The right half of a wide glyph has the glyph's style when the daemon's grid gives
            // it, so the two go in one span. A right half of another style (a blank right of a
            // narrow glyph, or a wide glyph's spacer the grid left plain) goes as its own span
            // before the glyph's, so the glyph is written over it and stays.
            let mut right_half = vec![false; changes.len()];
            for x in 0..changes.len().saturating_sub(1) {
                let (Some(glyph), Some(right)) = (cell_at(real, y, x), cell_at(real, y, x + 1))
                else {
                    break;
                };
                let paired = right.text.is_empty()
                    && !glyph.text.is_empty()
                    && !matches!(glyph.text.as_bytes(), [b] if (0x20..=0x7e).contains(b));
                if paired
                    && let [this, next, ..] = changes.get_mut(x..).unwrap_or_default()
                    && !matches!(next, Change::Keep)
                {
                    *this = Change::Set(glyph.clone());
                    *next = Change::Set(right.clone());
                    if let [_, half, ..] = right_half.get_mut(x..).unwrap_or_default() {
                        *half = true;
                    }
                }
            }
            let mut open: Option<Span> = None;
            for (x, change) in changes.into_iter().enumerate() {
                let Ok(col) = u16::try_from(x) else { break };
                if let (Change::Set(cell), Some(Span::Set { cells, .. })) = (&change, &mut open)
                    && right_half.get(x).copied().unwrap_or(false)
                    && cells.first().is_some_and(|first| first.style != cell.style)
                {
                    let glyph: Vec<Cell> = cells.pop().into_iter().collect();
                    // The open span ends here either way. Held only the glyph, it is now empty
                    // and goes nowhere: a set of no cells is a frame the phone refuses.
                    let only_glyph = cells.is_empty();
                    let earlier = open.take();
                    if !only_glyph {
                        spans.extend(earlier);
                    }
                    spans.push(Span::Set { row: row_no, col, cells: vec![cell.clone()] });
                    // The glyph's span ends here: it starts left of this cell, so the next cell
                    // cannot join it.
                    spans.push(Span::Set { row: row_no, col: col.saturating_sub(1), cells: glyph });
                    continue;
                }
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

    /// [`Overlay::scroll`] over a blank drawn screen. An override there never looks blank (a
    /// diff over blank sets only cells that do not), so the rows just move: no compose, no
    /// clone of a cell.
    pub fn scroll_over_blank(&mut self, by: i16) {
        let rows = self.cells.len();
        let n = usize::from(by.unsigned_abs()).min(rows);
        if n == 0 {
            return;
        }
        let incoming = if by > 0 {
            self.cells.rotate_left(n);
            rows - n..rows
        } else {
            self.cells.rotate_right(n);
            0..n
        };
        for row in self.cells.get_mut(incoming).into_iter().flatten() {
            row.fill(None);
        }
    }

    /// [`Overlay::apply_delta`] over a blank drawn screen.
    pub fn apply_delta_over_blank(&mut self, delta: &Delta) {
        self.scroll_over_blank(delta.shift);
        self.apply(&delta.spans);
    }

    /// Each row's [`row_hash`] as shown over a blank drawn screen, into `out`.
    pub fn row_hashes_over_blank(&self, out: &mut Vec<u64>) {
        let blank = Cell::default();
        out.clear();
        out.extend(
            self.cells
                .iter()
                .map(|row| row_hash(row.iter().map(|over| over.as_ref().unwrap_or(&blank)))),
        );
    }

    /// [`Overlay::delta`] over a blank drawn screen, from the rows that changed. `shown` are the
    /// overlay's row hashes, `real` `real`'s ([`row_hash`]); a row whose hash matches after a
    /// shift is not diffed. Shifts are ranked by how many rows they line up, and only the best
    /// `SHIFT_TRIES` are diffed and encoded, against no shift; the smallest wins, as in
    /// [`Overlay::delta`]. `None`: the screen already shows `real`.
    pub fn delta_over_blank(
        &self,
        real: &Grid,
        shown: &[u64],
        real_hashes: &[u64],
        seq: u64,
        at_ms: u64,
        scratch: &mut Vec<u8>,
    ) -> Option<Delta> {
        if shown == real_hashes {
            return None;
        }
        let rows = shown.len();
        let blank_row = row_hash((0..self.cols).map(|_| &BLANK));
        let from = |by: i16, y: usize| -> Option<usize> {
            let n = usize::from(by.unsigned_abs());
            if by >= 0 { y.checked_add(n).filter(|from| *from < rows) } else { y.checked_sub(n) }
        };
        let shifted = |by: i16, y: usize| from(by, y).and_then(|y| shown.get(y)).copied();
        let lined_up = |by: i16| {
            real_hashes
                .iter()
                .enumerate()
                .filter(|(y, want)| shifted(by, *y).unwrap_or(blank_row) == **want)
                .count()
        };
        let mut tries = [(0i16, lined_up(0)); SHIFT_TRIES + 1];
        let limit = i16::try_from(self.rows).unwrap_or(i16::MAX);
        for by in (-(limit / 4)..limit).filter(|by| *by != 0) {
            let score = lined_up(by);
            // Kept best first; a later shift needs strictly more rows to displace one.
            let Some((_, kept)) = tries.split_first_mut() else { continue };
            let Some(at) = kept.iter().position(|(_, best)| score > *best) else { continue };
            if let Some(tail) = kept.get_mut(at..) {
                tail.rotate_right(1);
                if let Some(slot) = tail.first_mut() {
                    *slot = (by, score);
                }
            }
        }
        let mut best: Option<(Delta, usize)> = None;
        for (by, score) in tries {
            if best.is_some() && score <= tries[0].1 {
                continue;
            }
            let mut spans = Vec::new();
            for (y, want) in real_hashes.iter().enumerate() {
                if shifted(by, y).unwrap_or(blank_row) == *want {
                    continue;
                }
                let source = from(by, y).and_then(|y| self.cells.get(y));
                self.diff_row_over_blank(y, source, real, &mut spans);
            }
            let candidate = Delta { seq, at_ms, shift: by, spans };
            scratch.clear();
            candidate.encode_into(scratch);
            if best.as_ref().is_none_or(|(_, len)| scratch.len() < *len) {
                best = Some((candidate, scratch.len()));
            }
        }
        best.map(|(delta, _)| delta)
    }

    /// [`Overlay::diff`]'s spans for row `y`, its overrides `source` (a shifted row, `None`
    /// for a row scrolled in blank), over a blank drawn screen.
    fn diff_row_over_blank(
        &self,
        y: usize,
        source: Option<&Vec<Option<Cell>>>,
        real: &Grid,
        spans: &mut Vec<Span>,
    ) {
        let Ok(row_no) = u16::try_from(y) else { return };
        let mut open: Option<Span> = None;
        for x in 0..usize::from(self.cols) {
            let Ok(col) = u16::try_from(x) else { break };
            let want = cell_at(real, y, x).unwrap_or(&BLANK);
            let shown =
                source.and_then(|row| row.get(x)).and_then(Option::as_ref).unwrap_or(&BLANK);
            let change = if shown.looks_same(want) {
                Change::Keep
            } else if BLANK.looks_same(want) {
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

/// How many shifts besides none [`Overlay::delta_over_blank`] diffs and encodes.
const SHIFT_TRIES: usize = 2;

static BLANK: Cell = Cell { text: String::new(), style: Style::PLAIN };

/// A row's hash, equal for rows whose cells [`Cell::looks_same`]: a cell that draws no glyph
/// hashes as one blank, its foreground only under inverse.
pub fn row_hash<'a>(cells: impl Iterator<Item = &'a Cell>) -> u64 {
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    for cell in cells {
        let style = cell.style;
        if cell.is_blank() {
            0u8.hash(&mut hasher);
            if style.attrs & INVERSE != 0 {
                style.fg.hash(&mut hasher);
            }
        } else {
            1u8.hash(&mut hasher);
            cell.text.hash(&mut hasher);
            style.fg.hash(&mut hasher);
        }
        style.bg.hash(&mut hasher);
        style.attrs.hash(&mut hasher);
    }
    hasher.finish()
}

/// [`row_hash`] of each of `grid`'s rows, `cols` cells each (a missing cell is blank), into `out`.
pub fn grid_row_hashes(grid: &Grid, cols: u16, rows: u16, out: &mut Vec<u64>) {
    out.clear();
    out.extend(
        (0..usize::from(rows)).map(|y| {
            row_hash((0..usize::from(cols)).map(|x| cell_at(grid, y, x).unwrap_or(&BLANK)))
        }),
    );
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

    /// An unsigned LEB128 value; `None` when the bytes end first or it does not fit 64 bits.
    /// The tenth byte holds bit 63 alone: anything more (a higher bit, or an eleventh byte) is a
    /// value past 64 bits, which the shift would drop and read as a smaller one.
    fn varint(&mut self) -> Option<u64> {
        let mut value = 0u64;
        let mut shift = 0;
        loop {
            let byte = self.byte()?;
            if shift == 63 && byte > 1 {
                return None;
            }
            value |= u64::from(byte & 0x7f).checked_shl(shift)?;
            if byte & 0x80 == 0 {
                return Some(value);
            }
            shift += 7;
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
        self.encode_into(&mut out);
        out
    }

    /// [`Delta::encode`], appended to `out`.
    pub fn encode_into(&self, out: &mut Vec<u8>) {
        put(out, self.seq);
        put(out, self.at_ms);
        // Zigzag, so a small scroll either way is one byte.
        let shift = i32::from(self.shift);
        put(out, ((shift << 1) ^ (shift >> 31)) as u64);
        put(out, self.spans.len() as u64);
        for span in &self.spans {
            match span {
                Span::Set { row, col, cells } => {
                    put(out, u64::from(*row));
                    put(out, u64::from(*col));
                    put(out, ((cells.len() as u64) << 1) | 1);
                    let style = cells.first().map(|cell| cell.style).unwrap_or_default();
                    put_color(out, style.fg);
                    put_color(out, style.bg);
                    put(out, u64::from(style.attrs));
                    for cell in cells {
                        put_text(out, &cell.text);
                    }
                }
                Span::Clear { row, col, len } => {
                    put(out, u64::from(*row));
                    put(out, u64::from(*col));
                    put(out, u64::from(*len) << 1);
                }
            }
        }
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
#[path = "hybrid_tests.rs"]
mod tests;
