use super::*;

/// Rows of `cols` narrow cells from `text`, soft-wrapping like a terminal; `\n` ends a line.
fn screen(text: &str, cols: usize) -> Vec<RowCells> {
    let mut rows = Vec::new();
    for line in text.split('\n') {
        let chars: Vec<char> = line.chars().collect();
        let pieces: Vec<&[char]> =
            if chars.is_empty() { vec![&[][..]] } else { chars.chunks(cols).collect() };
        let count = pieces.len();
        for (index, piece) in pieces.into_iter().enumerate() {
            let mut cells: Vec<Cell> = piece
                .iter()
                .map(|c| Cell { text: c.to_string(), role: CellRole::Narrow })
                .collect();
            cells.resize(cols, Cell::default());
            rows.push(RowCells { cells, wraps: index + 1 < count });
        }
    }
    rows
}

fn fetcher(rows: &[RowCells]) -> impl FnMut(u64, u64) -> Vec<RowCells> + '_ {
    move |start, end| rows[start as usize..end as usize].to_vec()
}

fn matcher(query: &str, options: FindOptions) -> Matcher {
    Matcher::new(query, options).unwrap().unwrap()
}

fn all(query: &str, options: FindOptions, rows: &[RowCells]) -> Vec<ScreenMatch> {
    let m = matcher(query, options);
    scan_page(&m, rows.len() as u64, u64::MAX, usize::MAX, 7, fetcher(rows)).matches
}

fn starts(matches: &[ScreenMatch]) -> Vec<(u64, u16)> {
    matches.iter().map(|m| (m.start.row, m.start.column)).collect()
}

#[test]
fn empty_query_matches_nothing_and_a_bad_regex_says_why() {
    assert!(Matcher::new("", FindOptions::default()).unwrap().is_none());
    let err = Matcher::new("(", FindOptions { regex: true, ..Default::default() }).unwrap_err();
    assert!(matches!(err, FindError::InvalidPattern(_)));
    // The same text as a literal is fine.
    assert!(Matcher::new("(", FindOptions::default()).unwrap().is_some());
}

#[test]
fn newest_match_comes_first() {
    let rows = screen("error one\nok\nerror two\nlast error", 20);
    let found = all("error", FindOptions::default(), &rows);
    assert_eq!(starts(&found), vec![(3, 5), (2, 0), (0, 0)]);
}

#[test]
fn toggles_case_whole_word_and_regex() {
    let rows = screen("Error errors error\nerr0r", 40);
    let plain = FindOptions::default();
    assert_eq!(all("error", plain, &rows).len(), 3);
    let case = FindOptions { case_sensitive: true, ..plain };
    assert_eq!(starts(&all("Error", case, &rows)), vec![(0, 0)]);
    let word = FindOptions { whole_word: true, ..plain };
    assert_eq!(starts(&all("error", word, &rows)), vec![(0, 13), (0, 0)]);
    let regex = FindOptions { regex: true, ..plain };
    assert_eq!(starts(&all(r"err[0o]r\b", regex, &rows)), vec![(1, 0), (0, 13), (0, 0)]);
    // A literal query's regex characters are literal.
    assert!(all("err.r", plain, &rows).is_empty());
}

#[test]
fn a_match_across_a_soft_wrap_spans_both_rows() {
    let rows = screen("xxxxhello world", 6);
    let found = all("hello", FindOptions::default(), &rows);
    assert_eq!(found.len(), 1);
    assert_eq!(found[0].start, ScreenPoint { row: 0, column: 4 });
    assert_eq!(found[0].end, ScreenPoint { row: 1, column: 2 });
    assert_eq!(found[0].snippet, "xxxxhello world");
    assert_eq!((found[0].snippet_start, found[0].snippet_len), (4, 5));
}

#[test]
fn a_hard_newline_never_joins_rows() {
    let rows = screen("hel\nlo", 10);
    assert!(all("hello", FindOptions::default(), &rows).is_empty());
}

#[test]
fn wide_characters_map_to_their_cells() {
    let cell = |text: &str, role| Cell { text: text.into(), role };
    let rows = vec![RowCells {
        cells: vec![
            cell("日", CellRole::Wide),
            cell("", CellRole::SpacerTail),
            cell("本", CellRole::Wide),
            cell("", CellRole::SpacerTail),
            cell("x", CellRole::Narrow),
        ],
        wraps: false,
    }];
    let found = all("本x", FindOptions::default(), &rows);
    assert_eq!(found[0].start, ScreenPoint { row: 0, column: 2 });
    assert_eq!(found[0].end, ScreenPoint { row: 0, column: 4 });
    let found = all("日", FindOptions::default(), &rows);
    assert_eq!(found[0].end, ScreenPoint { row: 0, column: 1 });
}

