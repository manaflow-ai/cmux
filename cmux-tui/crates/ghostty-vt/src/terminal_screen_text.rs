//! Copy-mode reads of the retained screen: one row's cells, the text of a
//! block selection, and a scrollback search through libghostty-vt's search
//! API. Every read is in screen coordinates (row 0 is the oldest retained
//! row), never moves the viewport, and consumes no render damage.

use super::*;
use crate::screen_text::{ScreenRowText, ScreenSearch, ScreenTextCell};

/// Owns one `GhosttySearch` for the length of a single read. Dropping it
/// frees the search while the caller still holds the terminal exclusively.
struct SearchHandle(sys::GhosttySearch);

impl Drop for SearchHandle {
    fn drop(&mut self) {
        unsafe { sys::ghostty_search_free(self.0) };
    }
}

impl Terminal {
    /// The cells of one screen row and its soft-wrap flag, or `None` past
    /// the last retained row.
    pub fn screen_row_text(&self, row: u64) -> Option<ScreenRowText> {
        let cols = self.cols();
        if cols == 0 {
            return None;
        }
        let mut cells = Vec::with_capacity(usize::from(cols));
        let mut codepoints = Vec::new();
        for column in 0..cols {
            let grid_ref = self.grid_ref(sys::GHOSTTY_POINT_TAG_SCREEN, column, row)?;
            let mut raw = sys::GhosttyCell::default();
            check(unsafe { sys::ghostty_grid_ref_cell(&grid_ref, &mut raw) }).ok()?;
            let width = crate::render::cell_width(raw);
            let text = grid_ref_text(&grid_ref, &mut codepoints)?;
            cells.push(ScreenTextCell { text, width });
        }
        let wraps = self.row_flag(sys::GHOSTTY_POINT_TAG_SCREEN, row, sys::GHOSTTY_ROW_DATA_WRAP)
            == Some(true);
        Some(ScreenRowText { cells, wraps })
    }

    /// Plain text of the rectangle spanned by two absolute screen points
    /// (inclusive), one line per row with trailing blanks trimmed.
    pub fn block_selection_text_absolute(
        &mut self,
        start: (u16, u64),
        end: (u16, u64),
    ) -> Option<String> {
        let (left, right) = (start.0.min(end.0), start.0.max(end.0));
        let (top, bottom) = (start.1.min(end.1), start.1.max(end.1));
        let tag = sys::GHOSTTY_POINT_TAG_SCREEN;
        let selection = sys::GhosttySelection {
            size: size_of::<sys::GhosttySelection>(),
            start: self.grid_ref(tag, left, top)?,
            end: self.grid_ref(tag, right, bottom)?,
            rectangle: true,
        };
        let bytes = self.format(plain_selection_options(&selection, false, true)).ok()?;
        Some(String::from_utf8_lossy(&bytes).into_owned())
    }

    /// Find `needle` on the active screen, scrollback included.
    ///
    /// libghostty-vt matches bytes exactly except ASCII letters, which it
    /// compares case-insensitively. With `case_sensitive`, a match is kept
    /// only when its text equals `needle` exactly. At most `limit` matches
    /// are returned, the newest first kept; the result is ordered top to
    /// bottom.
    pub fn search_screen(
        &mut self,
        needle: &str,
        case_sensitive: bool,
        limit: usize,
    ) -> Result<ScreenSearch> {
        if needle.is_empty() || limit == 0 {
            return Ok(ScreenSearch::default());
        }
        let mut raw: sys::GhosttySearch = ptr::null_mut();
        check(unsafe { sys::ghostty_search_new(ptr::null(), &mut raw, self.raw) })?;
        let search = SearchHandle(raw);
        let value = sys::GhosttyString { ptr: needle.as_ptr(), len: needle.len() };
        check(unsafe {
            sys::ghostty_search_set(
                search.0,
                sys::GHOSTTY_SEARCH_OPT_NEEDLE,
                (&value as *const sys::GhosttyString).cast(),
            )
        })?;
        check(unsafe { sys::ghostty_search_run(search.0) })?;
        let selections = search_matches(&search)?;
        let mut result = ScreenSearch::default();
        // Matches arrive newest first, so a full result keeps the newest.
        for selection in &selections {
            if case_sensitive {
                let text = self.format(plain_selection_options(selection, true, false))?;
                if text != needle.as_bytes() {
                    continue;
                }
            }
            if result.matches.len() == limit {
                result.truncated = true;
                break;
            }
            let range = self.selection_range(selection)?;
            let ordered =
                if (range.end.row, range.end.column) < (range.start.row, range.start.column) {
                    SelectionRange { start: range.end, end: range.start }
                } else {
                    range
                };
            result.matches.push(ordered);
        }
        drop(search);
        result.matches.sort_by_key(|range| (range.start.row, range.start.column));
        Ok(result)
    }
}

/// Every match of a finished search, newest first.
fn search_matches(search: &SearchHandle) -> Result<Vec<sys::GhosttySelection>> {
    let mut buffer = sys::GhosttySelectionBuffer { ptr: ptr::null_mut(), cap: 0, len: 0 };
    let query = unsafe {
        sys::ghostty_search_get(
            search.0,
            sys::GHOSTTY_SEARCH_DATA_MATCHES,
            (&mut buffer as *mut sys::GhosttySelectionBuffer).cast(),
        )
    };
    let needed = match query {
        sys::GHOSTTY_SUCCESS => return Ok(Vec::new()),
        sys::GHOSTTY_OUT_OF_SPACE => buffer.len,
        other => {
            check(other)?;
            return Ok(Vec::new());
        }
    };
    let empty =
        sys::GhosttySelection { size: size_of::<sys::GhosttySelection>(), ..Default::default() };
    let mut selections = vec![empty; needed];
    let mut buffer =
        sys::GhosttySelectionBuffer { ptr: selections.as_mut_ptr(), cap: selections.len(), len: 0 };
    check(unsafe {
        sys::ghostty_search_get(
            search.0,
            sys::GHOSTTY_SEARCH_DATA_MATCHES,
            (&mut buffer as *mut sys::GhosttySelectionBuffer).cast(),
        )
    })?;
    selections.truncate(buffer.len);
    Ok(selections)
}

