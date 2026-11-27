use super::*;
use serde_json::{Value, json};
use std::path::PathBuf;

fn ids(list: &[Option<&str>]) -> Vec<Option<String>> {
    list.iter().map(|i| i.map(str::to_owned)).collect()
}

fn parents(pairs: &[(&str, &str)]) -> HashMap<String, String> {
    pairs.iter().map(|(c, p)| ((*c).to_owned(), (*p).to_owned())).collect()
}

fn order(
    list: &[Option<&str>],
    tree: Option<&HashMap<String, String>>,
    collapsed: &[&str],
) -> (Vec<i64>, Vec<i64>) {
    let collapsed: HashSet<String> = collapsed.iter().map(|c| (*c).to_owned()).collect();
    let folded = |id: &str, _: i64| collapsed.contains(id);
    let drawn = tree_order(&ids(list), tree, &folded, None, &BTreeSet::new());
    (drawn.iter().map(|e| e.index).collect(), drawn.iter().map(|e| e.depth).collect())
}

fn ws(id: &str) -> Workspace {
    Workspace { id: id.to_owned(), ..Workspace::default() }
}

fn done(id: &str) -> Workspace {
    Workspace { done: true, ..ws(id) }
}

fn entries(pairs: &[(i64, i64)]) -> Vec<Entry> {
    pairs.iter().map(|&(index, depth)| Entry { index, depth }).collect()
}

// SidebarDeepTreeTests / SidebarSessionTreeTests

#[test]
fn a_child_draws_under_its_parent_at_any_depth() {
    let tree = parents(&[("b", "a"), ("c", "b"), ("d", "far")]);
    let (index, depth) =
        order(&[Some("c"), None, Some("a"), Some("d"), Some("b")], Some(&tree), &[]);
    assert_eq!(index, vec![1, 2, 4, 0, 3]);
    assert_eq!(depth, vec![0, 0, 1, 2, 0]);
}

#[test]
fn siblings_keep_the_list_order() {
    let tree = parents(&[("y", "root"), ("x", "root"), ("x1", "x")]);
    let (index, depth) = order(&[Some("root"), Some("y"), Some("x1"), Some("x")], Some(&tree), &[]);
    assert_eq!(index, vec![0, 1, 3, 2]);
    assert_eq!(depth, vec![0, 1, 1, 2]);
}

#[test]
fn a_folded_parent_hides_its_whole_subtree() {
    let tree = parents(&[("b", "a"), ("c", "b")]);
    let (index, depth) =
        order(&[Some("c"), None, Some("a"), Some("d"), Some("b")], Some(&tree), &["b"]);
    assert_eq!(index, vec![1, 2, 4, 3]);
    assert_eq!(depth, vec![0, 0, 1, 0]);
}

#[test]
fn a_parent_in_another_list_or_a_cycle_leaves_roots_and_no_parents_keeps_the_model_order() {
    let far = parents(&[("d", "far")]);
    assert_eq!(
        order(&[None, Some("a"), Some("d")], Some(&far), &[]),
        (vec![0, 1, 2], vec![0, 0, 0])
    );
    let cycle = parents(&[("a", "b"), ("b", "a")]);
    assert_eq!(order(&[Some("a"), Some("b")], Some(&cycle), &[]), (vec![0, 1], vec![0, 0]));
    assert_eq!(order(&[Some("a"), Some("b")], None, &[]), (vec![0, 1], vec![0, 0]));
}

#[test]
fn fifty_sessions_four_levels_deep_draw_as_a_tree() {
    let all: Vec<String> = (0..50).map(|n| format!("w{n}")).collect();
    let mut depth: HashMap<String, i64> = HashMap::new();
    let mut tree: HashMap<String, String> = HashMap::new();
    for id in all.iter().take(5) {
        depth.insert(id.clone(), 0);
    }
    for n in 5..50 {
        let parent = (0..n).rev().skip(4).find(|p| depth[&all[*p]] < 4).unwrap_or(0);
        tree.insert(all[n].clone(), all[parent].clone());
        depth.insert(all[n].clone(), depth[&all[parent]] + 1);
    }
    // Model order: the ids shuffled by a fixed stride.
    let model: Vec<Option<String>> = (0..50).map(|k| Some(all[(k * 7) % 50].clone())).collect();
    let drawn = tree_order(&model, Some(&tree), &|_, _| false, None, &BTreeSet::new());
    assert_eq!(drawn.len(), 50);
    let name = |e: &Entry| model[e.index as usize].clone().unwrap_or_default();
    let mut at: HashMap<String, usize> = HashMap::new();
    for (position, e) in drawn.iter().enumerate() {
        assert_eq!(e.depth, depth[&name(e)], "{} draws at its depth", name(e));
        at.insert(name(e), position);
    }
    for (child, parent) in &tree {
        assert!(at[child] > at[parent], "{child} draws after its parent");
        for between in &drawn[at[parent] + 1..at[child]] {
            assert!(depth[&name(between)] > depth[parent]);
        }
    }
    assert_eq!(depth.values().max(), Some(&4));
}

