//! Terminal grid implementation with tripartite design.
//!
//! This module implements a zellij-inspired grid structure:
//! - lines_above: VecDeque of rows in scrollback (above the viewport)
//! - viewport: Vec of rows currently visible
//! - lines_below: Vec of rows below the viewport (when scrolled up)
//!
//! This design enables efficient scrolling without reallocating large buffers.

use std::collections::{HashSet, VecDeque};

use super::character::{CharacterStyles, Row, SharedStyles, TerminalCharacter};

/// Maximum number of lines to keep in scrollback.
const MAX_SCROLLBACK_LINES: usize = 10_000;

/// Terminal grid with tripartite design for efficient scrolling.
#[derive(Clone, Debug)]
pub struct Grid {
    /// Lines that have scrolled above the viewport (scrollback buffer).
    pub lines_above: VecDeque<Row>,
    /// Currently visible lines.
    pub viewport: Vec<Row>,
    /// Lines that are below the viewport (when user scrolls up to view history).
    pub lines_below: Vec<Row>,
    /// Number of columns in the terminal.
    pub cols: usize,
    /// Number of rows in the viewport.
    pub rows: usize,
    /// Cursor row position (0-indexed, relative to viewport).
    pub cursor_row: usize,
    /// Cursor column position (0-indexed).
    pub cursor_col: usize,
    /// Current style for new characters.
    pub current_styles: CharacterStyles,
    /// Shared style instance for current_styles (cached).
    current_shared_styles: SharedStyles,
    /// Scroll region (top, bottom) - 0-indexed, inclusive.
    pub scroll_region: (usize, usize),
    /// Set of line indices that have changed since last render.
    pub changed_lines: HashSet<usize>,
    /// Flag to indicate full redraw is needed.
    pub needs_full_redraw: bool,
}

impl Grid {
    /// Create a new grid with the given dimensions.
    pub fn new(rows: usize, cols: usize) -> Self {
        let viewport: Vec<Row> = (0..rows).map(|_| Row::filled(cols)).collect();

        Self {
            lines_above: VecDeque::new(),
            viewport,
            lines_below: Vec::new(),
            cols,
            rows,
            cursor_row: 0,
            cursor_col: 0,
            current_styles: CharacterStyles::default(),
            current_shared_styles: SharedStyles::Default,
            scroll_region: (0, rows.saturating_sub(1)),
            changed_lines: HashSet::new(),
            needs_full_redraw: true,
        }
    }

    /// Mark a line as changed for differential rendering.
    #[inline]
    pub fn mark_line_changed(&mut self, line: usize) {
        if line < self.rows {
            self.changed_lines.insert(line);
        }
    }

    /// Mark all lines as changed.
    pub fn mark_all_changed(&mut self) {
        self.needs_full_redraw = true;
        self.changed_lines.clear();
        for i in 0..self.rows {
            self.changed_lines.insert(i);
        }
    }

    /// Clear the changed lines set.
    pub fn clear_changed(&mut self) {
        self.changed_lines.clear();
        self.needs_full_redraw = false;
    }

    /// Get the changed line indices.
    pub fn get_changed_lines(&self) -> &HashSet<usize> {
        &self.changed_lines
    }

    /// Check if full redraw is needed.
    pub fn needs_full_redraw(&self) -> bool {
        self.needs_full_redraw
    }

    /// Update the current style and cache the shared version.
    pub fn set_current_styles(&mut self, styles: CharacterStyles) {
        self.current_styles = styles;
        self.current_shared_styles = SharedStyles::new(styles);
    }

    /// Get the current shared styles.
    pub fn current_shared_styles(&self) -> SharedStyles {
        self.current_shared_styles.clone()
    }

    /// Get a reference to a row in the viewport.
    #[inline]
    pub fn get_row(&self, row: usize) -> Option<&Row> {
        self.viewport.get(row)
    }

