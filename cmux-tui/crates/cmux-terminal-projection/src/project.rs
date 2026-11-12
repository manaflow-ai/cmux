//! The phone's view: the host's logical lines (soft-wrapped rows joined)
//! re-wrapped at the phone's columns, written as VT bytes for a terminal of
//! the phone's grid, and kept up to date by repainting only from the first
//! row that changed.

use crate::style::Style;
use crate::terminal::{Cell, Row, SPACER_HEAD, Terminal, WIDE, WIDE_TAIL};

/// One row of the phone's view.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ProjectedRow {
    /// Glyph cells only (a wide glyph is one cell of width 2).
    pub cells: Vec<Cell>,
    /// The row's logical line goes on in the next row.
    pub wrapped: bool,
}

impl ProjectedRow {
    pub fn width(&self) -> usize {
        self.cells.iter().map(|c| c.width()).sum()
    }
}

/// A logical line re-wrapped: its rows, and where the host cursor lands.
pub struct Wrapped {
    pub rows: Vec<ProjectedRow>,
    /// (row in `rows`, column) of the cursor, when it is in this line.
    pub cursor: Option<(usize, usize)>,
    /// The line has no glyph and no cursor.
    pub empty: bool,
}

/// Re-wraps one logical line (host rows, the last one not wrapped, or the
/// screen's last) at `cols`. `cursor`: (host row index in `rows`, column).
pub fn wrap_line(
    term: &Terminal,
    rows: &[&Row],
    host_cols: usize,
    cols: usize,
    cursor: Option<(usize, usize)>,
) -> Wrapped {
    let cols = cols.max(2);
    // Glyphs with their offset in the host line.
    // A spacer head (the host's empty last cell before a wide glyph that
    // wrapped) is the host's own artifact: offsets after it do not count it.
    let mut units: Vec<(usize, Cell)> = Vec::new();
    let mut spacers = 0;
    let mut cursor_spacers = 0;
    let cursor_cell = cursor.map(|(k, x)| k * host_cols + x);
    for (k, row) in rows.iter().enumerate() {
        for (x, cell) in row.cells.iter().enumerate() {
            let at = k * host_cols + x;
            if cell.kind == SPACER_HEAD {
                spacers += 1;
                if cursor_cell.is_some_and(|c| at < c) {
                    cursor_spacers += 1;
                }
                continue;
            }
            if cell.kind == WIDE_TAIL {
                continue;
            }
            units.push((at - spacers, *cell));
        }
    }
    // Trailing blanks that draw nothing go (the host row's empty end).
    while let Some((_, cell)) = units.last() {
        if cell.is_empty_or_space() && term.styles.get(cell.style).is_invisible_when_blank() {
            units.pop();
        } else {
            break;
        }
    }
    let cursor_offset = cursor_cell.map(|c| c - cursor_spacers);
    let mut out = vec![ProjectedRow::default()];
    let mut col = 0;
    let mut cursor_at = None;
    let place = |out: &mut Vec<ProjectedRow>, col: &mut usize, width: usize| -> (usize, usize) {
        if *col + width > cols {
            if let Some(row) = out.last_mut() {
                row.wrapped = true;
            }
            out.push(ProjectedRow::default());
            *col = 0;
        }
        (out.len() - 1, *col)
    };
    let mut end_offset = 0;
    for (offset, cell) in &units {
        let width = cell.width();
        if let Some(target) = cursor_offset
            && cursor_at.is_none()
            && *offset >= target
        {
            // The cursor is on this glyph (or on the empty cells before it).
            cursor_at =
                Some(place(&mut out, &mut col, 1.max(if *offset == target { width } else { 1 })));
        }
        let (row, _) = place(&mut out, &mut col, width);
        out[row].cells.push(*cell);
        col += width;
        end_offset = offset + width;
    }
    if let (Some(target), None) = (cursor_offset, cursor_at) {
        // Past the line's end: the blank cells up to the cursor count, on
        // the line's last row. Past the phone's edge it waits on the last
        // cell, as a terminal's cursor does before it wraps.
        let blanks = target.saturating_sub(end_offset);
        cursor_at = Some((out.len() - 1, (col + blanks).min(cols - 1)));
    }
    let empty = units.is_empty() && cursor_at.is_none();
    Wrapped { rows: out, cursor: cursor_at, empty }
}

/// Phone screens of scrollback a reset paints above the host's screen
/// (the reader's first flick up); older rows come on demand.
pub const TAIL_SCREENS: usize = 2;