#[test]
fn a_deep_chain_keeps_every_link_and_draws_without_recursion() {
    let chain: Vec<Option<String>> = (0..20_000).map(|n| Some(format!("c{n}"))).collect();
    let mut tree = HashMap::new();
    for n in 1..chain.len() {
        tree.insert(format!("c{n}"), format!("c{}", n - 1));
    }
    let children = tree_children(&chain, &tree);
    assert_eq!(children.len(), chain.len() - 1);
    assert_eq!(children["c0"], vec![1]);
    let drawn = tree_order(&chain, Some(&tree), &|_, _| false, Some(&children), &BTreeSet::new());
    assert_eq!(drawn.last(), Some(&Entry { index: 19_999, depth: 19_999 }));
}

#[test]
fn a_folded_parent_rolls_up_everything_under_it_by_state() {
    // a started b and e; b started c and d.
    let list = ids(&[Some("a"), Some("b"), Some("c"), Some("d"), Some("e")]);
    let states = [
        AgentState::Idle,
        AgentState::Blocked,
        AgentState::Failed,
        AgentState::FinishedUnread,
        AgentState::Running,
    ];
    let mut tree = SessionTree {
        parents: parents(&[("b", "a"), ("e", "a"), ("c", "b"), ("d", "b")]),
        ..SessionTree::default()
    };
    let open = tree_rows(&list, &states, Some(&tree), false);
    assert_eq!(open.len(), 5);
    assert_eq!(open[0].fold, Some(TreeFold::Expanded));
    assert_eq!(open[1].fold, Some(TreeFold::Expanded));
    assert_eq!(open[2].fold, None);
    assert_eq!(open[0].roll_up, None);
    tree.collapsed = HashSet::from(["a".to_owned()]);
    let folded = tree_rows(&list, &states, Some(&tree), false);
    assert_eq!(folded.len(), 1);
    assert_eq!(folded[0].fold, Some(TreeFold::Collapsed));
    assert_eq!(
        folded[0].roll_up,
        Some(RollUp { blocked: 1, failed: 1, running: 1, unread: 1, total: 4 })
    );
    // A filter draws a folded parent open.
    let filtered = tree_rows(&list, &states, Some(&tree), true);
    assert_eq!(filtered.len(), 5);
    assert_eq!(filtered[0].fold, Some(TreeFold::Expanded));
}

#[test]
fn hidden_started_sessions_keep_the_blocked_and_kept_ones_with_their_ancestors() {
    let list = ids(&[Some("root"), Some("lane"), Some("sub"), Some("other"), None]);
    let tree = SessionTree {
        parents: parents(&[("lane", "root"), ("sub", "lane"), ("other", "root")]),
        hides_started: true,
        ..SessionTree::default()
    };
    let states = [AgentState::Idle, AgentState::Idle, AgentState::Blocked, AgentState::Running];
    assert_eq!(tree.hidden_started(&list, &states), BTreeSet::from([3]));
    let rows = tree_rows(&list, &states, Some(&tree), false);
    let drawn: Vec<(i64, i64)> = rows.iter().map(|r| (r.index, r.depth)).collect();
    assert_eq!(drawn, vec![(0, 0), (1, 1), (2, 2), (4, 0)]);
    assert!(rows.iter().all(|r| r.fold.is_none() && r.roll_up.is_none()));
    assert!(tree_rows(&list, &states, Some(&tree), true).len() == 5, "a filter finds them all");
}

