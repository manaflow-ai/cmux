use super::*;

fn term_with(cols: usize, rows: usize, bytes: &str) -> Terminal {
    let mut term = Terminal::new(cols, rows, 1000);
    for &b in bytes.as_bytes() {
        term.advance(b);
    }
    term
}

fn text(row: &ProjectedRow) -> String {
    row.cells.iter().map(|c| char::from_u32(c.ch).filter(|&c| c != '\0').unwrap_or(' ')).collect()
}

#[test]
fn a_word_wrapped_paragraph_wraps_again_at_the_phones_width() {
    let host = 20;
    let term = term_with(host, 5, "⏺ one two three four\r\n  five six seven\r\n");
    let rows: Vec<&Row> = term.primary_rows().iter().take(2).collect();
    assert!(continues(&term, rows[0], rows[1], host));
    let laid = layout(&term, &rows, host, 12, None).unwrap();
    let got: Vec<String> = laid.rows.iter().map(text).collect();
    assert_eq!(got, ["⏺ one two", "  three four", "  five six", "  seven"]);
    assert!(laid.rows.iter().all(|r| !r.wrapped));
}

#[test]
fn a_hard_line_after_a_short_row_stays_its_own() {
    let host = 40;
    let term = term_with(host, 5, "⏺ short\r\n  next line\r\n");
    let rows: Vec<&Row> = term.primary_rows().iter().take(2).collect();
    assert!(!continues(&term, rows[0], rows[1], host));
}

#[test]
fn a_box_keeps_its_borders_at_the_phones_edges() {
    let host = 24;
    let term = term_with(host, 5, "│ > fix the parity now │\r\n");
    let rows: Vec<&Row> = term.primary_rows().iter().take(1).collect();
    let laid = layout(&term, &rows, host, 14, None).unwrap();
    let got: Vec<String> = laid.rows.iter().map(text).collect();
    assert_eq!(got, ["│ > fix the  │", "│   parity   │", "│   now      │"]);
}