/// The start (an index in `term.history`) of the logical line holding
/// history row `index` (`history.len()`: the screen's first line).
pub fn line_start(term: &Terminal, index: usize) -> usize {
    let mut i = index.min(term.history.len());
    while i > 0 && term.history[i - 1].wrapped {
        i -= 1;
    }
    i
}

/// Walks back from history index `end` (exclusive, at a line start) over
/// whole logical lines until they fill `want` rows at `cols`; their start.
pub fn rows_back(term: &Terminal, end: usize, cols: usize, want: usize) -> usize {
    let mut start = line_start(term, end);
    let mut rows = 0;
    while start > 0 && rows < want {
        let first = line_start(term, start - 1);
        let line: Vec<&Row> = (first..start).map(|i| &term.history[i]).collect();
        rows += wrap_line(term, &line, term.cols, cols, None).rows.len();
        start = first;
    }
    start
}

/// What a feed gives the phone's terminal.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Paint {
    /// Bytes for the phone's terminal as it is.
    Update(Vec<u8>),
    /// The phone's terminal starts over (`ESC c`, sent by the caller), then these bytes.
    Reset(Vec<u8>),
}

/// The phone's view of the primary screen.
pub struct View {
    pub cols: usize,
    pub rows: usize,
    /// Projected rows of settled lines (whole in the scrollback), counted
    /// from the last reset.
    settled_end: u64,
    /// Host scrollback rows (absolute, counting dropped ones) settled so far.
    settled_host: u64,
    /// Rows written after the settled ones, as the phone's terminal has them.
    shown: Vec<ProjectedRow>,
    /// Where the phone's cursor is: (absolute row, column, pending wrap).
    phone_cursor: (u64, usize),
    phone_style: Option<Style>,
    phone_cursor_visible: bool,
    needs_reset: bool,
    /// The oldest host row (absolute) a reset must paint (rows the reader
    /// is on, or asked for by scrolling up); nil: only the tail window.
    pub keep_from: Option<u64>,
    /// The first host row (absolute) the last reset painted: older rows are
    /// in the model, not on the phone, until [`View::load_older`].
    window_from: u64,
    /// Bytes painted since creation (for benches).
    pub bytes_out: u64,
    pub resets: u64,
}

impl View {
    pub fn new(cols: usize, rows: usize) -> View {
        View {
            cols: cols.max(2),
            rows: rows.max(1),
            settled_end: 0,
            settled_host: 0,
            shown: Vec::new(),
            phone_cursor: (0, 0),
            phone_style: None,
            phone_cursor_visible: true,
            needs_reset: true,
            keep_from: None,
            window_from: 0,
            bytes_out: 0,
            resets: 0,
        }
    }

    pub fn request_reset(&mut self) {
        self.needs_reset = true;
    }

    /// Host scrollback rows older than what the phone's terminal holds.
    pub fn older_rows(&self, term: &Terminal) -> usize {
        (self.window_from.saturating_sub(term.history_dropped) as usize).min(term.history.len())
    }

    /// The phone's terminal takes `host_rows` more of the older scrollback
    /// (a reset painted at the next paint). False: it has all of it.
    pub fn load_older(&mut self, term: &Terminal, host_rows: usize) -> bool {
        let older = self.older_rows(term);
        if older == 0 {
            return false;
        }
        let from = line_start(term, older.saturating_sub(host_rows.max(1)));
        self.keep_from = Some(term.history_dropped + from as u64);
        self.needs_reset = true;
        true
    }

    /// Where a reset starts painting (an index in `term.history`, at a
    /// logical line's start): the scrollback lines that fill
    /// [`TAIL_SCREENS`] of the phone's screens above the host's screen, or
    /// older ones kept by [`View::keep_from`]. A width change costs this
    /// window, not the whole scrollback.
    fn window_start(&self, term: &Terminal) -> usize {
        let tail = rows_back(term, term.history.len(), self.cols, TAIL_SCREENS * self.rows);
        match self.keep_from {
            Some(keep) => {
                let keep = keep.saturating_sub(term.history_dropped) as usize;
                line_start(term, keep.min(tail))
            }
            None => tail,
        }
    }

    /// Rows of the live part (the unsettled lines and the screen) shown.
    pub fn live_rows(&self) -> usize {
        self.shown.len()
    }

    fn shown_end(&self) -> u64 {
        self.settled_end + self.shown.len() as u64
    }

    /// The first absolute row on the phone's screen (rows above it are in its scrollback).
    fn top(&self) -> u64 {
        self.shown_end().saturating_sub(self.rows as u64)
    }

