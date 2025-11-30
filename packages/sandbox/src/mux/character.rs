//! Terminal character and row types optimized for performance.
//!
//! This module implements a zellij-inspired approach to terminal character storage:
//! - Shared styles via Arc to reduce memory duplication (Arc for thread safety)
//! - Precomputed character width to avoid repeated unicode_width calls
//! - Row structure with canonical line tracking for proper resize/rewrap

use ratatui::style::{Color, Modifier, Style};
use std::cmp::Ordering;
use std::collections::VecDeque;
use std::sync::Arc;
use unicode_width::UnicodeWidthChar;

/// Shared character styles using atomic reference counting.
/// This avoids duplicating style data across millions of cells.
/// Uses Arc for thread safety in async contexts.
#[derive(Clone, Debug, PartialEq, Default)]
pub enum SharedStyles {
    /// Default style (no allocation needed)
    #[default]
    Default,
    /// Custom style (atomic reference counted for thread safety)
    Custom(Arc<CharacterStyles>),
}

/// Static default style to avoid allocations for the common case.
static DEFAULT_STYLES: std::sync::LazyLock<CharacterStyles> =
    std::sync::LazyLock::new(CharacterStyles::default);

impl SharedStyles {
    /// Create a new shared style from a CharacterStyles struct.
    pub fn new(styles: CharacterStyles) -> Self {
        if styles == CharacterStyles::default() {
            SharedStyles::Default
        } else {
            SharedStyles::Custom(Arc::new(styles))
        }
    }

    /// Get the underlying CharacterStyles.
    pub fn get(&self) -> &CharacterStyles {
        match self {
            SharedStyles::Default => &DEFAULT_STYLES,
            SharedStyles::Custom(arc) => arc.as_ref(),
        }
    }

    /// Check if this is the default style.
    pub fn is_default(&self) -> bool {
        matches!(self, SharedStyles::Default)
    }

    /// Convert to a ratatui Style.
    pub fn to_ratatui_style(&self) -> Style {
        self.get().to_ratatui_style()
    }
}

/// Character styles - similar to ratatui's Style but designed for sharing.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub struct CharacterStyles {
    pub foreground: Option<Color>,
    pub background: Option<Color>,
    pub modifiers: Modifier,
}

impl CharacterStyles {
    /// Create from a ratatui Style.
    pub fn from_ratatui_style(style: Style) -> Self {
        Self {
            foreground: style.fg,
            background: style.bg,
            modifiers: style.add_modifier,
        }
    }

    /// Convert to a ratatui Style.
    pub fn to_ratatui_style(&self) -> Style {
        let mut style = Style::default();
        if let Some(fg) = self.foreground {
            style = style.fg(fg);
        }
        if let Some(bg) = self.background {
            style = style.bg(bg);
        }
        style = style.add_modifier(self.modifiers);
        style
    }

    /// Set foreground color.
    pub fn fg(mut self, color: Color) -> Self {
        self.foreground = Some(color);
        self
    }

    /// Set background color.
    pub fn bg(mut self, color: Color) -> Self {
        self.background = Some(color);
        self
    }

    /// Add a modifier.
    pub fn add_modifier(mut self, modifier: Modifier) -> Self {
        self.modifiers = self.modifiers.union(modifier);
        self
    }

    /// Remove a modifier.
    pub fn remove_modifier(mut self, modifier: Modifier) -> Self {
        self.modifiers = self.modifiers.difference(modifier);
        self
    }
}

/// A single character in the terminal grid.
/// Designed to be exactly 16 bytes for cache efficiency (following zellij's approach).
///
/// Memory layout:
/// - character: 4 bytes (char)
/// - styles: 8 bytes (enum with Rc pointer or Default variant)
/// - width: 1 byte (precomputed character width)
/// - wide_spacer: 1 byte (bool, indicates this is a spacer for a wide char)
/// - padding: 2 bytes
#[derive(Clone, Debug)]
pub struct TerminalCharacter {
    /// The Unicode character.
    pub character: char,
    /// Shared styles for this character.
    pub styles: SharedStyles,
    /// Precomputed display width (0, 1, or 2).
    width: u8,
    /// True if this cell is a spacer for a wide character (the cell to the right of a double-width char).
    pub wide_spacer: bool,
}

