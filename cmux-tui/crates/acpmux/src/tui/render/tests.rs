use super::*;

#[test]
fn selection_text_spans_rows() {
    let rows = vec!["hello world".to_owned(), "second line".to_owned(), "third".to_owned()];
    let s = Selection { session: "x".into(), anchor: (0, 6), head: (2, 3), mode: SelectMode::Cell };
    assert_eq!(s.text(&rows), "world\nsecond line\nthi");
    let back =
        Selection { session: "x".into(), anchor: (2, 3), head: (0, 6), mode: SelectMode::Cell };
    assert_eq!(back.text(&rows), s.text(&rows));
}

#[test]
fn word_bounds_pick_a_token() {
    assert_eq!(word_bounds("run cargo-build now", 6), (4, 15));
    assert_eq!(word_bounds("a  b", 1), (1, 3));
}

#[test]
fn wrap_keeps_prefix_on_first_row_only() {
    let mut rows = Vec::new();
    wrap("one two three four", 9, Style::default(), "> ", 0, &mut rows);
    assert_eq!(rows.len(), 3);
    assert!(rows[0].text.starts_with("> one"));
    assert!(rows[1].text.starts_with("  "));
}
