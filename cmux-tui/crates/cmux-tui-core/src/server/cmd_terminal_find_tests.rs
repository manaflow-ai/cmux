use super::*;
use std::cell::RefCell;

fn terminal(cols: u16, rows: u16, max_scrollback: usize) -> RefCell<Terminal> {
    RefCell::new(
        Terminal::new(cols, rows, max_scrollback, ghostty_vt::Callbacks::default()).unwrap(),
    )
}

fn write(term: &RefCell<Terminal>, text: &str) {
    term.borrow_mut().vt_write(text.as_bytes());
}

fn request(query: &str) -> FindRequest {
    FindRequest {
        query: query.into(),
        options: FindOptions::default(),
        before: None,
        epoch: None,
        page_rows: None,
        max_matches: None,
    }
}

fn page(term: &RefCell<Terminal>, request: &FindRequest) -> Value {
    find_page(request, |read| {
        read(&mut term.borrow_mut());
        Ok(())
    })
    .unwrap()
}

/// Every page from the bottom to the top, the way the find bar asks for them.
fn every_match(term: &RefCell<Terminal>, mut request: FindRequest) -> (Vec<Value>, usize) {
    let mut matches = Vec::new();
    let mut pages = 0;
    loop {
        let found = page(term, &request);
        pages += 1;
        matches.extend(found["matches"].as_array().unwrap().iter().cloned());
        let Some(next) = found["next_before"].as_u64() else { break };
        request.before = Some(next);
        request.epoch = found["epoch"].as_u64();
    }
    (matches, pages)
}

/// Leo's case: the text is 10 000 lines back, far past the screen, and Cmd-F finds it.
#[test]
fn finds_a_match_ten_thousand_lines_back_in_the_scrollback() {
    let term = terminal(80, 24, 64 << 20);
    write(&term, "the deep needle is here\r\n");
    for index in 0..10_000 {
        write(&term, &format!("build step {index} ok\r\n"));
    }
    write(&term, "a recent needle\r\n");
    let (matches, pages) = every_match(&term, request("needle"));
    assert_eq!(matches.len(), 2, "{matches:#?}");
    assert!(pages > 1, "a long history is searched in pages");
    // Newest first: the recent one, then the deep one.
    assert_eq!(matches[0]["snippet"], "a recent needle");
    assert_eq!(matches[1]["snippet"], "the deep needle is here");
    assert_eq!(matches[1]["start"]["column"], 9);
    let from_bottom = matches[1]["rows_from_bottom"].as_u64().unwrap();
    assert!(from_bottom > 10_000, "{from_bottom}");
    // Its marker names the row: reading it back gives the line.
    let marker = matches[1]["start"]["marker"].as_u64().unwrap();
    let term = term.borrow();
    let row = marker - term.history_marker(0);
    let text: String =
        term.screen_row_text(row).unwrap().cells.iter().map(|cell| cell.text.as_str()).collect();
    assert!(text.starts_with("the deep needle is here"), "{text:?}");
}

#[test]
fn a_soft_wrapped_match_is_found_across_rows() {
    let term = terminal(10, 4, 1 << 20);
    write(&term, "xxxxxxxneedle\r\n");
    let found = page(&term, &request("needle"));
    let hit = &found["matches"][0];
    assert_eq!(hit["start"]["column"], 7);
    assert_eq!(hit["end"]["column"], 2);
    assert_eq!(hit["end"]["marker"].as_u64(), hit["start"]["marker"].as_u64().map(|m| m + 1));
}

#[test]
fn toggles_reach_the_matcher_and_a_bad_regex_answers_why() {
    let term = terminal(40, 4, 1 << 20);
    write(&term, "Error error errors\r\n");
    let mut word = request("error");
    word.options.whole_word = true;
    assert_eq!(page(&term, &word)["matches"].as_array().unwrap().len(), 2);
    word.options.case_sensitive = true;
    assert_eq!(page(&term, &word)["matches"].as_array().unwrap().len(), 1);
    let mut bad = request("(");
    bad.options.regex = true;
    let found = page(&term, &bad);
    assert!(found["invalid_pattern"].as_str().unwrap().contains("invalid pattern"));
    assert_eq!(page(&term, &request(""))["matches"], json!([]));
}

#[test]
fn a_cursor_from_another_epoch_restarts_at_the_bottom() {
    let term = terminal(40, 4, 1 << 20);
    write(&term, "needle\r\n");
    let first = page(&term, &request("needle"));
    let mut stale = request("needle");
    stale.before = Some(0);
    stale.epoch = Some(first["epoch"].as_u64().unwrap() + 1);
    let again = page(&term, &stale);
    assert_eq!(again["restarted"], true);
    assert_eq!(again["matches"].as_array().unwrap().len(), 1);
}

#[test]
fn markers_stay_valid_while_old_rows_are_evicted() {
    // A small scrollback: writing more evicts the oldest rows.
    let term = terminal(40, 4, 16 << 10);
    for index in 0..3_000 {
        write(&term, &format!("line {index} needle\r\n"));
    }
    let mut first = request("needle");
    first.page_rows = Some(20);
    let found = page(&term, &first);
    let next = found["next_before"].as_u64().unwrap();
    let newest = found["matches"][0]["start"]["marker"].as_u64().unwrap();
    for index in 0..3_000 {
        write(&term, &format!("more {index}\r\n"));
    }
    // The next page continues above `next`, or reports nothing left once those rows are gone:
    // it never repeats a match the first page gave.
    let mut rest = request("needle");
    rest.before = Some(next);
    rest.epoch = found["epoch"].as_u64();
    let (later, _) = every_match(&term, rest);
    for hit in &later {
        let marker = hit["start"]["marker"].as_u64().unwrap();
        assert!(marker < next && marker < newest, "{marker} {next}");
    }
}
