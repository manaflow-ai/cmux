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
