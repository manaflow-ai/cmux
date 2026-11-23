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
        let runs = self.runs(drawn, real, |y, x| {
            self.cells[y][x].as_ref().or_else(|| cell_at(drawn, y, x)).unwrap_or(&blank)
        });
        runs.into_iter().map(Run::into_span).collect()
    }

    /// [`Overlay::diff`] over borrowed cells, against what `shown(y, x)` says the phone shows.
    fn runs<'a>(
        &self,
        drawn: &'a Grid,
        real: &'a Grid,
        shown: impl Fn(usize, usize) -> &'a Cell,
    ) -> Vec<Run<'a>> {
        let mut runs = Vec::new();
        for (y, row) in self.cells.iter().enumerate() {
            let Ok(row_no) = u16::try_from(y) else { break };
            let mut open: Option<Run<'a>> = None;
            for x in 0..row.len() {
                let Ok(col) = u16::try_from(x) else { break };
                let want = cell_at(real, y, x).unwrap_or(&BLANK);
                let under = cell_at(drawn, y, x).unwrap_or(&BLANK);
                let change = if shown(y, x).looks_same(want) {
                    None
                } else if under.looks_same(want) {
                    Some(None)
                } else {
                    Some(Some(want))
                };
                match (change, &mut open) {
                    (Some(None), Some(Run::Clear { len, .. })) => *len += 1,
                    (Some(Some(cell)), Some(Run::Set { cells, .. }))
                        if cells.first().is_some_and(|first| first.style == cell.style) =>
                    {
                        cells.push(cell);
                    }
                    (change, open) => {
                        runs.extend(open.take());
                        *open = match change {
                            None => None,
                            Some(None) => Some(Run::Clear { row: row_no, col, len: 1 }),
                            Some(Some(cell)) => {
                                Some(Run::Set { row: row_no, col, cells: vec![cell] })
                            }
                        };
                    }
                }
            }
            runs.extend(open);
        }
        runs
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
    ///
    /// Each scroll is scored on borrowed cells and a byte count (what [`Overlay::scroll`] then
    /// [`Overlay::diff`] would give, without cloning the overlay or a cell): the Mac runs this
    /// for every frame, and the cloning search took about 23 ms on a 50x40 screen, longer than
    /// a 16 ms redraw (the `tui-scroll-lag-projection` duress scenario's `mac_diff_ms`).
    pub fn delta(&self, drawn: &Grid, real: &Grid, seq: u64, at_ms: u64) -> Delta {
        let shown = self.compose(drawn);
        let mut best = self.runs(drawn, real, |y, x| &shown.cells[y][x]);
        if best.is_empty() {
            return Delta { seq, at_ms, shift: 0, spans: Vec::new() };
        }
        let mut best_shift = 0;
        let mut best_len = encoded_len(seq, at_ms, 0, &best);
        let rows = i16::try_from(self.rows).unwrap_or(i16::MAX);
        let height = usize::from(self.rows);
        for by in (-(rows / 4)..rows).filter(|by| *by != 0) {
            let n = usize::from(by.unsigned_abs());
            // What the phone shows after `scroll(drawn, by)`: the moved cell, or the drawn one
            // when the moved cell looks the same (its override dropped).
            let moved_shown = |y: usize, x: usize| -> &Cell {
                let from = if by > 0 {
                    y.checked_add(n).filter(|from| *from < height)
                } else {
                    y.checked_sub(n)
                };
                let moved = from.and_then(|from| cell_at(&shown, from, x)).unwrap_or(&BLANK);
                let under = cell_at(drawn, y, x).unwrap_or(&BLANK);
                if moved.looks_same(under) { under } else { moved }
            };
            let candidate = self.runs(drawn, real, moved_shown);
            let len = encoded_len(seq, at_ms, by, &candidate);
            if len < best_len {
                (best, best_shift, best_len) = (candidate, by, len);
            }
        }
        Delta {
            seq,
            at_ms,
            shift: best_shift,
            spans: best.into_iter().map(Run::into_span).collect(),
        }
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

/// Where encoded bytes go: a buffer, or a count of them (scoring a candidate delta).
trait Out {
    fn push(&mut self, byte: u8);
    fn extend_from_slice(&mut self, bytes: &[u8]);
    fn put_bytes<const N: usize>(&mut self, bytes: [u8; N]) {
        self.extend_from_slice(&bytes);
    }
}

impl Out for Vec<u8> {
    fn push(&mut self, byte: u8) {
        Vec::push(self, byte);
    }
    fn extend_from_slice(&mut self, bytes: &[u8]) {
        Vec::extend_from_slice(self, bytes);
    }
}

/// Counts the bytes it would hold.
struct Count(usize);

impl Out for Count {
    fn push(&mut self, _: u8) {
        self.0 += 1;
    }
    fn extend_from_slice(&mut self, bytes: &[u8]) {
        self.0 += bytes.len();
    }
}

static BLANK: Cell =
    Cell { text: String::new(), style: Style { fg: Color::Default, bg: Color::Default, attrs: 0 } };

/// A [`Span`] over borrowed cells: [`Overlay::delta`] scores candidates without cloning.
enum Run<'a> {
    Set { row: u16, col: u16, cells: Vec<&'a Cell> },
    Clear { row: u16, col: u16, len: u16 },
}

impl Run<'_> {
    fn into_span(self) -> Span {
        match self {
            Run::Set { row, col, cells } => {
                Span::Set { row, col, cells: cells.into_iter().cloned().collect() }
            }
            Run::Clear { row, col, len } => Span::Clear { row, col, len },
        }
    }
}

