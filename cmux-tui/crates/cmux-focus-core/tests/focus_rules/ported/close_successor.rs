//! The tab and workspace successors, ported from the Swift
//! `FocusAfterCloseOpenerTests`: closing the selected link tab goes back to
//! its opener family first, in Chrome's order (`DetermineNewSelectedIndex`):
//! its next child, else a sibling, else its opener; then the next shown tab,
//! else the previous one (close-focus.md, Tab; manaflow-ai/cmux#21805 row 1).

use cmux_focus_core::close_focus::{live_openers, tab, workspace};
use std::collections::{HashMap, HashSet};

fn s(ids: &[&str]) -> Vec<String> {
    ids.iter().map(|id| (*id).to_owned()).collect()
}

fn map(pairs: &[(&str, &str)]) -> HashMap<String, String> {
    pairs.iter().map(|(a, b)| ((*a).to_owned(), (*b).to_owned())).collect()
}

fn pick(closed: &str, old: &[&str], opener: &[(&str, &str)], hidden: &[&str]) -> Option<String> {
    let old = s(old);
    let surviving: Vec<String> = old.iter().filter(|id| *id != closed).cloned().collect();
    let shown: HashSet<String> =
        surviving.iter().filter(|id| !hidden.contains(&id.as_str())).cloned().collect();
    tab(Some(&closed.to_owned()), &old, &surviving, &shown, &map(opener))
}

fn some(id: &str) -> Option<String> {
    Some(id.to_owned())
}

#[test]
fn a_closed_child_goes_back_to_its_opener() {
    // A link opened in a new tab, read, Cmd-W: back to the page it came from,
    // not the tab on its right.
    assert_eq!(pick("B", &["A", "B", "C"], &[("B", "A")], &[]), some("A"));
}

#[test]
fn a_closed_child_picks_the_next_sibling_before_the_opener() {
    let opener = [("B", "A"), ("C", "A"), ("D", "A")];
    assert_eq!(pick("B", &["A", "B", "C", "D", "X"], &opener, &[]), some("C"));
    // The last child: the nearest sibling before it, not the unrelated tab on
    // its right.
    assert_eq!(pick("D", &["A", "B", "C", "D", "X"], &opener, &[]), some("C"));
}

#[test]
fn a_closed_opener_picks_its_next_child() {
    assert_eq!(pick("A", &["A", "X", "B"], &[("B", "A")], &[]), some("B"));
    // A child before it counts when none follows (Chrome searches after, then
    // before).
    assert_eq!(pick("A", &["B", "X", "A", "Y"], &[("B", "A")], &[]), some("B"));
}

#[test]
fn a_child_comes_before_a_sibling() {
    // B opened C and was itself opened by A, like A's other child D.
    let opener = [("B", "A"), ("C", "B"), ("D", "A")];
    assert_eq!(pick("B", &["A", "B", "D", "C"], &opener, &[]), some("C"));
}

#[test]
fn forgotten_openers_fall_back_to_the_right_neighbor() {
    // After a switch to an unrelated tab every relation is forgotten.
    assert_eq!(pick("B", &["A", "B", "C"], &[], &[]), some("C"));
    assert_eq!(pick("C", &["A", "B", "C"], &[], &[]), some("B"));
}

#[test]
fn tabs_without_relations_keep_next_else_previous() {
    // A terminal next to a link family: it has no relation, so the family is
    // not consulted.
    assert_eq!(pick("T", &["A", "T", "B"], &[("B", "A")], &[]), some("B"));
    assert_eq!(pick("T", &["B", "A", "T"], &[("B", "A")], &[]), some("A"));
}