// Verify size is reasonable (may not be exactly 16 bytes due to Rust's layout, but should be close)
const _: () = {
    // Note: Actual size depends on pointer size and alignment. On 64-bit systems:
    // char: 4 bytes, SharedStyles enum: 16 bytes (discriminant + Rc), width: 1, wide_spacer: 1, padding: 2
    // Total: ~24 bytes. This is still much better than having full Style inline.
};

impl Default for TerminalCharacter {
    fn default() -> Self {
        Self {
            character: ' ',
            styles: SharedStyles::Default,
            width: 1,
            wide_spacer: false,
        }
    }
}

impl PartialEq for TerminalCharacter {
    fn eq(&self, other: &Self) -> bool {
        self.character == other.character
            && self.styles == other.styles
            && self.wide_spacer == other.wide_spacer
    }
}

impl TerminalCharacter {
    /// Create a new terminal character with precomputed width.
    pub fn new(character: char, styles: SharedStyles) -> Self {
        let width = character.width().unwrap_or(1) as u8;
        Self {
            character,
            styles,
            width,
            wide_spacer: false,
        }
    }

    /// Create a new terminal character with explicit width.
    pub fn with_width(character: char, styles: SharedStyles, width: u8) -> Self {
        Self {
            character,
            styles,
            width,
            wide_spacer: false,
        }
    }

    /// Create a wide character spacer cell.
    pub fn wide_spacer(styles: SharedStyles) -> Self {
        Self {
            character: ' ',
            styles,
            width: 0,
            wide_spacer: true,
        }
    }

    /// Get the display width of this character.
    #[inline]
    pub fn width(&self) -> usize {
        self.width as usize
    }

    /// Get the character.
    #[inline]
    pub fn char(&self) -> char {
        self.character
    }

    /// Check if this is a wide character (width > 1).
    #[inline]
    pub fn is_wide(&self) -> bool {
        self.width > 1
    }
}

/// A single row in the terminal grid.
/// Uses VecDeque for efficient insertion/deletion at both ends.
#[derive(Clone, Debug)]
pub struct Row {
    /// Characters in this row.
    pub columns: VecDeque<TerminalCharacter>,
    /// True if this is the start of a logical line (after a newline).
    /// False if this row is a wrapped continuation of the previous line.
    pub is_canonical: bool,
}

impl Default for Row {
    fn default() -> Self {
        Self {
            columns: VecDeque::new(),
            is_canonical: true,
        }
    }
}

impl PartialEq for Row {
    fn eq(&self, other: &Self) -> bool {
        self.columns == other.columns && self.is_canonical == other.is_canonical
    }
}

impl Row {
    /// Create a new empty row.
    pub fn new() -> Self {
        Self::default()
    }

    /// Create a new row with a given capacity.
    pub fn with_capacity(capacity: usize) -> Self {
        Self {
            columns: VecDeque::with_capacity(capacity),
            is_canonical: true,
        }
    }

    /// Create a new row filled with default characters.
    pub fn filled(width: usize) -> Self {
        let mut row = Self::with_capacity(width);
        for _ in 0..width {
            row.columns.push_back(TerminalCharacter::default());
        }
        row
    }

    /// Get the number of character cells in this row.
    #[inline]
    pub fn len(&self) -> usize {
        self.columns.len()
    }

    /// Check if the row is empty.
    #[inline]
    pub fn is_empty(&self) -> bool {
        self.columns.is_empty()
    }

    /// Get the display width of this row (accounting for wide characters).
    pub fn width(&self) -> usize {
        self.columns.iter().map(|c| c.width()).sum()
    }

    /// Get a character at the given column index.
    #[inline]
    pub fn get(&self, index: usize) -> Option<&TerminalCharacter> {
        self.columns.get(index)
    }

    /// Get a mutable character at the given column index.
    #[inline]
    pub fn get_mut(&mut self, index: usize) -> Option<&mut TerminalCharacter> {
        self.columns.get_mut(index)
    }

    /// Set a character at the given column index, extending the row if necessary.
    pub fn set(&mut self, index: usize, character: TerminalCharacter) {
        while self.columns.len() <= index {
            self.columns.push_back(TerminalCharacter::default());
        }
        self.columns[index] = character;
    }

