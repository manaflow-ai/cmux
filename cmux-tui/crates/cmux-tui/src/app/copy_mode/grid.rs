//! The terminal-backed grid copy mode reads while it holds the terminal:
//! cached screen rows, cell roles, logical lines, search, and selection text.

use std::collections::HashMap;

use ghostty_vt::{CellWidth, ScreenRowText, Terminal};

use super::engine::{CopyPoint, CopyView};

/// Rows a soft-wrapped logical line may span before line selection stops
/// extending it, so a pathological wrap chain stays bounded.
const LOGICAL_LINE_ROWS: u64 = 256;

/// One command's view of a terminal. Rows are read on demand and cached for
/// the length of the command; every coordinate is an absolute screen row.
pub(crate) struct TerminalGrid<'a> {
    term: &'a mut Terminal,
    cols: u16,
    total: u64,
    rows: HashMap<u64, ScreenRowText>,
}

impl<'a> TerminalGrid<'a> {
    pub(crate) fn new(term: &'a mut Terminal) -> Self {
        let cols = term.cols();
        let total =
            term.scrollbar().map_or(u64::from(term.rows()), |scrollbar| scrollbar.total).max(1);
        Self { term, cols, total, rows: HashMap::new() }
    }

    pub(crate) fn total_rows(&self) -> u64 {
        self.total
    }

    pub(crate) fn last_col(&self) -> u16 {
        self.cols.saturating_sub(1)
    }

    fn row(&mut self, row: u64) -> Option<&ScreenRowText> {
        if !self.rows.contains_key(&row) {
            let text = self.term.screen_row_text(row)?;
            self.rows.insert(row, text);
        }
        self.rows.get(&row)
    }

    pub(crate) fn width(&mut self, point: CopyPoint) -> CellWidth {
        self.row(point.row)
            .and_then(|row| row.cells.get(usize::from(point.col)))
            .map_or(CellWidth::Narrow, |cell| cell.width)
    }

    /// The first character of a cell, `None` for a blank cell or a spacer.
    pub(crate) fn first_char(&mut self, point: CopyPoint) -> Option<char> {
        self.row(point.row)
            .and_then(|row| row.cells.get(usize::from(point.col)))
            .and_then(|cell| cell.text.chars().next())
    }

    pub(crate) fn is_blank(&mut self, point: CopyPoint) -> bool {
        self.first_char(point).is_none_or(char::is_whitespace)
    }

    /// Whether a row soft-wraps into the next one.
    pub(crate) fn wraps(&mut self, row: u64) -> bool {
        self.row(row).is_some_and(|row| row.wraps)
    }

    /// The column of the cell that owns `col`: a wide grapheme's spacers
    /// resolve to its lead cell, so the cursor never rests on a spacer.
    pub(crate) fn lead_col(&mut self, row: u64, col: u16) -> u16 {
        let mut col = col.min(self.last_col());
        while col > 0
            && matches!(
                self.width(CopyPoint { row, col }),
                CellWidth::SpacerTail | CellWidth::SpacerHead
            )
        {
            col -= 1;
        }
        col
    }

    /// The next cell in the same row, skipping a wide grapheme's spacers.
    pub(crate) fn next_col(&mut self, point: CopyPoint) -> Option<u16> {
        let step = if self.width(point) == CellWidth::Wide { 2 } else { 1 };
        let mut col = point.col.checked_add(step)?;
        while col <= self.last_col()
            && matches!(
                self.width(CopyPoint { row: point.row, col }),
                CellWidth::SpacerTail | CellWidth::SpacerHead
            )
        {
            col += 1;
        }
        (col <= self.last_col()).then_some(col)
    }

    /// The previous cell in the same row.
    pub(crate) fn prev_col(&mut self, point: CopyPoint) -> Option<u16> {
        let col = point.col.checked_sub(1)?;
        Some(self.lead_col(point.row, col))
    }

    pub(crate) fn first_non_blank(&mut self, row: u64) -> u16 {
        (0..=self.last_col()).find(|&col| !self.is_blank(CopyPoint { row, col })).unwrap_or(0)
    }

    pub(crate) fn last_non_blank(&mut self, row: u64) -> u16 {
        let col = (0..=self.last_col())
            .rev()
            .find(|&col| !self.is_blank(CopyPoint { row, col }))
            .unwrap_or(0);
        self.lead_col(row, col)
    }

    /// The first and last rows of the soft-wrapped logical line holding `row`.
    pub(crate) fn logical_line(&mut self, row: u64) -> (u64, u64) {
        let mut top = row;
        while top > 0 && row - top < LOGICAL_LINE_ROWS && self.wraps(top - 1) {
            top -= 1;
        }
        let mut bottom = row;
        while bottom + 1 < self.total && bottom - row < LOGICAL_LINE_ROWS && self.wraps(bottom) {
            bottom += 1;
        }
        (top, bottom)
    }

    /// The terminal's own cursor, when it lies in `view`.
    pub(crate) fn terminal_cursor_in(&self, view: CopyView) -> Option<CopyPoint> {
        let (col, row) = self.term.cursor_position()?;
        let active_top = self.total.saturating_sub(u64::from(self.term.rows()));
        let point = CopyPoint { row: active_top + u64::from(row), col };
        view.contains_row(point.row).then_some(point)
    }

    /// Search matches as inclusive ranges, top to bottom, and whether more
    /// than `limit` existed.
    pub(crate) fn search(
        &mut self,
        needle: &str,
        case_sensitive: bool,
        limit: usize,
    ) -> (Vec<(CopyPoint, CopyPoint)>, bool) {
        let Ok(found) = self.term.search_screen(needle, case_sensitive, limit) else {
            return (Vec::new(), false);
        };
        let point = |point: ghostty_vt::SelectionPoint| CopyPoint {
            row: u64::from(point.row),
            col: point.column,
        };
        let matches =
            found.matches.iter().map(|range| (point(range.start), point(range.end))).collect();
        (matches, found.truncated)
    }

    /// The text between two points. A linear range joins soft-wrapped rows
    /// into one line; a block range keeps its columns on every row.
    pub(crate) fn text(&mut self, start: CopyPoint, end: CopyPoint, block: bool) -> Option<String> {
        let start = (start.col, start.row);
        let end = (end.col, end.row);
        let text = if block {
            self.term.block_selection_text_absolute(start, end)
        } else {
            self.term.selection_text_absolute(start, end)
        }?;
        (!text.is_empty()).then_some(text)
    }
}
