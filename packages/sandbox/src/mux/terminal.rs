use futures::{SinkExt, StreamExt};
use ratatui::style::{Color, Modifier, Style};
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::mpsc;
use tokio::sync::Mutex;
use tokio_tungstenite::{connect_async, tungstenite::protocol::Message};
use unicode_width::UnicodeWidthChar;
use vte::{Params, Parser, Perform};

use crate::models::{MuxClientMessage, MuxServerMessage, PtySessionId};
use crate::mux::events::MuxEvent;
use crate::mux::layout::{PaneId, TabId};

/// A single cell in the terminal grid
#[derive(Debug, Clone)]
pub struct Cell {
    pub c: char,
    pub style: Style,
    /// True if this cell is a spacer for a wide character (the cell to the right of a double-width char)
    pub wide_spacer: bool,
}

impl Default for Cell {
    fn default() -> Self {
        Self {
            c: ' ',
            style: Style::default(),
            wide_spacer: false,
        }
    }
}

/// Virtual terminal that properly handles ANSI escape sequences
#[derive(Debug, Clone)]
pub struct VirtualTerminal {
    /// Grid of cells (rows x cols)
    pub grid: Vec<Vec<Cell>>,
    /// Number of rows
    pub rows: usize,
    /// Number of columns
    pub cols: usize,
    /// Cursor row (0-indexed)
    pub cursor_row: usize,
    /// Cursor column (0-indexed)
    pub cursor_col: usize,
    /// Current style for new characters
    pub current_style: Style,
    /// Scroll offset for viewing history
    pub scroll_offset: usize,
    /// Scrollback buffer (lines that scrolled off top)
    pub scrollback: Vec<Vec<Cell>>,
    /// Maximum scrollback lines
    pub max_scrollback: usize,
    /// Saved cursor position and style
    saved_cursor: Option<SavedCursor>,
    /// Scroll region (top, bottom) - 0-indexed, inclusive
    scroll_region: (usize, usize),
    /// Cursor visible
    pub cursor_visible: bool,
    /// Insert mode (IRM) - when true, characters shift right instead of overwriting
    insert_mode: bool,
    /// Alternate screen buffer
    alternate_screen: Option<Box<AlternateScreen>>,
    /// Origin mode (DECOM) - cursor positioning relative to scroll region
    origin_mode: bool,
    /// Auto-wrap mode (DECAWM)
    auto_wrap: bool,
    /// Pending wrap - cursor is at the edge and next char will wrap
    pending_wrap: bool,
    /// Tab stops (columns where tabs stop)
    tab_stops: Vec<usize>,
    /// Current charset (0 = G0, 1 = G1)
    charset_index: usize,
    /// G0 charset mode (false = normal, true = line drawing)
    g0_charset_line_drawing: bool,
    /// G1 charset mode (false = normal, true = line drawing)
    g1_charset_line_drawing: bool,
    /// Application cursor keys mode (affects arrow key output)
    pub application_cursor_keys: bool,
    /// Application keypad mode (affects numpad output)
    pub application_keypad: bool,
    /// Bracketed paste mode
    pub bracketed_paste: bool,
    /// Mouse tracking mode (1000=X10, 1002=button-event, 1003=any-event)
    pub mouse_tracking: Option<u16>,
    /// SGR extended mouse mode (1006) - affects encoding of mouse events
    pub sgr_mouse_mode: bool,
    /// Bell triggered flag (for UI notification)
    pub bell_pending: bool,
    /// Window title (set via OSC)
    pub title: Option<String>,
    /// Last printed character (for REP - repeat)
    last_printed_char: Option<char>,
    /// Pending responses to send back to the PTY (e.g., DSR cursor position report)
    pub pending_responses: Vec<Vec<u8>>,
}

/// Saved cursor state (DECSC/DECRC)
#[derive(Debug, Clone)]
struct SavedCursor {
    row: usize,
    col: usize,
    style: Style,
    origin_mode: bool,
    auto_wrap: bool,
    charset_index: usize,
    g0_charset_line_drawing: bool,
    g1_charset_line_drawing: bool,
}

/// Saved state for alternate screen buffer
#[derive(Debug, Clone)]
struct AlternateScreen {
    grid: Vec<Vec<Cell>>,
    cursor_row: usize,
    cursor_col: usize,
    current_style: Style,
}

/// Line drawing character mapping (DEC Special Graphics)
fn line_drawing_char(c: char) -> char {
    match c {
        'j' => '┘', // Lower right corner
        'k' => '┐', // Upper right corner
        'l' => '┌', // Upper left corner
        'm' => '└', // Lower left corner
        'n' => '┼', // Crossing lines
        'q' => '─', // Horizontal line
        't' => '├', // Left tee
        'u' => '┤', // Right tee
        'v' => '┴', // Bottom tee
        'w' => '┬', // Top tee
        'x' => '│', // Vertical line
        'a' => '▒', // Checker board
        'f' => '°', // Degree symbol
        'g' => '±', // Plus/minus
        'y' => '≤', // Less than or equal
        'z' => '≥', // Greater than or equal
        '{' => 'π', // Pi
        '|' => '≠', // Not equal
        '}' => '£', // Pound sign
        '~' => '·', // Middle dot
        _ => c,
    }
}

/// Characters that are valid in URLs (simplified)
fn is_url_char(c: char) -> bool {
    c.is_ascii_alphanumeric()
        || matches!(
            c,
            '-' | '_'
                | '.'
                | '~'
                | ':'
                | '/'
                | '?'
                | '#'
                | '['
                | ']'
                | '@'
                | '!'
                | '$'
                | '&'
                | '\''
                | '('
                | ')'
                | '*'
                | '+'
                | ','
                | ';'
                | '='
                | '%'
        )
}

/// Find a URL at the given column position in a line of text.
/// Returns the URL if the column falls within a detected URL.
/// Note: `col` is a character index (0-based column position).
fn find_url_at_column(line: &str, col: usize) -> Option<String> {
    // Common URL schemes to detect
    const SCHEMES: &[&str] = &[
        "https://", "http://", "file://", "ssh://", "git://", "ftp://",
    ];

    // Convert line to chars for proper character-based indexing
    let chars: Vec<char> = line.chars().collect();

    // Find all URLs in the line using character positions
    for scheme in SCHEMES {
        let scheme_chars: Vec<char> = scheme.chars().collect();
        let scheme_len = scheme_chars.len();

        // Search for scheme in the character array
        let mut pos = 0;
        while pos + scheme_len <= chars.len() {
            // Check if scheme matches at this position
            if chars[pos..pos + scheme_len] == scheme_chars[..] {
                let start = pos;

                // Find the end of the URL (characters after the scheme that are valid URL chars)
                let url_end = chars[start..]
                    .iter()
                    .take_while(|&&c| is_url_char(c))
                    .count();
                let end = start + url_end;

                // Build the URL string
                let url_str: String = chars[start..end].iter().collect();

                // Strip trailing punctuation
                let url = url_str.trim_end_matches(['.', ',', ')', ']', ';']);

                if !url.is_empty() {
                    let actual_end = start + url.chars().count();

                    // Check if the column falls within this URL
                    if col >= start && col < actual_end {
                        return Some(url.to_string());
                    }
                }

                pos = start + scheme_len;
            } else {
                pos += 1;
            }
        }
    }

    None
}

impl VirtualTerminal {
    pub fn new(rows: usize, cols: usize) -> Self {
        let grid = vec![vec![Cell::default(); cols]; rows];
        // Initialize default tab stops every 8 columns
        let tab_stops: Vec<usize> = (0..cols).filter(|&c| c % 8 == 0 && c > 0).collect();
        Self {
            grid,
            rows,
            cols,
            cursor_row: 0,
            cursor_col: 0,
            current_style: Style::default(),
            scroll_offset: 0,
            scrollback: Vec::new(),
            max_scrollback: 10000,
            saved_cursor: None,
            scroll_region: (0, rows.saturating_sub(1)),
            cursor_visible: true,
            insert_mode: false,
            alternate_screen: None,
            origin_mode: false,
            auto_wrap: true,
            pending_wrap: false,
            tab_stops,
            charset_index: 0,
            g0_charset_line_drawing: false,
            g1_charset_line_drawing: false,
            application_cursor_keys: false,
            application_keypad: false,
            bracketed_paste: false,
            mouse_tracking: None,
            sgr_mouse_mode: false,
            bell_pending: false,
            title: None,
            last_printed_char: None,
            pending_responses: Vec::new(),
        }
    }

    /// Initialize default tab stops (every 8 columns)
    #[allow(dead_code)]
    fn reset_tab_stops(&mut self) {
        self.tab_stops = (0..self.cols).filter(|&c| c % 8 == 0 && c > 0).collect();
    }

    /// Clear all tab stops
    fn clear_all_tab_stops(&mut self) {
        self.tab_stops.clear();
    }

    /// Clear tab stop at current column
    fn clear_tab_stop_at_cursor(&mut self) {
        self.tab_stops.retain(|&c| c != self.cursor_col);
    }

    /// Set tab stop at current column
    fn set_tab_stop_at_cursor(&mut self) {
        if !self.tab_stops.contains(&self.cursor_col) {
            self.tab_stops.push(self.cursor_col);
            self.tab_stops.sort();
        }
    }

    /// Move cursor to next tab stop
    fn tab_forward(&mut self) {
        if let Some(&next_tab) = self.tab_stops.iter().find(|&&c| c > self.cursor_col) {
            self.cursor_col = next_tab.min(self.cols - 1);
        } else {
            // No more tab stops, go to end of line
            self.cursor_col = self.cols - 1;
        }
        self.pending_wrap = false;
    }

    /// Move cursor to previous tab stop (CBT)
    fn tab_backward(&mut self, n: usize) {
        for _ in 0..n {
            if let Some(&prev_tab) = self.tab_stops.iter().rev().find(|&&c| c < self.cursor_col) {
                self.cursor_col = prev_tab;
            } else {
                self.cursor_col = 0;
            }
        }
        self.pending_wrap = false;
    }

