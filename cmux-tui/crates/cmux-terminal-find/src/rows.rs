//! Matches in a terminal's rows, in screen coordinates (row 0 is the oldest retained row).

use std::collections::VecDeque;

use serde::{Deserialize, Serialize};

use crate::lines::snippet;
use crate::matcher::Matcher;

/// A cell's part in a grapheme, as Ghostty reports it (`ghostty_vt::CellWidth`).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CellRole {
    /// A one-column cell.
    #[default]
    Narrow,
    /// The first cell of a two-column grapheme.
    Wide,
    /// The second cell of a two-column grapheme: no text of its own.
    SpacerTail,
    /// The blank a wide grapheme leaves at a row's end when it wraps to the next row.
    SpacerHead,
}

/// One cell: its grapheme (empty for a blank) and its role.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Cell {
    pub text: String,
    pub role: CellRole,
}

/// One row: a cell per column, and whether its text continues on the next row (a soft wrap).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct RowCells {
    pub cells: Vec<Cell>,
    pub wraps: bool,
}

/// A cell in screen coordinates.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct ScreenPoint {
    pub row: u64,
    pub column: u16,
}

/// One match: the cells it covers (inclusive at both ends, `start` never after `end`) and a
/// snippet of its line, with the match's place in the snippet in UTF-16 units (what AppKit and
/// UIKit attributed strings index by).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ScreenMatch {
    pub start: ScreenPoint,
    pub end: ScreenPoint,
    pub snippet: String,
    pub snippet_start: u32,
    pub snippet_len: u32,
}

/// One page of a find, newest match first.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Page {
    /// Newest first: bottom row first, and right to left within a row.
    pub matches: Vec<ScreenMatch>,
    /// Where the next page starts (pass it as `before`): the first row of the oldest line this
    /// page searched. `None` once row 0 was searched.
    pub next_before: Option<u64>,
    /// Rows this page read.
    pub scanned_rows: u64,
    /// The rows changed under the find (`fetch` returned fewer rows than asked: the oldest
    /// were dropped); the page stops at what it could read and the find is complete.
    pub interrupted: bool,
}

/// One cell's place in a logical line's text.
struct Span {
    byte: usize,
    row: u64,
    column: u16,
    width: u16,
}

/// Searches the rows above `before` (exclusive), bottom up, until about `row_budget` rows were
/// read or `max_matches` matches found, always finishing the logical line it is in.
///
/// `fetch(start, end)` returns rows `start..end` top to bottom, reading `chunk` rows at a time,
/// so a caller holds the terminal's lock for one chunk and never for the whole search.
pub fn scan_page(
    matcher: &Matcher,
    before: u64,
    row_budget: u64,
    max_matches: usize,
    chunk: u64,
    mut fetch: impl FnMut(u64, u64) -> Vec<RowCells>,
) -> Page {
    let chunk = chunk.max(1);
    let mut page = Page::default();
    // The rows of the line being assembled, top to bottom, and the first one's row number.
    let mut pending: VecDeque<RowCells> = VecDeque::new();
    let mut pending_top = before;
    let mut cursor = before;
    while cursor > 0 {
        let start = cursor.saturating_sub(chunk);
        let rows = fetch(start, cursor);
        let expected = usize::try_from(cursor - start).unwrap_or(usize::MAX);
        let complete = rows.len() == expected;
        // A short read lost its oldest rows: keep the newest ones it has.
        let first = cursor - rows.len() as u64;
        page.scanned_rows += rows.len() as u64;
        for (offset, row) in rows.into_iter().enumerate().rev() {
            let number = first + offset as u64;
            if !row.wraps && !pending.is_empty() {
                // `row` ends a line, so the pending one (from `number + 1`) is whole.
                search_line(matcher, &pending, pending_top, &mut page.matches);
                pending.clear();
                if before - pending_top >= row_budget || page.matches.len() >= max_matches {
                    page.next_before = Some(pending_top);
                    return page;
                }
            }
            pending.push_front(row);
            pending_top = number;
        }
        if !complete {
            page.interrupted = true;
            search_line(matcher, &pending, pending_top, &mut page.matches);
            // The rows above were evicted (eviction takes the oldest first), so nothing is left
            // to search: a cursor here would read zero rows and come back forever.
            page.next_before = None;
            return page;
        }
        cursor = start;
    }
    search_line(matcher, &pending, pending_top, &mut page.matches);
    page
}

/// Appends the matches of one logical line (its rows top to bottom, the first at `top`),
/// rightmost first.
fn search_line(matcher: &Matcher, rows: &VecDeque<RowCells>, top: u64, out: &mut Vec<ScreenMatch>) {
    if rows.is_empty() {
        return;
    }
    let mut text = String::new();
    let mut spans = Vec::new();
    let last = rows.len() - 1;
    for (index, row) in rows.iter().enumerate() {
        // A line's last row ends at its last drawn cell; a wrapped row runs to its edge.
        let end = if index == last {
            row.cells
                .iter()
                .rposition(|cell| {
                    !cell.text.is_empty() && !cell.text.chars().all(char::is_whitespace)
                })
                .map_or(0, |at| at + 1)
        } else {
            row.cells.len()
        };
        for (column, cell) in row.cells.iter().enumerate().take(end) {
            let width = match cell.role {
                CellRole::SpacerTail | CellRole::SpacerHead => continue,
                CellRole::Wide => 2,
                CellRole::Narrow => 1,
            };
            spans.push(Span {
                byte: text.len(),
                row: top + index as u64,
                column: u16::try_from(column).unwrap_or(u16::MAX),
                width,
            });
            text.push_str(if cell.text.is_empty() { " " } else { &cell.text });
        }
    }
    if spans.is_empty() {
        return;
    }
    let found: Vec<(usize, usize)> = matcher.ranges(&text).collect();
    for &(start, end) in found.iter().rev() {
        let first = &spans[spans.partition_point(|span| span.byte <= start) - 1];
        let final_span = &spans[spans.partition_point(|span| span.byte < end) - 1];
        let (snippet, snippet_start, snippet_len) = snippet(&text, start, end);
        out.push(ScreenMatch {
            start: ScreenPoint { row: first.row, column: first.column },
            end: ScreenPoint {
                row: final_span.row,
                column: final_span.column.saturating_add(final_span.width - 1),
            },
            snippet,
            snippet_start,
            snippet_len,
        });
    }
}
