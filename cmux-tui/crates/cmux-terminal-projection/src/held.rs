//! Held rows: what a full-screen app (the alternate screen) showed the
//! phone and then moved off its screen, so a pan reads back through it on
//! the phone instead of sending wheel or arrow keys to the Mac and waiting
//! for the app's repaint (Leo's "if the data was sent through... why cant
//! you simply scroll through the depiction that was already given?").
//!
//! - **Rows that scrolled off.** When the app scrolls its region up (a line
//!   feed at its bottom margin, `IND`, `SU`), the rows leaving the region's
//!   top are held, oldest first. A scroll back down (`RI`, `SD`) brings the
//!   newest held rows back onto the screen, so they leave the store: a row is
//!   held once, and a pan moves through one continuous run of rows.
//! - **Whole screens, only where an app repaints without scrolling.** An
//!   app that clears its screen (`ED 2`, or `ED 0` from the home cell) to draw
//!   the next page holds the page it clears, as one screen of rows in the
//!   same run. A clear that changed at most [`FRAME_REDRAW_ROWS`] rows of the
//!   last held screen (a spinner, a clock) replaces that screen instead of
//!   holding another.
//!
//! - **Rows an app moved by repainting.** An app that never scrolls but
//!   redraws its screen in place, its content one or more rows higher (Claude
//!   Code's full-screen mode: cursor moves, no scroll region, no `IND` or
//!   `SU`), is compared after each batch of its bytes with the screen before
//!   it. When a band of rows moved up by `k` (at least
//!   [`SHIFT_MATCH_ROWS`] of its rows with text, each unlike the row above
//!   it, match `k` rows higher; a blank screen or one repeated line never
//!   counts), the
//!   `k` rows that left the band's top are held, as if it had scrolled; rows
//!   above and below the band (a header, an input box, a status line) stay
//!   put on a pan.
//!
//! The store keeps at most [`HELD_ROW_CAP`] rows (the oldest go first), each
//! without its trailing empty cells. It holds only what the phone was sent:
//! it is filled from the same bytes the phone's surface drew. The store
//! starts empty on entering or leaving the alternate screen and on a host
//! resize.

use std::collections::VecDeque;

use crate::project::write_style;
use crate::style::Style;
use crate::terminal::{Cell, Row, SPACER_HEAD, Terminal, WIDE_TAIL};

/// The most rows held (about 4.8 MB at 200 full columns, 8 bytes a cell;
/// rows are held without their trailing empty cells, so usually far less).
pub const HELD_ROW_CAP: usize = 3_000;

/// A clear that redrew at most this many rows of the last held screen
/// replaces it (an in-place update, not a new page).
pub const FRAME_REDRAW_ROWS: usize = 2;

/// Rows with text that must match, one band `k` rows higher, for a repaint
/// to count as the band moving up `k` rows; a row the same as the one
/// above it (a rule, a repeated line) does not count.
pub const SHIFT_MATCH_ROWS: usize = 3;

/// The rows a full-screen app moved off its screen, oldest first.
#[derive(Debug, Default)]
pub struct HeldRows {
    /// The screen at the end of the last batch, rows without trailing empty
    /// cells, for a repaint's inferred move.
    last_seen: Vec<Vec<Cell>>,
    /// The app scrolled, or cleared a page, in this batch: nothing to infer.
    moved: bool,
    /// The screen rows (first, last) a repaint's move was seen in: a pan
    /// shows the held rows there and keeps the rows outside it in place.
    band: Option<(usize, usize)>,
    /// The app marks where its frames end (the cursor shown again after a
    /// hidden redraw, or a synchronized update's end): a repaint is compared
    /// there, not at a batch's end, which can fall mid-frame.
    framed: bool,
    rows: VecDeque<Row>,
    /// Rows ever held since the store started (front drops keep counting).
    pushed: u64,
    /// The last held screen: where its rows start (in `pushed` terms) and
    /// how many there are, while it is still the newest thing held.
    last_frame: Option<(u64, usize)>,
}

impl HeldRows {
    pub fn len(&self) -> usize {
        self.rows.len()
    }

    pub fn is_empty(&self) -> bool {
        self.rows.is_empty()
    }

    /// The held row `index` (0: the oldest).
    pub fn get(&self, index: usize) -> Option<&Row> {
        self.rows.get(index)
    }

