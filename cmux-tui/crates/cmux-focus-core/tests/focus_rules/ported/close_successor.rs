//! The tab and workspace successors. Closing the selected tab selects as
//! Chrome's `TabStripModel::DetermineNewSelectedIndex` does
//! (chrome/browser/ui/tabs/tab_strip_model.cc; close-focus.md, Tab; Lawrence
//! 2026-11-09: "ensure our cmd w behavior matches chrome, in terms of what's
//! the next tab that should be focused to"): a child it opened, a sibling,
//! its opener, its group's neighbor, else the shown tab to its right, else
//! the one to its left. Test names carry the case ids of close-focus.md's
//! Chrome table.

use cmux_focus_core::close_focus::{TabRelations, live_openers, tab, workspace};
use std::collections::{HashMap, HashSet};

fn s(ids: &[&str]) -> Vec<String> {
    ids.iter().map(|id| (*id).to_owned()).collect()
}

fn map(pairs: &[(&str, &str)]) -> HashMap<String, String> {
    pairs.iter().map(|(a, b)| ((*a).to_owned(), (*b).to_owned())).collect()
}

fn some(id: &str) -> Option<String> {
    Some(id.to_owned())
}

/// The strip around one close: `opener` child to opener, `group` tab to
/// group, `hidden` members of a collapsed group.
#[derive(Default)]
struct Strip<'a> {
    opener: &'a [(&'a str, &'a str)],
    group: &'a [(&'a str, &'a str)],
    hidden: &'a [&'a str],
}

impl Strip<'_> {
    /// One close of `closed` while `selected` is selected.
    fn close(&self, selected: &str, closed: &[&str], old: &[&str]) -> Option<String> {
        let old = s(old);
        let surviving: Vec<String> =
            old.iter().filter(|id| !closed.contains(&id.as_str())).cloned().collect();
        let shown: HashSet<String> =
            surviving.iter().filter(|id| !self.hidden.contains(&id.as_str())).cloned().collect();
        let relations = TabRelations { opener: map(self.opener), group: map(self.group) };
        tab(Some(&selected.to_owned()), &old, &surviving, &shown, &relations)
    }

    fn pick(&self, closed: &str, old: &[&str]) -> Option<String> {
        self.close(closed, &[closed], old)
    }
}

fn pick(closed: &str, old: &[&str]) -> Option<String> {
    Strip::default().pick(closed, old)
}

fn close(selected: &str, closed: &[&str], old: &[&str]) -> Option<String> {
    Strip::default().close(selected, closed, old)
}

#[test]
fn tab_close_like_chrome_p1_closing_the_selected_tab_selects_the_tab_to_its_right() {
    // Chrome's last step: "prefer picking the tab after the last tab in the
    // block".
    assert_eq!(pick("B", &["A", "B", "C"]), some("C"));
    assert_eq!(pick("A", &["A", "B", "C"]), some("B"));
    assert_eq!(pick("B", &["A", "B", "C", "D"]), some("C"));
}

#[test]
fn tab_close_like_chrome_p2_the_last_tab_selects_the_tab_to_its_left() {
    assert_eq!(pick("C", &["A", "B", "C"]), some("B"));
    assert_eq!(pick("B", &["A", "B"]), some("A"));
}

#[test]
fn tab_close_like_chrome_p3_the_only_tab_leaves_nothing_selected() {
    assert_eq!(pick("A", &["A"]), None);
}

#[test]
fn tab_close_like_chrome_p4_closing_a_tab_that_is_not_selected_keeps_the_selection() {
    assert_eq!(close("A", &["C"], &["A", "B", "C"]), some("A"));
    assert_eq!(close("C", &["A"], &["A", "B", "C"]), some("C"));
    assert_eq!(close("B", &["A", "C"], &["A", "B", "C"]), some("B"));
    // Even a tab the selected one opened, or its opener.
    let strip = Strip { opener: &[("B", "A")], ..Strip::default() };
    assert_eq!(strip.close("A", &["B"], &["A", "B", "C"]), some("A"));
    assert_eq!(strip.close("B", &["A"], &["A", "B", "C"]), some("B"));
}