    /// Get a mutable reference to a row in the viewport.
    #[inline]
    pub fn get_row_mut(&mut self, row: usize) -> Option<&mut Row> {
        self.mark_line_changed(row);
        self.viewport.get_mut(row)
    }

    /// Get a character at the given position.
    pub fn get_char(&self, row: usize, col: usize) -> Option<&TerminalCharacter> {
        self.viewport.get(row).and_then(|r| r.get(col))
    }

    /// Set a character at the given position.
    pub fn set_char(&mut self, row: usize, col: usize, character: TerminalCharacter) {
        if row < self.viewport.len() {
            self.mark_line_changed(row);
            self.viewport[row].set(col, character);
        }
    }

    /// Put a character at the current cursor position and advance the cursor.
    /// Returns the new cursor position.
    pub fn put_char(&mut self, c: char) -> (usize, usize) {
        if self.cursor_row >= self.rows {
            return (self.cursor_row, self.cursor_col);
        }

        let character = TerminalCharacter::new(c, self.current_shared_styles.clone());
        let char_width = character.width();

        // Handle wide character that doesn't fit at the end of line
        if char_width == 2 && self.cursor_col + 1 >= self.cols {
            // Clear current cell and wrap
            self.set_char(
                self.cursor_row,
                self.cursor_col,
                TerminalCharacter::default(),
            );
            self.cursor_col = 0;
            self.newline();
        }

        if self.cursor_row < self.viewport.len() {
            self.mark_line_changed(self.cursor_row);
            let new_col =
                self.viewport[self.cursor_row].add_character_at(character, self.cursor_col);

            // Ensure row has enough columns
            self.viewport[self.cursor_row].fill_to_width(self.cols);
            self.viewport[self.cursor_row].truncate(self.cols);

            self.cursor_col = new_col;
        }

        (self.cursor_row, self.cursor_col)
    }

    /// Move to a new line, scrolling if necessary.
    pub fn newline(&mut self) {
        let (_top, bottom) = self.scroll_region;

        if self.cursor_row >= bottom {
            self.scroll_up_in_region(1);
        } else {
            self.cursor_row += 1;
        }
    }

    /// Scroll up within the scroll region.
    pub fn scroll_up_in_region(&mut self, count: usize) {
        let (top, bottom) = self.scroll_region;

        for _ in 0..count {
            if top == 0 {
                // Save the top line to scrollback
                if !self.viewport.is_empty() {
                    let line = self.viewport.remove(0);
                    self.push_to_scrollback(line);
                }
                // Add a new empty line at the bottom of the scroll region
                self.viewport
                    .insert(bottom.min(self.viewport.len()), Row::filled(self.cols));
            } else {
                // Scroll within a limited region
                if top < self.viewport.len() && bottom < self.viewport.len() && top <= bottom {
                    self.viewport.remove(top);
                    self.viewport.insert(bottom, Row::filled(self.cols));
                }
            }
        }

        // Mark all lines in scroll region as changed
        for i in top..=bottom.min(self.rows - 1) {
            self.mark_line_changed(i);
        }
    }

    /// Scroll down within the scroll region.
    pub fn scroll_down_in_region(&mut self, count: usize) {
        let (top, bottom) = self.scroll_region;

        for _ in 0..count {
            if top < self.viewport.len() && bottom < self.viewport.len() && top <= bottom {
                self.viewport.remove(bottom);
                self.viewport.insert(top, Row::filled(self.cols));
            }
        }

        // Mark all lines in scroll region as changed
        for i in top..=bottom.min(self.rows - 1) {
            self.mark_line_changed(i);
        }
    }

