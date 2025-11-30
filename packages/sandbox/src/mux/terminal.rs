use futures::{SinkExt, StreamExt};
use ratatui::style::{Color, Modifier, Style};
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::mpsc;
use tokio::sync::Mutex;
use tokio_tungstenite::{connect_async, tungstenite::protocol::Message};
use vte::{Params, Parser, Perform};

use crate::models::{MuxClientMessage, MuxServerMessage, PtySessionId};
use crate::mux::character::{CharacterStyles, Row, TerminalCharacter};
use crate::mux::events::MuxEvent;
use crate::mux::grid::Grid;
use crate::mux::layout::{PaneId, TabId};

/// A single cell in the terminal grid (legacy compatibility type).
/// This is used for backward compatibility with existing tests and APIs.
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

impl From<&TerminalCharacter> for Cell {
    fn from(tc: &TerminalCharacter) -> Self {
        Cell {
            c: tc.character,
            style: tc.styles.to_ratatui_style(),
            wide_spacer: tc.wide_spacer,
        }
    }
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

/// Parse an OSC color specification and return RGB values.
/// Supports formats:
/// - `rgb:RRRR/GGGG/BBBB` (X11 format, 16-bit per channel)
/// - `rgb:RR/GG/BB` (X11 format, 8-bit per channel)
/// - `#RRGGBB` (6-digit hex)
/// - `#RGB` (3-digit hex)
fn parse_osc_color(s: &str) -> Option<(u8, u8, u8)> {
    let s = s.trim();

    if let Some(rest) = s.strip_prefix("rgb:") {
        // X11 rgb:RRRR/GGGG/BBBB or rgb:RR/GG/BB format
        let parts: Vec<&str> = rest.split('/').collect();
        if parts.len() == 3 {
            let r = u16::from_str_radix(parts[0], 16).ok()?;
            let g = u16::from_str_radix(parts[1], 16).ok()?;
            let b = u16::from_str_radix(parts[2], 16).ok()?;

            // Scale to 8-bit based on input length
            let scale = |v: u16, len: usize| -> u8 {
                match len {
                    1 => ((v * 255) / 15) as u8,   // 4-bit to 8-bit
                    2 => v as u8,                  // Already 8-bit
                    3 => ((v * 255) / 4095) as u8, // 12-bit to 8-bit
                    4 => (v / 257) as u8,          // 16-bit to 8-bit
                    _ => v as u8,
                }
            };

            return Some((
                scale(r, parts[0].len()),
                scale(g, parts[1].len()),
                scale(b, parts[2].len()),
            ));
        }
    } else if let Some(rest) = s.strip_prefix('#') {
        match rest.len() {
            // #RGB -> expand to #RRGGBB
            3 => {
                let r = u8::from_str_radix(&rest[0..1], 16).ok()?;
                let g = u8::from_str_radix(&rest[1..2], 16).ok()?;
                let b = u8::from_str_radix(&rest[2..3], 16).ok()?;
                return Some((r * 17, g * 17, b * 17));
            }
            // #RRGGBB
            6 => {
                let r = u8::from_str_radix(&rest[0..2], 16).ok()?;
                let g = u8::from_str_radix(&rest[2..4], 16).ok()?;
                let b = u8::from_str_radix(&rest[4..6], 16).ok()?;
                return Some((r, g, b));
            }
            _ => {}
        }
    }

    None
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

/// Virtual terminal that properly handles ANSI escape sequences.
/// Uses the optimized Grid structure internally for efficient storage and scrolling.
#[derive(Debug, Clone)]
pub struct VirtualTerminal {
    /// Optimized grid structure with tripartite design
    pub(crate) internal_grid: Grid,
    /// Maximum scrollback lines
    pub max_scrollback: usize,
    /// Saved cursor position and style
    saved_cursor: Option<SavedCursor>,
    /// Cursor visible
    pub cursor_visible: bool,
    /// Cursor blink enabled
    pub cursor_blink: bool,
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
    /// Default foreground color (OSC 10) - None means use terminal's native color
    pub default_fg_color: Option<(u8, u8, u8)>,
    /// Default background color (OSC 11) - None means use terminal's native color
    pub default_bg_color: Option<(u8, u8, u8)>,
    /// Flag to signal alt screen was entered/exited (for UI to reset scroll state)
    pub alt_screen_toggled: bool,
}

/// Saved cursor state (DECSC/DECRC)
#[derive(Debug, Clone)]
struct SavedCursor {
    row: usize,
    col: usize,
    styles: CharacterStyles,
    origin_mode: bool,
    auto_wrap: bool,
    charset_index: usize,
    g0_charset_line_drawing: bool,
    g1_charset_line_drawing: bool,
}

/// Saved state for alternate screen buffer
#[derive(Debug, Clone)]
struct AlternateScreen {
    grid: Grid,
    cursor_row: usize,
    cursor_col: usize,
    current_styles: CharacterStyles,
    // Terminal modes that affect cursor positioning (per xterm behavior)
    origin_mode: bool,
    auto_wrap: bool,
    pending_wrap: bool,
    // Cursor visibility modes (per-screen state)
    cursor_visible: bool,
    cursor_blink: bool,
    // Charset state
    charset_index: usize,
    g0_charset_line_drawing: bool,
    g1_charset_line_drawing: bool,
}

impl VirtualTerminal {
    pub fn new(rows: usize, cols: usize) -> Self {
        // Initialize default tab stops every 8 columns
        let tab_stops: Vec<usize> = (0..cols).filter(|&c| c % 8 == 0 && c > 0).collect();
        Self {
            internal_grid: Grid::new(rows, cols),
            max_scrollback: 10000,
            saved_cursor: None,
            cursor_visible: true,
            cursor_blink: true,
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
            default_fg_color: None, // Use terminal's native color
            default_bg_color: None, // Use terminal's native color
            alt_screen_toggled: false,
        }
    }

    // ===== Property accessors for backward compatibility =====

    /// Get number of rows
    #[inline]
    pub fn rows(&self) -> usize {
        self.internal_grid.rows
    }

    /// Get number of columns
    #[inline]
    pub fn cols(&self) -> usize {
        self.internal_grid.cols
    }

    /// Get cursor row
    #[inline]
    pub fn cursor_row(&self) -> usize {
        self.internal_grid.cursor_row
    }

    /// Get cursor column
    #[inline]
    pub fn cursor_col(&self) -> usize {
        self.internal_grid.cursor_col
    }

    /// Set cursor row
    #[inline]
    pub fn set_cursor_row(&mut self, row: usize) {
        self.internal_grid.cursor_row = row;
    }

    /// Set cursor column
    #[inline]
    pub fn set_cursor_col(&mut self, col: usize) {
        self.internal_grid.cursor_col = col;
    }

    /// Get scroll region
    #[inline]
    pub fn scroll_region(&self) -> (usize, usize) {
        self.internal_grid.scroll_region
    }

    /// Get current style as ratatui Style
    pub fn current_style(&self) -> Style {
        self.internal_grid.current_styles.to_ratatui_style()
    }

    /// Get scrollback length
    pub fn scrollback_len(&self) -> usize {
        self.internal_grid.scrollback_len()
    }

    // ===== Legacy grid accessor (for tests) =====

    /// Provides legacy Vec<Vec<Cell>> like access for backward compatibility.
    /// Returns a Cell at the given position.
    pub fn get_cell(&self, row: usize, col: usize) -> Cell {
        if let Some(tc) = self.internal_grid.get_char(row, col) {
            Cell::from(tc)
        } else {
            Cell::default()
        }
    }

    /// Legacy grid accessor that simulates the old `grid[row][col]` access pattern.
    /// This exists purely for test compatibility and should not be used in new code.
    #[cfg(test)]
    pub fn legacy_grid(&self) -> LegacyGridAccessor<'_> {
        LegacyGridAccessor { term: self }
    }

    // ===== Public field accessors for backward compatibility with tests =====

    /// Legacy grid accessor - returns a view that can be indexed like Vec<Vec<Cell>>
    /// WARNING: This allocates! Use get_cell() for single cell access.
    pub fn grid_snapshot(&self) -> Vec<Vec<Cell>> {
        self.internal_grid
            .viewport
            .iter()
            .map(|row| row.columns.iter().map(Cell::from).collect())
            .collect()
    }

    /// Legacy scrollback accessor
    /// WARNING: This allocates!
    pub fn scrollback_snapshot(&self) -> Vec<Vec<Cell>> {
        self.internal_grid
            .lines_above
            .iter()
            .map(|row| row.columns.iter().map(Cell::from).collect())
            .collect()
    }

    // ===== Tab stop methods =====

    /// Initialize default tab stops (every 8 columns)
    #[allow(dead_code)]
    fn reset_tab_stops(&mut self) {
        self.tab_stops = (0..self.internal_grid.cols)
            .filter(|&c| c % 8 == 0 && c > 0)
            .collect();
    }

    /// Clear all tab stops
    fn clear_all_tab_stops(&mut self) {
        self.tab_stops.clear();
    }

    /// Clear tab stop at current column
    fn clear_tab_stop_at_cursor(&mut self) {
        self.tab_stops
            .retain(|&c| c != self.internal_grid.cursor_col);
    }

    /// Set tab stop at current column
    fn set_tab_stop_at_cursor(&mut self) {
        if !self.tab_stops.contains(&self.internal_grid.cursor_col) {
            self.tab_stops.push(self.internal_grid.cursor_col);
            self.tab_stops.sort();
        }
    }

    /// Move cursor to next tab stop
    fn tab_forward(&mut self) {
        if let Some(&next_tab) = self
            .tab_stops
            .iter()
            .find(|&&c| c > self.internal_grid.cursor_col)
        {
            self.internal_grid.cursor_col = next_tab.min(self.internal_grid.cols - 1);
        } else {
            // No more tab stops, go to end of line
            self.internal_grid.cursor_col = self.internal_grid.cols - 1;
        }
        self.pending_wrap = false;
    }

    /// Move cursor to previous tab stop (CBT)
    fn tab_backward(&mut self, n: usize) {
        for _ in 0..n {
            if let Some(&prev_tab) = self
                .tab_stops
                .iter()
                .rev()
                .find(|&&c| c < self.internal_grid.cursor_col)
            {
                self.internal_grid.cursor_col = prev_tab;
            } else {
                self.internal_grid.cursor_col = 0;
            }
        }
        self.pending_wrap = false;
    }

    /// Save cursor position and attributes (DECSC)
    fn save_cursor(&mut self) {
        self.saved_cursor = Some(SavedCursor {
            row: self.internal_grid.cursor_row,
            col: self.internal_grid.cursor_col,
            styles: self.internal_grid.current_styles,
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
            self.internal_grid.cursor_row =
                saved.row.min(self.internal_grid.rows.saturating_sub(1));
            self.internal_grid.cursor_col =
                saved.col.min(self.internal_grid.cols.saturating_sub(1));
            self.internal_grid.set_current_styles(saved.styles);
            self.origin_mode = saved.origin_mode;
            self.auto_wrap = saved.auto_wrap;
            self.charset_index = saved.charset_index;
            self.g0_charset_line_drawing = saved.g0_charset_line_drawing;
            self.g1_charset_line_drawing = saved.g1_charset_line_drawing;
        }
        self.pending_wrap = false;
    }

    /// Soft Terminal Reset (DECSTR) - CSI ! p
    /// Resets modes to defaults without clearing screen or scrollback
    fn soft_reset(&mut self) {
        // Reset text attributes (SGR)
        self.internal_grid
            .set_current_styles(CharacterStyles::default());

        // Reset insert mode
        self.insert_mode = false;

        // Reset origin mode
        self.origin_mode = false;

        // Reset auto-wrap mode (default is on)
        self.auto_wrap = true;

        // Reset cursor visibility (default is visible)
        self.cursor_visible = true;

        // Reset cursor blink (default is on)
        self.cursor_blink = true;

        // Reset scroll region to full screen
        self.internal_grid.scroll_region = (0, self.internal_grid.rows.saturating_sub(1));

        // Reset saved cursor
        self.saved_cursor = None;

        // Reset pending wrap state
        self.pending_wrap = false;

        // Reset charset to G0 and clear line drawing modes
        self.charset_index = 0;
        self.g0_charset_line_drawing = false;
        self.g1_charset_line_drawing = false;

        // Reset tab stops to default (every 8 columns)
        self.tab_stops = (0..self.internal_grid.cols)
            .filter(|&c| c % 8 == 0 && c > 0)
            .collect();
    }

    /// Resize the terminal
    pub fn resize(&mut self, new_rows: usize, new_cols: usize) {
        self.internal_grid.resize(new_rows, new_cols);
        // Update tab stops for new width
        self.tab_stops.retain(|&c| c < new_cols);
        self.internal_grid.fix_cursor_on_spacer();
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
        self.internal_grid.scroll_up_in_region(1);
    }

    /// Scroll the screen down by one line within the scroll region
    fn scroll_down(&mut self) {
        self.internal_grid.scroll_down_in_region(1);
    }

    /// Move cursor to new line, scrolling if necessary
    fn newline(&mut self) {
        self.internal_grid.newline();
    }

    /// Carriage return - move cursor to beginning of line
    fn carriage_return(&mut self) {
        self.internal_grid.cursor_col = 0;
    }

    /// Put a character at cursor position and advance
    fn put_char(&mut self, c: char) {
        // Handle pending wrap from previous character at edge
        if self.pending_wrap {
            self.pending_wrap = false;
            self.internal_grid.cursor_col = 0;
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

        // Create the terminal character
        let character =
            TerminalCharacter::new(display_char, self.internal_grid.current_shared_styles());
        let char_width = character.width();

        // Handle zero-width characters (combining chars, etc.) - just skip them for now
        if char_width == 0 {
            return;
        }

        // For wide characters, check if we have room for both cells
        if char_width == 2 && self.internal_grid.cursor_col + 1 >= self.internal_grid.cols {
            if self.auto_wrap {
                // Clear the current cell (it would be orphaned) and wrap
                self.internal_grid.set_char(
                    self.internal_grid.cursor_row,
                    self.internal_grid.cursor_col,
                    TerminalCharacter::default(),
                );
                self.internal_grid.cursor_col = 0;
                self.newline();
            } else {
                // Can't fit, don't print
                return;
            }
        }

        let cursor_row = self.internal_grid.cursor_row;
        let cursor_col = self.internal_grid.cursor_col;
        let cols = self.internal_grid.cols;

        // Defensive bounds check
        if cursor_row < self.internal_grid.rows && cursor_col < cols {
            // In insert mode, shift characters right
            if self.insert_mode {
                self.internal_grid.insert_chars(char_width);
            }

            // Handle overwriting wide character spacer
            if let Some(existing) = self.internal_grid.get_char(cursor_row, cursor_col) {
                if existing.wide_spacer && cursor_col > 0 {
                    self.internal_grid.set_char(
                        cursor_row,
                        cursor_col - 1,
                        TerminalCharacter::default(),
                    );
                }
            }

            // Handle overwriting a wide character's first cell with a narrow character
            if char_width == 1 && cursor_col + 1 < cols {
                if let Some(next) = self.internal_grid.get_char(cursor_row, cursor_col + 1) {
                    if next.wide_spacer {
                        self.internal_grid.set_char(
                            cursor_row,
                            cursor_col + 1,
                            TerminalCharacter::default(),
                        );
                    }
                }
            }

            // Place the character
            self.internal_grid
                .set_char(cursor_row, cursor_col, character);

            // For wide characters, place a spacer in the next cell
            if char_width == 2 && cursor_col + 1 < cols {
                // Check if next cell would overwrite another wide char
                if cursor_col + 2 < cols {
                    if let Some(next_next) = self.internal_grid.get_char(cursor_row, cursor_col + 2)
                    {
                        if next_next.wide_spacer {
                            self.internal_grid.set_char(
                                cursor_row,
                                cursor_col + 2,
                                TerminalCharacter::default(),
                            );
                        }
                    }
                }
                self.internal_grid.set_char(
                    cursor_row,
                    cursor_col + 1,
                    TerminalCharacter::wide_spacer(self.internal_grid.current_shared_styles()),
                );
            }

            // Advance cursor
            if cursor_col + char_width >= cols {
                // At the edge - set pending wrap if auto-wrap is enabled
                if self.auto_wrap {
                    self.pending_wrap = true;
                }
                self.internal_grid.cursor_col = cols - 1;
            } else {
                self.internal_grid.cursor_col += char_width;
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
            for _ in 0..n {
                // Temporarily disable line drawing since character is already translated
                let old_g0 = self.g0_charset_line_drawing;
                let old_g1 = self.g1_charset_line_drawing;
                self.g0_charset_line_drawing = false;
                self.g1_charset_line_drawing = false;
                self.put_char(c);
                self.g0_charset_line_drawing = old_g0;
                self.g1_charset_line_drawing = old_g1;
            }
        }
    }

    /// Insert n blank characters at cursor position, shifting existing chars right
    fn insert_chars(&mut self, n: usize) {
        self.internal_grid.insert_chars(n);
    }

    /// Clear from cursor to end of line
    fn clear_to_end_of_line(&mut self) {
        self.internal_grid.clear_to_end_of_line();
    }

    /// Clear from cursor to beginning of line
    fn clear_to_start_of_line(&mut self) {
        self.internal_grid.clear_to_start_of_line();
    }

    /// Clear entire line
    fn clear_line(&mut self) {
        self.internal_grid.clear_line();
    }

    /// Clear from cursor to end of screen
    fn clear_to_end_of_screen(&mut self) {
        self.internal_grid.clear_to_end_of_screen();
    }

    /// Clear from cursor to beginning of screen
    fn clear_to_start_of_screen(&mut self) {
        self.internal_grid.clear_to_start_of_screen();
    }

    /// Clear entire screen
    fn clear_screen(&mut self) {
        self.internal_grid.clear_screen();
    }

    /// Get visible lines for rendering (including scrollback)
    pub fn visible_lines(&self, height: usize, scroll_offset: usize) -> Vec<&Row> {
        self.internal_grid
            .visible_lines(scroll_offset)
            .into_iter()
            .take(height)
            .collect()
    }

    /// Scroll view up (into history)
    pub fn scroll_view_up(&mut self, n: usize) -> usize {
        self.internal_grid.scroll_view_up(n)
    }

    /// Parse SGR (Select Graphic Rendition) parameters
    fn apply_sgr(&mut self, params: &Params) {
        let params: Vec<u16> = params.iter().map(|p| p[0]).collect();

        if params.is_empty() {
            self.internal_grid
                .set_current_styles(CharacterStyles::default());
            return;
        }

        let mut styles = self.internal_grid.current_styles;
        let mut i = 0;
        while i < params.len() {
            match params[i] {
                0 => styles = CharacterStyles::default(),
                1 => styles = styles.add_modifier(Modifier::BOLD),
                2 => styles = styles.add_modifier(Modifier::DIM),
                3 => styles = styles.add_modifier(Modifier::ITALIC),
                4 => styles = styles.add_modifier(Modifier::UNDERLINED),
                5 | 6 => styles = styles.add_modifier(Modifier::SLOW_BLINK),
                7 => styles = styles.add_modifier(Modifier::REVERSED),
                8 => styles = styles.add_modifier(Modifier::HIDDEN),
                9 => styles = styles.add_modifier(Modifier::CROSSED_OUT),
                22 => styles = styles.remove_modifier(Modifier::BOLD | Modifier::DIM),
                23 => styles = styles.remove_modifier(Modifier::ITALIC),
                24 => styles = styles.remove_modifier(Modifier::UNDERLINED),
                25 => styles = styles.remove_modifier(Modifier::SLOW_BLINK),
                27 => styles = styles.remove_modifier(Modifier::REVERSED),
                28 => styles = styles.remove_modifier(Modifier::HIDDEN),
                29 => styles = styles.remove_modifier(Modifier::CROSSED_OUT),
                // Foreground colors
                30 => styles = styles.fg(Color::Black),
                31 => styles = styles.fg(Color::Red),
                32 => styles = styles.fg(Color::Green),
                33 => styles = styles.fg(Color::Yellow),
                34 => styles = styles.fg(Color::Blue),
                35 => styles = styles.fg(Color::Magenta),
                36 => styles = styles.fg(Color::Cyan),
                37 => styles = styles.fg(Color::Gray),
                38 => {
                    // Extended foreground color
                    if i + 2 < params.len() && params[i + 1] == 5 {
                        // 256 color mode
                        styles = styles.fg(Color::Indexed(params[i + 2] as u8));
                        i += 2;
                    } else if i + 4 < params.len() && params[i + 1] == 2 {
                        // RGB color mode
                        styles = styles.fg(Color::Rgb(
                            params[i + 2] as u8,
                            params[i + 3] as u8,
                            params[i + 4] as u8,
                        ));
                        i += 4;
                    }
                }
                39 => styles.foreground = None,
                // Background colors
                40 => styles = styles.bg(Color::Black),
                41 => styles = styles.bg(Color::Red),
                42 => styles = styles.bg(Color::Green),
                43 => styles = styles.bg(Color::Yellow),
                44 => styles = styles.bg(Color::Blue),
                45 => styles = styles.bg(Color::Magenta),
                46 => styles = styles.bg(Color::Cyan),
                47 => styles = styles.bg(Color::Gray),
                48 => {
                    // Extended background color
                    if i + 2 < params.len() && params[i + 1] == 5 {
                        // 256 color mode
                        styles = styles.bg(Color::Indexed(params[i + 2] as u8));
                        i += 2;
                    } else if i + 4 < params.len() && params[i + 1] == 2 {
                        // RGB color mode
                        styles = styles.bg(Color::Rgb(
                            params[i + 2] as u8,
                            params[i + 3] as u8,
                            params[i + 4] as u8,
                        ));
                        i += 4;
                    }
                }
                49 => styles.background = None,
                // Bright foreground colors
                90 => styles = styles.fg(Color::DarkGray),
                91 => styles = styles.fg(Color::LightRed),
                92 => styles = styles.fg(Color::LightGreen),
                93 => styles = styles.fg(Color::LightYellow),
                94 => styles = styles.fg(Color::LightBlue),
                95 => styles = styles.fg(Color::LightMagenta),
                96 => styles = styles.fg(Color::LightCyan),
                97 => styles = styles.fg(Color::White),
                // Bright background colors
                100 => styles = styles.bg(Color::DarkGray),
                101 => styles = styles.bg(Color::LightRed),
                102 => styles = styles.bg(Color::LightGreen),
                103 => styles = styles.bg(Color::LightYellow),
                104 => styles = styles.bg(Color::LightBlue),
                105 => styles = styles.bg(Color::LightMagenta),
                106 => styles = styles.bg(Color::LightCyan),
                107 => styles = styles.bg(Color::White),
                _ => {}
            }
            i += 1;
        }
        self.internal_grid.set_current_styles(styles);
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
                self.internal_grid.cursor_col = self.internal_grid.cursor_col.saturating_sub(1);
                self.pending_wrap = false;
            }
            // Tab
            0x09 => {
                self.tab_forward();
            }
            // Line feed, vertical tab, form feed
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
        if params.is_empty() {
            return;
        }

        let cmd = params[0];
        if let Ok(cmd_str) = std::str::from_utf8(cmd) {
            match cmd_str {
                // Window title (OSC 0 and OSC 2)
                "0" | "2" => {
                    if params.len() > 1 {
                        if let Ok(title) = std::str::from_utf8(params[1]) {
                            self.title = Some(title.to_string());
                        }
                    }
                }
                // OSC 10 - Query/Set default foreground color
                "10" => {
                    if params.len() > 1 {
                        if let Ok(color_str) = std::str::from_utf8(params[1]) {
                            if color_str == "?" {
                                // Query - respond with current foreground color (default to white if not set)
                                let (r, g, b) = self.default_fg_color.unwrap_or((255, 255, 255));
                                let response = format!(
                                    "\x1b]10;rgb:{:04x}/{:04x}/{:04x}\x1b\\",
                                    (r as u16) * 257,
                                    (g as u16) * 257,
                                    (b as u16) * 257
                                );
                                self.pending_responses.push(response.into_bytes());
                            } else if let Some(color) = parse_osc_color(color_str) {
                                // Set foreground color
                                self.default_fg_color = Some(color);
                            }
                        }
                    }
                }
                // OSC 11 - Query/Set default background color
                "11" => {
                    if params.len() > 1 {
                        if let Ok(color_str) = std::str::from_utf8(params[1]) {
                            if color_str == "?" {
                                // Query - respond with current background color (default to black if not set)
                                let (r, g, b) = self.default_bg_color.unwrap_or((0, 0, 0));
                                let response = format!(
                                    "\x1b]11;rgb:{:04x}/{:04x}/{:04x}\x1b\\",
                                    (r as u16) * 257,
                                    (g as u16) * 257,
                                    (b as u16) * 257
                                );
                                self.pending_responses.push(response.into_bytes());
                            } else if let Some(color) = parse_osc_color(color_str) {
                                // Set background color
                                self.default_bg_color = Some(color);
                            }
                        }
                    }
                }
                // OSC 110 - Reset default foreground color to terminal default
                "110" => {
                    self.default_fg_color = None;
                }
                // OSC 111 - Reset default background color to terminal default
                "111" => {
                    self.default_bg_color = None;
                }
                _ => {}
            }
        }
    }

    fn csi_dispatch(&mut self, params: &Params, intermediates: &[u8], _ignore: bool, action: char) {
        let params_vec: Vec<u16> = params.iter().map(|p| p[0]).collect();

        match action {
            // Cursor Up
            'A' => {
                let n = params_vec.first().copied().unwrap_or(1).max(1) as usize;
                self.internal_grid.cursor_row = self.internal_grid.cursor_row.saturating_sub(n);
            }
            // Cursor Down
            'B' => {
                let n = params_vec.first().copied().unwrap_or(1).max(1) as usize;
                self.internal_grid.cursor_row =
                    (self.internal_grid.cursor_row + n).min(self.internal_grid.rows - 1);
            }
            // Cursor Forward
            'C' => {
                let n = params_vec.first().copied().unwrap_or(1).max(1) as usize;
                self.internal_grid.cursor_col =
                    (self.internal_grid.cursor_col + n).min(self.internal_grid.cols - 1);
            }
            // Cursor Back
            'D' => {
                let n = params_vec.first().copied().unwrap_or(1).max(1) as usize;
                self.internal_grid.cursor_col = self.internal_grid.cursor_col.saturating_sub(n);
            }
            // Cursor Next Line
            'E' => {
                let n = params_vec.first().copied().unwrap_or(1).max(1) as usize;
                self.internal_grid.cursor_row =
                    (self.internal_grid.cursor_row + n).min(self.internal_grid.rows - 1);
                self.internal_grid.cursor_col = 0;
            }
            // Cursor Previous Line
            'F' => {
                let n = params_vec.first().copied().unwrap_or(1).max(1) as usize;
                self.internal_grid.cursor_row = self.internal_grid.cursor_row.saturating_sub(n);
                self.internal_grid.cursor_col = 0;
            }
            // Cursor Horizontal Absolute
            'G' => {
                let col = params_vec.first().copied().unwrap_or(1).max(1) as usize;
                self.internal_grid.cursor_col = (col - 1).min(self.internal_grid.cols - 1);
            }
            // Cursor Position
            'H' | 'f' => {
                let row = params_vec.first().copied().unwrap_or(1).max(1) as usize;
                let col = params_vec.get(1).copied().unwrap_or(1).max(1) as usize;
                self.internal_grid.cursor_row = (row - 1).min(self.internal_grid.rows - 1);
                self.internal_grid.cursor_col = (col - 1).min(self.internal_grid.cols - 1);
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
            // Insert Lines (IL) - insert blank lines at cursor, shift lines down
            'L' => {
                let n = params_vec.first().copied().unwrap_or(1).max(1) as usize;
                self.internal_grid.insert_lines_at_cursor(n);
            }
            // Delete Lines (DL) - delete lines at cursor, shift lines up
            'M' => {
                let n = params_vec.first().copied().unwrap_or(1).max(1) as usize;
                self.internal_grid.delete_lines_at_cursor(n);
            }
            // Delete Characters
            'P' => {
                let n = params_vec.first().copied().unwrap_or(1).max(1) as usize;
                self.internal_grid.delete_chars(n);
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
                self.internal_grid.erase_chars(n);
            }
            // Cursor Horizontal Absolute
            '`' => {
                let col = params_vec.first().copied().unwrap_or(1).max(1) as usize;
                self.internal_grid.cursor_col = (col - 1).min(self.internal_grid.cols - 1);
            }
            // Vertical Position Absolute
            'd' => {
                let row = params_vec.first().copied().unwrap_or(1).max(1) as usize;
                self.internal_grid.cursor_row = (row - 1).min(self.internal_grid.rows - 1);
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
                        // Cursor Position Report (CPR)
                        let response = format!(
                            "\x1b[{};{}R",
                            self.internal_grid.cursor_row + 1,
                            self.internal_grid.cursor_col + 1
                        );
                        self.pending_responses.push(response.into_bytes());
                    }
                    _ => {}
                }
            }
            // Device Attributes (DA1 and DA2)
            'c' => {
                if intermediates.is_empty() {
                    // Primary Device Attributes (DA1): CSI c or CSI 0 c
                    // Respond as VT220 with various capabilities:
                    // 62 = VT220, 1 = 132 columns, 2 = printer, 4 = sixel graphics
                    self.pending_responses.push(b"\x1b[?62;1;2;4c".to_vec());
                } else if intermediates == [b'>'] {
                    // Secondary Device Attributes (DA2): CSI > c
                    // Respond as screen/tmux-like terminal:
                    // 41 = terminal type (screen), 0 = version, 0 = ROM
                    self.pending_responses.push(b"\x1b[>41;0;0c".to_vec());
                }
            }
            // Set scroll region
            'r' => {
                let top = params_vec.first().copied().unwrap_or(1).max(1) as usize - 1;
                let bottom = params_vec
                    .get(1)
                    .copied()
                    .unwrap_or(self.internal_grid.rows as u16)
                    .max(1) as usize
                    - 1;
                if top < self.internal_grid.rows
                    && bottom < self.internal_grid.rows
                    && top <= bottom
                {
                    self.internal_grid.scroll_region = (top, bottom);
                }
                self.internal_grid.cursor_row = 0;
                self.internal_grid.cursor_col = 0;
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
            // Soft Terminal Reset (DECSTR) - CSI ! p
            'p' if intermediates == [b'!'] => {
                self.soft_reset();
            }
            // Private modes (DECSET/DECRST) and standard modes (SM/RM)
            'h' | 'l' => {
                let enable = action == 'h';
                if intermediates == [b'?'] {
                    // Private (DEC) modes
                    for &param in &params_vec {
                        match param {
                            1 => {
                                // DECCKM - Cursor Keys Mode
                                self.application_cursor_keys = enable;
                            }
                            6 => {
                                // DECOM - Origin Mode
                                self.origin_mode = enable;
                                self.internal_grid.cursor_row = 0;
                                self.internal_grid.cursor_col = 0;
                            }
                            7 => {
                                // DECAWM - Auto-wrap Mode
                                self.auto_wrap = enable;
                            }
                            12 => {
                                // Cursor blink mode
                                // h = enable blink, l = disable blink (steady cursor)
                                self.cursor_blink = enable;
                            }
                            25 => {
                                // DECTCEM - Cursor visibility
                                self.cursor_visible = enable;
                            }
                            1049 => {
                                // Alternate screen buffer (save cursor + switch)
                                // Per xterm, mode 1049 combines 1047 (alt screen) + 1048 (save/restore cursor)
                                if enable {
                                    // Only enter if not already in alternate screen
                                    // (prevents losing main screen if app sends 1049h twice)
                                    if self.alternate_screen.is_none() {
                                        self.alternate_screen = Some(Box::new(AlternateScreen {
                                            grid: self.internal_grid.clone(),
                                            cursor_row: self.internal_grid.cursor_row,
                                            cursor_col: self.internal_grid.cursor_col,
                                            current_styles: self.internal_grid.current_styles,
                                            // Save terminal modes that affect cursor positioning
                                            origin_mode: self.origin_mode,
                                            auto_wrap: self.auto_wrap,
                                            pending_wrap: self.pending_wrap,
                                            // Save cursor visibility (per-screen state)
                                            cursor_visible: self.cursor_visible,
                                            cursor_blink: self.cursor_blink,
                                            // Save charset state
                                            charset_index: self.charset_index,
                                            g0_charset_line_drawing: self.g0_charset_line_drawing,
                                            g1_charset_line_drawing: self.g1_charset_line_drawing,
                                        }));
                                        // Clear any saved cursor from before alt screen - it's now stale
                                        self.saved_cursor = None;
                                        let rows = self.internal_grid.rows;
                                        let cols = self.internal_grid.cols;
                                        self.internal_grid = Grid::new(rows, cols);
                                        self.alt_screen_toggled = true;
                                    }
                                } else if let Some(saved) = self.alternate_screen.take() {
                                    // Resize saved grid to current dimensions if needed
                                    let mut restored = saved.grid;
                                    restored
                                        .resize(self.internal_grid.rows, self.internal_grid.cols);
                                    self.internal_grid = restored;
                                    // Mark all lines as changed to force full redraw
                                    // (resize only marks changed if dimensions actually change)
                                    self.internal_grid.mark_all_changed();
                                    self.internal_grid.cursor_row = saved
                                        .cursor_row
                                        .min(self.internal_grid.rows.saturating_sub(1));
                                    self.internal_grid.cursor_col = saved
                                        .cursor_col
                                        .min(self.internal_grid.cols.saturating_sub(1));
                                    self.internal_grid.set_current_styles(saved.current_styles);
                                    // Restore terminal modes
                                    self.origin_mode = saved.origin_mode;
                                    self.auto_wrap = saved.auto_wrap;
                                    self.pending_wrap = saved.pending_wrap;
                                    // Restore cursor visibility
                                    self.cursor_visible = saved.cursor_visible;
                                    self.cursor_blink = saved.cursor_blink;
                                    // Restore charset state
                                    self.charset_index = saved.charset_index;
                                    self.g0_charset_line_drawing = saved.g0_charset_line_drawing;
                                    self.g1_charset_line_drawing = saved.g1_charset_line_drawing;
                                    // Clear saved_cursor instead of restoring stale state
                                    // When a TUI exits, any cursor position it saved before entering
                                    // alt screen is no longer relevant. If we restore it, subsequent
                                    // commands that call RESTORE_CURSOR (like codex) would jump to
                                    // that stale position.
                                    self.saved_cursor = None;
                                    self.alt_screen_toggled = true;
                                }
                            }
                            47 | 1047 => {
                                // Alternate screen buffer (without save cursor)
                                // Per xterm, mode 47/1047 switches screen but doesn't save/restore cursor
                                if enable {
                                    // Only enter if not already in alternate screen
                                    if self.alternate_screen.is_none() {
                                        self.alternate_screen = Some(Box::new(AlternateScreen {
                                            grid: self.internal_grid.clone(),
                                            cursor_row: self.internal_grid.cursor_row,
                                            cursor_col: self.internal_grid.cursor_col,
                                            current_styles: self.internal_grid.current_styles,
                                            // Save terminal modes (struct fields required)
                                            origin_mode: self.origin_mode,
                                            auto_wrap: self.auto_wrap,
                                            pending_wrap: self.pending_wrap,
                                            cursor_visible: self.cursor_visible,
                                            cursor_blink: self.cursor_blink,
                                            charset_index: self.charset_index,
                                            g0_charset_line_drawing: self.g0_charset_line_drawing,
                                            g1_charset_line_drawing: self.g1_charset_line_drawing,
                                        }));
                                        // Clear any saved cursor from before alt screen - it's now stale
                                        self.saved_cursor = None;
                                        let rows = self.internal_grid.rows;
                                        let cols = self.internal_grid.cols;
                                        self.internal_grid = Grid::new(rows, cols);
                                        self.alt_screen_toggled = true;
                                    }
                                } else if let Some(saved) = self.alternate_screen.take() {
                                    let mut restored = saved.grid;
                                    restored
                                        .resize(self.internal_grid.rows, self.internal_grid.cols);
                                    self.internal_grid = restored;
                                    // Mark all lines as changed to force full redraw
                                    // (resize only marks changed if dimensions actually change)
                                    self.internal_grid.mark_all_changed();
                                    // Note: modes 47/1047 don't restore cursor position or terminal modes
                                    // Only the grid content is restored
                                    // But we do restore cursor visibility
                                    self.cursor_visible = saved.cursor_visible;
                                    self.cursor_blink = saved.cursor_blink;
                                    // Clear saved_cursor instead of restoring stale state
                                    self.saved_cursor = None;
                                    self.alt_screen_toggled = true;
                                }
                            }
                            2004 => {
                                // Bracketed paste mode
                                self.bracketed_paste = enable;
                            }
                            // Mouse tracking modes
                            1000 | 1002 | 1003 => {
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
                        if param == 4 {
                            // IRM - Insert/Replace Mode
                            self.insert_mode = enable;
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
                let rows = self.internal_grid.rows;
                let cols = self.internal_grid.cols;
                *self = VirtualTerminal::new(rows, cols);
            }
            // Index - move down one line, scroll if at bottom
            ([], b'D') => {
                self.newline();
            }
            // Next Line
            ([], b'E') => {
                self.newline();
                self.internal_grid.cursor_col = 0;
            }
            // Horizontal Tab Set (HTS)
            ([], b'H') => {
                self.set_tab_stop_at_cursor();
            }
            // Reverse Index - move up one line, scroll if at top
            ([], b'M') => {
                if self.internal_grid.cursor_row == self.internal_grid.scroll_region.0 {
                    self.scroll_down();
                } else {
                    self.internal_grid.cursor_row = self.internal_grid.cursor_row.saturating_sub(1);
                }
            }
            // G0 charset designations
            ([b'('], b'0') => {
                self.g0_charset_line_drawing = true;
            }
            ([b'('], b'B') => {
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

/// Legacy accessor for test compatibility that provides grid[row][col] syntax
#[cfg(test)]
pub struct LegacyGridAccessor<'a> {
    term: &'a VirtualTerminal,
}

#[cfg(test)]
impl<'a> std::ops::Index<usize> for LegacyGridAccessor<'a> {
    type Output = LegacyRowAccessor<'a>;

    fn index(&self, row: usize) -> &Self::Output {
        // Leak a reference to enable the double-index syntax
        // This is only used in tests so the leak is acceptable
        let accessor = Box::new(LegacyRowAccessor {
            term: self.term,
            row,
        });
        Box::leak(accessor)
    }
}

#[cfg(test)]
pub struct LegacyRowAccessor<'a> {
    term: &'a VirtualTerminal,
    row: usize,
}

#[cfg(test)]
impl<'a> std::ops::Index<usize> for LegacyRowAccessor<'a> {
    type Output = Cell;

    fn index(&self, col: usize) -> &Self::Output {
        // Leak a Cell to return a reference
        // This is only used in tests so the leak is acceptable
        let cell = Box::new(self.term.get_cell(self.row, col));
        Box::leak(cell)
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
    pub cursor_blink: bool,
    pub has_content: bool,
    pub changed_lines: Arc<[usize]>,
    pub is_alt_screen: bool,
}

struct RenderCache {
    height: usize,
    scroll_offset: usize,
    generation: u64,
    lines: Arc<[ratatui::text::Line<'static>]>,
    cursor: Option<(u16, u16)>,
    cursor_visible: bool,
    cursor_blink: bool,
    has_content: bool,
    changed_lines: Arc<[usize]>,
    is_alt_screen: bool,
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
            cursor_blink: self.cursor_blink,
            has_content: self.has_content,
            changed_lines: self.changed_lines.clone(),
            is_alt_screen: self.is_alt_screen,
        }
    }
}

/// Terminal output buffer for rendering - now using VirtualTerminal
pub struct TerminalBuffer {
    pub terminal: VirtualTerminal,
    parser: Parser,
    render_cache: Option<RenderCache>,
    generation: u64,
    scroll_offset: usize,
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
            scroll_offset: 0,
        }
    }

    pub fn with_size(rows: usize, cols: usize) -> Self {
        Self {
            terminal: VirtualTerminal::new(rows, cols),
            parser: Parser::new(),
            render_cache: None,
            generation: 0,
            scroll_offset: 0,
        }
    }

    fn mark_dirty(&mut self) {
        self.render_cache = None;
        self.generation = self.generation.wrapping_add(1);
    }

    /// Process raw terminal data
    pub fn process(&mut self, data: &[u8]) {
        self.parser.advance(&mut self.terminal, data);
        // Reset scroll position when alternate screen is entered/exited
        if self.terminal.alt_screen_toggled {
            self.terminal.alt_screen_toggled = false;
            self.scroll_offset = 0;
        }
        self.mark_dirty();
    }

    /// Resize the terminal
    pub fn resize(&mut self, rows: usize, cols: usize) {
        self.terminal.resize(rows, cols);
        self.mark_dirty();
    }

    /// Scroll view up
    pub fn scroll_up(&mut self, n: usize) {
        let max_scroll = self.terminal.scrollback_len();
        self.scroll_offset = (self.scroll_offset + n).min(max_scroll);
        self.mark_dirty();
    }

    /// Scroll view down
    pub fn scroll_down(&mut self, n: usize) {
        self.scroll_offset = self.scroll_offset.saturating_sub(n);
        self.mark_dirty();
    }

    /// Scroll to bottom
    pub fn scroll_to_bottom(&mut self) {
        self.scroll_offset = 0;
        self.mark_dirty();
    }

    /// Get current scroll offset (0 = bottom)
    pub fn scroll_offset(&self) -> usize {
        self.scroll_offset
    }

    /// Clear the terminal
    pub fn clear(&mut self) {
        let rows = self.terminal.rows();
        let cols = self.terminal.cols();
        self.terminal = VirtualTerminal::new(rows, cols);
        self.parser = Parser::new();
        self.scroll_offset = 0;
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

        if self.terminal.scrollback_len() > 0 {
            return true;
        }

        let default_styles = CharacterStyles::default();
        for row in self.terminal.internal_grid.viewport_iter() {
            for cell in row.iter() {
                if cell.character != ' ' || cell.styles.get() != &default_styles {
                    return true;
                }
            }
        }
        false
    }

    /// Get cursor position (row, col) - returns None if scrolled away from bottom
    pub fn cursor_position(&self) -> Option<(u16, u16)> {
        if self.scroll_offset == 0 && self.terminal.cursor_visible {
            Some((
                self.terminal.cursor_row() as u16,
                self.terminal.cursor_col() as u16,
            ))
        } else {
            None
        }
    }

    /// Check if cursor is visible
    pub fn cursor_visible(&self) -> bool {
        self.terminal.cursor_visible && self.scroll_offset == 0
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
        self.terminal.rows()
    }

    /// Try to extract a URL at the given row and column (0-indexed).
    pub fn url_at_position(&self, row: usize, col: usize) -> Option<String> {
        if self.scroll_offset != 0 {
            return None;
        }

        if row >= self.terminal.internal_grid.viewport.len() {
            return None;
        }

        let line = &self.terminal.internal_grid.viewport[row];
        if col >= line.len() {
            return None;
        }

        let line_text = line.as_string();
        let line_text = line_text.trim_end();

        if let Some(url) = find_url_at_column(line_text, col) {
            // Check for multi-line URL continuation
            let cols = self.terminal.cols();
            if line_text.len() >= cols.saturating_sub(1) && !url.is_empty() {
                let mut full_url = url.clone();
                let mut next_row = row + 1;

                while next_row < self.terminal.internal_grid.viewport.len() {
                    let next_line = self.terminal.internal_grid.viewport[next_row].as_string();
                    let next_line = next_line.trim_end();

                    let continuation: String =
                        next_line.chars().take_while(|&c| is_url_char(c)).collect();

                    if continuation.is_empty() {
                        break;
                    }

                    full_url.push_str(&continuation);

                    if next_line.len() < cols.saturating_sub(1) {
                        break;
                    }
                    next_row += 1;
                }

                return Some(full_url);
            }
            return Some(url);
        }

        None
    }

    /// Build a cached render view for the given height.
    pub fn render_view(&mut self, height: usize) -> TerminalRenderView {
        if let Some(cache) = &self.render_cache {
            if cache.is_valid(height, self.generation, self.scroll_offset) {
                return cache.as_view();
            }
        }

        let visible_rows = self.terminal.visible_lines(height, self.scroll_offset);
        let mut lines: Vec<ratatui::text::Line<'static>> = Vec::with_capacity(visible_rows.len());
        let mut has_content = self.terminal.scrollback_len() > 0;
        let default_styles = CharacterStyles::default();

        // Get default colors from terminal (OSC 10/11) - None means use terminal's native color
        let default_fg = self
            .terminal
            .default_fg_color
            .map(|(r, g, b)| Color::Rgb(r, g, b));
        let default_bg = self
            .terminal
            .default_bg_color
            .map(|(r, g, b)| Color::Rgb(r, g, b));

        for row in visible_rows {
            if !has_content {
                for cell in row.iter() {
                    if cell.character != ' ' || cell.styles.get() != &default_styles {
                        has_content = true;
                        break;
                    }
                }
            }
            lines.push(row.to_ratatui_line_with_defaults(default_fg, default_bg));
        }

        let cursor = self.cursor_position();
        let cursor_visible = self.cursor_visible();
        let cursor_blink = self.terminal.cursor_blink;
        let is_alt_screen = self.terminal.alternate_screen.is_some();
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
            scroll_offset: self.scroll_offset,
            generation: self.generation,
            lines: lines.clone(),
            cursor,
            cursor_visible,
            cursor_blink,
            has_content,
            changed_lines: changed_lines.clone(),
            is_alt_screen,
        };
        self.render_cache = Some(cache);

        TerminalRenderView {
            lines,
            cursor,
            cursor_visible,
            cursor_blink,
            has_content,
            changed_lines,
            is_alt_screen,
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
                                    pane_id,
                                } => {
                                    let _ = event_tx_clone.send(MuxEvent::Notification {
                                        message,
                                        level,
                                        sandbox_id,
                                        tab_id,
                                        pane_id,
                                    });
                                }
                                MuxServerMessage::GhRequest {
                                    request_id,
                                    args,
                                    stdin,
                                    ..
                                } => {
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
        let grid = term.legacy_grid();
        assert_eq!(grid[0][0].c, 'H');
        assert_eq!(grid[0][6].c, ' ');
        assert_eq!(grid[0][7].c, 'W');
    }

    #[test]
    fn virtual_terminal_handles_newline() {
        let mut term = VirtualTerminal::new(24, 80);
        term.process(b"Line 1\nLine 2");
        let grid = term.legacy_grid();
        assert_eq!(grid[0][0].c, 'L');
        assert_eq!(grid[1][0].c, 'L');
    }

    #[test]
    fn virtual_terminal_handles_cursor_movement() {
        let mut term = VirtualTerminal::new(24, 80);
        term.process(b"Hello\x1b[2;1HWorld"); // Move to row 2, col 1
        let grid = term.legacy_grid();
        assert_eq!(grid[0][0].c, 'H');
        assert_eq!(grid[1][0].c, 'W');
    }

    #[test]
    fn virtual_terminal_handles_colors() {
        let mut term = VirtualTerminal::new(24, 80);
        term.process(b"\x1b[31mRed\x1b[0m");
        let grid = term.legacy_grid();
        assert_eq!(grid[0][0].c, 'R');
        assert_eq!(grid[0][0].style.fg, Some(Color::Red));
        assert_eq!(grid[0][2].style.fg, Some(Color::Red));
    }

    #[test]
    fn ignores_private_intermediate_sgr() {
        let mut term = VirtualTerminal::new(2, 10);
        term.process(b"\x1b[>4;1mHi");
        let grid = term.legacy_grid();
        assert_eq!(grid[0][0].style, Style::default());
        assert_eq!(grid[0][1].style, Style::default());
    }

    #[test]
    fn virtual_terminal_handles_clear_screen() {
        let mut term = VirtualTerminal::new(24, 80);
        term.process(b"Hello");
        term.process(b"\x1b[2J"); // Clear screen
        let grid = term.legacy_grid();
        assert_eq!(grid[0][0].c, ' ');
    }

    #[test]
    fn virtual_terminal_scrolls() {
        let mut term = VirtualTerminal::new(3, 80);
        term.process(b"Line 1\nLine 2\nLine 3\nLine 4");
        // Line 1 should have scrolled into scrollback
        let scrollback = term.scrollback_snapshot();
        assert_eq!(scrollback.len(), 1);
        assert_eq!(scrollback[0][0].c, 'L');
    }

    #[test]
    fn virtual_terminal_responds_to_dsr_cursor_position() {
        let mut term = VirtualTerminal::new(24, 80);
        // Move cursor to row 5, col 10 (1-indexed in escape sequence)
        term.process(b"\x1b[5;10H");
        assert_eq!(term.cursor_row(), 4); // 0-indexed
        assert_eq!(term.cursor_col(), 9); // 0-indexed

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

    #[test]
    fn virtual_terminal_responds_to_da1() {
        let mut term = VirtualTerminal::new(24, 80);
        // Send Primary Device Attributes request (CSI c)
        term.process(b"\x1b[c");

        let responses = term.drain_responses();
        assert_eq!(responses.len(), 1);
        // Should respond as VT220 with capabilities
        assert_eq!(responses[0], b"\x1b[?62;1;2;4c");
    }

    #[test]
    fn virtual_terminal_responds_to_da1_with_zero() {
        let mut term = VirtualTerminal::new(24, 80);
        // Send Primary Device Attributes request with explicit 0 (CSI 0 c)
        term.process(b"\x1b[0c");

        let responses = term.drain_responses();
        assert_eq!(responses.len(), 1);
        assert_eq!(responses[0], b"\x1b[?62;1;2;4c");
    }

    #[test]
    fn virtual_terminal_responds_to_da2() {
        let mut term = VirtualTerminal::new(24, 80);
        // Send Secondary Device Attributes request (CSI > c)
        term.process(b"\x1b[>c");

        let responses = term.drain_responses();
        assert_eq!(responses.len(), 1);
        // Should respond as screen-like terminal
        assert_eq!(responses[0], b"\x1b[>41;0;0c");
    }

    #[test]
    fn virtual_terminal_cursor_blink_default_enabled() {
        let term = VirtualTerminal::new(24, 80);
        // Cursor blink should be enabled by default
        assert!(term.cursor_blink);
    }

    #[test]
    fn virtual_terminal_cursor_blink_disable() {
        let mut term = VirtualTerminal::new(24, 80);
        assert!(term.cursor_blink);

        // Disable cursor blink (CSI ? 12 l)
        term.process(b"\x1b[?12l");
        assert!(!term.cursor_blink);
    }

    #[test]
    fn virtual_terminal_cursor_blink_enable() {
        let mut term = VirtualTerminal::new(24, 80);

        // First disable
        term.process(b"\x1b[?12l");
        assert!(!term.cursor_blink);

        // Then re-enable (CSI ? 12 h)
        term.process(b"\x1b[?12h");
        assert!(term.cursor_blink);
    }

    #[test]
    fn virtual_terminal_soft_reset_preserves_screen() {
        let mut term = VirtualTerminal::new(24, 80);

        // Write some content
        term.process(b"Hello, World!");

        // Apply some styling
        term.process(b"\x1b[31m"); // Red foreground
        term.process(b"\x1b[?25l"); // Hide cursor
        term.process(b"\x1b[?12l"); // Disable cursor blink
        term.process(b"\x1b[4h"); // Enable insert mode

        // Verify state changed
        assert!(!term.cursor_visible);
        assert!(!term.cursor_blink);
        assert!(term.insert_mode);

        // Perform soft reset (CSI ! p)
        term.process(b"\x1b[!p");

        // Screen content should be preserved
        let grid = term.legacy_grid();
        assert_eq!(grid[0][0].c, 'H');
        assert_eq!(grid[0][6].c, ' ');
        assert_eq!(grid[0][7].c, 'W');

        // Modes should be reset to defaults
        assert!(term.cursor_visible);
        assert!(term.cursor_blink);
        assert!(!term.insert_mode);
        assert!(term.auto_wrap);
        assert!(!term.origin_mode);
    }

    #[test]
    fn virtual_terminal_soft_reset_resets_sgr() {
        let mut term = VirtualTerminal::new(24, 80);

        // Apply styling
        term.process(b"\x1b[1;31;44m"); // Bold, red fg, blue bg

        // Verify style is applied
        let styles = term.internal_grid.current_styles;
        assert!(styles.modifiers.contains(Modifier::BOLD));
        assert_eq!(styles.foreground, Some(Color::Red));
        assert_eq!(styles.background, Some(Color::Blue));

        // Perform soft reset
        term.process(b"\x1b[!p");

        // SGR should be reset
        let styles = term.internal_grid.current_styles;
        assert!(!styles.modifiers.contains(Modifier::BOLD));
        assert_eq!(styles.foreground, None);
        assert_eq!(styles.background, None);
    }

    #[test]
    fn virtual_terminal_soft_reset_resets_scroll_region() {
        let mut term = VirtualTerminal::new(24, 80);

        // Set custom scroll region
        term.process(b"\x1b[5;20r");
        assert_eq!(term.internal_grid.scroll_region, (4, 19)); // 0-indexed

        // Perform soft reset
        term.process(b"\x1b[!p");

        // Scroll region should be reset to full screen
        assert_eq!(term.internal_grid.scroll_region, (0, 23));
    }

    #[test]
    fn virtual_terminal_soft_reset_resets_charset() {
        let mut term = VirtualTerminal::new(24, 80);

        // Enable line drawing charset for G0
        term.process(b"\x1b(0");
        assert!(term.g0_charset_line_drawing);

        // Switch to G1
        term.process(b"\x0e"); // SO - Shift Out
        assert_eq!(term.charset_index, 1);

        // Perform soft reset
        term.process(b"\x1b[!p");

        // Charset should be reset
        assert_eq!(term.charset_index, 0);
        assert!(!term.g0_charset_line_drawing);
        assert!(!term.g1_charset_line_drawing);
    }

    #[test]
    fn virtual_terminal_osc10_query_foreground() {
        let mut term = VirtualTerminal::new(24, 80);

        // Default foreground is None (use terminal's native color)
        assert_eq!(term.default_fg_color, None);

        // Query foreground color (OSC 10 ; ? ST) - returns assumed white if not set
        term.process(b"\x1b]10;?\x1b\\");

        let responses = term.drain_responses();
        assert_eq!(responses.len(), 1);
        // 255 * 257 = 65535 = 0xffff
        assert_eq!(
            String::from_utf8_lossy(&responses[0]),
            "\x1b]10;rgb:ffff/ffff/ffff\x1b\\"
        );
    }

    #[test]
    fn virtual_terminal_osc11_query_background() {
        let mut term = VirtualTerminal::new(24, 80);

        // Default background is None (use terminal's native color)
        assert_eq!(term.default_bg_color, None);

        // Query background color (OSC 11 ; ? ST) - returns assumed black if not set
        term.process(b"\x1b]11;?\x1b\\");

        let responses = term.drain_responses();
        assert_eq!(responses.len(), 1);
        assert_eq!(
            String::from_utf8_lossy(&responses[0]),
            "\x1b]11;rgb:0000/0000/0000\x1b\\"
        );
    }

    #[test]
    fn virtual_terminal_osc10_set_foreground_hex() {
        let mut term = VirtualTerminal::new(24, 80);

        // Set foreground to red (#ff0000)
        term.process(b"\x1b]10;#ff0000\x1b\\");
        assert_eq!(term.default_fg_color, Some((255, 0, 0)));

        // Set foreground using 3-digit hex (#0f0 = green)
        term.process(b"\x1b]10;#0f0\x1b\\");
        assert_eq!(term.default_fg_color, Some((0, 255, 0)));
    }

    #[test]
    fn virtual_terminal_osc10_set_foreground_rgb() {
        let mut term = VirtualTerminal::new(24, 80);

        // Set foreground using X11 rgb format (8-bit)
        term.process(b"\x1b]10;rgb:80/40/c0\x1b\\");
        assert_eq!(term.default_fg_color, Some((0x80, 0x40, 0xc0)));

        // Set foreground using X11 rgb format (16-bit)
        term.process(b"\x1b]10;rgb:ffff/8080/0000\x1b\\");
        assert_eq!(term.default_fg_color, Some((255, 128, 0)));
    }

    #[test]
    fn virtual_terminal_osc11_set_background() {
        let mut term = VirtualTerminal::new(24, 80);

        // Set background to blue (#0000ff)
        term.process(b"\x1b]11;#0000ff\x1b\\");
        assert_eq!(term.default_bg_color, Some((0, 0, 255)));

        // Query to verify it responds with the new color
        term.process(b"\x1b]11;?\x1b\\");
        let responses = term.drain_responses();
        assert_eq!(responses.len(), 1);
        // 255 * 257 = 65535 = 0xffff
        assert_eq!(
            String::from_utf8_lossy(&responses[0]),
            "\x1b]11;rgb:0000/0000/ffff\x1b\\"
        );
    }

    #[test]
    fn virtual_terminal_osc110_reset_foreground() {
        let mut term = VirtualTerminal::new(24, 80);

        // Set foreground to red
        term.process(b"\x1b]10;#ff0000\x1b\\");
        assert_eq!(term.default_fg_color, Some((255, 0, 0)));

        // Reset foreground (OSC 110)
        term.process(b"\x1b]110\x1b\\");
        assert_eq!(term.default_fg_color, None);
    }

    #[test]
    fn virtual_terminal_osc111_reset_background() {
        let mut term = VirtualTerminal::new(24, 80);

        // Set background to blue
        term.process(b"\x1b]11;#0000ff\x1b\\");
        assert_eq!(term.default_bg_color, Some((0, 0, 255)));

        // Reset background (OSC 111)
        term.process(b"\x1b]111\x1b\\");
        assert_eq!(term.default_bg_color, None);
    }

    #[test]
    fn parse_osc_color_formats() {
        use super::parse_osc_color;

        // Hex formats
        assert_eq!(parse_osc_color("#ff0000"), Some((255, 0, 0)));
        assert_eq!(parse_osc_color("#00ff00"), Some((0, 255, 0)));
        assert_eq!(parse_osc_color("#0000ff"), Some((0, 0, 255)));
        assert_eq!(parse_osc_color("#f00"), Some((255, 0, 0)));
        assert_eq!(parse_osc_color("#0f0"), Some((0, 255, 0)));
        assert_eq!(parse_osc_color("#00f"), Some((0, 0, 255)));

        // X11 rgb formats (8-bit)
        assert_eq!(parse_osc_color("rgb:ff/00/00"), Some((255, 0, 0)));
        assert_eq!(parse_osc_color("rgb:00/ff/00"), Some((0, 255, 0)));

        // X11 rgb formats (16-bit)
        assert_eq!(parse_osc_color("rgb:ffff/0000/0000"), Some((255, 0, 0)));
        assert_eq!(parse_osc_color("rgb:0000/ffff/0000"), Some((0, 255, 0)));
        assert_eq!(parse_osc_color("rgb:8080/8080/8080"), Some((128, 128, 128)));

        // Invalid
        assert_eq!(parse_osc_color("invalid"), None);
        assert_eq!(parse_osc_color("#gg0000"), None);
    }

    #[test]
    fn alternate_screen_preserves_cursor_position() {
        let mut term = VirtualTerminal::new(24, 80);

        // Write some content and move cursor
        term.process(b"Hello");
        term.process(b"\x1b[10;20H"); // Move to row 10, col 20 (1-indexed)
        assert_eq!(term.cursor_row(), 9); // 0-indexed
        assert_eq!(term.cursor_col(), 19);

        // Enter alternate screen (CSI ? 1049 h)
        term.process(b"\x1b[?1049h");

        // Cursor should be at origin in alternate screen
        assert_eq!(term.cursor_row(), 0);
        assert_eq!(term.cursor_col(), 0);

        // Move cursor in alternate screen
        term.process(b"\x1b[5;10H");
        assert_eq!(term.cursor_row(), 4);
        assert_eq!(term.cursor_col(), 9);

        // Exit alternate screen (CSI ? 1049 l)
        term.process(b"\x1b[?1049l");

        // Cursor should be restored to original position
        assert_eq!(term.cursor_row(), 9);
        assert_eq!(term.cursor_col(), 19);
    }

    #[test]
    fn alternate_screen_preserves_origin_mode() {
        let mut term = VirtualTerminal::new(24, 80);

        // Verify origin mode is off by default
        assert!(!term.origin_mode);

        // Enter alternate screen
        term.process(b"\x1b[?1049h");

        // Enable origin mode in alternate screen (CSI ? 6 h)
        term.process(b"\x1b[?6h");
        assert!(term.origin_mode);

        // Exit alternate screen
        term.process(b"\x1b[?1049l");

        // Origin mode should be restored (off)
        assert!(!term.origin_mode);
    }

    #[test]
    fn alternate_screen_preserves_auto_wrap() {
        let mut term = VirtualTerminal::new(24, 80);

        // Verify auto wrap is on by default
        assert!(term.auto_wrap);

        // Disable auto wrap before entering alternate screen
        term.process(b"\x1b[?7l");
        assert!(!term.auto_wrap);

        // Enter alternate screen
        term.process(b"\x1b[?1049h");

        // Re-enable auto wrap in alternate screen
        term.process(b"\x1b[?7h");
        assert!(term.auto_wrap);

        // Exit alternate screen
        term.process(b"\x1b[?1049l");

        // Auto wrap should be restored (off)
        assert!(!term.auto_wrap);
    }

    #[test]
    fn alternate_screen_preserves_charset() {
        let mut term = VirtualTerminal::new(24, 80);

        // Verify charset defaults
        assert_eq!(term.charset_index, 0);
        assert!(!term.g0_charset_line_drawing);

        // Enable line drawing for G0 and switch to G1
        term.process(b"\x1b(0"); // G0 = line drawing
        term.process(b"\x0e"); // Shift Out (switch to G1)
        assert!(term.g0_charset_line_drawing);
        assert_eq!(term.charset_index, 1);

        // Enter alternate screen
        term.process(b"\x1b[?1049h");

        // Change charset in alternate screen
        term.process(b"\x1b(B"); // G0 = ASCII
        term.process(b"\x0f"); // Shift In (switch to G0)
        assert!(!term.g0_charset_line_drawing);
        assert_eq!(term.charset_index, 0);

        // Exit alternate screen
        term.process(b"\x1b[?1049l");

        // Charset should be restored
        assert!(term.g0_charset_line_drawing);
        assert_eq!(term.charset_index, 1);
    }

    #[test]
    fn alternate_screen_preserves_saved_cursor() {
        // Test that saved_cursor is cleared on alt screen transitions to prevent
        // stale cursor positions from affecting subsequent commands (e.g., codex after opencode)
        let mut term = VirtualTerminal::new(24, 80);

        // Save cursor at specific position (DECSC = ESC 7)
        term.process(b"\x1b[15;30H"); // Move to row 15, col 30
        term.process(b"\x1b7"); // Save cursor
        assert!(term.saved_cursor.is_some());

        // Enter alternate screen - saved_cursor should be cleared
        term.process(b"\x1b[?1049h");
        assert!(term.saved_cursor.is_none());

        // Save a different cursor position in alternate screen
        term.process(b"\x1b[3;5H");
        term.process(b"\x1b7");
        assert!(term.saved_cursor.is_some());

        // Exit alternate screen - saved_cursor should be cleared again
        // This prevents stale cursor positions from the TUI (or before it)
        // from affecting subsequent commands
        term.process(b"\x1b[?1049l");
        assert!(term.saved_cursor.is_none());

        // Restore cursor (DECRC = ESC 8) - with no saved cursor, position unchanged
        let row_before = term.cursor_row();
        let col_before = term.cursor_col();
        term.process(b"\x1b8");
        // Cursor should stay at current position when no saved cursor exists
        assert_eq!(term.cursor_row(), row_before);
        assert_eq!(term.cursor_col(), col_before);
    }

    #[test]
    fn alternate_screen_mode_47_doesnt_restore_cursor() {
        let mut term = VirtualTerminal::new(24, 80);

        // Move cursor to specific position
        term.process(b"\x1b[10;20H");
        assert_eq!(term.cursor_row(), 9);
        assert_eq!(term.cursor_col(), 19);

        // Enter alternate screen with mode 47 (no cursor save/restore)
        term.process(b"\x1b[?47h");

        // Move cursor in alternate screen
        term.process(b"\x1b[5;10H");
        assert_eq!(term.cursor_row(), 4);
        assert_eq!(term.cursor_col(), 9);

        // Exit alternate screen with mode 47
        term.process(b"\x1b[?47l");

        // Cursor position should NOT be restored (stays from restored grid)
        // Mode 47/1047 only restores grid content, not cursor position
        // The cursor position will be whatever was in the saved grid
        assert_eq!(term.cursor_row(), 9);
        assert_eq!(term.cursor_col(), 19);
    }

    #[test]
    fn alternate_screen_content_preserved() {
        let mut term = VirtualTerminal::new(24, 80);

        // Write content to main screen
        term.process(b"Main screen content");
        let grid = term.legacy_grid();
        assert_eq!(grid[0][0].c, 'M');
        assert_eq!(grid[0][5].c, 's');

        // Enter alternate screen
        term.process(b"\x1b[?1049h");

        // Alternate screen should be empty
        let grid = term.legacy_grid();
        assert_eq!(grid[0][0].c, ' ');

        // Write to alternate screen
        term.process(b"Alternate content");
        let grid = term.legacy_grid();
        assert_eq!(grid[0][0].c, 'A');

        // Exit alternate screen
        term.process(b"\x1b[?1049l");

        // Main screen content should be restored
        let grid = term.legacy_grid();
        assert_eq!(grid[0][0].c, 'M');
        assert_eq!(grid[0][5].c, 's');
    }

    // Debug test - run with: cargo test debug_alt_screen_cursor -- --nocapture
    fn dump_state(term: &VirtualTerminal, label: &str) {
        println!("\n=== {} ===", label);
        println!("  cursor: ({}, {})", term.cursor_row(), term.cursor_col());
        println!("  origin_mode: {}", term.origin_mode);
        println!("  auto_wrap: {}", term.auto_wrap);
        println!("  scroll_region: {:?}", term.scroll_region());
        println!("  pending_wrap: {}", term.pending_wrap);
        println!("  alternate_screen: {}", term.alternate_screen.is_some());
        println!("  saved_cursor: {}", term.saved_cursor.is_some());

        // Show viewport content
        println!("  viewport (first 8 lines):");
        for (i, row) in term.internal_grid.viewport.iter().take(8).enumerate() {
            let line: String = row.columns.iter().take(50).map(|c| c.character).collect();
            let trimmed = line.trim_end();
            if !trimmed.is_empty() {
                println!("    [{}]: '{}'", i, trimmed);
            } else {
                println!("    [{}]: (empty)", i);
            }
        }
    }

    #[test]
    fn debug_alt_screen_cursor() {
        let mut term = VirtualTerminal::new(24, 80);

        dump_state(&term, "Initial");

        term.process(b"Line1\n");
        term.process(b"Line2\n");
        term.process(b"Line3\n");
        term.process(b"Before->");
        dump_state(&term, "After initial content (cursor should be at row 3)");

        // Enter alternate screen
        term.process(b"\x1b[?1049h");
        dump_state(&term, "After entering alt screen (cursor should be at 0,0)");

        // Clear and write in alt screen
        term.process(b"\x1b[H\x1b[2J");
        term.process(b"ALT CONTENT");
        term.process(b"\x1b[10;20H"); // Move cursor
        term.process(b"At 10,20");
        dump_state(&term, "After writing in alt screen (cursor at 9,26)");

        // Exit alternate screen
        term.process(b"\x1b[?1049l");
        dump_state(
            &term,
            "After exiting alt screen (cursor should be at row 3, col 8)",
        );

        // Verify cursor position
        assert_eq!(term.cursor_row(), 3, "cursor row should be 3");
        assert_eq!(
            term.cursor_col(),
            8,
            "cursor col should be 8 (after 'Before->')"
        );

        // Write more content
        term.process(b"<-After\n");
        term.process(b"NextLine\n");
        dump_state(&term, "After writing post-alt content");
    }

    #[test]
    fn debug_with_scrollback() {
        let mut term = VirtualTerminal::new(5, 40); // Small terminal to force scrolling

        dump_state(&term, "Initial 5x40 terminal");

        // Fill screen and cause scrolling
        for i in 1..=10 {
            term.process(format!("Line{}\n", i).as_bytes());
        }
        term.process(b"BeforeAlt->");

        println!("\n  scrollback_len: {}", term.scrollback_len());
        dump_state(&term, "After scrolling (10 lines in 5-row term)");

        let saved_row = term.cursor_row();
        let saved_col = term.cursor_col();
        println!(
            "  >>> Saved cursor position: ({}, {})",
            saved_row, saved_col
        );

        term.process(b"\x1b[?1049h");
        term.process(b"\x1b[H\x1b[2JALT");
        dump_state(&term, "In alt screen");

        term.process(b"\x1b[?1049l");
        dump_state(&term, "After exiting alt screen");
        println!(
            "  >>> Restored cursor position: ({}, {})",
            term.cursor_row(),
            term.cursor_col()
        );
        println!("  scrollback_len after restore: {}", term.scrollback_len());

        // The cursor should be restored to the same position
        assert_eq!(
            term.cursor_row(),
            saved_row,
            "cursor row should be restored"
        );
        assert_eq!(
            term.cursor_col(),
            saved_col,
            "cursor col should be restored"
        );

        term.process(b"<-After\n");
        dump_state(&term, "After post-alt content");
    }

    /// Test that simulates the exact opentui/opencode startup and shutdown sequence.
    /// This reproduces the sequence that causes cursor position issues.
    #[test]
    fn test_opentui_full_sequence() {
        let mut term = VirtualTerminal::new(24, 80);

        // Simulate shell prompt and command
        term.process(b"$ opencode\r\n");
        let pre_alt_cursor_row = term.cursor_row();
        let pre_alt_cursor_col = term.cursor_col();

        // Verify initial state
        assert_eq!(
            term.cursor_row(),
            1,
            "cursor should be on line 2 after command"
        );
        assert_eq!(term.cursor_col(), 0, "cursor should be at column 0");
        assert!(term.cursor_visible, "cursor should be visible");
        assert!(
            term.alternate_screen.is_none(),
            "should not be in alt screen"
        );

        // === OpenTUI queryTerminalSend sequence ===
        // hideCursor + saveCursorState
        term.process(b"\x1b[?25l\x1b[s");
        assert!(!term.cursor_visible, "cursor should be hidden");

        // DECRPM queries (silently ignored - no response generated for unsupported queries)
        term.process(b"\x1b[?2026$p"); // SGR pixels
        term.process(b"\x1b[?2027$p"); // Unicode
        term.process(b"\x1b[?2031$p"); // Color scheme
        term.process(b"\x1b[?1004$p"); // Focus
        term.process(b"\x1b[?2004$p"); // Bracketed paste
        term.process(b"\x1b[?2026$p"); // Sync

        // home + explicitWidthQuery + cursorPositionRequest
        term.process(b"\x1b[H");
        assert_eq!(term.cursor_row(), 0, "cursor should be at home row");
        assert_eq!(term.cursor_col(), 0, "cursor should be at home col");
        term.process(b"\x1b]66;w=1; \x1b\\"); // OSC 66 (ignored)
        term.process(b"\x1b[6n"); // DSR - cursor position query

        // home + scaledTextQuery + cursorPositionRequest
        term.process(b"\x1b[H");
        term.process(b"\x1b]66;s=2; \x1b\\"); // OSC 66 scaled (ignored)
        term.process(b"\x1b[6n"); // DSR

        // xtversion, csiUQuery
        term.process(b"\x1b[>q"); // XTVERSION (likely ignored)
        term.process(b"\x1b[?u"); // CSI u query (likely ignored)

        // restoreCursorState - should restore to pre-alt position
        term.process(b"\x1b[u");
        assert_eq!(
            term.cursor_row(),
            pre_alt_cursor_row,
            "cursor row should be restored after query sequence"
        );
        assert_eq!(
            term.cursor_col(),
            pre_alt_cursor_col,
            "cursor col should be restored after query sequence"
        );

        // === OpenTUI setupTerminalWithoutDetection ===
        // saveCursorState again
        term.process(b"\x1b[s");

        // Enter alternate screen (mode 1049)
        term.process(b"\x1b[?1049h");
        assert!(
            term.alternate_screen.is_some(),
            "should be in alt screen now"
        );
        // Cursor should be at origin in fresh alt screen
        assert_eq!(
            term.cursor_row(),
            0,
            "alt screen cursor should start at row 0"
        );
        assert_eq!(
            term.cursor_col(),
            0,
            "alt screen cursor should start at col 0"
        );

        // setCursorPosition(1, 1) - move to home in alt screen
        term.process(b"\x1b[1;1H");

        // enableDetectedFeatures - enable bracketed paste, mouse, etc.
        term.process(b"\x1b[?2004h"); // Bracketed paste
        term.process(b"\x1b[?1003h"); // Mouse tracking

        // === Simulate TUI rendering ===
        term.process(b"\x1b[H\x1b[2J"); // Clear and home
        term.process(b"OpenCode TUI Content Here");
        term.process(b"\x1b[10;5HCursor at row 10");

        // Verify alt screen state
        assert_eq!(
            term.cursor_row(),
            9,
            "cursor should be at row 9 (0-indexed)"
        );
        assert_eq!(
            term.cursor_col(),
            20,
            "cursor should be after 'Cursor at row 10'"
        );

        // === OpenTUI performShutdownSequence (via resetState) ===
        // showCursor + reset
        term.process(b"\x1b[?25h\x1b[0m");
        assert!(term.cursor_visible, "cursor should be visible");

        // Disable features
        term.process(b"\x1b[?2004l"); // Disable bracketed paste
        term.process(b"\x1b[?1003l"); // Disable mouse tracking

        // Exit alternate screen (mode 1049)
        term.process(b"\x1b[?1049l");
        assert!(
            term.alternate_screen.is_none(),
            "should no longer be in alt screen"
        );

        // === Verify cursor restoration ===
        // The cursor should be restored to where it was when we entered alt screen
        assert_eq!(
            term.cursor_row(),
            pre_alt_cursor_row,
            "cursor row should be restored to pre-alt position"
        );
        assert_eq!(
            term.cursor_col(),
            pre_alt_cursor_col,
            "cursor col should be restored to pre-alt position"
        );

        // Additional cleanup sequences from shutdown
        term.process(b"\x1b]112\x07"); // OSC 112 - reset cursor color (ignored)
        term.process(b"\x1b]12;default\x07"); // OSC 12 - set cursor color to default (ignored)
        term.process(b"\x1b[0 q"); // DECSCUSR - default cursor style (ignored)
        term.process(b"\x1b[?25h"); // Show cursor again

        // Final verification - cursor should still be at restored position
        assert_eq!(
            term.cursor_row(),
            pre_alt_cursor_row,
            "cursor row should remain at restored position after cleanup"
        );
        assert_eq!(
            term.cursor_col(),
            pre_alt_cursor_col,
            "cursor col should remain at restored position after cleanup"
        );
        assert!(
            term.cursor_visible,
            "cursor should be visible after cleanup"
        );

        // Verify the main screen content was preserved
        let line0 = term.internal_grid.viewport[0].as_string();
        assert!(
            line0.starts_with("$ opencode"),
            "first line should have original content: '{}'",
            line0
        );
    }

    /// Test the bug: after exiting alt screen, pressing Enter, then entering
    /// alt screen again and exiting - the Enter presses should be preserved.
    #[test]
    fn test_multiple_alt_screen_sessions_preserve_content() {
        let mut term = VirtualTerminal::new(24, 80);

        // Step 1: Initial shell prompt and command
        term.process(b"$ opencode\r\n");
        assert_eq!(term.cursor_row(), 1);
        assert_eq!(term.cursor_col(), 0);

        // Step 2: First TUI enters alt screen
        term.process(b"\x1b[?1049h");
        assert!(term.alternate_screen.is_some());

        // TUI does stuff in alt screen
        term.process(b"\x1b[H\x1b[2JOpenCode TUI");

        // Step 3: First TUI exits alt screen
        term.process(b"\x1b[?1049l");
        assert!(term.alternate_screen.is_none());
        assert_eq!(term.cursor_row(), 1, "cursor should be restored to row 1");

        // Step 4: User presses Enter a few times (new content after first TUI)
        term.process(b"\r\n\r\n\r\n");
        assert_eq!(
            term.cursor_row(),
            4,
            "cursor should be at row 4 after 3 Enters"
        );

        // Verify line 1 (where we were after opencode) is now empty (from Enter)
        let line1 = term.internal_grid.viewport[1].as_string();
        let line2 = term.internal_grid.viewport[2].as_string();
        let line3 = term.internal_grid.viewport[3].as_string();
        assert!(
            line1.trim().is_empty(),
            "line 1 should be empty after Enter"
        );
        assert!(
            line2.trim().is_empty(),
            "line 2 should be empty after Enter"
        );
        assert!(
            line3.trim().is_empty(),
            "line 3 should be empty after Enter"
        );

        // Step 5: User types new command
        term.process(b"$ codex\r\n");
        assert_eq!(
            term.cursor_row(),
            5,
            "cursor should be at row 5 after codex command"
        );

        // Verify "codex" is on line 4
        let line4 = term.internal_grid.viewport[4].as_string();
        assert!(
            line4.contains("codex"),
            "line 4 should have codex command: '{}'",
            line4
        );

        // Step 6: Second TUI enters alt screen
        term.process(b"\x1b[?1049h");
        assert!(term.alternate_screen.is_some());

        // TUI does stuff
        term.process(b"\x1b[H\x1b[2JCodex TUI");

        // Step 7: Second TUI exits alt screen
        term.process(b"\x1b[?1049l");
        assert!(term.alternate_screen.is_none());

        // Step 8: Verify the content is preserved - this is the critical check!
        // Cursor should be at row 5 (after "codex" command), not row 1
        assert_eq!(
            term.cursor_row(),
            5,
            "cursor should be at row 5, NOT row 1 (the bug was cursor returning to first TUI exit position)"
        );

        // Verify the grid content includes the Enter presses AND the codex command
        let line0 = term.internal_grid.viewport[0].as_string();
        let line4_after = term.internal_grid.viewport[4].as_string();

        assert!(
            line0.contains("opencode"),
            "line 0 should still have opencode: '{}'",
            line0
        );
        assert!(
            line4_after.contains("codex"),
            "line 4 should still have codex (Enter presses preserved): '{}'",
            line4_after
        );
    }

    /// Test with chunked data processing (simulates real WebSocket data flow)
    /// This specifically tests the bug where content between alt screen sessions disappears
    #[test]
    fn test_chunked_alt_screen_sessions() {
        let mut buffer = TerminalBuffer::with_size(24, 80);

        // Step 1: Shell prompt (might come in chunks)
        buffer.process(b"$ open");
        buffer.process(b"code");
        buffer.process(b"\r\n");

        // Step 2: opencode enters alt screen
        buffer.process(b"\x1b[?1049h");
        assert!(buffer.terminal.alternate_screen.is_some());

        // opencode does TUI stuff
        buffer.process(b"\x1b[H");
        buffer.process(b"\x1b[2J");
        buffer.process(b"OpenCode Content");

        // Step 3: opencode exits alt screen
        buffer.process(b"\x1b[?1049l");
        assert!(buffer.terminal.alternate_screen.is_none());

        // Verify we're back to main screen
        let view_after_first = buffer.render_view(24);
        assert_eq!(view_after_first.cursor, Some((1, 0)));
        let line0: String = view_after_first.lines[0]
            .spans
            .iter()
            .flat_map(|s| s.content.chars())
            .collect();
        assert!(
            line0.contains("opencode"),
            "should have opencode: {}",
            line0
        );

        // Step 4: User presses Enter multiple times (shell echoes or shows prompts)
        // In reality, each Enter produces output from the shell
        buffer.process(b"\r\n");
        let v1 = buffer.render_view(24);
        assert_eq!(v1.cursor, Some((2, 0)), "cursor should be at row 2");

        buffer.process(b"\r\n");
        let v2 = buffer.render_view(24);
        assert_eq!(v2.cursor, Some((3, 0)), "cursor should be at row 3");

        buffer.process(b"\r\n");
        let v3 = buffer.render_view(24);
        assert_eq!(v3.cursor, Some((4, 0)), "cursor should be at row 4");

        // Step 5: User types codex command
        buffer.process(b"$ codex");
        buffer.process(b"\r\n");
        let v4 = buffer.render_view(24);
        assert_eq!(v4.cursor, Some((5, 0)), "cursor should be at row 5");

        // Verify "codex" is on line 4
        let line4: String = v4.lines[4]
            .spans
            .iter()
            .flat_map(|s| s.content.chars())
            .collect();
        assert!(
            line4.contains("codex"),
            "line 4 should have codex: {}",
            line4
        );

        // CRITICAL: Save what we expect the grid to contain
        let expected_line0 = buffer.terminal.internal_grid.viewport[0].as_string();
        let expected_line4 = buffer.terminal.internal_grid.viewport[4].as_string();
        let expected_cursor_row = buffer.terminal.cursor_row();

        // Step 6: codex enters alt screen - THIS IS WHERE THE BUG MIGHT BE
        buffer.process(b"\x1b[?1049h");
        assert!(buffer.terminal.alternate_screen.is_some());

        // Verify the saved grid (in alternate_screen) contains the Enter lines
        let saved = buffer.terminal.alternate_screen.as_ref().unwrap();
        let saved_line4 = saved.grid.viewport[4].as_string();
        assert!(
            saved_line4.contains("codex"),
            "SAVED grid should have codex on line 4: {}",
            saved_line4
        );
        assert_eq!(
            saved.cursor_row, expected_cursor_row,
            "saved cursor row should be {}",
            expected_cursor_row
        );

        // codex does TUI stuff
        buffer.process(b"\x1b[H\x1b[2JCodex Content");

        // Step 7: codex exits alt screen
        buffer.process(b"\x1b[?1049l");
        assert!(buffer.terminal.alternate_screen.is_none());

        // CRITICAL CHECK: Content should be preserved
        let final_view = buffer.render_view(24);
        assert_eq!(
            final_view.cursor,
            Some((5, 0)),
            "cursor should be at (5, 0), NOT (1, 0)"
        );

        let final_line0: String = final_view.lines[0]
            .spans
            .iter()
            .flat_map(|s| s.content.chars())
            .collect();
        let final_line4: String = final_view.lines[4]
            .spans
            .iter()
            .flat_map(|s| s.content.chars())
            .collect();

        assert!(
            final_line0.contains("opencode"),
            "final line 0 should have opencode: {}",
            final_line0
        );
        assert!(
            final_line4.contains("codex"),
            "final line 4 should have codex (Enter lines preserved): {}",
            final_line4
        );
    }

    /// Test the same scenario but using TerminalBuffer to verify the buffer layer
    #[test]
    fn test_terminal_buffer_multiple_alt_screen_sessions() {
        let mut buffer = TerminalBuffer::with_size(24, 80);

        // Step 1: Initial shell prompt and command
        buffer.process(b"$ opencode\r\n");
        let view1 = buffer.render_view(24);
        assert_eq!(view1.cursor, Some((1, 0)), "cursor should be at (1, 0)");

        // Step 2: First TUI enters alt screen
        buffer.process(b"\x1b[?1049h");
        let view2 = buffer.render_view(24);
        assert!(view2.is_alt_screen, "should be in alt screen");

        // TUI does stuff
        buffer.process(b"\x1b[H\x1b[2JOpenCode TUI");

        // Step 3: First TUI exits alt screen
        buffer.process(b"\x1b[?1049l");
        let view3 = buffer.render_view(24);
        assert!(!view3.is_alt_screen, "should not be in alt screen");
        assert_eq!(
            view3.cursor,
            Some((1, 0)),
            "cursor should be restored to (1, 0)"
        );

        // Step 4: User presses Enter a few times
        buffer.process(b"\r\n\r\n\r\n");
        let view4 = buffer.render_view(24);
        assert_eq!(
            view4.cursor,
            Some((4, 0)),
            "cursor should be at (4, 0) after Enters"
        );

        // Step 5: User types codex command
        buffer.process(b"$ codex\r\n");
        let view5 = buffer.render_view(24);
        assert_eq!(view5.cursor, Some((5, 0)), "cursor should be at (5, 0)");

        // Step 6: Second TUI enters alt screen
        buffer.process(b"\x1b[?1049h");
        let view6 = buffer.render_view(24);
        assert!(view6.is_alt_screen, "should be in alt screen");

        // TUI does stuff
        buffer.process(b"\x1b[H\x1b[2JCodex TUI");

        // Step 7: Second TUI exits alt screen
        buffer.process(b"\x1b[?1049l");
        let view7 = buffer.render_view(24);

        // THE CRITICAL CHECK - cursor should be at (5, 0) not (1, 0)
        assert!(!view7.is_alt_screen, "should not be in alt screen");
        assert_eq!(
            view7.cursor,
            Some((5, 0)),
            "cursor should be at (5, 0) after second alt screen exit, NOT (1, 0)"
        );

        // Verify content
        let line0: String = view7.lines[0]
            .spans
            .iter()
            .flat_map(|s| s.content.chars())
            .collect();
        let line4: String = view7.lines[4]
            .spans
            .iter()
            .flat_map(|s| s.content.chars())
            .collect();
        assert!(
            line0.contains("opencode"),
            "line 0 should have opencode: '{}'",
            line0
        );
        assert!(
            line4.contains("codex"),
            "line 4 should have codex: '{}'",
            line4
        );
    }

    /// Test that TerminalBuffer's render_view correctly reports cursor position
    /// after alt screen exit. This verifies the full render pipeline.
    #[test]
    fn test_terminal_buffer_cursor_after_alt_screen() {
        let mut buffer = TerminalBuffer::with_size(24, 80);

        // Simulate shell prompt and command
        buffer.process(b"$ opencode\r\n");

        // Get initial render view
        let view1 = buffer.render_view(24);
        assert_eq!(
            view1.cursor,
            Some((1, 0)),
            "cursor should be at (1, 0) after command"
        );
        assert!(view1.cursor_visible, "cursor should be visible");
        assert!(!view1.is_alt_screen, "should not be in alt screen");

        // Enter alt screen
        buffer.process(b"\x1b[?1049h");

        let view2 = buffer.render_view(24);
        assert_eq!(
            view2.cursor,
            Some((0, 0)),
            "cursor should be at origin in alt screen"
        );
        assert!(view2.is_alt_screen, "should be in alt screen");

        // Move cursor and add content in alt screen
        buffer.process(b"\x1b[10;20HTUI Content");

        // Exit alt screen
        buffer.process(b"\x1b[?1049l");

        // Verify render view after alt screen exit
        let view3 = buffer.render_view(24);
        assert_eq!(
            view3.cursor,
            Some((1, 0)),
            "cursor should be restored to (1, 0) after alt screen exit"
        );
        assert!(view3.cursor_visible, "cursor should be visible after exit");
        assert!(
            !view3.is_alt_screen,
            "should not be in alt screen after exit"
        );

        // Verify needs_full_clear was set
        // (Note: we've already called render_view which might have consumed it via the cache)
        // So we check that the content is preserved
        let line0 = &view3.lines[0];
        let line0_str: String = line0.spans.iter().flat_map(|s| s.content.chars()).collect();
        assert!(
            line0_str.starts_with("$ opencode"),
            "first line should show original content: '{}'",
            line0_str
        );
    }
}