#[test]
fn pages_cover_every_row_once_and_end_on_line_starts() {
    let mut text = String::new();
    for index in 0..500 {
        // Every third line is long enough to wrap across three rows.
        if index % 3 == 0 {
            text.push_str(&format!("line {index} needle {}", "-".repeat(30)));
        } else {
            text.push_str(&format!("line {index} needle"));
        }
        text.push('\n');
    }
    let rows = screen(text.trim_end(), 16);
    let m = matcher("needle", FindOptions::default());
    let whole = scan_page(&m, rows.len() as u64, u64::MAX, usize::MAX, 64, fetcher(&rows));
    assert_eq!(whole.matches.len(), 500);
    assert_eq!(whole.next_before, None);

    let mut paged = Vec::new();
    let mut before = Some(rows.len() as u64);
    let mut pages = 0;
    while let Some(at) = before {
        let page = scan_page(&m, at, 37, usize::MAX, 10, fetcher(&rows));
        if let Some(next) = page.next_before {
            assert!(next < at);
            // A page ends on a line's first row: the row above it does not wrap.
            assert!(next == 0 || !rows[next as usize - 1].wraps);
        }
        paged.extend(page.matches);
        before = page.next_before;
        pages += 1;
    }
    assert!(pages > 10);
    assert_eq!(paged, whole.matches);
}

#[test]
fn max_matches_stops_a_page_at_a_line_boundary() {
    let rows = screen(&"a a a\n".repeat(10), 10);
    let m = matcher("a", FindOptions::default());
    let page = scan_page(&m, rows.len() as u64, u64::MAX, 4, 3, fetcher(&rows));
    // The line that crossed the cap is finished: two lines of three.
    assert_eq!(page.matches.len(), 6);
    assert!(page.next_before.is_some());
}

#[test]
fn a_short_read_stops_without_panicking() {
    let rows = screen(&"needle\n".repeat(20), 10);
    let m = matcher("needle", FindOptions::default());
    let page = scan_page(&m, rows.len() as u64, u64::MAX, usize::MAX, 8, |start, end| {
        // The oldest rows were dropped while the find ran: only rows from 10 are left.
        rows[start.max(10) as usize..end as usize].to_vec()
    });
    assert!(page.interrupted);
    assert_eq!(page.matches.len(), 10);
    // Nothing above the evicted rows: no cursor that would read nothing forever.
    assert_eq!(page.next_before, None);
}

#[test]
fn a_cursor_above_every_retained_row_ends_the_find() {
    let m = matcher("needle", FindOptions::default());
    // Every row above 15 was evicted since the last page.
    let page = scan_page(&m, 15, u64::MAX, usize::MAX, 8, |_, _| Vec::new());
    assert!(page.matches.is_empty());
    assert_eq!(page.next_before, None);
}

#[test]
fn an_empty_width_regex_counts_only_real_matches() {
    let rows = screen("aaa b", 10);
    let regex = FindOptions { regex: true, ..Default::default() };
    assert_eq!(all("a*", regex, &rows).len(), 1);
}

#[test]
fn lines_find_newest_first_with_utf16_offsets() {
    let m = matcher("needle", FindOptions::default());
    let lines = ["needle one", "😀 needle", "none"];
    let (found, truncated) = find_in_lines(&m, &lines, 10);
    assert!(!truncated);
    assert_eq!(found.iter().map(|f| f.line).collect::<Vec<_>>(), vec![1, 0]);
    assert_eq!((found[0].start, found[0].len), (3, 6));
    let (capped, truncated) = find_in_lines(&m, &lines, 1);
    assert_eq!(capped.len(), 1);
    assert!(truncated);
}

#[test]
fn a_long_line_snippet_is_bounded_and_keeps_the_match() {
    let line = format!("{}needle{}", "x".repeat(1000), "y".repeat(1000));
    let rows = screen(&line, 80);
    let found = all("needle", FindOptions::default(), &rows);
    let hit = &found[0];
    assert!(hit.snippet.chars().count() <= SNIPPET_CHARS);
    let at = hit.snippet_start as usize;
    assert_eq!(&hit.snippet[at..at + 6], "needle");
}

#[test]
fn options_read_from_the_wire_with_defaults() {
    let options: FindOptions = serde_json::from_str(r#"{"regex":true}"#).unwrap();
    assert_eq!(options, FindOptions { regex: true, ..Default::default() });
}

/// 100 000 rows, a 1-in-50 hit rate: the whole history in pages, the cost a find bar pays.
#[test]
fn a_hundred_thousand_rows_search_in_bounded_time() {
    let mut text = String::new();
    for index in 0..100_000 {
        if index % 50 == 0 {
            text.push_str("compiling crate needle ok\n");
        } else {
            text.push_str("   Compiling some-dependency v1.2.3 (registry)\n");
        }
    }
    let rows = screen(text.trim_end(), 120);
    let m = matcher("needle", FindOptions::default());
    let started = std::time::Instant::now();
    let mut before = Some(rows.len() as u64);
    let mut total = 0;
    while let Some(at) = before {
        let page = scan_page(&m, at, 4096, MATCH_CAP, 512, fetcher(&rows));
        total += page.matches.len();
        before = page.next_before;
    }
    let elapsed = started.elapsed();
    eprintln!("terminal-find bench: 100000 rows, {total} matches, {elapsed:?}");
    assert_eq!(total, 2_000);
}