    /// Insert n blank lines at the current cursor row (IL / CSI L).
    /// Lines at and below cursor shift down within scroll region.
    /// Lines that fall off the bottom of the scroll region are lost.
    pub fn insert_lines_at_cursor(&mut self, count: usize) {
        let (top, bottom) = self.scroll_region;
        let cursor_row = self.cursor_row;

        // Only operate if cursor is within scroll region
        if cursor_row < top || cursor_row > bottom {
            return;
        }

        for _ in 0..count {
            // Remove line at bottom of scroll region (it falls off)
            if bottom < self.viewport.len() {
                self.viewport.remove(bottom);
            }
            // Insert blank line at cursor row
            if cursor_row <= self.viewport.len() {
                self.viewport.insert(cursor_row, Row::filled(self.cols));
            }
        }

        // Mark all affected lines as changed (from cursor to bottom)
        for i in cursor_row..=bottom.min(self.rows - 1) {
            self.mark_line_changed(i);
        }
    }

    /// Delete n lines at the current cursor row (DL / CSI M).
    /// Lines below cursor shift up within scroll region.
    /// Blank lines are inserted at the bottom of the scroll region.
    pub fn delete_lines_at_cursor(&mut self, count: usize) {
        let (top, bottom) = self.scroll_region;
        let cursor_row = self.cursor_row;

        // Only operate if cursor is within scroll region
        if cursor_row < top || cursor_row > bottom {
            return;
        }

        for _ in 0..count {
            // Remove line at cursor row
            if cursor_row < self.viewport.len() {
                self.viewport.remove(cursor_row);
            }
            // Insert blank line at bottom of scroll region
            let insert_pos = bottom.min(self.viewport.len());
            self.viewport.insert(insert_pos, Row::filled(self.cols));
        }

        // Mark all affected lines as changed (from cursor to bottom)
        for i in cursor_row..=bottom.min(self.rows - 1) {
            self.mark_line_changed(i);
        }
    }

    /// Push a line to the scrollback buffer, respecting the maximum size.
    fn push_to_scrollback(&mut self, line: Row) {
        if self.lines_above.len() >= MAX_SCROLLBACK_LINES {
            self.lines_above.pop_front();
        }
        self.lines_above.push_back(line);
    }

    /// Clear from cursor to end of line.
    pub fn clear_to_end_of_line(&mut self) {
        if self.cursor_row < self.viewport.len() {
            self.mark_line_changed(self.cursor_row);
            self.viewport[self.cursor_row].clear_from(self.cursor_col);
            self.viewport[self.cursor_row].fill_to_width(self.cols);
        }
    }

    /// Clear from cursor to beginning of line.
    pub fn clear_to_start_of_line(&mut self) {
        if self.cursor_row < self.viewport.len() {
            self.mark_line_changed(self.cursor_row);
            self.viewport[self.cursor_row].clear_to(self.cursor_col);
        }
    }

    /// Clear entire line.
    pub fn clear_line(&mut self) {
        if self.cursor_row < self.viewport.len() {
            self.mark_line_changed(self.cursor_row);
            self.viewport[self.cursor_row] = Row::filled(self.cols);
        }
    }

    /// Clear from cursor to end of screen.
    pub fn clear_to_end_of_screen(&mut self) {
        self.clear_to_end_of_line();
        for row in (self.cursor_row + 1)..self.rows {
            if row < self.viewport.len() {
                self.mark_line_changed(row);
                self.viewport[row] = Row::filled(self.cols);
            }
        }
    }

    /// Clear from cursor to beginning of screen.
    pub fn clear_to_start_of_screen(&mut self) {
        self.clear_to_start_of_line();
        for row in 0..self.cursor_row {
            if row < self.viewport.len() {
                self.mark_line_changed(row);
                self.viewport[row] = Row::filled(self.cols);
            }
        }
    }

    /// Clear entire screen.
    pub fn clear_screen(&mut self) {
        for row in 0..self.rows {
            if row < self.viewport.len() {
                self.mark_line_changed(row);
                self.viewport[row] = Row::filled(self.cols);
            }
        }
    }

    /// Insert blank characters at cursor position.
    pub fn insert_chars(&mut self, count: usize) {
        if self.cursor_row < self.viewport.len() {
            self.mark_line_changed(self.cursor_row);
            self.viewport[self.cursor_row].insert_blank(self.cursor_col, count, self.cols);
        }
    }