    /// Save cursor position and attributes (DECSC)
    fn save_cursor(&mut self) {
        self.saved_cursor = Some(SavedCursor {
            row: self.cursor_row,
            col: self.cursor_col,
            style: self.current_style,
            origin_mode: self.origin_mode,
            auto_wrap: self.auto_wrap,
            charset_index: self.charset_index,
            g0_charset_line_drawing: self.g0_charset_line_drawing,
            g1_charset_line_drawing: self.g1_charset_line_drawing,
        });
    }

    /// Restore cursor position and attributes (DECRC)
    fn restore_cursor(&mut self) {
        if let Some(saved) = &self.saved_cursor {
            self.cursor_row = saved.row.min(self.rows.saturating_sub(1));
            self.cursor_col = saved.col.min(self.cols.saturating_sub(1));
            self.current_style = saved.style;
            self.origin_mode = saved.origin_mode;
            self.auto_wrap = saved.auto_wrap;
            self.charset_index = saved.charset_index;
            self.g0_charset_line_drawing = saved.g0_charset_line_drawing;
            self.g1_charset_line_drawing = saved.g1_charset_line_drawing;
        }
        self.pending_wrap = false;
    }

    /// Resize the terminal
    pub fn resize(&mut self, new_rows: usize, new_cols: usize) {
        if new_rows == self.rows && new_cols == self.cols {
            return;
        }

        // Create new grid
        let mut new_grid = vec![vec![Cell::default(); new_cols]; new_rows];

        // Copy existing content
        for (row_idx, row) in self.grid.iter().enumerate() {
            if row_idx >= new_rows {
                break;
            }
            for (col_idx, cell) in row.iter().enumerate() {
                if col_idx >= new_cols {
                    break;
                }
                new_grid[row_idx][col_idx] = cell.clone();
            }
        }

        self.grid = new_grid;
        self.rows = new_rows;
        self.cols = new_cols;
        self.cursor_row = self.cursor_row.min(new_rows.saturating_sub(1));
        self.cursor_col = self.cursor_col.min(new_cols.saturating_sub(1));
        self.scroll_region = (0, new_rows.saturating_sub(1));
        // Update tab stops for new width
        self.tab_stops.retain(|&c| c < new_cols);
        // Fix wide characters that may have been split by the new edge
        self.fix_wide_chars_at_edge();
        // Ensure cursor isn't on a wide spacer
        self.fix_wide_char_at_cursor();
    }

    /// Resize a grid to current terminal dimensions, used when restoring alternate screen
    fn resize_grid_to_current(&self, old_grid: Vec<Vec<Cell>>) -> Vec<Vec<Cell>> {
        let old_rows = old_grid.len();
        let old_cols = old_grid.first().map(|r| r.len()).unwrap_or(0);

        // If dimensions match, return as-is
        if old_rows == self.rows && old_cols == self.cols {
            return old_grid;
        }

        // Create new grid with current dimensions
        let mut new_grid = vec![vec![Cell::default(); self.cols]; self.rows];

        // Copy existing content
        for (row_idx, row) in old_grid.iter().enumerate() {
            if row_idx >= self.rows {
                break;
            }
            for (col_idx, cell) in row.iter().enumerate() {
                if col_idx >= self.cols {
                    break;
                }
                new_grid[row_idx][col_idx] = cell.clone();
            }
        }

        new_grid
    }

    /// Process raw terminal data
    pub fn process(&mut self, data: &[u8]) {
        let mut parser = Parser::new();
        parser.advance(self, data);
    }

    /// Drain pending responses that should be sent back to the PTY
    pub fn drain_responses(&mut self) -> Vec<Vec<u8>> {
        std::mem::take(&mut self.pending_responses)
    }

    /// Scroll the screen up by one line within the scroll region
    fn scroll_up(&mut self) {
        let (top, bottom) = self.scroll_region;
        if top < self.rows && bottom < self.rows && top <= bottom {
            // Save the top line to scrollback if scrolling the whole screen
            if top == 0 {
                let line = self.grid[0].clone();
                self.scrollback.push(line);
                if self.scrollback.len() > self.max_scrollback {
                    self.scrollback.remove(0);
                }
            }

            // Shift lines up within scroll region
            for row in top..bottom {
                self.grid[row] = self.grid[row + 1].clone();
            }
            // Clear the bottom line of scroll region
            self.grid[bottom] = vec![Cell::default(); self.cols];
        }
    }

    /// Scroll the screen down by one line within the scroll region
    fn scroll_down(&mut self) {
        let (top, bottom) = self.scroll_region;
        if top < self.rows && bottom < self.rows && top <= bottom {
            // Shift lines down within scroll region
            for row in (top + 1..=bottom).rev() {
                self.grid[row] = self.grid[row - 1].clone();
            }
            // Clear the top line of scroll region
            self.grid[top] = vec![Cell::default(); self.cols];
        }
    }

    /// Move cursor to new line, scrolling if necessary
    fn newline(&mut self) {
        if self.cursor_row >= self.scroll_region.1 {
            self.scroll_up();
        } else {
            self.cursor_row += 1;
        }
    }

    /// Carriage return - move cursor to beginning of line
    fn carriage_return(&mut self) {
        self.cursor_col = 0;
    }

    /// Fix orphaned wide character cells after cursor movement or editing.
    /// If cursor lands on a wide spacer, move it to the main character.
    fn fix_wide_char_at_cursor(&mut self) {
        if self.cursor_row >= self.rows || self.cursor_col >= self.cols {
            return;
        }

        // If cursor is on a wide spacer, move to the main character
        if self.grid[self.cursor_row][self.cursor_col].wide_spacer && self.cursor_col > 0 {
            self.cursor_col -= 1;
        }
    }

    /// Fix wide characters that are split by the right edge of the terminal.
    /// Call this after resize operations.
    fn fix_wide_chars_at_edge(&mut self) {
        for row in &mut self.grid {
            if let Some(last_cell) = row.last() {
                // If the last cell is NOT a spacer but IS a wide character,
                // it means the spacer would be off-screen - clear it
                if !last_cell.wide_spacer && last_cell.c.width().unwrap_or(1) > 1 {
                    if let Some(last) = row.last_mut() {
                        *last = Cell::default();
                    }
                }
            }
        }
    }

    /// Put a character at cursor position and advance
    fn put_char(&mut self, c: char) {
        // Handle pending wrap from previous character at edge
        if self.pending_wrap {
            self.pending_wrap = false;
            self.cursor_col = 0;
            self.newline();
        }

        // Apply line drawing character set if active
        let display_char = if self.is_line_drawing_active() {
            line_drawing_char(c)
        } else {
            c
        };

        // Save for REP (repeat character) command
        self.last_printed_char = Some(display_char);

        // Determine character width (0, 1, or 2)
        let char_width = display_char.width().unwrap_or(1);

        // Handle zero-width characters (combining chars, etc.) - just skip them for now
        if char_width == 0 {
            return;
        }

        // For wide characters, check if we have room for both cells
        // If we're at the last column and it's a wide char, we need to wrap first
        if char_width == 2 && self.cursor_col + 1 >= self.cols {
            if self.auto_wrap {
                // Clear the current cell (it would be orphaned) and wrap
                if self.cursor_row < self.rows && self.cursor_col < self.cols {
                    self.grid[self.cursor_row][self.cursor_col] = Cell::default();
                }
                self.cursor_col = 0;
                self.newline();
            } else {
                // Can't fit, don't print
                return;
            }
        }

        // Defensive bounds check - ensure grid is properly sized
        if self.cursor_row < self.rows
            && self.cursor_col < self.cols
            && self.cursor_row < self.grid.len()
            && self
                .grid
                .get(self.cursor_row)
                .map(|r| self.cursor_col < r.len())
                .unwrap_or(false)
        {
            // In insert mode, shift characters right
            if self.insert_mode {
                let row = &mut self.grid[self.cursor_row];
                // Shift characters from cursor to end of line right by char_width
                for i in (self.cursor_col + char_width..self.cols.min(row.len())).rev() {
                    if i >= char_width && i < row.len() && i - char_width < row.len() {
                        row[i] = row[i - char_width].clone();
                    }
                }
            }

            // If we're overwriting a wide character spacer, clear the main char too
            if self.grid[self.cursor_row][self.cursor_col].wide_spacer && self.cursor_col > 0 {
                self.grid[self.cursor_row][self.cursor_col - 1] = Cell::default();
            }

            // If we're overwriting a wide character's first cell, clear the spacer
            if char_width == 1
                && self.cursor_col + 1 < self.cols
                && self.grid[self.cursor_row][self.cursor_col + 1].wide_spacer
            {
                self.grid[self.cursor_row][self.cursor_col + 1] = Cell::default();
            }

            // Place the character
            self.grid[self.cursor_row][self.cursor_col] = Cell {
                c: display_char,
                style: self.current_style,
                wide_spacer: false,
            };

            // For wide characters, place a spacer in the next cell
            if char_width == 2 && self.cursor_col + 1 < self.cols {
                // If the next cell is a wide char's first cell, clear its spacer too
                if self.cursor_col + 2 < self.cols
                    && self.grid[self.cursor_row][self.cursor_col + 2].wide_spacer
                {
                    self.grid[self.cursor_row][self.cursor_col + 2] = Cell::default();
                }

                self.grid[self.cursor_row][self.cursor_col + 1] = Cell {
                    c: ' ',
                    style: self.current_style,
                    wide_spacer: true,
                };
            }

            // Advance cursor
            let advance = char_width;
            if self.cursor_col + advance >= self.cols {
                // At the edge - set pending wrap if auto-wrap is enabled
                if self.auto_wrap {
                    self.pending_wrap = true;
                }
                self.cursor_col = self.cols - 1;
            } else {
                self.cursor_col += advance;
            }
        }
    }

    /// Check if line drawing character set is active
    fn is_line_drawing_active(&self) -> bool {
        if self.charset_index == 0 {
            self.g0_charset_line_drawing
        } else {
            self.g1_charset_line_drawing
        }
    }