#[test]
fn folds_deep_folds_parents_below_the_top_level_until_opened() {
    let tree = SessionTree {
        folds_deep: true,
        opened: HashSet::from(["b".to_owned()]),
        ..SessionTree::default()
    };
    assert!(!tree.is_folded("a", 0));
    assert!(tree.is_folded("a", 1));
    assert!(!tree.is_folded("b", 1));
}

// SidebarLayout+DoneFold

#[test]
fn done_rows_fold_behind_one_row_at_the_end_and_open_below_it() {
    let workspaces = vec![Some(ws("a")), Some(done("b")), Some(ws("c")), Some(done("d"))];
    let drawn = entries(&[(0, 0), (1, 0), (2, 0), (3, 0)]);
    let mut o = FoldOptions { folds_done: true, ..FoldOptions::default() };
    assert_eq!(fold(&drawn, &workspaces, &[], &o), entries(&[(0, 0), (2, 0), (DONE_FOLD, 2)]));
    o.open.insert(FoldKind::Done);
    assert_eq!(
        fold(&drawn, &workspaces, &[], &o),
        entries(&[(0, 0), (2, 0), (DONE_FOLD, 2), (1, 0), (3, 0)])
    );
    o.active = Some("b".to_owned());
    o.open.clear();
    assert_eq!(
        fold(&drawn, &workspaces, &[], &o),
        entries(&[(0, 0), (1, 0), (2, 0), (DONE_FOLD, 1)])
    );
    o.filtering = true;
    assert_eq!(fold(&drawn, &workspaces, &[], &o), drawn, "a filter shows a match where it is");
}

#[test]
fn folds_draw_automatic_then_settled_then_done_then_archived() {
    let workspaces = vec![
        Some(Workspace { archived: true, ..ws("arch") }),
        Some(done("done")),
        Some(ws("settled")),
        Some(ws("auto")),
        Some(ws("live")),
    ];
    let drawn = entries(&[(0, 0), (1, 0), (2, 0), (3, 0), (4, 0)]);
    let o = FoldOptions {
        folds_done: true,
        folds_archived: true,
        settled: HashSet::from(["settled".to_owned()]),
        automatic: HashSet::from(["auto".to_owned()]),
        ..FoldOptions::default()
    };
    assert_eq!(
        fold(&drawn, &workspaces, &[], &o),
        entries(&[
            (4, 0),
            (AUTOMATIC_FOLD, 1),
            (SETTLED_FOLD, 1),
            (DONE_FOLD, 1),
            (ARCHIVED_FOLD, 1)
        ])
    );
    // A nesting tree keeps settled and automatic rows in place unless agent-started rows hide.
    let nested = FoldOptions { tree: Some(FoldTree::default()), ..o };
    assert_eq!(
        fold(&drawn, &workspaces, &[], &nested),
        entries(&[(2, 0), (3, 0), (4, 0), (DONE_FOLD, 1), (ARCHIVED_FOLD, 1)])
    );
}

#[test]
fn a_done_root_takes_its_run_and_the_active_row_keeps_its_run_in_place() {
    let workspaces = vec![Some(done("root")), Some(ws("child")), Some(ws("other"))];
    let drawn = entries(&[(0, 0), (1, 1), (2, 0)]);
    let mut o = FoldOptions { folds_done: true, ..FoldOptions::default() };
    assert_eq!(fold(&drawn, &workspaces, &[], &o), entries(&[(2, 0), (DONE_FOLD, 2)]));
    o.active = Some("child".to_owned());
    assert_eq!(fold(&drawn, &workspaces, &[], &o), drawn);
}

#[test]
fn past_the_row_limit_the_rest_hide_behind_show_more_but_the_active_and_needing_rows_stay() {
    let mut workspaces: Vec<Option<Workspace>> =
        (0..6).map(|n| Some(ws(&format!("w{n}")))).collect();
    if let Some(Some(w)) = workspaces.get_mut(4) {
        w.needs_you = true;
    }
    let drawn = entries(&[(0, 0), (1, 0), (2, 0), (3, 0), (4, 0), (5, 0)]);
    let mut o =
        FoldOptions { row_limit: 2, active: Some("w5".to_owned()), ..FoldOptions::default() };
    assert_eq!(
        fold(&drawn, &workspaces, &[], &o),
        entries(&[(0, 0), (1, 0), (4, 0), (5, 0), (SHOW_MORE, 2)])
    );
    o.show_more_open = true;
    let mut opened = drawn.clone();
    opened.push(Entry { index: SHOW_MORE, depth: 0 });
    assert_eq!(fold(&drawn, &workspaces, &[], &o), opened);
    // One row over the limit shows whole.
    o.row_limit = 5;
    assert_eq!(fold(&drawn, &workspaces, &[], &o), drawn);
    // Entries the limit does not count always show.
    o = FoldOptions { row_limit: 1, ..FoldOptions::default() };
    let limits = [false, false, false, true, true, true];
    assert_eq!(
        fold(&drawn, &workspaces, &limits, &o),
        entries(&[(0, 0), (1, 0), (2, 0), (3, 0), (4, 0), (SHOW_MORE, 1)])
    );
}

