//! Which predicted glyphs fit on the cursor row, and the span of cells the
//! overlay covers to draw them. Pure cell arithmetic: the host supplies the
//! grid geometry and turns cells into points.

use crate::glyph::{PredictedGlyph, Standing};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PredictionOverlayLayout {
    /// The glyphs to draw, each keeping its offset from the live cursor.
    pub glyphs: Vec<PredictedGlyph>,
    /// Offset from the cursor of the overlay's first cell. Negative while a
    /// confirmed glyph is held, positive when the first drawn glyph follows
    /// keystrokes that were never shown.
    pub leading_offset: i32,
    /// Offset of the caret marking where typing continues, or `None` when that
    /// cell is past the right margin.
    pub caret_offset: Option<i32>,
    /// Cells from `leading_offset` through the last glyph or the caret.
    pub cell_count: i32,
}

impl PredictionOverlayLayout {
    /// `cursor_column`: the cursor's zero-based column on screen; `columns`:
    /// the grid's width. `None` when nothing should be drawn.
    pub fn new(glyphs: &[PredictedGlyph], cursor_column: i32, columns: i32) -> Option<Self> {
        // On the last column the cursor may be waiting to wrap, and nothing
        // says whether the character under it is already printed. Offsets
        // there could be off by one cell either way, so prediction stops at the
        // margin rather than guess.
        if columns <= 0 || cursor_column < 0 || cursor_column >= columns - 1 {
            return None;
        }
        // Drop what falls off either end of the row: speculative glyphs past the
        // margin wrap somewhere this does not model, and held confirmations can
        // sit on the row above once the echo wrapped.
        let on_row: Vec<PredictedGlyph> = glyphs
            .iter()
            .copied()
            .filter(|glyph| (0..columns).contains(&(cursor_column + glyph.offset)))
            .collect();
        let first = on_row.iter().map(|glyph| glyph.offset).min()?;
        let last = on_row.iter().map(|glyph| glyph.offset).max()?;
        // Typing continues after the last live glyph, or, when every drawn cell
        // is a deleted one, at the first of those.
        let last_typed = glyphs
            .iter()
            .filter(|glyph| glyph.standing != Standing::Erased)
            .map(|glyph| glyph.offset)
            .max();
        let caret = match last_typed {
            Some(offset) => offset + 1,
            None => glyphs.iter().map(|glyph| glyph.offset).min()?,
        };
        // Left of the cursor with nothing speculative, the caret would mark where
        // typing resumes once a pending erase lands, beside the live cursor
        // ghostty already draws. Only a drawn prediction justifies a second one.
        let caret_is_ahead =
            caret >= 0 || glyphs.iter().any(|glyph| glyph.standing == Standing::Speculative);
        let caret_offset = (caret_is_ahead && cursor_column + caret < columns).then_some(caret);
        Some(Self {
            glyphs: on_row,
            leading_offset: first,
            caret_offset,
            cell_count: last.max(caret_offset.unwrap_or(last)) - first + 1,
        })
    }
}