    /// Repeat the last printed character n times
    fn repeat_char(&mut self, n: usize) {
        if let Some(c) = self.last_printed_char {
            let char_width = c.width().unwrap_or(1);
            if char_width == 0 {
                return;
            }

            for _ in 0..n {
                // Directly put the character without line drawing translation (already translated)
                if self.pending_wrap {
                    self.pending_wrap = false;
                    self.cursor_col = 0;
                    self.newline();
                }

                // For wide characters, check if we have room
                if char_width == 2 && self.cursor_col + 1 >= self.cols {
                    if self.auto_wrap {
                        if self.cursor_row < self.rows && self.cursor_col < self.cols {
                            self.grid[self.cursor_row][self.cursor_col] = Cell::default();
                        }
                        self.cursor_col = 0;
                        self.newline();
                    } else {
                        continue;
                    }
                }

                if self.cursor_row < self.rows && self.cursor_col < self.cols {
                    if self.insert_mode {
                        let row = &mut self.grid[self.cursor_row];
                        for i in (self.cursor_col + char_width..self.cols).rev() {
                            if i >= char_width {
                                row[i] = row[i - char_width].clone();
                            }
                        }
                    }

                    self.grid[self.cursor_row][self.cursor_col] = Cell {
                        c,
                        style: self.current_style,
                        wide_spacer: false,
                    };

                    // For wide characters, place a spacer
                    if char_width == 2 && self.cursor_col + 1 < self.cols {
                        self.grid[self.cursor_row][self.cursor_col + 1] = Cell {
                            c: ' ',
                            style: self.current_style,
                            wide_spacer: true,
                        };
                    }

                    let advance = char_width;
                    if self.cursor_col + advance >= self.cols {
                        if self.auto_wrap {
                            self.pending_wrap = true;
                        }
                        self.cursor_col = self.cols - 1;
                    } else {
                        self.cursor_col += advance;
                    }
                }
            }
        }
    }

    /// Insert n blank characters at cursor position, shifting existing chars right
    fn insert_chars(&mut self, n: usize) {
        if self.cursor_row < self.rows {
            let row = &mut self.grid[self.cursor_row];
            for _ in 0..n {
                if self.cursor_col < self.cols {
                    // Remove last character and insert blank at cursor
                    row.pop();
                    row.insert(self.cursor_col, Cell::default());
                }
            }
            // Ensure row has correct length
            while row.len() < self.cols {
                row.push(Cell::default());
            }
        }
    }

    /// Clear from cursor to end of line
    fn clear_to_end_of_line(&mut self) {
        if self.cursor_row < self.rows {
            for col in self.cursor_col..self.cols {
                self.grid[self.cursor_row][col] = Cell::default();
            }
        }
    }

    /// Clear from cursor to beginning of line
    fn clear_to_start_of_line(&mut self) {
        if self.cursor_row < self.rows {
            for col in 0..=self.cursor_col.min(self.cols - 1) {
                self.grid[self.cursor_row][col] = Cell::default();
            }
        }
    }

    /// Clear entire line
    fn clear_line(&mut self) {
        if self.cursor_row < self.rows {
            self.grid[self.cursor_row] = vec![Cell::default(); self.cols];
        }
    }

    /// Clear from cursor to end of screen
    fn clear_to_end_of_screen(&mut self) {
        self.clear_to_end_of_line();
        for row in (self.cursor_row + 1)..self.rows {
            self.grid[row] = vec![Cell::default(); self.cols];
        }
    }

    /// Clear from cursor to beginning of screen
    fn clear_to_start_of_screen(&mut self) {
        self.clear_to_start_of_line();
        for row in 0..self.cursor_row {
            self.grid[row] = vec![Cell::default(); self.cols];
        }
    }

    /// Clear entire screen
    fn clear_screen(&mut self) {
        for row in 0..self.rows {
            self.grid[row] = vec![Cell::default(); self.cols];
        }
    }

    /// Get visible lines for rendering (including scrollback)
    pub fn visible_lines(&self, height: usize) -> Vec<&Vec<Cell>> {
        if self.scroll_offset == 0 {
            // Show current screen
            self.grid.iter().take(height).collect()
        } else {
            // Show scrollback
            let total_lines = self.scrollback.len() + self.rows;
            let end = total_lines.saturating_sub(self.scroll_offset);
            let start = end.saturating_sub(height);

            let mut lines = Vec::new();
            for i in start..end {
                if i < self.scrollback.len() {
                    lines.push(&self.scrollback[i]);
                } else {
                    let grid_idx = i - self.scrollback.len();
                    if grid_idx < self.grid.len() {
                        lines.push(&self.grid[grid_idx]);
                    }
                }
            }
            lines
        }
    }

    /// Scroll view up (into history)
    pub fn scroll_view_up(&mut self, n: usize) {
        let max_scroll = self.scrollback.len();
        self.scroll_offset = (self.scroll_offset + n).min(max_scroll);
    }

    /// Scroll view down (towards current)
    pub fn scroll_view_down(&mut self, n: usize) {
        self.scroll_offset = self.scroll_offset.saturating_sub(n);
    }

    /// Scroll to bottom (current screen)
    pub fn scroll_to_bottom(&mut self) {
        self.scroll_offset = 0;
    }

    /// Parse SGR (Select Graphic Rendition) parameters
    fn apply_sgr(&mut self, params: &Params) {
        let params: Vec<u16> = params.iter().map(|p| p[0]).collect();

        if params.is_empty() {
            self.current_style = Style::default();
            return;
        }

        let mut i = 0;
        while i < params.len() {
            match params[i] {
                0 => self.current_style = Style::default(),
                1 => self.current_style = self.current_style.add_modifier(Modifier::BOLD),
                2 => self.current_style = self.current_style.add_modifier(Modifier::DIM),
                3 => self.current_style = self.current_style.add_modifier(Modifier::ITALIC),
                4 => self.current_style = self.current_style.add_modifier(Modifier::UNDERLINED),
                5 | 6 => self.current_style = self.current_style.add_modifier(Modifier::SLOW_BLINK),
                7 => self.current_style = self.current_style.add_modifier(Modifier::REVERSED),
                8 => self.current_style = self.current_style.add_modifier(Modifier::HIDDEN),
                9 => self.current_style = self.current_style.add_modifier(Modifier::CROSSED_OUT),
                22 => {
                    self.current_style = self
                        .current_style
                        .remove_modifier(Modifier::BOLD | Modifier::DIM)
                }
                23 => self.current_style = self.current_style.remove_modifier(Modifier::ITALIC),
                24 => self.current_style = self.current_style.remove_modifier(Modifier::UNDERLINED),
                25 => self.current_style = self.current_style.remove_modifier(Modifier::SLOW_BLINK),
                27 => self.current_style = self.current_style.remove_modifier(Modifier::REVERSED),
                28 => self.current_style = self.current_style.remove_modifier(Modifier::HIDDEN),
                29 => {
                    self.current_style = self.current_style.remove_modifier(Modifier::CROSSED_OUT)
                }
                // Foreground colors
                30 => self.current_style = self.current_style.fg(Color::Black),
                31 => self.current_style = self.current_style.fg(Color::Red),
                32 => self.current_style = self.current_style.fg(Color::Green),
                33 => self.current_style = self.current_style.fg(Color::Yellow),
                34 => self.current_style = self.current_style.fg(Color::Blue),
                35 => self.current_style = self.current_style.fg(Color::Magenta),
                36 => self.current_style = self.current_style.fg(Color::Cyan),
                37 => self.current_style = self.current_style.fg(Color::Gray),
                38 => {
                    // Extended foreground color
                    if i + 2 < params.len() && params[i + 1] == 5 {
                        // 256 color mode
                        self.current_style =
                            self.current_style.fg(Color::Indexed(params[i + 2] as u8));
                        i += 2;
                    } else if i + 4 < params.len() && params[i + 1] == 2 {
                        // RGB color mode
                        self.current_style = self.current_style.fg(Color::Rgb(
                            params[i + 2] as u8,
                            params[i + 3] as u8,
                            params[i + 4] as u8,
                        ));
                        i += 4;
                    }
                }
                39 => self.current_style = self.current_style.fg(Color::Reset),
                // Background colors
                40 => self.current_style = self.current_style.bg(Color::Black),
                41 => self.current_style = self.current_style.bg(Color::Red),
                42 => self.current_style = self.current_style.bg(Color::Green),
                43 => self.current_style = self.current_style.bg(Color::Yellow),
                44 => self.current_style = self.current_style.bg(Color::Blue),
                45 => self.current_style = self.current_style.bg(Color::Magenta),
                46 => self.current_style = self.current_style.bg(Color::Cyan),
                47 => self.current_style = self.current_style.bg(Color::Gray),
                48 => {
                    // Extended background color
                    if i + 2 < params.len() && params[i + 1] == 5 {
                        // 256 color mode
                        self.current_style =
                            self.current_style.bg(Color::Indexed(params[i + 2] as u8));
                        i += 2;
                    } else if i + 4 < params.len() && params[i + 1] == 2 {
                        // RGB color mode
                        self.current_style = self.current_style.bg(Color::Rgb(
                            params[i + 2] as u8,
                            params[i + 3] as u8,
                            params[i + 4] as u8,
                        ));
                        i += 4;
                    }
                }
                49 => self.current_style = self.current_style.bg(Color::Reset),
                // Bright foreground colors
                90 => self.current_style = self.current_style.fg(Color::DarkGray),
                91 => self.current_style = self.current_style.fg(Color::LightRed),
                92 => self.current_style = self.current_style.fg(Color::LightGreen),
                93 => self.current_style = self.current_style.fg(Color::LightYellow),
                94 => self.current_style = self.current_style.fg(Color::LightBlue),
                95 => self.current_style = self.current_style.fg(Color::LightMagenta),
                96 => self.current_style = self.current_style.fg(Color::LightCyan),
                97 => self.current_style = self.current_style.fg(Color::White),
                // Bright background colors
                100 => self.current_style = self.current_style.bg(Color::DarkGray),
                101 => self.current_style = self.current_style.bg(Color::LightRed),
                102 => self.current_style = self.current_style.bg(Color::LightGreen),
                103 => self.current_style = self.current_style.bg(Color::LightYellow),
                104 => self.current_style = self.current_style.bg(Color::LightBlue),
                105 => self.current_style = self.current_style.bg(Color::LightMagenta),
                106 => self.current_style = self.current_style.bg(Color::LightCyan),
                107 => self.current_style = self.current_style.bg(Color::White),
                _ => {}
            }
            i += 1;
        }
    }
}

