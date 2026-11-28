//! Copy-mode reads of the retained screen: one row's cells, the text of a
//! block selection, and a scrollback search. Every read is in screen
//! coordinates (row 0 is the oldest retained row), never moves the viewport,
//! and consumes no render damage.
//!
//! The libghostty-vt pin on this branch has no search API, so the search is
//! a Rust scan (feat-cmux-next calls `ghostty_search_*` instead; a later
//! promotion of feat's engine replaces this file). One read of each row's
//! first cell finds the logical lines. The formatter then reads them in
//! chunks of [`CHUNK_LINES`], one text line per logical line. A chunk whose
//! text cannot hold the needle is skipped. In the other chunks only the
//! lines whose text can hold it are read cell by cell to place the matches;
//! when a chunk's formatter lines do not line up with its logical lines,
//! that chunk alone is read cell by cell. The cost per search is one cell per
//! row, one formatter pass, and the lines (at worst the chunks) that match.

use super::*;
use crate::screen_text::{ScreenRowText, ScreenSearch, ScreenTextCell};

/// Logical lines per formatter read; also the most lines one misaligned
/// read can cost.
const CHUNK_LINES: usize = 64;

/// One character of a logical line and the cell that holds it.
#[derive(Debug, Clone, Copy)]
struct PlacedChar {
    ch: char,
    col: u16,
    row: u32,
}

/// One soft-wrapped logical line of the screen.
#[derive(Debug, Clone, Copy)]
struct LogicalLine {
    top: u32,
    bottom: u32,
    /// The first character of the line's first cell; `None` when that cell
    /// is blank or holds whitespace.
    lead: Option<char>,
}

