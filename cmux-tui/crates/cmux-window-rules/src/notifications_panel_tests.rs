//! The selection rules of the app's `NotificationsPanelSelection`.

use super::*;

fn rows(ids: &[&str]) -> Vec<String> {
    ids.iter().map(|id| (*id).to_owned()).collect()
}

#[test]
fn no_rows_select_nothing() {
    assert_eq!(move_selection(Some("a"), 1, &[]), None);
    assert_eq!(move_selection(None, -1, &[]), None);
}

#[test]
fn the_first_press_selects_the_first_row_down_and_the_last_up() {
    let list = rows(&["a", "b", "c"]);
    assert_eq!(move_selection(None, 1, &list).as_deref(), Some("a"));
    assert_eq!(move_selection(None, 0, &list).as_deref(), Some("a"));
    assert_eq!(move_selection(None, -1, &list).as_deref(), Some("c"));
    assert_eq!(
        move_selection(Some("gone"), -1, &list).as_deref(),
        Some("c"),
        "a row that left counts as none"
    );
}

#[test]
fn a_move_stays_in_the_list() {
    let list = rows(&["a", "b", "c"]);
    assert_eq!(move_selection(Some("a"), 1, &list).as_deref(), Some("b"));
    assert_eq!(move_selection(Some("c"), 1, &list).as_deref(), Some("c"));
    assert_eq!(move_selection(Some("a"), -1, &list).as_deref(), Some("a"));
    assert_eq!(move_selection(Some("b"), i64::MAX, &list).as_deref(), Some("c"));
    assert_eq!(move_selection(Some("b"), i64::MIN, &list).as_deref(), Some("a"));
}

#[test]
fn a_reload_keeps_the_row_or_takes_the_one_at_its_index() {
    let old = rows(&["a", "b", "c"]);
    assert_eq!(reconcile_selection(Some("b"), &old, &rows(&["x", "b"])).as_deref(), Some("b"));
    assert_eq!(reconcile_selection(Some("b"), &old, &rows(&["a", "c"])).as_deref(), Some("c"));
    assert_eq!(
        reconcile_selection(Some("c"), &old, &rows(&["a"])).as_deref(),
        Some("a"),
        "the last when the list got shorter"
    );
    assert_eq!(reconcile_selection(Some("b"), &old, &[]), None);
    assert_eq!(
        reconcile_selection(Some("z"), &old, &rows(&["a"])),
        None,
        "a row not in the old list"
    );
    assert_eq!(reconcile_selection(None, &old, &rows(&["a"])), None);
}