impl Perform for VirtualTerminal {
    fn print(&mut self, c: char) {
        self.put_char(c);
    }

    fn execute(&mut self, byte: u8) {
        match byte {
            // Bell
            0x07 => {
                self.bell_pending = true;
            }
            // Backspace
            0x08 => {
                self.cursor_col = self.cursor_col.saturating_sub(1);
                self.pending_wrap = false;
            }
            // Tab
            0x09 => {
                self.tab_forward();
            }
            // Line feed, vertical tab, form feed
            // Note: In most terminal emulators, LF implies CR as well (onlcr behavior)
            0x0A..=0x0C => {
                self.newline();
                self.carriage_return();
            }
            // Carriage return
            0x0D => {
                self.carriage_return();
                self.pending_wrap = false;
            }
            // Shift Out - switch to G1 charset
            0x0E => {
                self.charset_index = 1;
            }
            // Shift In - switch to G0 charset
            0x0F => {
                self.charset_index = 0;
            }
            _ => {}
        }
    }

    fn hook(&mut self, _params: &Params, _intermediates: &[u8], _ignore: bool, _action: char) {}

    fn put(&mut self, _byte: u8) {}

    fn unhook(&mut self) {}

    fn osc_dispatch(&mut self, params: &[&[u8]], _bell_terminated: bool) {
        // Handle OSC sequences
        if params.is_empty() {
            return;
        }

        // Parse the command number
        let cmd = params[0];
        if let Ok(cmd_str) = std::str::from_utf8(cmd) {
            // Set window title (OSC 0 or OSC 2)
            if let Ok(0 | 2) = cmd_str.parse::<u8>() {
                if params.len() > 1 {
                    if let Ok(title) = std::str::from_utf8(params[1]) {
                        self.title = Some(title.to_string());
                    }
                }
            }
            // Other OSC commands (colors, etc.) - ignore for now
        }
    }

    fn csi_dispatch(&mut self, params: &Params, intermediates: &[u8], _ignore: bool, action: char) {
        let params_vec: Vec<u16> = params.iter().map(|p| p[0]).collect();

        match action {
            // Cursor Up
            'A' => {
                let n = params_vec.first().copied().unwrap_or(1).max(1) as usize;
                self.cursor_row = self.cursor_row.saturating_sub(n);
            }
            // Cursor Down
            'B' => {
                let n = params_vec.first().copied().unwrap_or(1).max(1) as usize;
                self.cursor_row = (self.cursor_row + n).min(self.rows - 1);
            }
            // Cursor Forward
            'C' => {
                let n = params_vec.first().copied().unwrap_or(1).max(1) as usize;
                self.cursor_col = (self.cursor_col + n).min(self.cols - 1);
            }
            // Cursor Back
            'D' => {
                let n = params_vec.first().copied().unwrap_or(1).max(1) as usize;
                self.cursor_col = self.cursor_col.saturating_sub(n);
            }
            // Cursor Next Line
            'E' => {
                let n = params_vec.first().copied().unwrap_or(1).max(1) as usize;
                self.cursor_row = (self.cursor_row + n).min(self.rows - 1);
                self.cursor_col = 0;
            }
            // Cursor Previous Line
            'F' => {
                let n = params_vec.first().copied().unwrap_or(1).max(1) as usize;
                self.cursor_row = self.cursor_row.saturating_sub(n);
                self.cursor_col = 0;
            }
            // Cursor Horizontal Absolute
            'G' => {
                let col = params_vec.first().copied().unwrap_or(1).max(1) as usize;
                self.cursor_col = (col - 1).min(self.cols - 1);
            }
            // Cursor Position
            'H' | 'f' => {
                let row = params_vec.first().copied().unwrap_or(1).max(1) as usize;
                let col = params_vec.get(1).copied().unwrap_or(1).max(1) as usize;
                self.cursor_row = (row - 1).min(self.rows - 1);
                self.cursor_col = (col - 1).min(self.cols - 1);
            }
            // Erase in Display
            'J' => {
                let mode = params_vec.first().copied().unwrap_or(0);
                match mode {
                    0 => self.clear_to_end_of_screen(),
                    1 => self.clear_to_start_of_screen(),
                    2 | 3 => self.clear_screen(),
                    _ => {}
                }
            }
            // Erase in Line
            'K' => {
                let mode = params_vec.first().copied().unwrap_or(0);
                match mode {
                    0 => self.clear_to_end_of_line(),
                    1 => self.clear_to_start_of_line(),
                    2 => self.clear_line(),
                    _ => {}
                }
            }
            // Insert Lines
            'L' => {
                let n = params_vec.first().copied().unwrap_or(1).max(1) as usize;
                for _ in 0..n {
                    self.scroll_down();
                }
            }
            // Delete Lines
            'M' => {
                let n = params_vec.first().copied().unwrap_or(1).max(1) as usize;
                for _ in 0..n {
                    self.scroll_up();
                }
            }
            // Delete Characters
            'P' => {
                let n = params_vec.first().copied().unwrap_or(1).max(1) as usize;
                if self.cursor_row < self.rows {
                    let row = &mut self.grid[self.cursor_row];
                    for _ in 0..n {
                        if self.cursor_col < row.len() {
                            row.remove(self.cursor_col);
                            row.push(Cell::default());
                        }
                    }
                }
            }
            // Scroll Up
            'S' => {
                let n = params_vec.first().copied().unwrap_or(1).max(1) as usize;
                for _ in 0..n {
                    self.scroll_up();
                }
            }
            // Scroll Down
            'T' => {
                let n = params_vec.first().copied().unwrap_or(1).max(1) as usize;
                for _ in 0..n {
                    self.scroll_down();
                }
            }
            // Erase Characters
            'X' => {
                let n = params_vec.first().copied().unwrap_or(1).max(1) as usize;
                if self.cursor_row < self.rows {
                    for i in 0..n {
                        let col = self.cursor_col + i;
                        if col < self.cols {
                            self.grid[self.cursor_row][col] = Cell::default();
                        }
                    }
                }
            }
            // Cursor Horizontal Absolute
            '`' => {
                let col = params_vec.first().copied().unwrap_or(1).max(1) as usize;
                self.cursor_col = (col - 1).min(self.cols - 1);
            }
            // Vertical Position Absolute
            'd' => {
                let row = params_vec.first().copied().unwrap_or(1).max(1) as usize;
                self.cursor_row = (row - 1).min(self.rows - 1);
            }
            // SGR - Select Graphic Rendition
            'm' if intermediates.is_empty() => {
                self.apply_sgr(params);
            }
            // Device Status Report (DSR)
            'n' => {
                let mode = params_vec.first().copied().unwrap_or(0);
                match mode {
                    5 => {
                        // Status Report - respond with "OK" (CSI 0 n)
                        self.pending_responses.push(b"\x1b[0n".to_vec());
                    }
                    6 => {
                        // Cursor Position Report (CPR) - respond with cursor position
                        // Note: Terminal rows/cols are 1-indexed in the response
                        let response =
                            format!("\x1b[{};{}R", self.cursor_row + 1, self.cursor_col + 1);
                        self.pending_responses.push(response.into_bytes());
                    }
                    _ => {}
                }
            }
            // Set scroll region
            'r' => {
                let top = params_vec.first().copied().unwrap_or(1).max(1) as usize - 1;
                let bottom = params_vec
                    .get(1)
                    .copied()
                    .unwrap_or(self.rows as u16)
                    .max(1) as usize
                    - 1;
                if top < self.rows && bottom < self.rows && top <= bottom {
                    self.scroll_region = (top, bottom);
                }
                self.cursor_row = 0;
                self.cursor_col = 0;
            }
            // Save cursor position (ANSI.SYS style)
            's' => {
                self.save_cursor();
            }
            // Restore cursor position (ANSI.SYS style)
            'u' => {
                self.restore_cursor();
            }
            // Cursor Backward Tabulation (CBT)
            'Z' => {
                let n = params_vec.first().copied().unwrap_or(1).max(1) as usize;
                self.tab_backward(n);
            }
            // Repeat previous character (REP)
            'b' => {
                let n = params_vec.first().copied().unwrap_or(1).max(1) as usize;
                self.repeat_char(n);
            }
            // Tab Clear (TBC)
            'g' => {
                let mode = params_vec.first().copied().unwrap_or(0);
                match mode {
                    0 => self.clear_tab_stop_at_cursor(),
                    3 => self.clear_all_tab_stops(),
                    _ => {}
                }
            }
            // Insert Characters (ICH)
            '@' => {
                let n = params_vec.first().copied().unwrap_or(1).max(1) as usize;
                self.insert_chars(n);
            }
            // Private modes (DECSET/DECRST) and standard modes (SM/RM)
            'h' | 'l' => {
                let enable = action == 'h';
                if intermediates == [b'?'] {
                    // Private (DEC) modes
                    for &param in &params_vec {
                        match param {
                            1 => {
                                // DECCKM - Cursor Keys Mode (application vs normal)
                                self.application_cursor_keys = enable;
                            }
                            6 => {
                                // DECOM - Origin Mode
                                self.origin_mode = enable;
                                self.cursor_row = 0;
                                self.cursor_col = 0;
                            }
                            7 => {
                                // DECAWM - Auto-wrap Mode
                                self.auto_wrap = enable;
                            }
                            25 => {
                                // DECTCEM - Cursor visibility
                                self.cursor_visible = enable;
                            }
                            1049 => {
                                // Alternate screen buffer (save cursor + switch)
                                if enable {
                                    // Save current screen and switch to alternate
                                    self.alternate_screen = Some(Box::new(AlternateScreen {
                                        grid: self.grid.clone(),
                                        cursor_row: self.cursor_row,
                                        cursor_col: self.cursor_col,
                                        current_style: self.current_style,
                                    }));
                                    // Clear the screen for alternate buffer
                                    self.grid = vec![vec![Cell::default(); self.cols]; self.rows];
                                    self.cursor_row = 0;
                                    self.cursor_col = 0;
                                } else {
                                    // Restore from alternate screen
                                    if let Some(saved) = self.alternate_screen.take() {
                                        // Resize saved grid to current dimensions if needed
                                        self.grid = self.resize_grid_to_current(saved.grid);
                                        // Clamp cursor to current dimensions
                                        self.cursor_row =
                                            saved.cursor_row.min(self.rows.saturating_sub(1));
                                        self.cursor_col =
                                            saved.cursor_col.min(self.cols.saturating_sub(1));
                                        self.current_style = saved.current_style;
                                    }
                                }
                            }
                            47 | 1047 => {
                                // Alternate screen buffer (without save cursor)
                                if enable {
                                    self.alternate_screen = Some(Box::new(AlternateScreen {
                                        grid: self.grid.clone(),
                                        cursor_row: self.cursor_row,
                                        cursor_col: self.cursor_col,
                                        current_style: self.current_style,
                                    }));
                                    self.grid = vec![vec![Cell::default(); self.cols]; self.rows];
                                } else if let Some(saved) = self.alternate_screen.take() {
                                    // Resize saved grid to current dimensions if needed
                                    self.grid = self.resize_grid_to_current(saved.grid);
                                }
                            }
                            2004 => {
                                // Bracketed paste mode
                                self.bracketed_paste = enable;
                            }
                            // Mouse tracking modes
                            1000 | 1002 | 1003 => {
                                // X10 (1000), button-event (1002), any-event (1003) mouse tracking
                                if enable {
                                    self.mouse_tracking = Some(param);
                                } else {
                                    self.mouse_tracking = None;
                                }
                            }
                            1006 => {
                                // SGR extended mouse mode
                                self.sgr_mouse_mode = enable;
                            }
                            _ => {}
                        }
                    }
                } else {
                    // Standard (ANSI) modes
                    for &param in &params_vec {
                        match param {
                            4 => {
                                // IRM - Insert/Replace Mode
                                self.insert_mode = enable;
                            }
                            20 => {
                                // LNM - Line Feed/New Line Mode
                                // We always treat LF as LF+CR, so ignore
                            }
                            _ => {}
                        }
                    }
                }
            }
            _ => {}
        }

        // Clear pending wrap on cursor movement
        if matches!(
            action,
            'A' | 'B' | 'C' | 'D' | 'E' | 'F' | 'G' | 'H' | 'f' | 'd' | '`'
        ) {
            self.pending_wrap = false;
        }
    }