/// What one search read, for tests that bound its work.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
#[cfg_attr(not(test), allow(dead_code))]
struct ScanStats {
    /// Logical lines read cell by cell.
    precise_lines: usize,
    /// Chunks whose formatter lines did not line up with their logical
    /// lines, so each was read cell by cell.
    fallback_chunks: usize,
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
        let wraps = self.screen_row_wraps(row) == Some(true);
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
        let bytes = self.format(plain_text_options(&selection, false, true)).ok()?;
        Some(String::from_utf8_lossy(&bytes).into_owned())
    }

    /// Find `needle` on the active screen, scrollback included.
    ///
    /// Matching is exact except for ASCII letters, which match in any case
    /// unless `case_sensitive` is set. A match may cross a soft wrap; it
    /// never crosses a hard line break. At most `limit` matches are
    /// returned, the newest kept; the result is ordered top to bottom.
    pub fn search_screen(
        &mut self,
        needle: &str,
        case_sensitive: bool,
        limit: usize,
    ) -> Result<ScreenSearch> {
        Ok(self.search_screen_scan(needle, case_sensitive, limit).0)
    }

    fn search_screen_scan(
        &mut self,
        needle: &str,
        case_sensitive: bool,
        limit: usize,
    ) -> (ScreenSearch, ScanStats) {
        let query = Query {
            text: needle.to_owned(),
            needle: needle.chars().collect(),
            folded: fold(needle.chars(), case_sensitive),
            case_sensitive,
            limit,
        };
        let mut stats = ScanStats::default();
        if query.needle.is_empty() || limit == 0 {
            return (ScreenSearch::default(), stats);
        }
        let total = self.scrollbar().map_or(u64::from(self.rows()), |scrollbar| scrollbar.total);
        let lines = self.logical_lines(total);
        let mut result = ScreenSearch::default();
        let mut codepoints = Vec::new();
        // Newest chunk first, so a full result keeps the newest matches.
        for chunk in lines.chunks(CHUNK_LINES).rev() {
            let texts = self.chunk_texts(chunk);
            if let Some(texts) = &texts
                && !query.may_match(&texts.join("\n"))
            {
                continue;
            }
            let aligned = texts.filter(|texts| lines_align(chunk, texts));
            let mut found = Vec::new();
            let read = aligned.as_deref().and_then(|texts| {
                self.scan_chunk(chunk, Some(texts), &query, &mut found, &mut stats, &mut codepoints)
            });
            if read.is_none() {
                stats.fallback_chunks += 1;
                found.clear();
                self.scan_chunk(chunk, None, &query, &mut found, &mut stats, &mut codepoints);
            }
            // `found` is newest first; keep the newest up to the limit.
            for range in found {
                if result.matches.len() == query.limit {
                    result.truncated = true;
                    break;
                }
                result.matches.push(range);
            }
            if result.truncated {
                break;
            }
        }
        result.matches.sort_by_key(|range| (range.start.row, range.start.column));
        (result, stats)
    }

    /// Read a chunk's candidate lines newest first and push their matches,
    /// newest first, onto `found`. With `texts`, a line is a candidate only
    /// when its formatter text can hold the needle; the chunk's last
    /// formatter line and every line past it are always read, and every
    /// line read must equal its formatter text. `None` means the two
    /// disagree and the caller must read the whole chunk instead. Without
    /// `texts`, every line is read.
    fn scan_chunk(
        &self,
        chunk: &[LogicalLine],
        texts: Option<&[String]>,
        query: &Query,
        found: &mut Vec<SelectionRange>,
        stats: &mut ScanStats,
        codepoints: &mut Vec<u32>,
    ) -> Option<()> {
        let anchor = texts.map_or(0, |texts| texts.len().saturating_sub(1));
        for (index, line) in chunk.iter().enumerate().rev() {
            let expected = texts.map(|texts| texts.get(index));
            if let Some(Some(text)) = expected
                && index != anchor
                && !query.may_match(text)
            {
                continue;
            }
            stats.precise_lines += 1;
            let placed = self.logical_line_chars(line.top, line.bottom, codepoints);
            if let Some(expected) = expected {
                // A line past the formatter's last line must be blank.
                let formatter = expected.map_or(String::new(), |text| fold(text.chars(), true));
                if fold(placed.iter().map(|placed| placed.ch), true) != formatter {
                    return None;
                }
            }
            found.extend(query.find_in(&placed).into_iter().rev());
        }
        Some(())
    }

    /// Every soft-wrapped logical line, top to bottom.
    fn logical_lines(&self, total: u64) -> Vec<LogicalLine> {
        let mut lines = Vec::new();
        let mut codepoints = Vec::new();
        let mut open: Option<LogicalLine> = None;
        for row in 0..total {
            let Ok(row32) = u32::try_from(row) else { break };
            let (wraps, lead) = self.row_head(row, &mut codepoints);
            let line =
                open.get_or_insert(LogicalLine { top: row32, bottom: row32, lead: lead.flatten() });
            line.bottom = row32;
            if wraps != Some(true) || row + 1 == total {
                lines.extend(open.take());
            }
        }
        lines
    }

    /// The formatter's plain text of each logical line of a chunk, top to
    /// bottom, with trailing blanks trimmed. Trailing blank lines are left
    /// out. `None` when the formatter cannot read the chunk.
    fn chunk_texts(&mut self, chunk: &[LogicalLine]) -> Option<Vec<String>> {
        let (first, last) = (chunk.first()?, chunk.last()?);
        let tag = sys::GHOSTTY_POINT_TAG_SCREEN;
        let selection = sys::GhosttySelection {
            size: size_of::<sys::GhosttySelection>(),
            start: self.grid_ref(tag, 0, u64::from(first.top))?,
            end: self.grid_ref(tag, self.cols().saturating_sub(1), u64::from(last.bottom))?,
            rectangle: false,
        };
        let bytes = self.format(plain_text_options(&selection, true, true)).ok()?;
        let text = String::from_utf8_lossy(&bytes);
        let mut texts: Vec<String> = text.split('\n').map(str::to_owned).collect();
        while texts.last().is_some_and(|text| text.chars().all(char::is_whitespace)) {
            texts.pop();
        }
        Some(texts)
    }

    /// The characters of rows `top..=bottom` and their cells. A blank cell
    /// reads as a space, a wide grapheme's spacers are skipped, and the
    /// line's trailing blanks are dropped.
    fn logical_line_chars(
        &self,
        top: u32,
        bottom: u32,
        codepoints: &mut Vec<u32>,
    ) -> Vec<PlacedChar> {
        let cols = self.cols();
        let mut placed = Vec::new();
        for row in top..=bottom {
            for col in 0..cols {
                let Some(grid_ref) =
                    self.grid_ref(sys::GHOSTTY_POINT_TAG_SCREEN, col, u64::from(row))
                else {
                    break;
                };
                let mut raw = sys::GhosttyCell::default();
                if check(unsafe { sys::ghostty_grid_ref_cell(&grid_ref, &mut raw) }).is_err() {
                    continue;
                }
                if matches!(
                    crate::render::cell_width(raw),
                    CellWidth::SpacerTail | CellWidth::SpacerHead
                ) {
                    continue;
                }
                let text = grid_ref_text(&grid_ref, codepoints).unwrap_or_default();
                if text.is_empty() {
                    placed.push(PlacedChar { ch: ' ', col, row });
                } else {
                    placed.extend(text.chars().map(|ch| PlacedChar { ch, col, row }));
                }
            }
        }
        while placed.last().is_some_and(|placed| placed.ch.is_whitespace()) {
            placed.pop();
        }
        placed
    }

    /// A row's soft-wrap flag and the first character of its first cell
    /// (`Some(None)` for a blank or whitespace cell), from one grid
    /// reference.
    fn row_head(
        &self,
        row: u64,
        codepoints: &mut Vec<u32>,
    ) -> (Option<bool>, Option<Option<char>>) {
        let Some(grid_ref) = self.grid_ref(sys::GHOSTTY_POINT_TAG_SCREEN, 0, row) else {
            return (None, None);
        };
        let lead = grid_ref_text(&grid_ref, codepoints)
            .map(|text| text.chars().next().filter(|ch| !ch.is_whitespace()));
        (grid_ref_wraps(&grid_ref), lead)
    }

    /// Whether a screen row soft-wraps into the next one.
    fn screen_row_wraps(&self, row: u64) -> Option<bool> {
        grid_ref_wraps(&self.grid_ref(sys::GHOSTTY_POINT_TAG_SCREEN, 0, row)?)
    }
}