    /// Rows ever held since the store started: a reader's place in these
    /// terms stays on the same rows while newer ones are held.
    pub fn pushed(&self) -> u64 {
        self.pushed
    }

    /// Bytes the store holds (rows and their cells, by capacity).
    pub fn bytes(&self) -> usize {
        self.rows.capacity() * size_of::<Row>()
            + self.rows.iter().map(|r| r.cells.capacity() * size_of::<Cell>()).sum::<usize>()
    }

    pub fn clear(&mut self) {
        self.rows.clear();
        self.last_frame = None;
        self.last_seen.clear();
        self.moved = false;
        self.band = None;
        self.framed = false;
    }

    /// Whether the app marks its frames' ends ([`HeldRows::frame_end`]).
    pub fn framed(&self) -> bool {
        self.framed
    }

    /// The app finished a frame: compare it with the last whole one.
    pub fn frame_end(&mut self, screen: &[Row]) {
        self.framed = true;
        self.observe(screen);
    }

    /// Where a pan shows held rows, when a repaint's move set it.
    pub fn band(&self) -> Option<(usize, usize)> {
        self.band
    }

    /// The end of a batch of the app's bytes: `screen` is its screen now.
    /// When the app did not scroll or clear in the batch, compare it with
    /// the screen before: a band that moved up holds the rows that left it.
    pub fn observe(&mut self, screen: &[Row]) {
        let now: Vec<Vec<Cell>> = screen.iter().map(trimmed_cells).collect();
        if !std::mem::take(&mut self.moved)
            && let Some((top, k, bottom)) = inferred_shift(&self.last_seen, &now)
        {
            self.last_frame = None;
            for i in top..top + k {
                let cells = self.last_seen.get(i).cloned().unwrap_or_default();
                self.push_row(Row { cells, wrapped: false, prompt: false });
            }
            self.band = Some((top, bottom));
        }
        self.last_seen = now;
    }

    /// A row left the top of the app's scroll region.
    pub fn push(&mut self, row: Row) {
        self.last_frame = None;
        self.moved = true;
        self.band = None;
        self.push_row(row);
    }

    fn push_row(&mut self, mut row: Row) {
        let keep = row.cells.iter().rposition(|c| *c != Cell::default()).map_or(0, |i| i + 1);
        row.cells.truncate(keep);
        row.cells.shrink_to_fit();
        self.rows.push_back(row);
        self.pushed += 1;
        while self.rows.len() > HELD_ROW_CAP {
            self.rows.pop_front();
        }
    }

    /// The app scrolled its region down `n`: the newest `n` held rows are
    /// back on its screen.
    pub fn pop(&mut self, n: usize) {
        self.moved = true;
        for _ in 0..n.min(self.rows.len()) {
            self.rows.pop_back();
            self.pushed = self.pushed.saturating_sub(1);
        }
        if let Some((start, len)) = self.last_frame
            && start + len as u64 > self.pushed
        {
            self.last_frame = None;
        }
    }

    /// The app is about to clear `screen` (its region's rows) without
    /// scrolling: hold it as one screen, or replace the last held screen
    /// when only a few of its rows changed. A blank screen is not held.
    pub fn push_frame(&mut self, screen: &[Row]) {
        self.moved = true;
        self.band = None;
        let blank = |row: &Row| row.cells.iter().all(|c| c.is_empty_or_space() && c.style == 0);
        if screen.iter().all(blank) {
            return;
        }
        let trimmed = |row: &Row| {
            let keep = row.cells.iter().rposition(|c| *c != Cell::default()).map_or(0, |i| i + 1);
            row.cells.get(..keep).unwrap_or_default().to_vec()
        };
        if let Some((start, len)) = self.last_frame
            && len == screen.len()
            && start + len as u64 == self.pushed
            && let Some(first) = self.rows.len().checked_sub(len)
        {
            let changed = screen
                .iter()
                .enumerate()
                .filter(|(i, row)| {
                    self.rows.get(first + i).map(|held| held.cells.as_slice())
                        != Some(trimmed(row).as_slice())
                })
                .count();
            if changed == 0 {
                return;
            }
            if changed <= FRAME_REDRAW_ROWS {
                for _ in 0..len {
                    self.rows.pop_back();
                }
                self.pushed -= len as u64;
            }
        }
        let start = self.pushed;
        for row in screen {
            self.push_row(row.clone());
        }
        self.last_frame = Some((start, screen.len()));
    }
}