#[test]
fn a_hidden_opener_is_skipped() {
    // The opener sits in a collapsed group: the right neighbor, not a hidden
    // tab.
    assert_eq!(pick("B", &["A", "B", "C"], &[("B", "A")], &["A"]), some("C"));
    // A hidden sibling is skipped too; the shown opener comes next.
    assert_eq!(pick("B", &["A", "B", "C", "X"], &[("B", "A"), ("C", "A")], &["C"]), some("A"));
    // A hidden child is skipped; with no other relation, the right neighbor.
    assert_eq!(pick("A", &["A", "X", "B"], &[("B", "A")], &["B"]), some("X"));
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
    let picked =
        tab(Some(&"A".to_owned()), &s(&["A", "B"]), &s(&["A"]), &shown, &map(&[("B", "A")]));
    assert_eq!(picked, some("A"));
}

#[test]
fn no_selection_takes_the_first_shown_survivor() {
    let shown: HashSet<String> = s(&["B"]).into_iter().collect();
    assert_eq!(tab(None, &s(&["A", "B"]), &s(&["A", "B"]), &shown, &HashMap::new()), some("B"));
    assert_eq!(tab(None, &s(&["A"]), &s(&["A"]), &HashSet::new(), &HashMap::new()), some("A"));
    assert_eq!(tab::<String>(None, &[], &[], &HashSet::new(), &HashMap::new()), None);
}

/// Every assignment of an opener (or none) to each tab with no cycles.
fn forests(tabs: &[String]) -> Vec<HashMap<String, String>> {
    let mut result: Vec<HashMap<String, String>> = vec![HashMap::new()];
    for t in tabs {
        let mut next = Vec::new();
        for m in &result {
            next.push(m.clone());
            for parent in tabs.iter().filter(|p| *p != t && !reaches(m, p, t)) {
                let mut with = m.clone();
                with.entry(t.clone()).or_insert_with(|| parent.clone());
                next.push(with);
            }
        }
        result = next;
    }
    result
}

fn reaches(m: &HashMap<String, String>, start: &str, target: &str) -> bool {
    let mut current = Some(start.to_owned());
    let mut steps = 0;
    while let Some(id) = current {
        if steps > m.len() {
            break;
        }
        if id == target {
            return true;
        }
        current = m.get(&id).cloned();
        steps += 1;
    }
    false
}

/// Every strip of up to 4 tabs, every opener forest, every hidden set, every
/// closed tab: the pick is a surviving shown tab while one is left (C2, C3),
/// and it differs from the plain rule only for a tab of the closed tab's
/// family (child, sibling or opener).
#[test]
fn every_small_strip_keeps_the_contract() {
    let mut checked = 0;
    for count in 1..=4usize {
        let tabs: Vec<String> = (0..count).map(|i| format!("t{i}")).collect();
        for opener in forests(&tabs) {
            for mask in 0..(1u32 << count) {
                let hidden: HashSet<&String> = tabs
                    .iter()
                    .enumerate()
                    .filter(|(i, _)| mask & (1 << i) != 0)
                    .map(|(_, t)| t)
                    .collect();
                for closed in &tabs {
                    checked += 1;
                    let surviving: Vec<String> =
                        tabs.iter().filter(|t| *t != closed).cloned().collect();
                    let shown: HashSet<String> =
                        surviving.iter().filter(|t| !hidden.contains(t)).cloned().collect();
                    let picked = tab(Some(closed), &tabs, &surviving, &shown, &opener);
                    let plain = tab(Some(closed), &tabs, &surviving, &shown, &HashMap::new());
                    assert_eq!(picked.is_none(), surviving.is_empty());
                    if let Some(p) = &picked {
                        assert!(surviving.contains(p));
                        if !shown.is_empty() {
                            assert!(shown.contains(p));
                        }
                        if Some(p) != plain.as_ref() {
                            let family = opener.get(p) == Some(closed)
                                || opener.get(closed) == Some(p)
                                || (opener.contains_key(p) && opener.get(p) == opener.get(closed));
                            assert!(family, "{tabs:?} {opener:?} close {closed}: {p} not family");
                        }
                    }
                }
            }
        }
    }
    assert!(checked > 1000);
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
