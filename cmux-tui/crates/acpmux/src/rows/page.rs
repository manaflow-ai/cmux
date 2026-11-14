//! Byte-capped pages of a row table, by the `seq` that began each row (`_acpmux/rows`), as
//! `hub/paging.rs` pages the log. Rows rise in `seq` with their place, so a page is a binary
//! search and a walk over the rows it holds, never over the chat.

use serde::{Deserialize, Serialize};

use super::fold::{Row, RowTable};

/// A page's byte limit when the reader names none.
pub const DEFAULT_ROW_PAGE_BYTES: usize = 256 << 10;
/// The most a reader may name: every reply under 1 MiB (cmux#41559).
pub const MAX_ROW_PAGE_BYTES: usize = 1 << 20;

/// Where a page starts.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RowsCursor {
    /// The rows begun after this seq, oldest first.
    After(u64),
    /// The rows begun before this seq: the newest of them, still in order.
    Before(u64),
}

/// A row whose text alone passes the page's limit goes with its text cut; this says how long the
/// whole text is.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CutRow {
    pub index: u64,
    pub text_bytes: u64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RowPage {
    /// In table order.
    pub rows: Vec<Row>,
    /// More rows past the page in the direction read.
    pub has_more: bool,
    /// The table's version when read: live patches after it (`v > version`) follow this page.
    pub version: u64,
    /// How many rows the table holds.
    pub count: u64,
    /// The newest record folded.
    pub last_seq: u64,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub cut: Vec<CutRow>,
}

/// About what `row` adds to a page's JSON.
fn row_bytes(row: &Row) -> usize {
    serde_json::to_vec(row).map_or(usize::MAX, |json| json.len().saturating_add(1))
}

/// `row` with its text cut so the row fits in `max` bytes, at a char boundary.
fn cut_to(row: &Row, max: usize) -> Row {
    let head = Row { head: row.head.clone(), text: String::new() };
    let room = max.saturating_sub(row_bytes(&head).saturating_add(2));
    // JSON escapes can make a byte of text up to six; leave room for the worst.
    let mut end = room.checked_div(6).unwrap_or(0).min(row.text.len());
    while end > 0 && !row.text.is_char_boundary(end) {
        end = end.saturating_sub(1);
    }
    Row { head: row.head.clone(), text: row.text.get(..end).unwrap_or_default().to_owned() }
}

impl RowTable {
    /// One page from `cursor`, its rows' JSON at most `max_bytes` (clamped to
    /// [`MAX_ROW_PAGE_BYTES`]); a page holds at least one row when any is there.
    pub fn page(&self, cursor: RowsCursor, max_bytes: usize) -> RowPage {
        let max = max_bytes.clamp(1, MAX_ROW_PAGE_BYTES);
        let rows = self.rows();
        let mut page = RowPage {
            rows: Vec::new(),
            has_more: false,
            version: self.version(),
            count: rows.len() as u64,
            last_seq: self.last_seq(),
            cut: Vec::new(),
        };
        let mut bytes = 0usize;
        // Whether `row` went into the page: the first row always does, cut to fit if it must.
        let mut take = |row: &Row, page: &mut RowPage| -> bool {
            let size = row_bytes(row);
            if page.rows.is_empty() && size > max {
                page.cut.push(CutRow { index: row.head.index, text_bytes: row.text.len() as u64 });
                page.rows.push(cut_to(row, max));
                bytes = max;
                return true;
            }
            if bytes.saturating_add(size) > max {
                return false;
            }
            bytes = bytes.saturating_add(size);
            page.rows.push(row.clone());
            true
        };
        let order: Box<dyn Iterator<Item = &Row>> = match cursor {
            RowsCursor::After(seq) => {
                let from = rows.partition_point(|r| r.head.seq <= seq);
                Box::new(rows.get(from..).unwrap_or_default().iter())
            }
            RowsCursor::Before(seq) => {
                let to = rows.partition_point(|r| r.head.seq < seq);
                Box::new(rows.get(..to).unwrap_or_default().iter().rev())
            }
        };
        for row in order {
            if !take(row, &mut page) {
                page.has_more = true;
                break;
            }
        }
        if matches!(cursor, RowsCursor::Before(_)) {
            page.rows.reverse();
        }
        page
    }
}