/// Text with whitespace removed and, unless `case_sensitive`, ASCII letters
/// lowercased: the form in which a formatter line and a needle are compared.
fn fold(chars: impl Iterator<Item = char>, case_sensitive: bool) -> String {
    chars
        .filter(|ch| !ch.is_whitespace())
        .map(|ch| if case_sensitive { ch } else { ch.to_ascii_lowercase() })
        .collect()
}

/// Whether the row under a grid reference soft-wraps into the next one.
fn grid_ref_wraps(grid_ref: &sys::GhosttyGridRef) -> Option<bool> {
    let mut raw_row = sys::GhosttyRow::default();
    check(unsafe { sys::ghostty_grid_ref_row(grid_ref, &mut raw_row) }).ok()?;
    let mut wraps = false;
    check(unsafe {
        sys::ghostty_row_get(raw_row, sys::GHOSTTY_ROW_DATA_WRAP, (&mut wraps as *mut bool).cast())
    })
    .ok()?;
    Some(wraps)
}

/// Whether the formatter lines can belong to the logical lines one to one:
/// no more formatter lines than logical lines, and each line whose first
/// cell holds a character has a formatter line that starts with it. A line
/// whose first cell is blank or whitespace may start with anything, because
/// the formatter may or may not write leading blanks.
fn lines_align(lines: &[LogicalLine], texts: &[String]) -> bool {
    texts.len() <= lines.len()
        && lines.iter().enumerate().all(|(index, line)| {
            let first = texts.get(index).and_then(|text| text.chars().next());
            line.lead.is_none_or(|lead| first == Some(lead))
        })
}