    fn esc_dispatch(&mut self, intermediates: &[u8], _ignore: bool, byte: u8) {
        match (intermediates, byte) {
            // Save cursor (DECSC)
            ([], b'7') => {
                self.save_cursor();
            }
            // Restore cursor (DECRC)
            ([], b'8') => {
                self.restore_cursor();
            }
            // Reset (RIS)
            ([], b'c') => {
                *self = VirtualTerminal::new(self.rows, self.cols);
            }
            // Index - move down one line, scroll if at bottom
            ([], b'D') => {
                self.newline();
            }
            // Next Line
            ([], b'E') => {
                self.newline();
                self.cursor_col = 0;
            }
            // Horizontal Tab Set (HTS)
            ([], b'H') => {
                self.set_tab_stop_at_cursor();
            }
            // Reverse Index - move up one line, scroll if at top
            ([], b'M') => {
                if self.cursor_row == self.scroll_region.0 {
                    self.scroll_down();
                } else {
                    self.cursor_row = self.cursor_row.saturating_sub(1);
                }
            }
            // G0 charset designations
            ([b'('], b'0') => {
                // DEC Special Graphics (line drawing)
                self.g0_charset_line_drawing = true;
            }
            ([b'('], b'B') => {
                // ASCII (default)
                self.g0_charset_line_drawing = false;
            }
            // G1 charset designations
            ([b')'], b'0') => {
                self.g1_charset_line_drawing = true;
            }
            ([b')'], b'B') => {
                self.g1_charset_line_drawing = false;
            }
            // Application keypad mode (DECKPAM)
            ([], b'=') => {
                self.application_keypad = true;
            }
            // Normal keypad mode (DECKPNM)
            ([], b'>') => {
                self.application_keypad = false;
            }
            _ => {}
        }
    }
}

/// State for a single terminal session within the multiplexed connection.
#[derive(Debug)]
struct TerminalSession {
    /// Session ID used in the multiplexed protocol
    session_id: PtySessionId,
    /// Sandbox ID this session is connected to
    sandbox_id: String,
}

/// Convert PaneId to a session ID string for the multiplexed protocol.
fn pane_id_to_session_id(pane_id: PaneId) -> PtySessionId {
    pane_id.to_string()
}

/// Sender for the multiplexed WebSocket connection.
#[derive(Clone)]
pub struct MuxConnectionSender {
    tx: mpsc::UnboundedSender<MuxClientMessage>,
}

impl MuxConnectionSender {
    /// Send a message to the multiplexed connection.
    pub fn send(&self, msg: MuxClientMessage) -> bool {
        self.tx.send(msg).is_ok()
    }
}

/// Lightweight view of the terminal buffer tailored for rendering.
#[derive(Clone)]
pub struct TerminalRenderView {
    pub lines: Arc<[ratatui::text::Line<'static>]>,
    pub cursor: Option<(u16, u16)>,
    pub cursor_visible: bool,
    pub has_content: bool,
    pub changed_lines: Arc<[usize]>,
}

struct RenderCache {
    height: usize,
    scroll_offset: usize,
    generation: u64,
    lines: Arc<[ratatui::text::Line<'static>]>,
    cursor: Option<(u16, u16)>,
    cursor_visible: bool,
    has_content: bool,
    changed_lines: Arc<[usize]>,
}

impl RenderCache {
    fn is_valid(&self, height: usize, generation: u64, scroll_offset: usize) -> bool {
        self.height == height
            && self.generation == generation
            && self.scroll_offset == scroll_offset
    }

    fn as_view(&self) -> TerminalRenderView {
        TerminalRenderView {
            lines: self.lines.clone(),
            cursor: self.cursor,
            cursor_visible: self.cursor_visible,
            has_content: self.has_content,
            changed_lines: self.changed_lines.clone(),
        }
    }
}

/// Terminal output buffer for rendering - now using VirtualTerminal
pub struct TerminalBuffer {
    pub terminal: VirtualTerminal,
    parser: Parser,
    render_cache: Option<RenderCache>,
    generation: u64,
}

impl std::fmt::Debug for TerminalBuffer {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("TerminalBuffer")
            .field("terminal", &self.terminal)
            .field("generation", &self.generation)
            .finish()
    }
}

impl Default for TerminalBuffer {
    fn default() -> Self {
        Self::new()
    }
}

impl TerminalBuffer {
    pub fn new() -> Self {
        Self {
            terminal: VirtualTerminal::new(24, 80),
            parser: Parser::new(),
            render_cache: None,
            generation: 0,
        }
    }

    pub fn with_size(rows: usize, cols: usize) -> Self {
        Self {
            terminal: VirtualTerminal::new(rows, cols),
            parser: Parser::new(),
            render_cache: None,
            generation: 0,
        }
    }

    fn mark_dirty(&mut self) {
        self.render_cache = None;
        self.generation = self.generation.wrapping_add(1);
    }

    /// Process raw terminal data
    pub fn process(&mut self, data: &[u8]) {
        self.parser.advance(&mut self.terminal, data);
        self.mark_dirty();
    }

    /// Resize the terminal
    pub fn resize(&mut self, rows: usize, cols: usize) {
        self.terminal.resize(rows, cols);
        self.mark_dirty();
    }

    /// Scroll view up
    pub fn scroll_up(&mut self, n: usize) {
        self.terminal.scroll_view_up(n);
        self.mark_dirty();
    }

    /// Scroll view down
    pub fn scroll_down(&mut self, n: usize) {
        self.terminal.scroll_view_down(n);
        self.mark_dirty();
    }

    /// Scroll to bottom
    pub fn scroll_to_bottom(&mut self) {
        self.terminal.scroll_to_bottom();
        self.mark_dirty();
    }

    /// Clear the terminal
    pub fn clear(&mut self) {
        let rows = self.terminal.rows;
        let cols = self.terminal.cols;
        self.terminal = VirtualTerminal::new(rows, cols);
        self.parser = Parser::new();
        self.mark_dirty();
    }

    /// Drain pending responses that should be sent back to the PTY
    pub fn drain_responses(&mut self) -> Vec<Vec<u8>> {
        self.terminal.drain_responses()
    }

    /// Check if the terminal has any content
    pub fn has_content(&mut self) -> bool {
        if let Some(cache) = &self.render_cache {
            return cache.has_content;
        }

        if !self.terminal.scrollback.is_empty() {
            return true;
        }

        let default_style = Style::default();
        self.terminal.grid.iter().any(|row| {
            row.iter()
                .any(|cell| cell.c != ' ' || cell.style != default_style)
        })
    }

    /// Get cursor position (row, col) - returns None if scrolled away from bottom
    pub fn cursor_position(&self) -> Option<(u16, u16)> {
        // Only show cursor if we're at the bottom (not scrolled back)
        if self.terminal.scroll_offset == 0 && self.terminal.cursor_visible {
            Some((
                self.terminal.cursor_row as u16,
                self.terminal.cursor_col as u16,
            ))
        } else {
            None
        }
    }

    /// Check if cursor is visible
    pub fn cursor_visible(&self) -> bool {
        self.terminal.cursor_visible && self.terminal.scroll_offset == 0
    }