    /// Add a character at the given position, handling wide character semantics.
    /// Returns the new cursor position after the character.
    pub fn add_character_at(&mut self, character: TerminalCharacter, x: usize) -> usize {
        let char_width = character.width();

        match self.len().cmp(&x) {
            Ordering::Equal => {
                // Append at end
                self.columns.push_back(character);
                if char_width == 2 {
                    self.columns
                        .push_back(TerminalCharacter::wide_spacer(SharedStyles::Default));
                }
            }
            Ordering::Less => {
                // Pad with spaces and append
                while self.columns.len() < x {
                    self.columns.push_back(TerminalCharacter::default());
                }
                self.columns.push_back(character);
                if char_width == 2 {
                    self.columns
                        .push_back(TerminalCharacter::wide_spacer(SharedStyles::Default));
                }
            }
            Ordering::Greater => {
                // Replace existing character(s)
                // Handle wide character at current position
                if x > 0 && self.columns[x].wide_spacer {
                    // Overwriting spacer, clear the main character
                    self.columns[x - 1] = TerminalCharacter::default();
                }

                // Handle wide character being partially overwritten
                if char_width == 1 && x + 1 < self.columns.len() && self.columns[x + 1].wide_spacer
                {
                    self.columns[x + 1] = TerminalCharacter::default();
                }

                self.columns[x] = character;

                // Place spacer for wide characters
                if char_width == 2 {
                    if x + 1 < self.columns.len() {
                        // Handle overwriting another wide char's spacer
                        if x + 2 < self.columns.len() && self.columns[x + 2].wide_spacer {
                            self.columns[x + 2] = TerminalCharacter::default();
                        }
                        self.columns[x + 1] = TerminalCharacter::wide_spacer(SharedStyles::Default);
                    } else {
                        self.columns
                            .push_back(TerminalCharacter::wide_spacer(SharedStyles::Default));
                    }
                }
            }
        }

        x + char_width
    }

    /// Insert blank characters at the given position, shifting existing chars right.
    pub fn insert_blank(&mut self, x: usize, count: usize, max_width: usize) {
        for _ in 0..count {
            if self.columns.len() >= max_width {
                self.columns.pop_back();
            }
            if x < self.columns.len() {
                self.columns.insert(x, TerminalCharacter::default());
            }
        }
    }

    /// Delete characters at the given position, shifting remaining chars left.
    pub fn delete_chars(&mut self, x: usize, count: usize, max_width: usize) {
        for _ in 0..count {
            if x < self.columns.len() {
                self.columns.remove(x);
            }
        }
        // Pad to max_width
        while self.columns.len() < max_width {
            self.columns.push_back(TerminalCharacter::default());
        }
    }

    /// Clear characters from the given position to the end.
    pub fn clear_from(&mut self, x: usize) {
        while self.columns.len() > x {
            self.columns.pop_back();
        }
    }

    /// Clear characters from the start to the given position (inclusive).
    pub fn clear_to(&mut self, x: usize) {
        for i in 0..=x.min(self.columns.len().saturating_sub(1)) {
            self.columns[i] = TerminalCharacter::default();
        }
    }

    /// Clear all characters in the row.
    pub fn clear(&mut self) {
        self.columns.clear();
    }

    /// Fill the row to a given width with default characters.
    pub fn fill_to_width(&mut self, width: usize) {
        while self.columns.len() < width {
            self.columns.push_back(TerminalCharacter::default());
        }
    }

    /// Truncate the row to a given width.
    pub fn truncate(&mut self, width: usize) {
        while self.columns.len() > width {
            self.columns.pop_back();
        }
    }

    /// Split this row into multiple rows of the given maximum length.
    /// Used when resizing the terminal to rewrap lines.
    pub fn split_to_rows_of_length(&self, max_row_length: usize) -> Vec<Row> {
        if max_row_length == 0 {
            return vec![self.clone()];
        }

        let mut result = Vec::new();
        let mut current_row = Row::with_capacity(max_row_length);
        current_row.is_canonical = self.is_canonical;
        let mut current_width = 0;

        for character in &self.columns {
            let char_width = character.width();

            // Check if adding this character would exceed the max width
            if current_width + char_width > max_row_length {
                // Start a new row
                result.push(current_row);
                current_row = Row::with_capacity(max_row_length);
                current_row.is_canonical = false; // Continuation row
                current_width = 0;
            }

            current_row.columns.push_back(character.clone());
            current_width += char_width;
        }

        if !current_row.is_empty() || result.is_empty() {
            result.push(current_row);
        }

        result
    }