    /// Delete characters at cursor position.
    pub fn delete_chars(&mut self, count: usize) {
        if self.cursor_row < self.viewport.len() {
            self.mark_line_changed(self.cursor_row);
            self.viewport[self.cursor_row].delete_chars(self.cursor_col, count, self.cols);
        }
    }

    /// Erase characters at cursor position (replace with blanks).
    pub fn erase_chars(&mut self, count: usize) {
        if self.cursor_row < self.viewport.len() {
            self.mark_line_changed(self.cursor_row);
            for i in 0..count {
                let col = self.cursor_col + i;
                if col < self.cols {
                    self.viewport[self.cursor_row].set(col, TerminalCharacter::default());
                }
            }
        }
    }

    /// Resize the grid to new dimensions.
    pub fn resize(&mut self, new_rows: usize, new_cols: usize) {
        if new_rows == self.rows && new_cols == self.cols {
            return;
        }

        let old_cols = self.cols;

        self.rows = new_rows;
        self.cols = new_cols;

        // Handle width change
        if new_cols != old_cols {
            // Rewrap lines if width changed
            self.rewrap_lines(new_cols);
        }

        // Handle height change
        while self.viewport.len() < new_rows {
            self.viewport.push(Row::filled(new_cols));
        }
        while self.viewport.len() > new_rows {
            // Move excess lines to lines_below
            if let Some(line) = self.viewport.pop() {
                self.lines_below.insert(0, line);
            }
        }

        // Adjust scroll region
        self.scroll_region = (0, new_rows.saturating_sub(1));

        // Clamp cursor to new bounds
        self.cursor_row = self.cursor_row.min(new_rows.saturating_sub(1));
        self.cursor_col = self.cursor_col.min(new_cols.saturating_sub(1));

        // Fix wide characters at the new edge
        self.fix_wide_chars_at_edge();

        self.mark_all_changed();
    }

    /// Rewrap lines when the terminal width changes.
    fn rewrap_lines(&mut self, new_cols: usize) {
        // Rewrap viewport lines
        let mut new_viewport = Vec::new();
        for row in &self.viewport {
            if new_cols < self.cols {
                // Narrower: split long lines
                let split_rows = row.split_to_rows_of_length(new_cols);
                for mut split_row in split_rows {
                    split_row.truncate(new_cols);
                    split_row.fill_to_width(new_cols);
                    new_viewport.push(split_row);
                }
            } else {
                // Wider: just extend/truncate
                let mut new_row = row.clone();
                new_row.fill_to_width(new_cols);
                new_row.truncate(new_cols);
                new_viewport.push(new_row);
            }
        }
        self.viewport = new_viewport;

        // Also rewrap scrollback
        let old_lines_above = std::mem::take(&mut self.lines_above);
        for row in old_lines_above {
            if new_cols < self.cols {
                let split_rows = row.split_to_rows_of_length(new_cols);
                for split_row in split_rows {
                    self.lines_above.push_back(split_row);
                }
            } else {
                let mut new_row = row;
                new_row.fill_to_width(new_cols);
                new_row.truncate(new_cols);
                self.lines_above.push_back(new_row);
            }
        }
    }

    /// Fix wide characters that are split at the edge after resize.
    fn fix_wide_chars_at_edge(&mut self) {
        for row in &mut self.viewport {
            if !row.is_empty() {
                // Check if last character is a wide character without its spacer
                if let Some(last) = row.columns.back() {
                    if last.width() > 1 && !last.wide_spacer {
                        // The spacer was cut off, clear this cell
                        if let Some(cell) = row.columns.back_mut() {
                            *cell = TerminalCharacter::default();
                        }
                    }
                }
            }
        }
    }

    /// Fix cursor position if it's on a wide character spacer.
    pub fn fix_cursor_on_spacer(&mut self) {
        if self.cursor_row < self.viewport.len() {
            if let Some(cell) = self.viewport[self.cursor_row].get(self.cursor_col) {
                if cell.wide_spacer && self.cursor_col > 0 {
                    self.cursor_col -= 1;
                }
            }
        }
    }