fn plain_selection_options(
    selection: &sys::GhosttySelection,
    unwrap: bool,
    trim: bool,
) -> sys::GhosttyFormatterTerminalOptions {
    sys::GhosttyFormatterTerminalOptions {
        size: size_of::<sys::GhosttyFormatterTerminalOptions>(),
        emit: sys::GHOSTTY_FORMATTER_FORMAT_PLAIN,
        unwrap,
        trim,
        extra: sys::GhosttyFormatterTerminalExtra {
            size: size_of::<sys::GhosttyFormatterTerminalExtra>(),
            ..Default::default()
        },
        selection,
    }
}

/// The grapheme cluster at a grid reference; empty for a blank cell.
fn grid_ref_text(grid_ref: &sys::GhosttyGridRef, codepoints: &mut Vec<u32>) -> Option<String> {
    let mut len = 0usize;
    let query = unsafe { sys::ghostty_grid_ref_graphemes(grid_ref, ptr::null_mut(), 0, &mut len) };
    if query != sys::GHOSTTY_SUCCESS && query != sys::GHOSTTY_OUT_OF_SPACE {
        return None;
    }
    if len == 0 {
        return Some(String::new());
    }
    codepoints.clear();
    codepoints.resize(len, 0);
    check(unsafe {
        sys::ghostty_grid_ref_graphemes(
            grid_ref,
            codepoints.as_mut_ptr(),
            codepoints.len(),
            &mut len,
        )
    })
    .ok()?;
    Some(codepoints.iter().take(len).map(|&cp| char::from_u32(cp).unwrap_or('\u{FFFD}')).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn terminal(cols: u16, rows: u16, text: &str) -> Terminal {
        let mut term = Terminal::new(cols, rows, 1_000_000, Callbacks::default()).unwrap();
        term.vt_write(text.as_bytes());
        term
    }

    fn row_text(term: &Terminal, row: u64) -> String {
        term.screen_row_text(row).unwrap().cells.iter().map(|cell| cell.text.as_str()).collect()
    }

    #[test]
    fn copy_mode_screen_row_text_reports_wide_cells_and_soft_wraps() {
        let term = terminal(4, 3, "ABC橋D");
        let first = term.screen_row_text(0).unwrap();
        assert!(first.wraps, "a row that overflowed must report its soft wrap");
        assert_eq!(first.cells[3].width, CellWidth::SpacerHead);
        let second = term.screen_row_text(1).unwrap();
        assert!(!second.wraps);
        assert_eq!(second.cells[0].text, "橋");
        assert_eq!(second.cells[0].width, CellWidth::Wide);
        assert_eq!(second.cells[1].width, CellWidth::SpacerTail);
        assert_eq!(second.cells[2].text, "D");
        assert_eq!(row_text(&term, 0), "ABC");
        assert!(term.screen_row_text(999).is_none());
    }

    #[test]
    fn copy_mode_search_screen_covers_scrollback_and_filters_case() {
        let lines: String = (0..40).map(|n| format!("Foo foo {n:02}\r\n")).collect();
        let mut term = terminal(30, 5, &lines);
        assert!(term.history_rows() > 0, "the fixture must reach scrollback");

        let insensitive = term.search_screen("foo", false, 1_000).unwrap();
        assert_eq!(insensitive.matches.len(), 80);
        assert!(!insensitive.truncated);
        let first = insensitive.matches[0];
        assert_eq!((first.start.row, first.start.column), (0, 0));
        assert_eq!((first.end.row, first.end.column), (0, 2));
        assert!(insensitive.matches.windows(2).all(|pair| {
            (pair[0].start.row, pair[0].start.column) < (pair[1].start.row, pair[1].start.column)
        }));

        let sensitive = term.search_screen("Foo", true, 1_000).unwrap();
        assert_eq!(sensitive.matches.len(), 40);
        assert!(sensitive.matches.iter().all(|range| range.start.column == 0));

        let limited = term.search_screen("foo", false, 3).unwrap();
        assert!(limited.truncated);
        assert_eq!(limited.matches.len(), 3);
        assert_eq!(limited.matches[2].start.row, 39, "the limit keeps the newest matches");

        assert!(term.search_screen("absent", false, 10).unwrap().matches.is_empty());
    }

    #[test]
    fn copy_mode_search_screen_matches_across_a_soft_wrap() {
        let mut term = terminal(4, 3, "xxabcdyy");
        let found = term.search_screen("abcd", false, 10).unwrap();
        assert_eq!(found.matches.len(), 1);
        let range = found.matches[0];
        assert_eq!((range.start.row, range.start.column), (0, 2));
        assert_eq!((range.end.row, range.end.column), (1, 1));
    }

    #[test]
    fn copy_mode_block_selection_text_cuts_columns() {
        let mut term = terminal(10, 4, "abcdef\r\nghijkl\r\nmnopqr");
        assert_eq!(
            term.block_selection_text_absolute((3, 2), (1, 0)).as_deref(),
            Some("bcd\nhij\nnop")
        );
    }
}
