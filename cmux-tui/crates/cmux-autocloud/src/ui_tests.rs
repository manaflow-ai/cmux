use super::{window_start, wrap};

#[test]
fn the_columns_follow_the_focus() {
    assert_eq!(window_start(3, 2, 4), 0);
    assert_eq!(window_start(6, 0, 4), 0);
    assert_eq!(window_start(6, 3, 4), 0);
    assert_eq!(window_start(6, 4, 4), 1);
    assert_eq!(window_start(6, 5, 4), 2);
    assert_eq!(window_start(6, 9, 4), 2);
}

#[test]
fn wraps_at_spaces_and_keeps_blank_lines() {
    assert_eq!(wrap("hello there world", 11), vec!["hello there", "world"]);
    assert_eq!(wrap("a\n\nb", 5), vec!["a", "", "b"]);
    assert_eq!(wrap("abcdefghij", 4), vec!["abcd", "efgh", "ij"]);
}