/// How many bytes [`Delta::encode`] writes for these runs.
fn encoded_len(seq: u64, at_ms: u64, shift: i16, runs: &[Run<'_>]) -> usize {
    let mut count = Count(0);
    write_delta(
        &mut count,
        seq,
        at_ms,
        shift,
        runs.len(),
        runs.iter().map(|run| match run {
            Run::Set { row, col, cells } => {
                SpanRef::Set(*row, *col, cells.len(), cells.iter().copied())
            }
            Run::Clear { row, col, len } => SpanRef::Clear(*row, *col, *len),
        }),
    );
    count.0
}

/// One span as [`write_delta`] reads it: a set's cells as any iterator of borrowed cells.
enum SpanRef<'a, I: Iterator<Item = &'a Cell>> {
    Set(u16, u16, usize, I),
    Clear(u16, u16, u16),
}

/// The wire form [`Delta::encode`] documents, into any [`Out`].
fn write_delta<'a, O: Out, I: Iterator<Item = &'a Cell> + Clone>(
    out: &mut O,
    seq: u64,
    at_ms: u64,
    shift: i16,
    count: usize,
    spans: impl Iterator<Item = SpanRef<'a, I>>,
) {
    put(out, seq);
    put(out, at_ms);
    // Zigzag, so a small scroll either way is one byte.
    let shift = i32::from(shift);
    put(out, ((shift << 1) ^ (shift >> 31)) as u64);
    put(out, count as u64);
    for span in spans {
        match span {
            SpanRef::Set(row, col, len, cells) => {
                put(out, u64::from(row));
                put(out, u64::from(col));
                put(out, ((len as u64) << 1) | 1);
                let style = cells.clone().next().map(|cell| cell.style).unwrap_or_default();
                put_color(out, style.fg);
                put_color(out, style.bg);
                put(out, u64::from(style.attrs));
                for cell in cells {
                    put_text(out, &cell.text);
                }
            }
            SpanRef::Clear(row, col, len) => {
                put(out, u64::from(row));
                put(out, u64::from(col));
                put(out, u64::from(len) << 1);
            }
        }
    }
}

fn put(out: &mut impl Out, mut value: u64) {
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

fn put_color(out: &mut impl Out, color: Color) {
    match color {
        Color::Default => out.push(0),
        Color::Palette(index) => out.put_bytes([1, index]),
        Color::Rgb(r, g, b) => out.put_bytes([2, r, g, b]),
    }
}

/// A cell's text: a printable ASCII byte as itself, an empty cell as 2, anything else as 1,
/// its length and its UTF-8 bytes.
fn put_text(out: &mut impl Out, text: &str) {
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
        write_delta(
            &mut out,
            self.seq,
            self.at_ms,
            self.shift,
            self.spans.len(),
            self.spans.iter().map(|span| match span {
                Span::Set { row, col, cells } => {
                    SpanRef::Set(*row, *col, cells.len(), cells.iter())
                }
                Span::Clear { row, col, len } => SpanRef::Clear(*row, *col, *len),
            }),
        );
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

    /// The search `delta` ran before it scored on borrowed cells: clone, scroll, diff, encode.
    fn delta_by_cloning(overlay: &Overlay, drawn: &Grid, real: &Grid) -> Delta {
        let mut best = Delta { seq: 1, at_ms: 0, shift: 0, spans: overlay.diff(drawn, real) };
        let mut best_len = best.encode().len();
        if best.spans.is_empty() {
            return best;
        }
        let rows = i16::try_from(overlay.rows).unwrap();
        for by in (-(rows / 4)..rows).filter(|by| *by != 0) {
            let mut moved = overlay.clone();
            moved.scroll(drawn, by);
            let candidate = Delta { seq: 1, at_ms: 0, shift: by, spans: moved.diff(drawn, real) };
            let len = candidate.encode().len();
            if len < best_len {
                (best, best_len) = (candidate, len);
            }
        }
        best
    }

    #[test]
    fn the_delta_search_picks_what_cloning_each_scroll_picked() {
        // A full-screen TUI's redraws: a growing document scrolled both ways, a status row,
        // records drawing some rows right, two styles.
        let (cols, rows) = (20u16, 12u16);
        let page = |top: usize, status: &str| {
            let mut grid = Grid::blank(cols, rows);
            for (y, slot) in grid.cells.iter_mut().enumerate() {
                let mut line = Line::new();
                if y + 1 == usize::from(rows) {
                    line.push(status, Style::fg(2));
                } else {
                    line.push(&format!("line {}", top + y), Style::fg(246));
                    if (top + y) % 3 == 0 {
                        line.push(" !", Style { attrs: BOLD, ..Style::fg(1) });
                    }
                }
                *slot = line.into_row(cols);
            }
            grid
        };
        let mut drawn = Grid::blank(cols, rows);
        drawn.cells[0] = page(0, "").cells[0].clone();
        let mut overlay = Overlay::new(cols, rows);
        for (step, top) in [0, 1, 2, 5, 4, 3, 3, 9, 30, 29, 31, 31].into_iter().enumerate() {
            let real = page(top, &format!("step {step}"));
            let want = delta_by_cloning(&overlay, &drawn, &real);
            let got = overlay.delta(&drawn, &real, 1, 0);
            assert_eq!(got, want, "step {step}");
            assert_eq!(got.encode(), want.encode(), "step {step}");
            overlay.apply_delta(&got, &drawn);
            assert_eq!(real.parity(&overlay.compose(&drawn)), (240, 240), "step {step}");
        }
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

    /// A varint past 64 bits is not a delta: its high bits are not dropped to read a smaller
    /// value (#44052 F2).
    #[test]
    fn a_varint_past_64_bits_is_not_a_delta() {
        // seq, then at_ms 0, shift 0 and no spans.
        let with_seq = |seq: &[u8]| [seq, &[0, 0, 0]].concat();
        let max = [[0xff; 9].as_slice(), &[0x01]].concat();
        assert_eq!(Delta::decode(&with_seq(&max)).map(|delta| delta.seq), Some(u64::MAX));
        // Bit 64 set: the shift used to drop it and read seq 0.
        let bit_64 = [[0x80; 9].as_slice(), &[0x02]].concat();
        assert_eq!(Delta::decode(&with_seq(&bit_64)), None);
        // An eleventh byte.
        let eleven = [[0x80; 10].as_slice(), &[0x00]].concat();
        assert_eq!(Delta::decode(&with_seq(&eleven)), None);
    }
}
