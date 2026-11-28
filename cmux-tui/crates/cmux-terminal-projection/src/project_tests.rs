use super::*;

#[test]
fn locate_follows_a_host_cell_through_the_rewrap() {
    let mut term = Terminal::new(10, 3, 100);
    for &b in b"abcdefghijklmno\r\nxyz" {
        term.advance(b);
    }
    // The host's screen: "abcdefghij" (wrapped), "klmno", "xyz".
    // At 4 columns: abcd efgh ijkl mno xyz: 'j' (host row 3 from the
    // bottom, column 9) is on the row 3 from the bottom, column 1.
    let at = locate(&term, 4, false, 3, 9).unwrap();
    assert_eq!(at, Located { from_bottom: 3, column: 1 });
    // 'm' is on the host's row 2 from the bottom, column 2: phone row
    // "mno", 2 from the bottom, column 0.
    let at = locate(&term, 4, false, 2, 2).unwrap();
    assert_eq!(at, Located { from_bottom: 2, column: 0 });
    assert_eq!(locate(&term, 4, false, 99, 0), None);
    assert_eq!(locate(&term, 4, false, 0, 0), None);
}

#[test]
fn a_line_rewraps_at_the_phone_width() {
    let mut term = Terminal::new(10, 3, 100);
    for &b in b"abcdefghijklmno" {
        term.advance(b);
    }
    let rows: Vec<&Row> = term.primary_rows()[..2].iter().collect();
    let wrapped = wrap_line(&term, &rows, 10, 4, Some((1, 5)), false);
    let text: Vec<String> = wrapped
        .rows
        .iter()
        .map(|r| r.cells.iter().map(|c| char::from_u32(c.ch).unwrap_or(' ')).collect())
        .collect();
    assert_eq!(text, ["abcd", "efgh", "ijkl", "mno"]);
    assert_eq!(wrapped.cursor, Some((3, 3)));
    assert!(wrapped.rows[..3].iter().all(|r| r.wrapped));
}

#[test]
fn a_cursor_past_the_line_and_the_phone_edge_extends_the_line() {
    // A prompt "$ " with the host's cursor at column 90 (a right-side
    // input, a cursor moved right): on a 33-column phone the cursor is
    // on the line's third row, column 24, not clamped to column 32.
    let mut term = Terminal::new(120, 3, 100);
    for &b in b"$ \x1b[91G" {
        term.advance(b);
    }
    let rows: Vec<&Row> = term.primary_rows()[..1].iter().collect();
    let wrapped = wrap_line(&term, &rows, 120, 33, Some((0, 90)), false);
    assert_eq!(wrapped.cursor, Some((2, 24)));
    assert_eq!(wrapped.rows.len(), 3);
    assert!(wrapped.rows[0].wrapped && wrapped.rows[1].wrapped && !wrapped.rows[2].wrapped);
    assert_eq!(wrapped.rows[2].width(), 25, "blanks through the cursor's cell");
    // Within the row: the cursor waits past the content, nothing added.
    let wrapped = wrap_line(&term, &rows, 120, 33, Some((0, 10)), false);
    assert_eq!(wrapped.cursor, Some((0, 10)));
    assert_eq!(wrapped.rows.len(), 1);
    // Exact: the space the prompt printed is a cell of the line, as
    // Ghostty's reflow keeps it (only never-written cells are trimmed).
    assert_eq!(wrapped.rows[0].width(), 2, "the prompt's printed space is kept");
    // Compact too: the shell drawn at the phone's width prints that
    // one space as well (a run of spaces padding the row would go).
    let wrapped = wrap_line(&term, &rows, 120, 33, Some((0, 10)), true);
    assert_eq!(wrapped.cursor, Some((0, 10)));
    assert_eq!(wrapped.rows[0].width(), 2, "the prompt's one trailing space is a cell");
}

#[test]
fn compact_keeps_a_cursor_in_dropped_padding_on_the_line() {
    // A status row cut by a network read inside its padding: 17 glyphs
    // and 40 written spaces, the cursor after them. Compact drops the
    // run and the cursor waits on the line's one row (a second row
    // would scroll the phone, and the rest of the row takes it back
    // only on the Mac). Exact keeps every space and wraps them.
    let mut term = Terminal::new(120, 3, 100);
    for &b in format!("  ? for shortcuts{}", " ".repeat(40)).as_bytes() {
        term.advance(b);
    }
    let rows: Vec<&Row> = term.primary_rows()[..1].iter().collect();
    let wrapped = wrap_line(&term, &rows, 120, 33, Some((0, 57)), true);
    assert_eq!(wrapped.rows.len(), 1);
    assert_eq!(wrapped.cursor, Some((0, 17)));
    let wrapped = wrap_line(&term, &rows, 120, 33, Some((0, 57)), false);
    assert_eq!(wrapped.rows.len(), 2);
}

#[test]
fn a_cursor_after_a_line_that_fills_the_phone_row_is_on_the_next_row() {
    // 54 glyphs on a 54-column phone, the host's cursor right after
    // them: the logical column is 54, the next row's first cell.
    let mut term = Terminal::new(120, 3, 100);
    for _ in 0..54 {
        term.advance(b'x');
    }
    let rows: Vec<&Row> = term.primary_rows()[..1].iter().collect();
    let wrapped = wrap_line(&term, &rows, 120, 54, Some((0, 54)), false);
    assert_eq!(wrapped.cursor, Some((1, 0)));
    assert!(wrapped.rows[0].wrapped);
}

#[test]
fn one_pass_cell_places_match_wrap_line_per_cell() {
    // Every host cell (glyphs, wide glyphs, trailing blanks, cells past
    // the line) lands where a per-cell `wrap_line` puts the cursor.
    let mut term = Terminal::new(12, 4, 100);
    for &b in "ab世界cdefghij界klmno  pq \x1b[11G".as_bytes() {
        term.advance(b);
    }
    let n = term.primary_rows().iter().take_while(|r| r.wrapped).count() + 1;
    let rows: Vec<&Row> = term.primary_rows()[..n].iter().collect();
    let cells: Vec<(usize, usize)> = (0..n).flat_map(|k| (0..12).map(move |x| (k, x))).collect();
    for compact in [false, true] {
        for cols in [3, 4, 5, 7, 12, 30] {
            let places = wrap_line_cells(&term, &rows, 12, cols, compact, &cells);
            for (&(k, x), at) in cells.iter().zip(places) {
                let want = wrap_line(&term, &rows, 12, cols, Some((k, x)), compact).cursor;
                assert_eq!(at, want, "cell ({k}, {x}) at {cols} columns, compact {compact}");
            }
        }
    }
}

#[test]
fn a_wide_glyph_never_splits() {
    let mut term = Terminal::new(10, 3, 100);
    for &b in "ab世界".as_bytes() {
        term.advance(b);
    }
    let rows: Vec<&Row> = term.primary_rows()[..1].iter().collect();
    let wrapped = wrap_line(&term, &rows, 10, 3, None, false);
    assert_eq!(wrapped.rows.len(), 3);
    assert_eq!(wrapped.rows[0].width(), 2);
    assert_eq!(wrapped.rows[1].cells[0].kind, WIDE);
}
