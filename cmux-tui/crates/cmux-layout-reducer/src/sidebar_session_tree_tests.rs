//! Mirrors the Swift tests of `SidebarSessionTree.swift` (SidebarPullRequestBadgeTests,
//! SidebarLineageNestingTests, SidebarLayoutFoldTests, SidebarRestoreLineageTests) on the rules alone.

use super::*;

fn ids(list: &[&str]) -> BTreeSet<Id> {
    list.iter().map(|id| id.to_string()).collect()
}

fn parents(pairs: &[(&str, &str)]) -> Parents {
    pairs.iter().map(|(child, parent)| (child.to_string(), parent.to_string())).collect()
}

fn item(url: &str, number: i64, state: PullRequestState, created_at: &str) -> PullRequestItem {
    PullRequestItem {
        url: url.into(),
        repository: repository_of(url),
        number,
        title: format!("#{number}"),
        state,
        additions: 0,
        deletions: 0,
        created_at: created_at.into(),
    }
}

#[test]
fn a_failed_check_wins_and_closed_ones_leave_the_count() {
    use PullRequestState::*;
    let items = vec![
        item("https://github.com/o/r/pull/1", 1, Merged, "2026-10-01T00:00:00Z"),
        item("https://github.com/o/r/pull/2", 2, Failing, "2026-10-03T00:00:00Z"),
        item("https://github.com/o/r/pull/3", 3, Closed, "2026-10-04T00:00:00Z"),
        item("https://github.com/o/r/pull/4", 4, Draft, "2026-10-02T00:00:00Z"),
    ];
    let badge = combine_items(&items).unwrap();
    assert_eq!(badge.count, 3);
    assert_eq!(badge.status, BadgeStatus::Failing);
    let order: Vec<i64> = badge.items.iter().map(|item| item.number).collect();
    assert_eq!(order, [3, 2, 4, 1], "newest first, closed ones too");
}

#[test]
fn only_closed_pull_requests_draw_no_badge() {
    let items = vec![item("https://github.com/o/r/pull/1", 1, PullRequestState::Closed, "")];
    assert_eq!(combine_items(&items), None);
    assert_eq!(combine_statuses(&[]), None);
    let merged = combine_statuses(&[BadgeStatus::Merged, BadgeStatus::Passing]).unwrap();
    assert_eq!((merged.count, merged.status), (2, BadgeStatus::Passing));
}

#[test]
fn only_a_plain_pull_request_page_opens() {
    assert!(is_openable("https://github.com/manaflow-ai/cmux/pull/57239", None));
    assert!(is_openable("https://GitHub.com/a.b/c_d-e/pull/1", None));
    assert!(!is_openable("http://github.com/o/r/pull/1", None));
    assert!(!is_openable("https://github.com/o/r/pull/1?x=1", None));
    assert!(!is_openable("https://github.com/o/r/pull/1#top", None));
    assert!(!is_openable("https://user@github.com/o/r/pull/1", None));
    assert!(!is_openable("https://github.com:443/o/r/pull/1", None));
    assert!(!is_openable("https://github.com/o/r/pull/1/files", None));
    assert!(!is_openable("https://github.com/o/r/issues/1", None));
    assert!(!is_openable("https://github.com/o/r/pull/x1", None));
    assert!(!is_openable("https://evil.com/o/r/pull/1", None));
    assert!(is_openable("https://ghe.corp/o/r/pull/1", Some("GHE.corp")));
    assert!(!is_openable("https://ghe.corp/o/r/pull/1", Some("")));
}

#[test]
fn the_repository_comes_from_a_pull_request_url() {
    assert_eq!(repository_of("https://github.com/manaflow-ai/cmux/pull/1"), "manaflow-ai/cmux");
    assert_eq!(repository_of("https://github.com/o/r/issues/1"), "");
    assert_eq!(repository_of("not a url"), "");
}