    /// Iterate over characters in the row.
    pub fn iter(&self) -> impl Iterator<Item = &TerminalCharacter> {
        self.columns.iter()
    }

    /// Convert row to a string (for debugging and URL detection).
    pub fn as_string(&self) -> String {
        self.columns.iter().map(|c| c.character).collect()
    }

    /// Convert row contents to a ratatui Line for rendering.
    pub fn to_ratatui_line(&self) -> ratatui::text::Line<'static> {
        self.to_ratatui_line_with_defaults(None, None)
    }

    /// Convert row contents to a ratatui Line, using default colors for cells without explicit colors.
    pub fn to_ratatui_line_with_defaults(
        &self,
        default_fg: Option<Color>,
        default_bg: Option<Color>,
    ) -> ratatui::text::Line<'static> {
        let mut spans: Vec<ratatui::text::Span<'static>> = Vec::new();
        let mut current_style = Style::default();
        let mut current_text = String::new();

        for character in &self.columns {
            if character.wide_spacer {
                continue;
            }

            let mut char_style = character.styles.to_ratatui_style();

            // Apply default colors if no explicit color is set
            if char_style.fg.is_none() {
                char_style.fg = default_fg;
            }
            if char_style.bg.is_none() {
                char_style.bg = default_bg;
            }

            if char_style == current_style {
                current_text.push(character.character);
            } else {
                if !current_text.is_empty() {
                    spans.push(ratatui::text::Span::styled(
                        std::mem::take(&mut current_text),
                        current_style,
                    ));
                }
                current_style = char_style;
                current_text.push(character.character);
            }
        }

        if !current_text.is_empty() {
            spans.push(ratatui::text::Span::styled(current_text, current_style));
        }

        ratatui::text::Line::from(spans)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_terminal_character_default() {
        let c = TerminalCharacter::default();
        assert_eq!(c.character, ' ');
        assert_eq!(c.width(), 1);
        assert!(!c.wide_spacer);
        assert!(c.styles.is_default());
    }

    #[test]
    fn test_terminal_character_width() {
        // ASCII character
        let c = TerminalCharacter::new('A', SharedStyles::Default);
        assert_eq!(c.width(), 1);

        // Wide character (CJK)
        let c = TerminalCharacter::new('中', SharedStyles::Default);
        assert_eq!(c.width(), 2);
    }

    #[test]
    fn test_row_add_character() {
        let mut row = Row::new();

        // Add single-width character
        let next = row.add_character_at(TerminalCharacter::new('A', SharedStyles::Default), 0);
        assert_eq!(next, 1);
        assert_eq!(row.len(), 1);
        assert_eq!(row.columns[0].character, 'A');

        // Add wide character
        let next = row.add_character_at(TerminalCharacter::new('中', SharedStyles::Default), 1);
        assert_eq!(next, 3);
        assert_eq!(row.len(), 3);
        assert_eq!(row.columns[1].character, '中');
        assert!(row.columns[2].wide_spacer);
    }

    #[test]
    fn test_row_split() {
        let mut row = Row::with_capacity(10);
        for c in "Hello World".chars() {
            row.columns
                .push_back(TerminalCharacter::new(c, SharedStyles::Default));
        }
        row.is_canonical = true;

        let split = row.split_to_rows_of_length(5);
        assert_eq!(split.len(), 3);
        assert!(split[0].is_canonical);
        assert!(!split[1].is_canonical);
        assert!(!split[2].is_canonical);
    }

    #[test]
    fn test_shared_styles() {
        let default = SharedStyles::Default;
        assert!(default.is_default());

        let custom = SharedStyles::new(CharacterStyles::default().fg(Color::Red));
        assert!(!custom.is_default());

        let style = custom.to_ratatui_style();
        assert_eq!(style.fg, Some(Color::Red));
    }
}
