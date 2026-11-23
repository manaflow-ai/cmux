//! A page of styled history (`styled_history_rows`, the daemon's
//! `read-scrollback`) finds each of its rows in the history once, not each
//! cell: a history lookup walks the page list from the top of the history,
//! so a lookup per cell made a page of a long history cost rows x columns
//! walks.

use super::*;
use crate::ColorSpec;

const COLS: u16 = 120;
const ROWS: u16 = 40;

fn line(index: usize) -> String {
    format!("line {index:06} the quick brown fox jumps over the lazy dog")
}

fn long_history(lines: usize) -> Terminal {
    let mut term = Terminal::new(COLS, ROWS, 64 << 20, Callbacks::default()).unwrap();
    for index in 0..lines {
        term.vt_write(format!("\x1b[1;3{}m{}\x1b[0m\r\n", index % 8, line(index)).as_bytes());
    }
    term
}

fn text(row: &[Cell]) -> String {
    row.iter().map(|cell| cell.text.as_str()).collect::<String>().trim_end().to_string()
}

#[test]
fn a_history_page_looks_up_each_row_not_each_cell() {
    let term = long_history(10_000);
    let total = term.history_rows();
    assert!(total >= 9_000, "retained {total} rows");
    let start = total - 3 * u32::from(ROWS);
    HISTORY_GRID_LOOKUPS.with(|lookups| lookups.set(0));
    let page = term.styled_history_rows(start, ROWS).unwrap();
    let lookups = HISTORY_GRID_LOOKUPS.with(std::cell::Cell::get);
    assert_eq!(page.len(), usize::from(ROWS));
    assert!(
        lookups <= 2 * u64::from(ROWS),
        "{lookups} history lookups for a page of {ROWS} rows of {COLS} columns"
    );
    // Every cell is the one at its column: the text, its style and its color.
    let first = text(&term.styled_history_rows(0, 1).unwrap()[0]);
    let first_index: usize = first["line ".len().."line ".len() + 6].parse().unwrap();
    for (offset, row) in page.iter().enumerate() {
        let index = first_index + start as usize + offset;
        assert_eq!(row.len(), usize::from(COLS));
        assert_eq!(text(row), line(index));
        assert!(row[0].bold && row[10].bold);
        assert_eq!(row[0].fg, ColorSpec::Palette((index % 8) as u8));
        assert!(!row[usize::from(COLS) - 1].bold, "the row's end is past the styled text");
    }
}

#[test]
fn a_page_past_the_end_and_an_empty_page_stay_empty() {
    let term = long_history(200);
    let total = term.history_rows();
    assert!(term.styled_history_rows(total, 10).unwrap().is_empty());
    assert!(term.styled_history_rows(0, 0).unwrap().is_empty());
    let tail = term.styled_history_rows(total - 3, 10).unwrap();
    assert_eq!(tail.len(), 3);
}