#[test]
fn hidden_started_keeps_a_waiting_row_and_its_started_ancestors() {
    // chief <- lane <- helper, chief <- other.
    let tree = Tree {
        parents: parents(&[("lane", "chief"), ("helper", "lane"), ("other", "chief")]),
        hides_started: true,
        ..Tree::default()
    };
    let list: Vec<Option<Id>> =
        ["chief", "lane", "helper", "other"].iter().map(|id| Some(id.to_string())).collect();
    assert_eq!(tree.hidden_started(&list, |_| false), BTreeSet::from([1, 2, 3]));
    assert_eq!(
        tree.hidden_started(&list, |index| index == 2),
        BTreeSet::from([3]),
        "the waiting helper keeps lane"
    );
    let kept = Tree { keeps: ids(&["other"]), ..tree.clone() };
    assert_eq!(kept.hidden_started(&list, |_| false), BTreeSet::from([1, 2]));
    let off = Tree { hides_started: false, ..tree };
    assert!(off.hidden_started(&list, |_| false).is_empty());
}

#[test]
fn a_cycle_draws_no_nesting() {
    let cycle = parents(&[("a", "b"), ("b", "a")]);
    assert!(drawn_ancestors(&cycle, "a", |_| true).is_empty());
    let chain = parents(&[("c", "b"), ("b", "a")]);
    assert_eq!(drawn_ancestors(&chain, "c", |_| true), ["b", "a"]);
    assert_eq!(
        drawn_ancestors(&chain, "c", |id| id != "a"),
        ["b"],
        "a parent outside the list ends it"
    );
}

#[test]
fn a_deep_parent_starts_folded_until_opened() {
    let tree =
        Tree { parents: parents(&[("c", "b"), ("b", "a")]), folds_deep: true, ..Tree::default() };
    assert!(!tree.is_folded("a", 0));
    assert!(tree.is_folded("b", 1));
    let opened = Tree { opened: ids(&["b"]), ..tree.clone() };
    assert!(!opened.is_folded("b", 1));
    let all = [ids(&["a", "b", "c"])];
    assert!(tree.hides_in_fold("c", &all), "b folds c");
    assert!(!opened.hides_in_fold("c", &all));
    assert!(!tree.hides_in_fold("c", &[ids(&["b", "c"])]), "b is a root in that list");
    let hiding = Tree { hides_started: true, ..tree };
    assert!(!hiding.hides_in_fold("c", &all), "no folds while started rows hide");
}

#[test]
fn toggling_a_fold_prunes_folds_that_are_no_longer_parents() {
    let live = parents(&[("b", "a")]);
    let folds = Folds { collapsed: ids(&["gone"]), opened: ids(&[]) };
    let folded = folds.clone().toggled("a", None, Some(&live), &BTreeSet::new());
    assert_eq!(folded, Folds { collapsed: ids(&["a"]), opened: ids(&[]) });
    let opened = folded.toggled("a", None, Some(&live), &BTreeSet::new());
    assert_eq!(opened, Folds { collapsed: ids(&[]), opened: ids(&["a"]) });
    let before_first_pass = folds.clone().toggled("a", None, None, &BTreeSet::new());
    assert_eq!(
        before_first_pass.collapsed,
        ids(&["a", "gone"]),
        "nothing pruned before the first pass"
    );
    let kept = folds.toggled("x", Some(false), Some(&live), &ids(&["x"]));
    assert_eq!(kept.collapsed, ids(&["x"]), "a subagents' parent keeps its fold");
}

#[test]
fn reveal_opens_only_the_folds_above_the_row() {
    let live = parents(&[("c", "b"), ("b", "a")]);
    let folds = Folds { collapsed: ids(&["a", "b", "z"]), opened: ids(&[]) };
    let revealed = folds.revealed("c", &live, &[ids(&["a", "b", "c"])]).unwrap();
    assert_eq!(revealed, Folds { collapsed: ids(&["z"]), opened: ids(&["b"]) });
    assert_eq!(
        revealed.revealed("c", &live, &[ids(&["a", "b", "c"])]),
        None,
        "nothing more to open"
    );
    assert_eq!(folds.revealed("c", &live, &[ids(&["c"])]), None, "no parent in that list");
}