/// A row as it looks: an empty cell is a space (an app that moves the
/// cursor past blank cells instead of writing spaces draws the same row),
/// and trailing blank cells are dropped.
fn trimmed_cells(row: &Row) -> Vec<Cell> {
    let blank = Cell::blank(0);
    let mut cells: Vec<Cell> = row
        .cells
        .iter()
        .map(|&c| if c.is_empty_or_space() { Cell { ch: 0, ..c } } else { c })
        .collect();
    let keep =
        cells.iter().rposition(|c| *c != blank && *c != Cell::default()).map_or(0, |i| i + 1);
    cells.truncate(keep);
    cells
}

fn has_text(cells: &[Cell]) -> bool {
    cells.iter().any(|c| !c.is_empty_or_space())
}

/// How a repaint moved the screen: `(top, k, bottom)` when the rows from
/// `top` moved up `k` rows (the rows `top..top + k` of `before` left the
/// screen), with `bottom` the band's last row now. Rows the same in both,
/// at the top, are a header and not part of the band; the smallest `k`
/// whose matching run has [`SHIFT_MATCH_ROWS`] rows with text, each unlike
/// the row above it, wins.
fn inferred_shift(before: &[Vec<Cell>], now: &[Vec<Cell>]) -> Option<(usize, usize, usize)> {
    let n = now.len();
    if before.len() != n || n < SHIFT_MATCH_ROWS + 1 {
        return None;
    }
    let top = before.iter().zip(now).position(|(was, row)| was != row)?;
    for k in 1..n - top {
        let mut run = 0;
        let mut text = 0;
        let mut above: Option<&Vec<Cell>> = None;
        for (was, row) in before.iter().skip(top + k).zip(now.iter().skip(top)) {
            if was != row {
                break;
            }
            if has_text(row) && above != Some(row) {
                text += 1;
            }
            above = Some(row);
            run += 1;
        }
        // The run starts at the band's top: the rows the move brought there
        // are the ones that were `k` rows lower. Rows that left are gone from
        // the screen: a block still on it is the rest of a frame drawn in two
        // batches (its first half already moved up), not a move.
        if run > 0 && text >= SHIFT_MATCH_ROWS {
            // A row equal before and after can still be part of the move: in
            // a table whose rows repeat every two (an entry, a rule), an even
            // move leaves each rule where a rule was. The band starts at the
            // highest row the move also explains, or the rows held would be
            // one rule out of step with the entries.
            let mut start = top;
            while start > 0 && before.get(start - 1 + k) == now.get(start - 1) {
                start -= 1;
            }
            let left = before.get(start..start + k)?;
            if now.windows(k).any(|block| block == left) {
                return None;
            }
            return Some((start, k, (top + run + k - 1).min(n - 1)));
        }
    }
    None
}

/// The phone's surface showing the app's screen as it is now: every cell,
/// then the app's cursor, pen and character sets, so the app's next bytes
/// draw on the surface exactly as on the Mac.
pub fn paint_live(term: &Terminal) -> Vec<u8> {
    let rows: Vec<&Row> = term.screen_rows().iter().collect();
    let mut out = Vec::with_capacity(term.cols * term.rows * 2);
    paint_rows(term, &rows, &mut out);
    term.write_pen(&mut out);
    out.extend_from_slice(b"\x1b[?2026l");
    out
}

/// The phone's surface showing the app's screen `back` rows into the held
/// rows: rows above and below the app's scroll region stay (a header, a
/// status line), the region shows the run of held rows and the screen's own
/// rows `back` rows up. The cursor is hidden while the reader is back.
pub fn paint_back(term: &Terminal, held: &HeldRows, back: usize) -> Vec<u8> {
    let screen = term.screen_rows();
    let (top, bottom) = held.band().unwrap_or_else(|| term.scroll_region());
    let bottom = bottom.min(screen.len().saturating_sub(1));
    let height = bottom + 1 - top;
    let back = back.min(held.len());
    // The run: held rows, then the region's rows; the window ends `back`
    // rows before its end.
    let run_len = held.len() + height;
    let start = run_len - height - back;
    let mut rows: Vec<&Row> = Vec::with_capacity(screen.len());
    rows.extend(screen.iter().take(top));
    for i in start..start + height {
        let row = if i < held.len() { held.get(i) } else { screen.get(top + i - held.len()) };
        if let Some(row) = row {
            rows.push(row);
        }
    }
    rows.extend(screen.iter().skip(bottom + 1));
    let mut out = Vec::with_capacity(term.cols * term.rows * 2);
    paint_rows(term, &rows, &mut out);
    out.extend_from_slice(b"\x1b[?25l\x1b[?2026l");
    out
}