#[test]
fn tab_close_like_chrome_p5_pinned_tabs_are_tabs_like_any_other() {
    // Pinned tabs come first in the strip; Chrome's rule does not look at
    // the pin: the last pinned tab selects the first unpinned one.
    assert_eq!(pick("P2", &["P1", "P2", "U1", "U2"]), some("U1"));
    assert_eq!(pick("P1", &["P1", "P2", "U1"]), some("P2"));
    assert_eq!(pick("U1", &["P1", "P2", "U1", "U2"]), some("U2"));
    assert_eq!(pick("U1", &["P1", "P2", "U1"]), some("P2"));
}

#[test]
fn tab_close_like_chrome_o1_a_closed_opener_selects_the_tab_it_opened() {
    // First preference: "a tab the block opened". X A Y B, B opened by A:
    // closing A selects B, not Y.
    let strip = Strip { opener: &[("B", "A")], ..Strip::default() };
    assert_eq!(strip.pick("A", &["X", "A", "Y", "B"]), some("B"));
    // The nearest child after it, else the nearest before it.
    let strip = Strip { opener: &[("C1", "A"), ("C2", "A"), ("C3", "A")], ..Strip::default() };
    assert_eq!(strip.pick("A", &["C1", "X", "A", "Y", "C2", "C3"]), some("C2"));
    let strip = Strip { opener: &[("C1", "A")], ..Strip::default() };
    assert_eq!(strip.pick("A", &["C1", "X", "A", "Y"]), some("C1"));
}

#[test]
fn tab_close_like_chrome_o2_a_closed_link_tab_selects_its_next_sibling() {
    // Second preference: "a tab the block's opener opened". A B C D, B and
    // D opened by A, C not: closing B selects D, not C.
    let strip = Strip { opener: &[("B", "A"), ("D", "A")], ..Strip::default() };
    assert_eq!(strip.pick("B", &["A", "B", "C", "D"]), some("D"));
    // A sibling before it when none is after it.
    assert_eq!(strip.pick("D", &["A", "B", "C", "D"]), some("B"));
}

#[test]
fn tab_close_like_chrome_o3_a_closed_link_tab_with_no_sibling_returns_to_its_opener() {
    // Third preference: "the block's opener". A B X, B opened by A: closing
    // B selects A, not X (the tab to its right).
    let strip = Strip { opener: &[("B", "A")], ..Strip::default() };
    assert_eq!(strip.pick("B", &["A", "B", "X"]), some("A"));
    // Wherever the opener is.
    assert_eq!(strip.pick("B", &["X", "B", "Y", "A"]), some("A"));
}

#[test]
fn tab_close_like_chrome_o4_hidden_or_closed_family_does_not_qualify() {
    // "is_eligible": a collapsed child is skipped for the next step.
    let strip = Strip { opener: &[("B", "A")], hidden: &["B"], ..Strip::default() };
    assert_eq!(strip.pick("A", &["X", "A", "Y", "B"]), some("Y"));
    // An opener closed in the same batch: its own opener (FixOpeners).
    let strip = Strip { opener: &[("B", "A"), ("C", "B")], ..Strip::default() };
    assert_eq!(strip.close("C", &["B", "C"], &["A", "B", "C", "X"]), some("A"));
}

#[test]
fn tab_close_like_chrome_g1_a_grouped_tab_stays_in_its_group() {
    // Fourth preference: in the group, the tab after it, else before it.
    // A [B C] D: closing C (last of its group) selects B, not D.
    let strip = Strip { group: &[("B", "g"), ("C", "g")], ..Strip::default() };
    assert_eq!(strip.pick("C", &["A", "B", "C", "D"]), some("B"));
    assert_eq!(strip.pick("B", &["A", "B", "C", "D"]), some("C"));
    // The group's last tab: the tab to its right.
    let strip = Strip { group: &[("B", "g")], ..Strip::default() };
    assert_eq!(strip.pick("B", &["A", "B", "C"]), some("C"));
}

