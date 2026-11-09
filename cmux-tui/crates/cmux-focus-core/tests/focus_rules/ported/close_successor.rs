//! The tab and workspace successors: closing the selected tab selects the
//! shown tab before it, else the shown tab after it, for every tab kind and
//! every way a tab closes (close-focus.md, Tab; Lawrence 2026-11-08: "it
//! should always focus the tab before it if it exists").

use cmux_focus_core::close_focus::{live_openers, tab, workspace};
use std::collections::{HashMap, HashSet};

fn s(ids: &[&str]) -> Vec<String> {
    ids.iter().map(|id| (*id).to_owned()).collect()
}

fn map(pairs: &[(&str, &str)]) -> HashMap<String, String> {
    pairs.iter().map(|(a, b)| ((*a).to_owned(), (*b).to_owned())).collect()
}

fn pick(closed: &str, old: &[&str], hidden: &[&str]) -> Option<String> {
    close(closed, &[closed], old, hidden)
}

fn some(id: &str) -> Option<String> {
    Some(id.to_owned())
}

/// One close of `closed` while `selected` is selected; `hidden` are members
/// of a collapsed group.
fn close(selected: &str, closed: &[&str], old: &[&str], hidden: &[&str]) -> Option<String> {
    let old = s(old);
    let surviving: Vec<String> =
        old.iter().filter(|id| !closed.contains(&id.as_str())).cloned().collect();
    let shown: HashSet<String> =
        surviving.iter().filter(|id| !hidden.contains(&id.as_str())).cloned().collect();
    tab(Some(&selected.to_owned()), &old, &surviving, &shown)
}

#[test]
fn tab_close_selects_before_the_tab_before_it() {
    // Lawrence 2026-11-08: "it should always focus the tab before it if it
    // exists" (left in a strip, above in a vertical list).
    assert_eq!(pick("B", &["A", "B", "C"], &[]), some("A"));
    assert_eq!(pick("C", &["A", "B", "C"], &[]), some("B"));
    assert_eq!(pick("D", &["A", "B", "C", "D"], &[]), some("C"));
}

#[test]
fn tab_close_selects_before_else_the_tab_after_the_first() {
    assert_eq!(pick("A", &["A", "B", "C"], &[]), some("B"));
    assert_eq!(pick("A", &["A", "B"], &[]), some("B"));
    assert_eq!(pick("A", &["A"], &[]), None);
}

#[test]
fn tab_close_selects_before_keeps_the_selection_on_an_unselected_close() {
    assert_eq!(close("A", &["C"], &["A", "B", "C"], &[]), some("A"));
    assert_eq!(close("C", &["A"], &["A", "B", "C"], &[]), some("C"));
    assert_eq!(close("B", &["A", "C"], &["A", "B", "C"], &[]), some("B"));
}

#[test]
fn tab_close_selects_before_the_last_pinned_tab() {
    // Pinned tabs come first in the strip: closing the first unpinned tab
    // selects the last pinned tab before it.
    assert_eq!(pick("U1", &["P1", "P2", "U1", "U2"], &[]), some("P2"));
    assert_eq!(pick("P2", &["P1", "P2", "U1"], &[]), some("P1"));
}

#[test]
fn tab_close_selects_before_across_groups_and_past_collapsed_ones() {
    // The tab before, even in another (expanded) group: A [B C] [D].
    assert_eq!(pick("D", &["A", "B", "C", "D"], &[]), some("C"));
    // A collapsed group's members are skipped to the nearest shown tab
    // before: A [B C collapsed] D, close D: A.
    assert_eq!(pick("D", &["A", "B", "C", "D"], &["B", "C"]), some("A"));
    // No shown tab before: the nearest shown tab after.
    assert_eq!(pick("A", &["A", "B", "C", "D"], &["B", "C"]), some("D"));
    // Only hidden tabs are left: the one before (its group then expands).
    assert_eq!(pick("D", &["A", "B", "D"], &["A", "B"]), some("B"));
}