// SidebarDragKeepsDoneFoldTests

#[test]
fn which_drags_unfold() {
    let mut o = FoldOptions {
        folds_done: true,
        open: HashSet::from([FoldKind::Done]),
        active: Some("a".to_owned()),
        ..FoldOptions::default()
    };
    assert!(drag_unfolds(&[ws("b"), done("d")], &[], &o), "a mixed drag");
    assert!(drag_unfolds(&[done("d")], &[], &o), "a lone Done row");
    assert!(!drag_unfolds(&[ws("b"), ws("c")], &[], &o), "no Done row");
    assert!(!drag_unfolds(&[done("a"), ws("b")], &[], &o), "the active Done row keeps its place");
    o.open.clear();
    assert!(drag_unfolds(&[done("d")], &[], &o), "a selected Done row a closed fold hides");
    o.folds_done = false;
    assert!(!drag_unfolds(&[done("d")], &[], &o), "no fold");
}

// SidebarLineageNestingTests.aDragOfADoneRowUnfoldsWithTheTree

#[test]
fn a_drag_of_a_done_row_unfolds_with_the_tree() {
    let mut o = FoldOptions {
        folds_done: true,
        active: Some("mine".to_owned()),
        tree: Some(FoldTree {
            parents: parents(&[("lane", "coordinator"), ("sub", "lane")]),
            hides_started: false,
        }),
        ..FoldOptions::default()
    };
    assert!(drag_unfolds(&[done("coordinator")], &[], &o), "a Done root");
    assert!(drag_unfolds(&[done("lane")], &[], &o), "a Done nested row");
    assert!(!drag_unfolds(&[ws("mine")], &[], &o), "a row outside any Done run");
    let list = |marked: &str| -> Vec<Workspace> {
        ["coordinator", "lane", "sub", "mine"]
            .iter()
            .map(|id| if *id == marked { done(id) } else { ws(id) })
            .collect()
    };
    let done_root = list("coordinator");
    assert!(drag_unfolds(&[ws("lane")], &done_root, &o), "a lane in a Done root's run");
    assert!(drag_unfolds(&[ws("sub")], &done_root, &o), "two levels under a Done root");
    assert!(!drag_unfolds(&[ws("mine")], &done_root, &o), "a row outside the Done run");
    let done_lane = list("lane");
    assert!(drag_unfolds(&[ws("coordinator")], &done_lane, &o), "the parent of a Done lane");
    assert!(!drag_unfolds(&[ws("mine")], &done_lane, &o), "no Done row above or below");
    o.active = Some("coordinator".to_owned());
    assert!(!drag_unfolds(&[ws("lane")], &done_root, &o), "under the active Done root");
    o.folds_done = false;
    assert!(!drag_unfolds(&[done("coordinator")], &done_root, &o), "no fold");
}

#[test]
fn a_gap_opens_before_the_first_later_root_else_the_first_fold_row_else_at_the_end() {
    let gap = Gap { section: "s".to_owned(), group: None, index: 2 };
    let nested = entries(&[(0, 0), (2, 1), (1, 0), (3, 0)]);
    assert_eq!(gap_entry(&nested, Some(&gap), "s", None, 4), Some(Some(3)));
    let folded = entries(&[(0, 0), (1, 0), (DONE_FOLD, 2)]);
    assert_eq!(gap_entry(&folded, Some(&gap), "s", None, 4), Some(Some(DONE_FOLD)));
    let late = Gap { index: 4, ..gap.clone() };
    assert_eq!(gap_entry(&nested, Some(&late), "s", None, 4), Some(None));
    assert_eq!(
        gap_entry(&entries(&[(0, 0), (1, 0)]), Some(&gap), "s", None, 4),
        None,
        "model order"
    );
    assert_eq!(gap_entry(&nested, Some(&gap), "t", None, 4), None, "another list");
    assert_eq!(gap_entry(&nested, None, "s", None, 4), None);
}