#[test]
fn tab_close_like_chrome_g2_collapsed_groups_are_skipped() {
    // A [B C collapsed] D: closing D selects A; closing A selects D.
    let strip = Strip { group: &[("B", "g"), ("C", "g")], hidden: &["B", "C"], ..Strip::default() };
    assert_eq!(strip.pick("D", &["A", "B", "C", "D"]), some("A"));
    assert_eq!(strip.pick("A", &["A", "B", "C", "D"]), some("D"));
    // Only hidden tabs are left: the one after it, else before it (its
    // group then expands).
    let strip = Strip { hidden: &["A", "B"], ..Strip::default() };
    assert_eq!(strip.pick("D", &["A", "B", "D"]), some("B"));
    assert_eq!(strip.pick("D", &["D", "A", "B"]), some("A"));
}

#[test]
fn tab_close_like_chrome_b1_batch_closes_keep_the_tab_acted_on_or_go_right() {
    // Close Other Tabs keeps the selected tab.
    assert_eq!(close("B", &["A", "C", "D"], &["A", "B", "C", "D"]), some("B"));
    // Close Tabs to the Right of A while C is selected: A, the one left.
    assert_eq!(close("C", &["B", "C", "D"], &["A", "B", "C", "D"]), some("A"));
    // Close Tabs to the Left of D while B is selected: D.
    assert_eq!(close("B", &["A", "B", "C"], &["A", "B", "C", "D"]), some("D"));
}

#[test]
fn tab_close_like_chrome_b2_rapid_repeated_closes() {
    // Each close uses the selection the previous close made: C, then D (its
    // right), then B (D was last), then A.
    let mut strip = s(&["A", "B", "C", "D"]);
    let mut selected = Some("C".to_owned());
    let mut picks = Vec::new();
    let none = TabRelations::<String>::default();
    while let Some(current) = selected.clone() {
        let surviving: Vec<String> = strip.iter().filter(|id| **id != current).cloned().collect();
        let shown: HashSet<String> = surviving.iter().cloned().collect();
        selected = tab(Some(&current), &strip, &surviving, &shown, &none);
        picks.push(selected.clone());
        strip = surviving;
    }
    assert_eq!(picks, vec![some("D"), some("B"), some("A"), None]);
}

#[test]
fn live_openers_skip_tabs_that_left() {
    // B left: C, which B opened, takes B's opener A (Chrome's FixOpeners; new
    // link tab placement).
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
fn no_selection_takes_the_first_shown_survivor() {
    let none = TabRelations::<String>::default();
    let shown: HashSet<String> = s(&["B"]).into_iter().collect();
    assert_eq!(tab(None, &s(&["A", "B"]), &s(&["A", "B"]), &shown, &none), some("B"));
    assert_eq!(tab(None, &s(&["A"]), &s(&["A"]), &HashSet::new(), &none), some("A"));
    assert_eq!(tab::<String, u32>(None, &[], &[], &HashSet::new(), &TabRelations::default()), None);
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

/// Issue 38194: with no surviving pane in the focus history (a relaunch with
/// only the closed pane focused), `MostRecent` falls back to the closed
/// pane's sibling, the first pane of the subtree that takes its space, as
/// classic's `closePaneRecursively`: `H(1, V(2, 3))`, close 2: 3, not 1.
#[test]
fn most_recent_without_history_focuses_the_closed_panes_sibling() {
    use cmux_focus_core::close_focus::pane_or_sibling;
    use cmux_focus_core::state::CloseFocusPolicy::{MostRecent, PreviousNeighbor};
    let before = vec![s(&["1", "2", "3"])];
    let after = vec![s(&["1", "3"])];
    let two = "2".to_owned();
    let three = "3".to_owned();
    let pick = |history: &[&str], policy| {
        pane_or_sibling(Some(&two), &before, &after, &s(history), Some(&three), policy)
    };
    assert_eq!(pick(&["2"], MostRecent), some("3"));
    assert_eq!(pick(&[], MostRecent), some("3"));
    // A surviving pane in the history wins over the sibling.
    assert_eq!(pick(&["2", "1"], MostRecent), some("1"));
    // previousNeighbor keeps its own rule.
    assert_eq!(pick(&["2"], PreviousNeighbor), some("1"));
    // A sibling that did not survive is not picked.
    let gone = "9".to_owned();
    assert_eq!(
        pane_or_sibling(Some(&two), &before, &after, &s(&["2"]), Some(&gone), MostRecent),
        some("1")
    );
}
