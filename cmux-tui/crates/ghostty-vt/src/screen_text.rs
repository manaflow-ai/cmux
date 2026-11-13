//! Plain-text views of the screen for keyboard copy mode: one screen row's
//! cells with their wide-character roles and soft-wrap flag, and the matches
//! of a scrollback search. The reads live on [`crate::Terminal`]
//! (`screen_row_text`, `search_screen`, `block_selection_text_absolute`).

use crate::{CellWidth, SelectionRange};

/// One cell of a screen row as copy mode reads it.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ScreenTextCell {
    /// The cell's grapheme cluster; empty for a blank cell or a spacer.
    pub text: String,
    /// The cell's role in a wide grapheme.
    pub width: CellWidth,
}

/// One screen row: every column's cell and whether the row soft-wraps.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ScreenRowText {
    /// One entry per terminal column.
    pub cells: Vec<ScreenTextCell>,
    /// The row's text continues on the next row (a soft wrap, not a newline).
    pub wraps: bool,
}

/// The matches of one needle on the active screen, scrollback included.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ScreenSearch {
    /// Inclusive match ranges in screen coordinates (row 0 is the oldest
    /// retained row), ordered top to bottom. `start` is never after `end`.
    pub matches: Vec<SelectionRange>,
    /// More matches exist than the requested limit; the newest ones are kept.
    pub truncated: bool,
}