    /// Brings the phone's terminal to the host's primary screen now.
    pub fn paint(&mut self, term: &mut Terminal, passthrough: &[u8]) -> Option<Paint> {
        if term.reset_needed {
            term.reset_needed = false;
            self.needs_reset = true;
        }
        if self.settled_host < term.history_dropped {
            // An unsettled line longer than the scrollback lost its start.
            self.needs_reset = true;
        }
        let reset = self.needs_reset;
        if reset {
            self.needs_reset = false;
            self.settled_end = 0;
            self.settled_host = term.history_dropped + self.window_start(term) as u64;
            self.window_from = self.settled_host;
            self.shown.clear();
            self.phone_cursor = (0, 0);
            self.phone_style = None;
            self.phone_cursor_visible = true;
            self.resets += 1;
        }
        let mut out = Vec::new();
        if reset {
            term.write_modes(&mut out);
        }
        out.extend_from_slice(passthrough);
        // 1. Lines that are now whole in the scrollback settle.
        let base = term.history_dropped;
        let history_len = term.history.len();
        let mut first = (self.settled_host - base) as usize;
        let mut newly: Vec<ProjectedRow> = Vec::new();
        loop {
            let mut last = first;
            while last < history_len && term.history[last].wrapped {
                last += 1;
            }
            if last >= history_len {
                break;
            }
            let rows: Vec<&Row> = (first..=last).map(|i| &term.history[i]).collect();
            newly.extend(wrap_line(term, &rows, term.cols, self.cols, None).rows);
            first = last + 1;
        }
        let settled_rows = newly.len();
        // 2. The live lines: the unsettled scrollback tail and the screen.
        let (cursor_x, cursor_y) = term.primary_cursor();
        let screen = term.primary_rows();
        let live_rows: Vec<&Row> =
            (first..history_len).map(|i| &term.history[i]).chain(screen.iter()).collect();
        let cursor_row = live_rows.len() - screen.len() + cursor_y;
        let mut live: Vec<ProjectedRow> = Vec::new();
        let mut cursor: Option<(usize, usize)> = None;
        // Rows of the live part up to its last line with something in it.
        let mut keep = 0;
        let mut start = 0;
        while start < live_rows.len() {
            let mut end = start;
            while end + 1 < live_rows.len() && live_rows[end].wrapped {
                end += 1;
            }
            let in_line =
                (start..=end).contains(&cursor_row).then(|| (cursor_row - start, cursor_x));
            let wrapped = wrap_line(term, &live_rows[start..=end], term.cols, self.cols, in_line);
            if let Some((row, col)) = wrapped.cursor {
                cursor = Some((live.len() + row, col));
            }
            live.extend(wrapped.rows);
            if !wrapped.empty {
                keep = live.len();
            }
            start = end + 1;
        }
        let cursor_end = cursor.map_or(0, |(row, _)| row + 1);
        // The host's screen is a screen: at least the phone's rows of it, so a
        // cleared screen keeps its prompt at the top as on the host.
        let screen_floor = self.rows.min(live.len());
        let mut live_len = keep.max(cursor_end).max(screen_floor);
        // The phone's terminal never takes rows back: what it shows stays as long.
        let shown_end = self.shown_end();
        let new_settled_end = self.settled_end + settled_rows as u64;
        let min_len = shown_end.saturating_sub(new_settled_end) as usize;
        if !reset && live_len < min_len {
            live_len = min_len;
        }
        live.resize(live_len, ProjectedRow::default());
        // 3. Rows from the old settled end: the newly settled ones, then the live ones.
        let mut tail = newly;
        tail.extend(live.iter().cloned());
        let from = self.settled_end;
        let mut first_changed: Option<(u64, usize)> = None;
        for (i, row) in tail.iter().enumerate() {
            match self.shown.get(i) {
                Some(old) if old == row => {}
                Some(old) => {
                    let common =
                        old.cells.iter().zip(&row.cells).take_while(|(a, b)| a == b).count();
                    first_changed = Some((from + i as u64, common));
                    break;
                }
                None => {
                    first_changed = Some((from + i as u64, 0));
                    break;
                }
            }
        }
        if first_changed.is_none() && self.shown.len() > tail.len() {
            first_changed = Some((from + tail.len() as u64, 0));
        }
        if let Some((row, _)) = first_changed
            && row < self.top()
            && !reset
        {
            // A change in rows the phone's terminal scrolled away: start over.
            self.needs_reset = true;
            term.reset_needed = false;
            return self.paint(term, passthrough);
        }
        let old_shown_end = shown_end;
        if let Some((row, 0)) = first_changed {
            // A new row of a soft-wrapped line: write it by the phone's own
            // autowrap, from the previous row's last glyph, so its wrap flag
            // (copy, its own reflow) is the host's.
            let i = (row - from) as usize;
            // (Only when that row is still on the phone's screen.)
            if i > 0 && i <= self.shown.len() && row > self.top() {
                let previous = &tail[i - 1];
                if previous.wrapped
                    && previous.width() + 1 >= self.cols
                    && !previous.cells.is_empty()
                    && tail.get(i).is_some_and(|r| !r.cells.is_empty())
                {
                    first_changed = Some((row - 1, previous.cells.len() - 1));
                }
            }
        }
        if let Some((row, common)) = first_changed {
            // Only the wrap flag changed: the last glyph again, so the next
            // row comes by the phone's autowrap (wrapped), or after its own
            // line break (a full row no longer wrapped: the phone's cursor
            // cannot sit past its last column).
            let i = (row - from) as usize;
            if let Some(new_row) = tail.get(i)
                && common >= new_row.cells.len()
                && (new_row.wrapped || new_row.width() >= self.cols)
                && !new_row.cells.is_empty()
            {
                first_changed = Some((row, new_row.cells.len() - 1));
            }
        }
        if let Some((row, common)) = first_changed {
            let i = (row - from) as usize;
            let old_row = self.shown.get(i);
            let mut common = common;
            let mut unit_col: usize = tail.get(i).map_or(0, |r| {
                r.cells[..common.min(r.cells.len())].iter().map(|c| c.width()).sum()
            });
            // Blank cells up to where the phone's cursor already is (the
            // space after a prompt) need not be written: an echo is the key.
            if let (Some(new_row), true) =
                (tail.get(i), old_row.is_none_or(|r| r.cells.len() <= common))
            {
                while self.phone_cursor == (row, self.phone_cursor.1)
                    && unit_col < self.phone_cursor.1
                    && new_row
                        .cells
                        .get(common)
                        .is_some_and(|c| c.is_empty_or_space() && c.style == 0 && c.kind != WIDE)
                {
                    common += 1;
                    unit_col += 1;
                }
            }
            let rows_below_drawn = self
                .shown
                .get(i + 1..)
                .is_some_and(|rows| rows.iter().any(|r| !r.cells.is_empty()));
            let had_after = old_row.is_some_and(|r| r.cells.len() > common) || rows_below_drawn;
            let erase_rows_below = rows_below_drawn;
            // The phone's terminal rows: old ones in place; new ones are added at the bottom.
            self.move_to(&mut out, row, unit_col, old_shown_end);
            if had_after {
                if self.phone_style != Some(Style::default()) {
                    Style::default().write_sgr(&mut out);
                    self.phone_style = Some(Style::default());
                }
                out.extend_from_slice(if erase_rows_below { b"\x1b[J" } else { b"\x1b[K" });
            }
            let mut abs = row;
            let mut col = unit_col;
            // Blank rows the phone's screen already has (erased above) are
            // not written; rows past its bottom are, so it scrolls.
            let physical_end = old_shown_end.max(self.rows as u64);
            let new_end = from + tail.len() as u64;
            let last = if new_end > physical_end {
                tail.len() - 1 - i
            } else {
                tail[i..].iter().rposition(|r| !r.cells.is_empty()).unwrap_or(0)
            };
            for (k, projected) in tail[i..=i + last].iter().enumerate() {
                let skip = if k == 0 { common.min(projected.cells.len()) } else { 0 };
                if k > 0 {
                    // A soft wrap is the phone's own autowrap (a wrapped row
                    // is full, or one short of a wide glyph that follows).
                    if !tail[i + k - 1].wrapped {
                        out.extend_from_slice(b"\r\n");
                    }
                    abs += 1;
                    col = 0;
                }
                for cell in &projected.cells[skip..] {
                    let style = term.styles.get(cell.style);
                    if self.phone_style != Some(style) {
                        write_style(term, &mut out, self.phone_style, style);
                        self.phone_style = Some(style);
                    }
                    if cell.ch == 0 {
                        out.push(b' ');
                    } else {
                        out.extend_from_slice(term.cell_text(*cell).as_bytes());
                    }
                    col += cell.width();
                }
            }
            // A soft wrap left pending lands on the next row when written.
            self.phone_cursor = (abs, col);
        }
        self.settled_end = new_settled_end;
        self.settled_host = base + first as u64;
        self.shown = live;
        // 4. The cursor.
        let visible_row = cursor
            .map(|(row, col)| (self.settled_end + row as u64, col))
            .filter(|(row, _)| *row >= self.top());
        let want_visible = term.cursor_visible && visible_row.is_some();
        if let Some((row, col)) = visible_row {
            let shown_end = self.shown_end();
            let col = col.min(self.cols - 1);
            let (at_row, at_col) = self.phone_cursor;
            let row_width = row
                .checked_sub(self.settled_end)
                .and_then(|i| self.shown.get(i as usize))
                .map_or(0, ProjectedRow::width);
            if at_row == row
                && col > at_col
                && at_col >= row_width
                && col - at_col <= 8
                && self.phone_style.is_some_and(Style::is_invisible_when_blank)
            {
                // Past the row's end, as the host's own echo of a space does.
                out.extend(std::iter::repeat_n(b' ', col - at_col));
                self.phone_cursor = (row, col);
            } else if self.phone_cursor != (row, col) {
                self.move_to(&mut out, row, col, shown_end);
            }
        }
        if want_visible != self.phone_cursor_visible {
            out.extend_from_slice(if want_visible { b"\x1b[?25h" } else { b"\x1b[?25l" });
            self.phone_cursor_visible = want_visible;
        }
        // The program's own style again, for anything the phone draws itself.
        if reset {
            self.bytes_out += out.len() as u64;
            return Some(Paint::Reset(out));
        }
        if out.is_empty() {
            return None;
        }
        self.bytes_out += out.len() as u64;
        Some(Paint::Update(out))
    }

