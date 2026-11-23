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

/// The rows a full-screen app moved off its screen, oldest first.
#[derive(Debug, Default)]
pub struct HeldRows {
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

    /// Bytes the store holds (rows and their cells, by capacity).
    pub fn bytes(&self) -> usize {
        self.rows.capacity() * size_of::<Row>()
            + self.rows.iter().map(|r| r.cells.capacity() * size_of::<Cell>()).sum::<usize>()
    }

    pub fn clear(&mut self) {
        self.rows.clear();
        self.last_frame = None;
    }

    /// A row left the top of the app's scroll region.
    pub fn push(&mut self, row: Row) {
        self.last_frame = None;
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
    let (top, bottom) = term.scroll_region();
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

/// Every row at its place, from a known state (synchronized, the cursor
/// hidden, origin mode off, ASCII character sets, default pen).
fn paint_rows(term: &Terminal, rows: &[&Row], out: &mut Vec<u8>) {
    out.extend_from_slice(b"\x1b[?2026h\x1b[?25l\x1b[?6l\x1b(B\x1b)B\x0f\x1b[0m");
    for (y, row) in rows.iter().enumerate().take(term.rows) {
        out.extend_from_slice(format!("\x1b[{};1H", y + 1).as_bytes());
        let mut previous: Option<Style> = None;
        let mut x = 0;
        for cell in row.cells.iter().take(term.cols) {
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
mod tests {
    use super::*;

    fn row(text: &str) -> Row {
        Row {
            cells: text.chars().map(|c| Cell { ch: c as u32, style: 0, kind: 0 }).collect(),
            wrapped: false,
            prompt: false,
        }
    }

    #[test]
    fn a_scroll_back_down_unholds_the_rows_it_brings_back() {
        let mut held = HeldRows::default();
        for i in 0..5 {
            held.push(row(&format!("line {i}")));
        }
        held.pop(2);
        assert_eq!(held.len(), 3);
        held.push(row("line 3"));
        assert_eq!(held.len(), 4, "line 3 is held once");
    }

    #[test]
    fn the_store_is_capped() {
        let mut held = HeldRows::default();
        for i in 0..HELD_ROW_CAP + 500 {
            held.push(row(&format!("line {i}")));
        }
        assert_eq!(held.len(), HELD_ROW_CAP);
        let oldest = held.get(0).map(|r| r.cells.len());
        assert_eq!(oldest, Some(row("line 500").cells.len()));
    }

    #[test]
    fn a_frame_with_a_spinner_replaces_the_last_one() {
        let mut held = HeldRows::default();
        let page = |spin: &str| vec![row("header"), row(spin), row("body"), row("footer")];
        held.push_frame(&page("|"));
        held.push_frame(&page("/"));
        held.push_frame(&page("-"));
        assert_eq!(held.len(), 4, "one screen: only the spinner changed");
        held.push_frame(&[row("a"), row("b"), row("c"), row("d")]);
        assert_eq!(held.len(), 8, "a new page is held after it");
        held.push_frame(&[row(""), row(""), row(""), row("")]);
        assert_eq!(held.len(), 8, "a blank screen is not held");
    }
}