    /// Check if mouse tracking is enabled
    pub fn mouse_tracking(&self) -> Option<u16> {
        self.terminal.mouse_tracking
    }

    /// Check if SGR extended mouse mode is enabled
    pub fn sgr_mouse_mode(&self) -> bool {
        self.terminal.sgr_mouse_mode
    }

    /// Get the number of rows in the terminal grid
    pub fn rows(&self) -> usize {
        self.terminal.rows
    }

    /// Try to extract a URL at the given row and column (0-indexed).
    /// Returns the URL string if one is found at or near the given position.
    /// Handles URLs that wrap across multiple lines.
    pub fn url_at_position(&self, row: usize, col: usize) -> Option<String> {
        tracing::debug!(
            "url_at_position: row={}, col={}, scroll_offset={}, grid_len={}",
            row,
            col,
            self.terminal.scroll_offset,
            self.terminal.grid.len()
        );

        // Only support URL detection when not scrolled (simplifies the logic)
        if self.terminal.scroll_offset != 0 {
            tracing::debug!("Skipping URL detection: scrolled");
            return None;
        }

        // Bounds check
        if row >= self.terminal.grid.len() {
            tracing::debug!(
                "Row {} out of bounds (grid len: {})",
                row,
                self.terminal.grid.len()
            );
            return None;
        }

        let line = &self.terminal.grid[row];

        // Bounds check for column
        if col >= line.len() {
            tracing::debug!("Col {} out of bounds (line len: {})", col, line.len());
            return None;
        }

        // Convert current line to string (trimmed of trailing spaces)
        let line_text: String = line.iter().map(|cell| cell.c).collect();
        let line_text = line_text.trim_end();

        // Try to find URL on the current line first
        if let Some(url) = find_url_at_column(line_text, col) {
            // Check if URL might continue on the next line(s)
            // (line is full and ends with URL characters)
            let cols = self.terminal.cols;
            if line_text.len() >= cols.saturating_sub(1) && !url.is_empty() {
                let mut full_url = url.clone();
                let mut next_row = row + 1;

                // Look for continuation lines
                while next_row < self.terminal.grid.len() {
                    let next_line: String =
                        self.terminal.grid[next_row].iter().map(|c| c.c).collect();
                    let next_line = next_line.trim_end();

                    // Check if this line continues the URL (starts with URL chars, no space)
                    let continuation: String =
                        next_line.chars().take_while(|&c| is_url_char(c)).collect();

                    if continuation.is_empty() {
                        break;
                    }

                    full_url.push_str(&continuation);

                    // If this line doesn't fill the terminal width, stop
                    if next_line.len() < cols.saturating_sub(1) {
                        break;
                    }
                    next_row += 1;
                }

                return Some(full_url);
            }
            return Some(url);
        }

        // Check if this might be a continuation line - look for URL start on previous lines
        if row > 0 {
            // Check if previous line ends without a space (potential wrap)
            let prev_line: String = self.terminal.grid[row - 1].iter().map(|c| c.c).collect();
            let prev_line = prev_line.trim_end();
            let cols = self.terminal.cols;

            if prev_line.len() >= cols.saturating_sub(1) {
                // Look backwards for the URL start
                let mut start_row = row - 1;
                while start_row > 0 {
                    let check_line: String = self.terminal.grid[start_row - 1]
                        .iter()
                        .map(|c| c.c)
                        .collect();
                    let check_line = check_line.trim_end();
                    if check_line.len() < cols.saturating_sub(1) {
                        break;
                    }
                    start_row -= 1;
                }

                // Build the combined text from start_row to current row
                let mut combined = String::new();
                for r in start_row..=row {
                    let l: String = self.terminal.grid[r].iter().map(|c| c.c).collect();
                    combined.push_str(l.trim_end());
                }

                // Also include any continuation after current row
                let mut next_row = row + 1;
                while next_row < self.terminal.grid.len() {
                    let next_line: String =
                        self.terminal.grid[next_row].iter().map(|c| c.c).collect();
                    let next_line = next_line.trim_end();

                    let continuation: String =
                        next_line.chars().take_while(|&c| is_url_char(c)).collect();

                    if continuation.is_empty() {
                        break;
                    }

                    combined.push_str(&continuation);

                    if next_line.len() < cols.saturating_sub(1) {
                        break;
                    }
                    next_row += 1;
                }

                // Calculate the column position in the combined string
                let offset_in_combined = (row - start_row) * cols + col;

                if let Some(url) = find_url_at_column(&combined, offset_in_combined) {
                    return Some(url);
                }
            }
        }

        None
    }

    /// Build a cached render view for the given height.
    pub fn render_view(&mut self, height: usize) -> TerminalRenderView {
        if let Some(cache) = &self.render_cache {
            if cache.is_valid(height, self.generation, self.terminal.scroll_offset) {
                return cache.as_view();
            }
        }

        let cell_lines = self.terminal.visible_lines(height);
        let mut lines: Vec<ratatui::text::Line<'static>> = Vec::with_capacity(cell_lines.len());
        let mut has_content = !self.terminal.scrollback.is_empty();
        let default_style = Style::default();

        for cells in cell_lines {
            let mut spans: Vec<ratatui::text::Span<'static>> = Vec::new();
            let mut current_style = Style::default();
            let mut current_text = String::new();

            for cell in cells {
                if cell.wide_spacer {
                    continue;
                }

                if !has_content && (cell.c != ' ' || cell.style != default_style) {
                    has_content = true;
                }

                if cell.style == current_style {
                    current_text.push(cell.c);
                } else {
                    if !current_text.is_empty() {
                        spans.push(ratatui::text::Span::styled(
                            std::mem::take(&mut current_text),
                            current_style,
                        ));
                    }
                    current_style = cell.style;
                    current_text.push(cell.c);
                }
            }

            if !current_text.is_empty() {
                spans.push(ratatui::text::Span::styled(current_text, current_style));
            }

            lines.push(ratatui::text::Line::from(spans));
        }

        let cursor = self.cursor_position();
        let cursor_visible = self.cursor_visible();
        let lines: Arc<[ratatui::text::Line<'static>]> = lines.into();

        // Compute damage vs previous cache (line-level)
        let changed_lines: Arc<[usize]> = if let Some(cache) = &self.render_cache {
            if cache.height == height && cache.lines.len() == lines.len() {
                let mut changed = Vec::new();
                for (idx, (new_line, old_line)) in lines.iter().zip(cache.lines.iter()).enumerate()
                {
                    if new_line != old_line {
                        changed.push(idx);
                    }
                }
                changed.into()
            } else {
                (0..lines.len()).collect::<Vec<_>>().into()
            }
        } else {
            (0..lines.len()).collect::<Vec<_>>().into()
        };

        let cache = RenderCache {
            height,
            scroll_offset: self.terminal.scroll_offset,
            generation: self.generation,
            lines: lines.clone(),
            cursor,
            cursor_visible,
            has_content,
            changed_lines: changed_lines.clone(),
        };
        self.render_cache = Some(cache);

        TerminalRenderView {
            lines,
            cursor,
            cursor_visible,
            has_content,
            changed_lines,
        }
    }

    /// Get visible lines as ratatui Lines with styling
    pub fn visible_lines(&mut self, height: usize) -> Vec<ratatui::text::Line<'static>> {
        let view = self.render_view(height);
        view.lines.as_ref().to_vec()
    }
}

/// Manager for all terminal connections using a single multiplexed WebSocket.
pub struct TerminalManager {
    /// Base URL for WebSocket connections
    pub base_url: String,
    /// Active sessions by pane ID
    sessions: HashMap<PaneId, TerminalSession>,
    /// Reverse lookup: session_id -> pane_id
    session_to_pane: HashMap<PtySessionId, PaneId>,
    /// Output buffers by pane ID
    buffers: HashMap<PaneId, TerminalBuffer>,
    /// Last sent terminal sizes by pane ID (rows, cols)
    last_sizes: HashMap<PaneId, (u16, u16)>,
    /// Event channel to send events back to the app
    pub event_tx: mpsc::UnboundedSender<MuxEvent>,
    /// Sender for the multiplexed WebSocket connection (set after connection established)
    mux_sender: Option<MuxConnectionSender>,
    /// Flag indicating if connection is being established
    connecting: bool,
}

impl TerminalManager {
    pub fn new(base_url: String, event_tx: mpsc::UnboundedSender<MuxEvent>) -> Self {
        Self {
            base_url,
            sessions: HashMap::new(),
            session_to_pane: HashMap::new(),
            buffers: HashMap::new(),
            last_sizes: HashMap::new(),
            event_tx,
            mux_sender: None,
            connecting: false,
        }
    }

    /// Check if the multiplexed connection is established.
    pub fn is_mux_connected(&self) -> bool {
        self.mux_sender.is_some()
    }

    /// Check if we're currently trying to connect.
    pub fn is_connecting(&self) -> bool {
        self.connecting
    }

    /// Set the multiplexed connection sender.
    pub fn set_mux_sender(&mut self, sender: MuxConnectionSender) {
        self.mux_sender = Some(sender);
        self.connecting = false;
    }

    /// Mark that we're starting to connect.
    pub fn set_connecting(&mut self) {
        self.connecting = true;
    }

    /// Clear the multiplexed connection (on disconnect).
    pub fn clear_mux_connection(&mut self) {
        self.mux_sender = None;
        self.connecting = false;
        // Clear all sessions since they're now invalid
        self.sessions.clear();
        self.session_to_pane.clear();
    }

    /// Get the mux sender for sending messages.
    pub fn get_mux_sender(&self) -> Option<&MuxConnectionSender> {
        self.mux_sender.as_ref()
    }

    /// Get the output buffer for a pane
    pub fn get_buffer(&self, pane_id: PaneId) -> Option<&TerminalBuffer> {
        self.buffers.get(&pane_id)
    }

    /// Get the output buffer for a pane mutably
    pub fn get_buffer_mut(&mut self, pane_id: PaneId) -> Option<&mut TerminalBuffer> {
        self.buffers.get_mut(&pane_id)
    }