/// One search: the needle as typed and in folded form, and its limits.
struct Query {
    /// The needle as typed.
    text: String,
    needle: Vec<char>,
    /// The needle as [`fold`] writes it, to test formatter lines.
    folded: String,
    case_sensitive: bool,
    limit: usize,
}

impl Query {
    /// Whether a formatter line can hold a match. Folding keeps substrings,
    /// so this never drops a line that holds one. A needle of only
    /// whitespace is looked for as typed: the formatter keeps the blanks
    /// inside a line.
    fn may_match(&self, text: &str) -> bool {
        if self.folded.is_empty() {
            text.contains(self.text.as_str())
        } else {
            fold(text.chars(), self.case_sensitive).contains(self.folded.as_str())
        }
    }

    /// Non-overlapping matches of the needle in one logical line, left to
    /// right.
    fn find_in(&self, placed: &[PlacedChar]) -> Vec<SelectionRange> {
        let same =
            |a: char, b: char| a == b || (!self.case_sensitive && a.eq_ignore_ascii_case(&b));
        let mut found = Vec::new();
        let mut start = 0;
        while let Some(window) = placed.get(start..start + self.needle.len()) {
            if window.iter().zip(&self.needle).all(|(placed, &ch)| same(placed.ch, ch)) {
                if let (Some(first), Some(last)) = (window.first(), window.last()) {
                    found.push(SelectionRange {
                        start: SelectionPoint { column: first.col, row: first.row },
                        end: SelectionPoint { column: last.col, row: last.row },
                    });
                }
                start += self.needle.len();
            } else {
                start += 1;
            }
        }
        found
    }
}