    /// Get the number of scrollback lines.
    pub fn scrollback_len(&self) -> usize {
        self.lines_above.len()
    }

    /// Get visible lines for rendering, accounting for scroll offset.
    /// Returns references to the lines that should be displayed.
    pub fn visible_lines(&self, scroll_offset: usize) -> Vec<&Row> {
        if scroll_offset == 0 {
            // Show current viewport
            self.viewport.iter().collect()
        } else {
            // Show scrollback + part of viewport
            let total_lines = self.lines_above.len() + self.viewport.len();
            let end = total_lines.saturating_sub(scroll_offset);
            let start = end.saturating_sub(self.rows);

            let mut lines = Vec::new();
            for i in start..end {
                if i < self.lines_above.len() {
                    lines.push(&self.lines_above[i]);
                } else {
                    let viewport_idx = i - self.lines_above.len();
                    if viewport_idx < self.viewport.len() {
                        lines.push(&self.viewport[viewport_idx]);
                    }
                }
            }
            lines
        }
    }

    /// Transfer rows from lines_above to viewport (when scrolling down to view history).
    pub fn scroll_view_up(&mut self, count: usize) -> usize {
        let max_scroll = self.lines_above.len();
        count.min(max_scroll)
    }

    /// Iterator over all viewport rows.
    pub fn viewport_iter(&self) -> impl Iterator<Item = &Row> {
        self.viewport.iter()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_grid_new() {
        let grid = Grid::new(24, 80);
        assert_eq!(grid.rows, 24);
        assert_eq!(grid.cols, 80);
        assert_eq!(grid.viewport.len(), 24);
        assert_eq!(grid.cursor_row, 0);
        assert_eq!(grid.cursor_col, 0);
    }

    #[test]
    fn test_grid_put_char() {
        let mut grid = Grid::new(24, 80);
        grid.put_char('H');
        grid.put_char('i');

        assert_eq!(grid.viewport[0].columns[0].character, 'H');
        assert_eq!(grid.viewport[0].columns[1].character, 'i');
        assert_eq!(grid.cursor_col, 2);
    }

    #[test]
    fn test_grid_newline() {
        let mut grid = Grid::new(3, 80);
        grid.put_char('A');
        grid.newline();
        grid.cursor_col = 0; // Carriage return is separate from newline
        grid.put_char('B');

        assert_eq!(grid.viewport[0].columns[0].character, 'A');
        assert_eq!(grid.viewport[1].columns[0].character, 'B');
        assert_eq!(grid.cursor_row, 1);
    }

    #[test]
    fn test_grid_scroll() {
        let mut grid = Grid::new(3, 80);
        grid.put_char('1');
        grid.newline();
        grid.cursor_col = 0;
        grid.put_char('2');
        grid.newline();
        grid.cursor_col = 0;
        grid.put_char('3');
        grid.newline();
        grid.cursor_col = 0;
        grid.put_char('4');

        // Line 1 should have scrolled into scrollback
        assert_eq!(grid.lines_above.len(), 1);
        assert_eq!(grid.lines_above[0].columns[0].character, '1');
    }

    #[test]
    fn test_grid_changed_lines() {
        let mut grid = Grid::new(24, 80);
        grid.clear_changed();

        grid.put_char('X');
        assert!(grid.changed_lines.contains(&0));

        grid.cursor_row = 5;
        grid.cursor_col = 0;
        grid.put_char('Y');
        assert!(grid.changed_lines.contains(&5));
    }

    #[test]
    fn test_grid_resize() {
        let mut grid = Grid::new(24, 80);
        grid.put_char('A');

        grid.resize(30, 100);
        assert_eq!(grid.rows, 30);
        assert_eq!(grid.cols, 100);
        assert_eq!(grid.viewport.len(), 30);

        // Original content should be preserved
        assert_eq!(grid.viewport[0].columns[0].character, 'A');
    }
}