    /// Check if a pane has an active terminal session
    pub fn is_connected(&self, pane_id: PaneId) -> bool {
        self.sessions.contains_key(&pane_id)
    }

    /// Send input to a terminal session via the multiplexed connection
    pub fn send_input(&self, pane_id: PaneId, data: Vec<u8>) -> bool {
        let session = match self.sessions.get(&pane_id) {
            Some(s) => s,
            None => return false,
        };
        let sender = match &self.mux_sender {
            Some(s) => s,
            None => return false,
        };
        sender.send(MuxClientMessage::Input {
            session_id: session.session_id.clone(),
            data,
        })
    }

    /// Handle incoming terminal output from the multiplexed connection.
    /// Returns any pending responses that should be sent back to the PTY (e.g., DSR responses).
    pub fn handle_output(&mut self, pane_id: PaneId, data: Vec<u8>) -> Vec<Vec<u8>> {
        let buffer = self.buffers.entry(pane_id).or_default();
        buffer.process(&data);
        buffer.drain_responses()
    }

    /// Handle output by session ID (used by the mux connection handler).
    /// Automatically sends any pending responses back to the PTY.
    pub fn handle_output_by_session(
        &mut self,
        session_id: &PtySessionId,
        data: Vec<u8>,
    ) -> Option<PaneId> {
        let pane_id = *self.session_to_pane.get(session_id)?;
        let responses = self.handle_output(pane_id, data);
        // Send any pending responses back to the PTY
        if !responses.is_empty() {
            if let Some(sender) = &self.mux_sender {
                for response in responses {
                    sender.send(MuxClientMessage::Input {
                        session_id: session_id.clone(),
                        data: response,
                    });
                }
            }
        }
        Some(pane_id)
    }

    /// Get pane ID for a session ID
    pub fn get_pane_for_session(&self, session_id: &PtySessionId) -> Option<PaneId> {
        self.session_to_pane.get(session_id).copied()
    }

    /// Disconnect a terminal session
    pub fn disconnect(&mut self, pane_id: PaneId) {
        if let Some(session) = self.sessions.remove(&pane_id) {
            self.session_to_pane.remove(&session.session_id);
            // Send detach message to server
            if let Some(sender) = &self.mux_sender {
                let _ = sender.send(MuxClientMessage::Detach {
                    session_id: session.session_id,
                });
            }
        }
        self.last_sizes.remove(&pane_id);
    }

    /// Remove all state associated with a pane.
    pub fn remove_pane_state(&mut self, pane_id: PaneId) {
        if let Some(session) = self.sessions.remove(&pane_id) {
            self.session_to_pane.remove(&session.session_id);
            // Send detach message to server
            if let Some(sender) = &self.mux_sender {
                let _ = sender.send(MuxClientMessage::Detach {
                    session_id: session.session_id,
                });
            }
        }
        self.last_sizes.remove(&pane_id);
        self.buffers.remove(&pane_id);
    }

    /// Clear a terminal buffer
    pub fn clear_buffer(&mut self, pane_id: PaneId) {
        if let Some(buffer) = self.buffers.get_mut(&pane_id) {
            buffer.clear();
        }
    }

    /// Send resize event to a terminal and avoid duplicate updates
    pub fn update_view_size(&mut self, pane_id: PaneId, rows: u16, cols: u16) -> bool {
        if rows == 0 || cols == 0 {
            return false;
        }

        let last = self.last_sizes.get(&pane_id).copied();
        if let Some((last_rows, last_cols)) = last {
            if last_rows == rows && last_cols == cols {
                return true;
            }
        }

        if let Some(buffer) = self.buffers.get_mut(&pane_id) {
            buffer.resize(rows as usize, cols as usize);
        }

        self.last_sizes.insert(pane_id, (rows, cols));

        // Send resize via multiplexed connection
        if let Some(session) = self.sessions.get(&pane_id) {
            if let Some(sender) = &self.mux_sender {
                return sender.send(MuxClientMessage::Resize {
                    session_id: session.session_id.clone(),
                    cols,
                    rows,
                });
            }
        }
        true
    }

    /// Initialize a buffer with specific size
    pub fn init_buffer(&mut self, pane_id: PaneId, rows: usize, cols: usize) {
        self.buffers
            .insert(pane_id, TerminalBuffer::with_size(rows.max(1), cols.max(1)));
        self.last_sizes.insert(pane_id, (rows as u16, cols as u16));
    }

    /// Register a new session for a pane (called after receiving Attached message)
    pub fn register_session(
        &mut self,
        pane_id: PaneId,
        session_id: PtySessionId,
        sandbox_id: String,
    ) {
        self.sessions.insert(
            pane_id,
            TerminalSession {
                session_id: session_id.clone(),
                sandbox_id,
            },
        );
        self.session_to_pane.insert(session_id, pane_id);
    }