    /// Moves the phone's cursor to absolute row `row`, column `col`, given
    /// the rows its terminal holds (`end`). A row past the end is reached
    /// with line feeds, which scroll the phone's terminal as the host's would.
    fn move_to(&mut self, out: &mut Vec<u8>, row: u64, col: usize, end: u64) {
        let col = col.min(self.cols - 1);
        if self.phone_cursor == (row, col) && col < self.cols {
            return;
        }
        let top = end.saturating_sub(self.rows as u64);
        let last = end.max(1) - 1;
        if row <= last.max(top) && row >= top {
            let screen_row = row - top;
            out.extend_from_slice(format!("\x1b[{};{}H", screen_row + 1, col + 1).as_bytes());
        } else {
            // Below the rows written so far: to the last one, then down.
            let from = if end == 0 { 0 } else { last };
            let screen_row = from - top;
            out.extend_from_slice(format!("\x1b[{};1H", screen_row + 1).as_bytes());
            for _ in from..row {
                out.extend_from_slice(b"\n");
            }
            if col > 0 {
                out.extend_from_slice(format!("\x1b[{}G", col + 1).as_bytes());
            } else {
                out.push(b'\r');
            }
        }
        self.phone_cursor = (row, col);
    }
}

fn write_style(term: &Terminal, out: &mut Vec<u8>, previous: Option<Style>, style: Style) {
    if previous.map(|p| p.link) != Some(style.link) {
        if style.link == 0 {
            out.extend_from_slice(b"\x1b]8;;\x1b\\");
        } else {
            out.extend_from_slice(b"\x1b]8;");
            out.extend_from_slice(term.links.get(style.link).as_bytes());
            out.extend_from_slice(b"\x1b\\");
        }
    }
    let without_link = Style { link: 0, ..style };
    if previous.map(|p| Style { link: 0, ..p }) != Some(without_link) {
        without_link.write_sgr(out);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_line_rewraps_at_the_phone_width() {
        let mut term = Terminal::new(10, 3, 100);
        for &b in b"abcdefghijklmno" {
            term.advance(b);
        }
        let rows: Vec<&Row> = term.primary_rows()[..2].iter().collect();
        let wrapped = wrap_line(&term, &rows, 10, 4, Some((1, 5)));
        let text: Vec<String> = wrapped
            .rows
            .iter()
            .map(|r| r.cells.iter().map(|c| char::from_u32(c.ch).unwrap_or(' ')).collect())
            .collect();
        assert_eq!(text, ["abcd", "efgh", "ijkl", "mno"]);
        assert_eq!(wrapped.cursor, Some((3, 3)));
        assert!(wrapped.rows[..3].iter().all(|r| r.wrapped));
    }

    #[test]
    fn a_wide_glyph_never_splits() {
        let mut term = Terminal::new(10, 3, 100);
        for &b in "ab世界".as_bytes() {
            term.advance(b);
        }
        let rows: Vec<&Row> = term.primary_rows()[..1].iter().collect();
        let wrapped = wrap_line(&term, &rows, 10, 3, None);
        assert_eq!(wrapped.rows.len(), 3);
        assert_eq!(wrapped.rows[0].width(), 2);
        assert_eq!(wrapped.rows[1].cells[0].kind, WIDE);
    }
}
