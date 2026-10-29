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
mod tests {
    use super::*;

    #[test]
    fn active_text_reads_the_live_screen_while_the_viewport_is_scrolled_back() {
        let mut term = Terminal::new(10, 3, 1_000, Callbacks::default()).unwrap();
        let output: String = (1..=20).map(|line| format!("{line}\r\n")).collect();
        term.vt_write(output.as_bytes());
        let live = term.viewport_text().unwrap();
        assert_eq!(term.active_text().unwrap(), live, "at the live bottom they agree");

        term.scroll_delta(-5);
        assert!(term.scrollbar().unwrap().scrolled_back());
        assert_ne!(term.viewport_text().unwrap(), live, "the viewport shows history");
        assert_eq!(term.active_text().unwrap(), live, "the live screen does not move");
    }
}