#[test]
fn a_filter_keeps_every_group_above_a_match() {
    let group = |id: &str, parent: Option<&str>, visible| MatchGroup {
        id: id.to_owned(),
        parent: parent.map(str::to_owned),
        visible,
    };
    let groups = [
        group("top", None, false),
        group("mid", Some("top"), false),
        group("leaf", Some("mid"), true),
        group("loop", Some("loop"), true),
        group("idle", Some("top"), false),
    ];
    assert_eq!(path_to_match(&groups), vec!["loop", "mid", "top"]);
}

#[test]
fn folder_buckets_list_no_folder_last() {
    let folders = vec![
        Some(String::new()),
        None,
        Some("b".to_owned()),
        Some("a".to_owned()),
        Some("b".to_owned()),
    ];
    let (order, members) = folder_buckets(&folders);
    assert_eq!(order, vec!["b", "a", ""]);
    assert_eq!(members["b"], vec![2, 4]);
    assert_eq!(members[""], vec![0]);
}

// SidebarRowHoverInsetTests

#[test]
fn the_hover_pill_is_the_frame_inset_with_rounded_corners() {
    let rect = Rect { x: 0.0, y: 0.0, width: 100.0, height: 30.0 };
    let at = |x, y| pill(rect, 4.0, 10.0, Point { x, y });
    assert!(at(50.0, 15.0));
    assert!(!at(50.0, 3.5));
    assert!(!at(50.0, 26.5));
    assert!(at(50.0, 4.0));
    assert!(at(0.5, 15.0));
    assert!(at(4.0, 8.0));
    assert!(!at(2.0, 6.0));
    assert!(!at(2.0, 24.0));
    assert!(!at(98.0, 6.0));
    assert!(!at(98.0, 24.0));
    assert!(!at(100.0, 15.0));
    assert!(!at(-0.5, 15.0));
    let short = Rect { x: 0.0, y: 0.0, width: 100.0, height: 10.0 };
    for radius in [3.0, 1000.0] {
        assert!(pill(short, 2.0, radius, Point { x: 0.5, y: 5.0 }));
        assert!(!pill(short, 2.0, radius, Point { x: 0.5, y: 2.5 }));
    }
    assert!(!pill(short, 5.0, 3.0, Point { x: 50.0, y: 5.0 }), "an inset that eats the row");
}

fn row(kind: RowKind, id: &str, y: f64, height: f64, group: Option<&str>) -> Row {
    Row { kind, id: id.to_owned(), y, height, group: group.map(str::to_owned), collapsed: false }
}

#[test]
fn a_rows_hit_area_meets_its_neighbor_halfway_across_the_spacing() {
    let rows = [
        row(RowKind::Workspace, "a", 0.0, 28.0, None),
        row(RowKind::Workspace, "b", 30.0, 28.0, None),
        row(RowKind::Workspace, "c", 70.0, 28.0, None),
    ];
    assert_eq!(row_at(&rows, 2.0, -1.0), None);
    assert_eq!(row_at(&rows, 2.0, 27.9), Some(0));
    assert_eq!(row_at(&rows, 2.0, 28.5), Some(0));
    assert_eq!(row_at(&rows, 2.0, 29.0), Some(1));
    assert_eq!(row_at(&rows, 2.0, 60.0), None, "a section gap");
    assert_eq!(row_at(&rows, 2.0, 99.0), None);
}

#[test]
fn a_group_header_sticks_until_its_last_member_pushes_it_off() {
    let rows = [
        row(RowKind::Group, "g", 0.0, 20.0, Some("g")),
        row(RowKind::Workspace, "a", 20.0, 28.0, Some("g")),
        row(RowKind::Workspace, "b", 48.0, 28.0, Some("n")),
        row(RowKind::Group, "h", 76.0, 20.0, Some("h")),
    ];
    let lift = HashMap::from([("n".to_owned(), "g".to_owned())]);
    assert_eq!(stuck_header(&rows, 25.0, &lift), Some((0, 25.0)));
    assert_eq!(stuck_header(&rows, 60.0, &lift), Some((0, 56.0)));
    assert_eq!(stuck_header(&rows, 0.0, &lift), None, "the header shows in place");
    assert_eq!(stuck_header(&rows, 80.0, &lift), Some((3, 76.0)), "the last header ends the list");
    assert_eq!(stuck_header(&rows, 60.0, &HashMap::new()), None, "n is its own group");
}

