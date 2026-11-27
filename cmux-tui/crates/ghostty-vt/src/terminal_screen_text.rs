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

    /// The styled cells of one screen row (row 0 is the oldest retained
    /// row), whether each cell carries an OSC 8 hyperlink, and the row's
    /// soft-wrap flag; `None` past the last retained row. The projection
    /// parity harness reads the Mac's grid with it.
    pub fn styled_screen_row(&self, row: u64) -> Option<(Vec<Cell>, Vec<bool>, bool)> {
        let cols = self.cols();
        let tag = sys::GHOSTTY_POINT_TAG_SCREEN;
        let first = self.grid_ref(tag, 0, row)?;
        let palette = terminal_palette(self.raw, sys::GHOSTTY_TERMINAL_DATA_COLOR_PALETTE).ok()?;
        // One page-list walk for the row when both ends land on the same
        // page row (see `styled_history_rows`).
        let whole_row = cols == 1
            || self.grid_ref(tag, cols - 1, row).is_some_and(|last| {
                last.node == first.node && last.y == first.y && last.x == cols - 1
            });
        let mut grapheme_buf = Vec::new();
        let mut cells = Vec::with_capacity(usize::from(cols));
        let mut links = Vec::with_capacity(usize::from(cols));
        for x in 0..cols {
            let grid_ref = if whole_row {
                sys::GhosttyGridRef { x, ..first }
            } else {
                self.grid_ref(tag, x, row)?
            };
            cells.push(read_grid_ref_cell(&grid_ref, &palette, &mut grapheme_buf).ok()?);
            let mut raw = sys::GhosttyCell::default();
            check(unsafe { sys::ghostty_grid_ref_cell(&grid_ref, &mut raw) }).ok()?;
            let mut link = false;
            let read = unsafe {
                sys::ghostty_cell_get(
                    raw,
                    sys::GHOSTTY_CELL_DATA_HAS_HYPERLINK,
                    (&mut link as *mut bool).cast(),
                )
            };
            links.push(read == sys::GHOSTTY_SUCCESS && link);
        }
        let wraps = self.row_flag(tag, row, sys::GHOSTTY_ROW_DATA_WRAP) == Some(true);
        Some((cells, links, wraps))
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
    let empty = sys::GhosttySelection::default();
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
) -> FormatterTerminalOptions {
    FormatterTerminalOptions {
        emit: sys::GHOSTTY_FORMATTER_FORMAT_PLAIN,
        unwrap,
        trim,
        extra: FormatterTerminalExtra { ..Default::default() },
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
#[path = "terminal_screen_text_tests.rs"]
mod tests;