#[test]
fn tab_close_selects_before_for_close_others_and_close_to_the_right() {
    // Close Other Tabs keeps the selected tab: it stays.
    assert_eq!(close("B", &["A", "C", "D"], &["A", "B", "C", "D"], &[]), some("B"));
    // Close Tabs to the Right of A while C is selected: C goes, so the
    // surviving tab before it, A.
    assert_eq!(close("C", &["B", "C", "D"], &["A", "B", "C", "D"], &[]), some("A"));
    // Close Tabs to the Right of the selected tab: it stays.
    assert_eq!(close("B", &["C", "D"], &["A", "B", "C", "D"], &[]), some("B"));
}

#[test]
fn tab_close_selects_before_on_rapid_repeated_closes() {
    // Each close uses the selection the previous close made.
    let mut strip = s(&["A", "B", "C", "D"]);
    let mut selected = Some("C".to_owned());
    let mut picks = Vec::new();
    while let Some(current) = selected.clone() {
        let surviving: Vec<String> = strip.iter().filter(|id| **id != current).cloned().collect();
        let shown: HashSet<String> = surviving.iter().cloned().collect();
        selected = tab(Some(&current), &strip, &surviving, &shown);
        picks.push(selected.clone());
        strip = surviving;
    }
    assert_eq!(picks, vec![some("B"), some("A"), some("D"), None]);
}

#[test]
fn live_openers_skip_tabs_that_left() {
    // B left: C, which B opened, takes B's opener A (Chrome's FixOpeners).
    assert_eq!(live_openers(&map(&[("B", "A"), ("C", "B")]), &s(&["A", "C"])), map(&[("C", "A")]));
    // Only tabs in the order are keys; a chain that leads nowhere present is
    // dropped.
    assert!(live_openers(&map(&[("B", "A"), ("C", "Z")]), &s(&["B", "C"])).is_empty());
    // A cycle through tabs that left ends, and a relation back to the tab
    // itself is dropped.
    assert!(live_openers(&map(&[("A", "X"), ("X", "Y"), ("Y", "X")]), &s(&["A"])).is_empty());
    assert!(live_openers(&map(&[("A", "X"), ("X", "A")]), &s(&["A"])).is_empty());
}

#[test]
fn a_surviving_selection_stays() {
    let shown: HashSet<String> = s(&["A"]).into_iter().collect();
    assert_eq!(tab(Some(&"A".to_owned()), &s(&["A", "B"]), &s(&["A"]), &shown), some("A"));
}

#[test]
fn no_selection_takes_the_first_shown_survivor() {
    let shown: HashSet<String> = s(&["B"]).into_iter().collect();
    assert_eq!(tab(None, &s(&["A", "B"]), &s(&["A", "B"]), &shown), some("B"));
    assert_eq!(tab(None, &s(&["A"]), &s(&["A"]), &HashSet::new()), some("A"));
    assert_eq!(tab::<String>(None, &[], &[], &HashSet::new()), None);
}

#[test]
fn a_workspace_hands_off_to_the_next_drawn_row() {
    let old = s(&["w1", "w2", "w3", "w4"]);
    let surviving = s(&["w1", "w2", "w4"]);
    // The model order puts w4 after w3; the drawn rows (sorted) put w1
    // there, and the drawn order decides first.
    let drawn = s(&["w3", "w1", "w2", "w4"]);
    assert_eq!(workspace(Some(&"w3".to_owned()), &old, &surviving, &[drawn]), some("w1"));
    // Without row orders: the next in `old`, else the previous one.
    assert_eq!(workspace(Some(&"w3".to_owned()), &old, &surviving, &[]), some("w4"));
    assert_eq!(workspace(Some(&"w4".to_owned()), &old, &s(&["w1", "w2", "w3"]), &[]), some("w3"));
    // A row order that does not list the closed workspace is skipped; rows
    // that are not members of the window are ignored.
    let unrelated = s(&["w1", "w2"]);
    let with_strangers = s(&["w3", "x9", "w2"]);
    assert_eq!(
        workspace(Some(&"w3".to_owned()), &old, &surviving, &[unrelated, with_strangers]),
        some("w2")
    );
    // A shown workspace that survives stays; none shown takes the first.
    assert_eq!(workspace(Some(&"w2".to_owned()), &old, &surviving, &[]), some("w2"));
    assert_eq!(workspace(None, &old, &surviving, &[]), some("w1"));
    assert_eq!(workspace(Some(&"w1".to_owned()), &s(&["w1"]), &[], &[]), None);
}