    /// Handle session exit (called when Exited message received)
    pub fn handle_session_exit(&mut self, session_id: &PtySessionId) -> Option<(PaneId, String)> {
        if let Some(&pane_id) = self.session_to_pane.get(session_id) {
            if let Some(session) = self.sessions.remove(&pane_id) {
                self.session_to_pane.remove(session_id);
                return Some((pane_id, session.sandbox_id));
            }
        }
        None
    }
}

/// Shared terminal manager for async access
pub type SharedTerminalManager = Arc<Mutex<TerminalManager>>;

/// Create a new shared terminal manager
pub fn create_terminal_manager(
    base_url: String,
    event_tx: mpsc::UnboundedSender<MuxEvent>,
) -> SharedTerminalManager {
    Arc::new(Mutex::new(TerminalManager::new(base_url, event_tx)))
}

/// Establish the single multiplexed WebSocket connection.
/// This should be called once at startup.
pub async fn establish_mux_connection(manager: SharedTerminalManager) -> anyhow::Result<()> {
    let (base_url, event_tx, already_connected) = {
        let mut mgr = manager.lock().await;
        if mgr.is_mux_connected() || mgr.is_connecting() {
            return Ok(()); // Already connected or connecting
        }
        mgr.set_connecting();
        (mgr.base_url.clone(), mgr.event_tx.clone(), false)
    };

    if already_connected {
        return Ok(());
    }

    let ws_url = base_url
        .replace("http://", "ws://")
        .replace("https://", "wss://")
        .trim_end_matches('/')
        .to_string();

    let url = format!("{}/mux/attach", ws_url);

    let (ws_stream, _) = match connect_async(&url).await {
        Ok(stream) => stream,
        Err(e) => {
            let mut mgr = manager.lock().await;
            mgr.clear_mux_connection();
            return Err(anyhow::anyhow!("Failed to connect to mux endpoint: {}", e));
        }
    };

    let (mut ws_write, mut ws_read) = ws_stream.split();

    // Create channel for sending messages to the WebSocket
    let (msg_tx, mut msg_rx) = mpsc::unbounded_channel::<MuxClientMessage>();

    // Store the sender in the manager
    let msg_tx_for_cache = {
        let mut mgr = manager.lock().await;
        mgr.set_mux_sender(MuxConnectionSender { tx: msg_tx });
        mgr.get_mux_sender().map(|s| s.tx.clone())
    };

    // Pre-fetch gh auth status and send to server for caching
    // This runs in the background so it doesn't block connection setup
    if let Some(tx) = msg_tx_for_cache {
        tokio::spawn(async move {
            let (exit_code, stdout, stderr) =
                run_gh_command(&["auth".to_string(), "status".to_string()], None).await;
            let _ = tx.send(MuxClientMessage::GhAuthCache {
                exit_code,
                stdout,
                stderr,
            });
        });
    }

    // Spawn task to handle WebSocket I/O
    let manager_clone = manager.clone();
    let event_tx_clone = event_tx.clone();

    tokio::spawn(async move {
        loop {
            tokio::select! {
                // Handle incoming messages from server
                msg = ws_read.next() => {
                    match msg {
                        Some(Ok(Message::Text(text))) => {
                            let server_msg: MuxServerMessage = match serde_json::from_str(&text) {
                                Ok(m) => m,
                                Err(e) => {
                                    let _ = event_tx_clone.send(MuxEvent::Error(format!(
                                        "Invalid server message: {}", e
                                    )));
                                    continue;
                                }
                            };

                            match server_msg {
                                MuxServerMessage::SandboxCreated(summary) => {
                                    let _ = event_tx_clone.send(MuxEvent::SandboxCreated(summary));
                                }
                                MuxServerMessage::SandboxList { sandboxes } => {
                                    let _ = event_tx_clone.send(MuxEvent::SandboxesRefreshed(sandboxes));
                                }
                                MuxServerMessage::Attached { session_id } => {
                                    // Session is now attached - this is handled via pending_attaches
                                    // in connect_to_sandbox
                                    let _ = event_tx_clone.send(MuxEvent::StatusMessage {
                                        message: format!("Session {} attached", session_id),
                                    });
                                }
                                MuxServerMessage::Output { session_id, data } => {
                                    let pane_id = {
                                        let mut mgr = manager_clone.lock().await;
                                        mgr.handle_output_by_session(&session_id, data)
                                    };
                                    if let Some(pane_id) = pane_id {
                                        let _ = event_tx_clone.send(MuxEvent::TerminalOutput {
                                            pane_id,
                                        });
                                    }
                                }
                                MuxServerMessage::Exited { session_id, .. } => {
                                    let exit_info = {
                                        let mut mgr = manager_clone.lock().await;
                                        mgr.handle_session_exit(&session_id)
                                    };
                                    if let Some((pane_id, sandbox_id)) = exit_info {
                                        let _ = event_tx_clone.send(MuxEvent::TerminalExited {
                                            pane_id,
                                            sandbox_id,
                                        });
                                    }
                                }
                                MuxServerMessage::Error { session_id, message } => {
                                    let _ = event_tx_clone.send(MuxEvent::Error(format!(
                                        "Session {:?}: {}", session_id, message
                                    )));
                                }
                                MuxServerMessage::Pong { .. } => {
                                    // Keepalive response, ignore
                                }
                                MuxServerMessage::OpenUrl { url, .. } => {
                                    // Open URL on the host machine (TUI runs on host)
                                    if let Err(e) = open::that(&url) {
                                        let _ = event_tx_clone.send(MuxEvent::Error(format!(
                                            "Failed to open URL {}: {}", url, e
                                        )));
                                    }
                                }
                                MuxServerMessage::Notification {
                                    message,
                                    level,
                                    sandbox_id,
                                    tab_id,
                                } => {
                                    let _ = event_tx_clone.send(MuxEvent::Notification {
                                        message,
                                        level,
                                        sandbox_id,
                                        tab_id,
                                    });
                                }
                                MuxServerMessage::GhRequest {
                                    request_id,
                                    args,
                                    stdin,
                                    ..
                                } => {
                                    // Run gh command locally and send response back
                                    let mgr = manager_clone.lock().await;
                                    if let Some(sender) = mgr.mux_sender.as_ref() {
                                        let response = run_gh_command(&args, stdin.as_deref()).await;
                                        let _ = sender.tx.send(MuxClientMessage::GhResponse {
                                            request_id,
                                            exit_code: response.0,
                                            stdout: response.1,
                                            stderr: response.2,
                                        });
                                    }
                                }
                            }
                        }
                        Some(Ok(Message::Close(_))) | None => {
                            break;
                        }
                        Some(Err(e)) => {
                            let _ = event_tx_clone.send(MuxEvent::Error(format!(
                                "Mux WebSocket error: {}", e
                            )));
                            break;
                        }
                        _ => {}
                    }
                }
                // Handle outgoing messages to server
                Some(msg) = msg_rx.recv() => {
                    let json = match serde_json::to_string(&msg) {
                        Ok(j) => j,
                        Err(e) => {
                            let _ = event_tx_clone.send(MuxEvent::Error(format!(
                                "Failed to serialize message: {}", e
                            )));
                            continue;
                        }
                    };
                    if ws_write.send(Message::Text(json)).await.is_err() {
                        break;
                    }
                }
            }
        }

        // Clean up connection
        {
            let mut mgr = manager_clone.lock().await;
            mgr.clear_mux_connection();
        }

        let _ = event_tx_clone.send(MuxEvent::Error("Multiplexed connection closed".to_string()));
    });

    Ok(())
}

/// Connect a pane to a sandbox terminal via the multiplexed connection.
/// This sends an Attach message to create a new PTY session for the pane.
pub async fn connect_to_sandbox(
    manager: SharedTerminalManager,
    pane_id: PaneId,
    sandbox_id: String,
    tab_id: Option<TabId>,
    cols: u16,
    rows: u16,
) -> anyhow::Result<()> {
    // Ensure the multiplexed connection is established
    establish_mux_connection(manager.clone()).await?;

    let session_id = pane_id_to_session_id(pane_id);
    let tab_id_string = tab_id.map(|id| id.to_string());
    let pane_id_string = pane_id.to_string();

    // Initialize buffer and send attach message
    {
        let mut mgr = manager.lock().await;

        // Initialize buffer with correct size
        mgr.init_buffer(pane_id, rows as usize, cols as usize);

        // Register the session (optimistically - server will confirm)
        mgr.register_session(pane_id, session_id.clone(), sandbox_id.clone());

        // Send attach message
        if let Some(sender) = mgr.get_mux_sender() {
            sender.send(MuxClientMessage::Attach {
                session_id,
                sandbox_id: sandbox_id.clone(),
                cols,
                rows,
                command: None,
                tty: true,
                tab_id: tab_id_string,
                pane_id: Some(pane_id_string),
            });
        } else {
            return Err(anyhow::anyhow!("Mux connection not established"));
        }
    }

    // Notify connection established
    let event_tx = {
        let mgr = manager.lock().await;
        mgr.event_tx.clone()
    };
    let _ = event_tx.send(MuxEvent::SandboxConnectionChanged {
        sandbox_id,
        connected: true,
    });

    Ok(())
}

/// Request sandbox creation via the multiplexed WebSocket connection.
/// The server will respond with a SandboxCreated message.
pub async fn request_create_sandbox(
    manager: SharedTerminalManager,
    name: Option<String>,
) -> anyhow::Result<()> {
    // Ensure the multiplexed connection is established
    establish_mux_connection(manager.clone()).await?;

    let mgr = manager.lock().await;
    if let Some(sender) = mgr.get_mux_sender() {
        sender.send(MuxClientMessage::CreateSandbox {
            name,
            env: crate::keyring::build_default_env_vars(),
        });
        Ok(())
    } else {
        Err(anyhow::anyhow!("Mux connection not established"))
    }
}

/// Request sandbox list via the multiplexed WebSocket connection.
/// The server will respond with a SandboxList message.
pub async fn request_list_sandboxes(manager: SharedTerminalManager) -> anyhow::Result<()> {
    // Ensure the multiplexed connection is established
    establish_mux_connection(manager.clone()).await?;

    let mgr = manager.lock().await;
    if let Some(sender) = mgr.get_mux_sender() {
        sender.send(MuxClientMessage::ListSandboxes);
        Ok(())
    } else {
        Err(anyhow::anyhow!("Mux connection not established"))
    }
}

/// Run a gh command locally on the host machine.
/// Returns (exit_code, stdout, stderr).
async fn run_gh_command(args: &[String], stdin: Option<&str>) -> (i32, String, String) {
    use std::process::Stdio;
    use tokio::io::AsyncWriteExt;
    use tokio::process::Command;

    let mut cmd = Command::new("gh");
    cmd.args(args);
    cmd.stdout(Stdio::piped());
    cmd.stderr(Stdio::piped());

    if stdin.is_some() {
        cmd.stdin(Stdio::piped());
    }

    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => {
            return (1, String::new(), format!("Failed to spawn gh: {}", e));
        }
    };

    // Write stdin if provided
    if let Some(input) = stdin {
        if let Some(mut child_stdin) = child.stdin.take() {
            if let Err(e) = child_stdin.write_all(input.as_bytes()).await {
                return (
                    1,
                    String::new(),
                    format!("Failed to write to gh stdin: {}", e),
                );
            }
            drop(child_stdin); // Close stdin to signal EOF
        }
    }

    match child.wait_with_output().await {
        Ok(output) => (
            output.status.code().unwrap_or(1),
            String::from_utf8_lossy(&output.stdout).to_string(),
            String::from_utf8_lossy(&output.stderr).to_string(),
        ),
        Err(e) => (1, String::new(), format!("Failed to wait for gh: {}", e)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn virtual_terminal_handles_basic_text() {
        let mut term = VirtualTerminal::new(24, 80);
        term.process(b"Hello, World!");
        assert_eq!(term.grid[0][0].c, 'H');
        assert_eq!(term.grid[0][6].c, ' ');
        assert_eq!(term.grid[0][7].c, 'W');
    }

    #[test]
    fn virtual_terminal_handles_newline() {
        let mut term = VirtualTerminal::new(24, 80);
        term.process(b"Line 1\nLine 2");
        assert_eq!(term.grid[0][0].c, 'L');
        assert_eq!(term.grid[1][0].c, 'L');
    }

    #[test]
    fn virtual_terminal_handles_cursor_movement() {
        let mut term = VirtualTerminal::new(24, 80);
        term.process(b"Hello\x1b[2;1HWorld"); // Move to row 2, col 1
        assert_eq!(term.grid[0][0].c, 'H');
        assert_eq!(term.grid[1][0].c, 'W');
    }

    #[test]
    fn virtual_terminal_handles_colors() {
        let mut term = VirtualTerminal::new(24, 80);
        term.process(b"\x1b[31mRed\x1b[0m");
        assert_eq!(term.grid[0][0].c, 'R');
        assert_eq!(term.grid[0][0].style.fg, Some(Color::Red));
        assert_eq!(term.grid[0][2].style.fg, Some(Color::Red));
    }

    #[test]
    fn ignores_private_intermediate_sgr() {
        let mut term = VirtualTerminal::new(2, 10);
        term.process(b"\x1b[>4;1mHi");
        assert_eq!(term.grid[0][0].style, Style::default());
        assert_eq!(term.grid[0][1].style, Style::default());
    }

    #[test]
    fn virtual_terminal_handles_clear_screen() {
        let mut term = VirtualTerminal::new(24, 80);
        term.process(b"Hello");
        term.process(b"\x1b[2J"); // Clear screen
        assert_eq!(term.grid[0][0].c, ' ');
    }

    #[test]
    fn virtual_terminal_scrolls() {
        let mut term = VirtualTerminal::new(3, 80);
        term.process(b"Line 1\nLine 2\nLine 3\nLine 4");
        // Line 1 should have scrolled into scrollback
        assert_eq!(term.scrollback.len(), 1);
        assert_eq!(term.scrollback[0][0].c, 'L');
    }

    #[test]
    fn virtual_terminal_responds_to_dsr_cursor_position() {
        let mut term = VirtualTerminal::new(24, 80);
        // Move cursor to row 5, col 10 (1-indexed in escape sequence)
        term.process(b"\x1b[5;10H");
        assert_eq!(term.cursor_row, 4); // 0-indexed
        assert_eq!(term.cursor_col, 9); // 0-indexed

        // Send DSR request for cursor position (CSI 6 n)
        term.process(b"\x1b[6n");

        // Should have a pending response with cursor position
        let responses = term.drain_responses();
        assert_eq!(responses.len(), 1);
        // Response should be CSI row;col R (1-indexed)
        assert_eq!(responses[0], b"\x1b[5;10R");
    }

    #[test]
    fn virtual_terminal_responds_to_dsr_status() {
        let mut term = VirtualTerminal::new(24, 80);
        // Send DSR request for status (CSI 5 n)
        term.process(b"\x1b[5n");

        // Should have a pending response with "OK" status
        let responses = term.drain_responses();
        assert_eq!(responses.len(), 1);
        assert_eq!(responses[0], b"\x1b[0n");
    }
}