#[test]
fn a_reveal_takes_the_headers_above_and_drops_context_that_does_not_fit() {
    let rows = [
        row(RowKind::Section, "s", 0.0, 20.0, None),
        row(RowKind::Workspace, "a", 20.0, 28.0, None),
        row(RowKind::Group, "g", 50.0, 20.0, Some("g")),
        row(RowKind::Workspace, "b", 70.0, 28.0, Some("g")),
        row(RowKind::Workspace, "c", 100.0, 28.0, Some("g")),
    ];
    let extent =
        |id: &str, height: f64| reveal_extent(&rows, RowKind::Workspace, id, None, height, 140.0);
    assert_eq!(extent("b", 400.0), Some(Span { start: 50.0, length: 48.0 }));
    assert_eq!(extent("b", 60.0), Some(Span { start: 70.0, length: 28.0 }), "the header drops");
    assert_eq!(extent("c", 400.0), Some(Span { start: 100.0, length: 40.0 }), "the list's end");
    assert_eq!(extent("c", 50.0), Some(Span { start: 100.0, length: 28.0 }), "the end drops");
    assert_eq!(extent("a", 400.0), Some(Span { start: 0.0, length: 48.0 }), "the list's top");
    assert_eq!(extent("missing", 400.0), None);
}

#[test]
fn the_rows_in_view_are_found_by_search_or_read_whole_with_a_gap() {
    let rows = [
        row(RowKind::Workspace, "a", 0.0, 28.0, None),
        row(RowKind::Workspace, "b", 30.0, 28.0, None),
        row(RowKind::Workspace, "c", 60.0, 28.0, None),
    ];
    assert_eq!(viewport_positions(&rows, false, 29.0, 61.0), vec![1, 2]);
    assert_eq!(viewport_positions(&rows, true, 29.0, 61.0), vec![1, 2]);
    assert!(on_screen(&rows, RowKind::Workspace, "c", 50.0, 20.0));
    assert!(!on_screen(&rows, RowKind::Workspace, "a", 28.0, 20.0));
    assert!(!on_screen(&rows, RowKind::Group, "a", 0.0, 20.0));
}

// Vectors from a Python transliteration of the Swift (schemas/sidebar-list-rules/vectors.json).

fn same(a: &Value, b: &Value) -> bool {
    match (a, b) {
        (Value::Number(x), Value::Number(y)) => x.as_f64() == y.as_f64(),
        (Value::Array(x), Value::Array(y)) => {
            x.len() == y.len() && x.iter().zip(y).all(|(x, y)| same(x, y))
        }
        (Value::Object(x), Value::Object(y)) => {
            x.len() == y.len() && x.iter().all(|(k, v)| y.get(k).is_some_and(|w| same(v, w)))
        }
        _ => a == b,
    }
}

#[test]
fn the_rules_match_the_swift_vectors() {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../../schemas/sidebar-list-rules/vectors.json");
    let doc: Value =
        serde_json::from_str(&std::fs::read_to_string(path).expect("vectors")).expect("json");
    let cases = doc["cases"].as_array().expect("cases");
    assert!(cases.len() >= 1000);
    for (n, case) in cases.iter().enumerate() {
        let request: Request = serde_json::from_value(case["request"].clone()).expect("request");
        let answer = serde_json::to_value(respond(&request)).expect("answer");
        assert!(
            same(&answer, &case["response"]),
            "case {n}: {}\nwant {}\ngot  {answer}",
            case["request"],
            case["response"]
        );
    }
}

#[test]
fn a_rule_request_round_trips_through_json() {
    let request: Request = serde_json::from_value(json!({
        "rule": "fold", "drawn": [{"index": 0, "depth": 0}, {"index": 1, "depth": 0}],
        "workspaces": [{"id": "a"}, {"id": "b", "done": true}], "options": {"foldsDone": true}
    }))
    .expect("request");
    assert_eq!(
        serde_json::to_value(respond(&request)).expect("answer"),
        json!({"drawn": [{"index": 0, "depth": 0}, {"index": -1, "depth": 1}]})
    );
}