fn plain_text_options(
    selection: *const sys::GhosttySelection,
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

    #[test]
    fn copy_mode_search_screen_places_matches_after_blank_rows_and_wide_cells() {
        // Blank rows, a wide grapheme, a soft wrap, and spaces inside a line
        // must leave the formatter lines aligned with the logical lines.
        let mut term = terminal(6, 4, "one\r\n\r\n\r\n橋 two\r\nabcdefghij\r\nx  needle\r\n");
        let (found, stats) = term.search_screen_scan("needle", false, 10);
        assert_eq!(stats.fallback_chunks, 0, "the formatter lines must line up: {stats:?}");
        assert_eq!(found.matches.len(), 1);
        let range = found.matches[0];
        let first = term.screen_row_text(u64::from(range.start.row)).unwrap();
        assert_eq!(first.cells[usize::from(range.start.column)].text, "n");
        let last = term.screen_row_text(u64::from(range.end.row)).unwrap();
        assert_eq!(last.cells[usize::from(range.end.column)].text, "e");

        let (wide, stats) = term.search_screen_scan("橋 TWO", false, 10);
        assert_eq!(stats.fallback_chunks, 0, "{stats:?}");
        assert_eq!(wide.matches.len(), 1);
        assert_eq!(wide.matches[0].start.column, 0);
        assert_eq!(wide.matches[0].end.column, 5, "the match ends on the `o` after the wide cell");

        assert!(term.search_screen("橋 TWO", true, 10).unwrap().matches.is_empty());
        assert_eq!(term.search_screen("cdefgh", false, 10).unwrap().matches.len(), 1);
        assert!(term.search_screen("one two", false, 10).unwrap().matches.is_empty());
    }

    #[test]
    fn copy_mode_search_screen_reads_only_matching_lines_of_a_large_scrollback() {
        let mut term = Terminal::new(40, 10, 50_000_000, Callbacks::default()).unwrap();
        let lines: String = (0..20_000).map(|n| format!("row {n:05} of output\r\n")).collect();
        term.vt_write(lines.as_bytes());
        assert!(term.history_rows() > 19_000, "the fixture must fill a large scrollback");

        // Only the matching line and its chunk's last line (the alignment
        // anchor) are read cell by cell; every other chunk is skipped.
        let (found, stats) = term.search_screen_scan("row 12345", false, 10_000);
        assert_eq!(found.matches.len(), 1);
        assert_eq!(stats.fallback_chunks, 0, "{stats:?}");
        assert!(stats.precise_lines <= 2, "{stats:?}");

        let (none, stats) = term.search_screen_scan("absent needle", false, 10_000);
        assert!(none.matches.is_empty());
        assert_eq!(stats, ScanStats::default(), "no line is read cell by cell");
    }

    #[test]
    fn copy_mode_search_screen_finds_matches_below_leading_blank_rows() {
        // Whether the formatter keeps blank rows above the first output
        // decides the path; a misaligned chunk costs at most CHUNK_LINES.
        let mut term = terminal(10, 6, "\x1b[3;1H   indented foo\r\nbar\r\n");
        let (found, stats) = term.search_screen_scan("foo", false, 10);
        assert!(stats.precise_lines <= CHUNK_LINES, "{stats:?}");
        assert_eq!(found.matches.len(), 1);
        let range = found.matches[0];
        assert_eq!((range.start.row, range.start.column), (3, 2));
        assert_eq!((range.end.row, range.end.column), (3, 4));
    }

    #[test]
    fn copy_mode_search_screen_keeps_alignment_over_space_lines_and_indents() {
        for text in ["a\r\n    \r\nb\r\n", "a\r\n    "] {
            let mut term = terminal(20, 4, text);
            let (found, stats) = term.search_screen_scan("a", false, 10);
            assert_eq!(stats.fallback_chunks, 0, "{text:?}: {stats:?}");
            assert_eq!(found.matches.len(), 1, "{text:?}");
        }
        // Blank cells that hold no text: a tab stop and a cursor move.
        for (text, column) in [("\tfoo\r\n", 8), ("\x1b[5Gfoo\r\n", 4)] {
            let mut term = terminal(20, 4, text);
            let (found, stats) = term.search_screen_scan("foo", false, 10);
            assert_eq!(stats.fallback_chunks, 0, "{text:?}: {stats:?}");
            assert_eq!(found.matches.len(), 1, "{text:?}");
            let range = found.matches[0];
            assert_eq!((range.start.row, range.start.column), (0, column), "{text:?}");
            assert_eq!((range.end.row, range.end.column), (0, column + 2), "{text:?}");
        }
    }

    #[test]
    fn copy_mode_search_screen_finds_a_whitespace_needle_without_reading_every_line() {
        let mut term = terminal(20, 4, "a  b\r\ncd\r\n");
        let (found, stats) = term.search_screen_scan("  ", false, 10);
        assert_eq!(stats.fallback_chunks, 0, "{stats:?}");
        assert_eq!(found.matches.len(), 1);
        let range = found.matches[0];
        assert_eq!((range.start.row, range.start.column), (0, 1));
        assert_eq!((range.end.row, range.end.column), (0, 2));
    }

    #[test]
    fn copy_mode_search_screen_handles_an_erased_row_after_a_soft_wrap() {
        // Row 0 keeps its wrap flag while the row it wrapped into is erased.
        // The test checks the matches, not the path: if the formatter splits
        // this logical line, the chunk is read cell by cell.
        let mut term = terminal(4, 4, "abcdefgh\x1b[2K\r\nxyz");
        let found = term.search_screen("abcd", false, 10).unwrap();
        assert_eq!(found.matches.len(), 1);
        let range = found.matches[0];
        assert_eq!((range.start.row, range.start.column), (0, 0));
        assert_eq!((range.end.row, range.end.column), (0, 3));
        assert!(term.search_screen("efgh", false, 10).unwrap().matches.is_empty());
        assert_eq!(term.search_screen("xyz", false, 10).unwrap().matches.len(), 1);
    }
}
