//! The live screen's text, independent of where the viewport is scrolled.

use super::*;

impl Terminal {
    /// Plain text of the live screen: the active area at the bottom of the
    /// page list, the rows output writes to, wherever the viewport is
    /// scrolled. Equal to [`Self::viewport_text`] while the viewport is at the
    /// live bottom. Readers that wait on or report new output use this, so a
    /// scrolled-back viewport does not hide it.
    pub fn active_text(&mut self) -> Result<String> {
        let cols = self.cols();
        let rows = self.rows();
        if cols == 0 || rows == 0 {
            return Ok(String::new());
        }
        self.selection_text_with_tag_options(
            sys::GHOSTTY_POINT_TAG_ACTIVE,
            (0, 0),
            (cols.saturating_sub(1), u64::from(rows.saturating_sub(1))),
            false,
            true,
        )
        .ok_or(Error::InvalidValue)
    }
}

#[cfg(test)]
mod tests;