/// A full-screen app's held rows and its screen as one document, for the
/// phone to scroll as a plain scroll view (Leo, 2026-11-24: "we can just
/// treat the scroll like any pedestrian scroll"): VT bytes for a fresh
/// terminal of the app's columns (after `ESC c`), one row a line, so its
/// scrollback is the held rows and its screen ends with the app's last row.
/// Returns the bytes, the document's rows and the row the app's screen
/// begins at (the held rows above it).
pub fn paint_document(term: &Terminal, held: &HeldRows) -> (Vec<u8>, usize, usize) {
    let screen = term.screen_rows();
    let mut rows: Vec<&Row> = Vec::with_capacity(held.len() + screen.len());
    rows.extend(held.rows.iter());
    rows.extend(screen.iter());
    let screen_top = held.len();
    let mut out = Vec::with_capacity(rows.len() * (term.cols + 8));
    out.extend_from_slice(b"\x1b[0m\x1b[H\x1b[2J");
    let mut style = Style::default();
    for (n, row) in rows.iter().enumerate() {
        if n > 0 {
            out.extend_from_slice(b"\r\n");
        }
        let mut width = 0;
        // Plain blanks past the last glyph are not written (the fresh
        // terminal's cells are blank already).
        let keep = row
            .cells
            .iter()
            .rposition(|c| !c.is_empty_or_space() || c.style != 0)
            .map_or(0, |i| i + 1);
        for cell in row.cells.iter().take(keep) {
            if width >= term.cols {
                break;
            }
            if cell.kind == WIDE_TAIL || cell.kind == SPACER_HEAD {
                continue;
            }
            let next = term.styles.get(cell.style);
            if next != style {
                write_style(term, &mut out, Some(style), next);
                style = next;
            }
            if cell.ch == 0 {
                out.push(b' ');
            } else {
                term.write_cell(*cell, &mut out);
            }
            width += cell.width();
        }
        if style != Style::default() {
            write_style(term, &mut out, Some(style), Style::default());
            style = Style::default();
        }
    }
    (out, rows.len(), screen_top)
}

/// Every row at its place, from a known state (synchronized, the cursor
/// hidden, origin mode off, ASCII character sets, default pen).
fn paint_rows(term: &Terminal, rows: &[&Row], out: &mut Vec<u8>) {
    out.extend_from_slice(b"\x1b[?2026h\x1b[?25l\x1b[?6l\x1b(B\x1b)B\x0f\x1b[0m");
    for (y, row) in rows.iter().enumerate().take(term.rows) {
        out.extend_from_slice(format!("\x1b[{};1H", y + 1).as_bytes());
        let mut previous: Option<Style> = None;
        let mut x = 0;
        // Trailing blanks in the default pen end in an erase, whether the row
        // is held (stored without them) or still on the screen: a row paints
        // the same bytes before and after it is held.
        let cells = row.cells.get(..term.cols.min(row.cells.len())).unwrap_or_default();
        let keep = cells
            .iter()
            .rposition(|c| !(c.is_empty_or_space() && c.style == 0 && c.kind == 0))
            .map_or(0, |i| i + 1);
        for cell in cells.get(..keep).unwrap_or_default() {
            if cell.kind == WIDE_TAIL {
                x += 1;
                continue;
            }
            let style = term.styles.get(cell.style);
            write_style(term, out, previous, style);
            previous = Some(style);
            if cell.ch == 0 || cell.kind == SPACER_HEAD {
                out.push(b' ');
            } else {
                term.write_cell(*cell, out);
            }
            x += 1;
        }
        if previous.is_some_and(|p| p != Style::default()) {
            out.extend_from_slice(b"\x1b]8;;\x1b\\\x1b[0m");
        }
        if x < term.cols {
            out.extend_from_slice(b"\x1b[K");
        }
    }
}

#[cfg(test)]
#[path = "held_tests.rs"]
mod tests;
