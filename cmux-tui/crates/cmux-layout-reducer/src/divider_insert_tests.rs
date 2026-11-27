use super::*;
use crate::optimistic::{Request, respond};

fn leaf(pane: u64) -> Node {
    Node::Leaf { pane }
}

fn split(handle: u64, dir: Dir, ratio: f64, a: Node, b: Node) -> Node {
    Node::Split { split: Some(handle), split_id: None, dir, ratio, a: Box::new(a), b: Box::new(b) }
}

/// Each pane's share of `node`'s extent along `dir` (panes split across `dir` share one span).
fn spans(node: &Node, dir: Dir, start: f64, extent: f64, out: &mut Vec<(u64, f64, f64)>) {
    match node {
        Node::Leaf { pane } => out.push((*pane, start, extent)),
        Node::Split { dir: d, ratio, a, b, .. } if *d == dir => {
            spans(a, dir, start, extent * ratio, out);
            spans(b, dir, start + extent * ratio, extent * (1.0 - ratio), out);
        }
        Node::Split { a, b, .. } => {
            spans(a, dir, start, extent, out);
            spans(b, dir, start, extent, out);
        }
        _ => {}
    }
}

fn span_of(node: &Node, dir: Dir, pane: u64) -> (f64, f64) {
    let mut out = Vec::new();
    spans(node, dir, 0.0, 1.0, &mut out);
    let (_, start, extent) = out.into_iter().find(|(p, ..)| *p == pane).expect("pane shown");
    (start, extent)
}

fn close(a: f64, b: f64) -> bool {
    (a - b).abs() < 1e-9
}

#[test]
fn two_panes_side_by_side_share_the_width_in_thirds() {
    let layout = split(10, Dir::Right, 0.5, leaf(1), leaf(2));
    let plan = plan(&layout, 10).expect("plan");
    assert_eq!(
        plan,
        DividerInsert { target: 1, around: None, dir: Dir::Right, split: 10, ratio: DIVIDER_RATIO }
    );
    let shown = shown(&layout, &plan, 9, "split_new").expect("shown");
    assert_eq!(shown.pane_ids(), vec![1, 9, 2], "the new pane sits between the two");
    for (pane, start) in [(1, 0.0), (9, 1.0 / 3.0), (2, 2.0 / 3.0)] {
        let (s, e) = span_of(&shown, Dir::Right, pane);
        assert!(close(s, start) && close(e, 1.0 / 3.0), "pane {pane}: {s} {e}");
    }
}

#[test]
fn two_panes_stacked_share_the_height_in_thirds() {
    let layout = split(10, Dir::Down, 0.5, leaf(1), leaf(2));
    let plan = plan(&layout, 10).expect("plan");
    assert_eq!(plan.dir, Dir::Down);
    let shown = shown(&layout, &plan, 9, "split_new").expect("shown");
    assert_eq!(shown.pane_ids(), vec![1, 9, 2]);
    for pane in [1, 9, 2] {
        assert!(close(span_of(&shown, Dir::Down, pane).1, 1.0 / 3.0), "pane {pane}");
    }
}

#[test]
fn an_uneven_divider_still_gives_each_of_the_three_a_third() {
    let layout = split(10, Dir::Right, 0.8, leaf(1), leaf(2));
    let shown = shown(&layout, &plan(&layout, 10).expect("plan"), 9, "s").expect("shown");
    for pane in [1, 9, 2] {
        assert!(close(span_of(&shown, Dir::Right, pane).1, 1.0 / 3.0), "pane {pane}");
    }
}

#[test]
fn a_chain_of_three_inserts_at_the_divider_named_and_keeps_the_others() {
    // A | (B | C): the divider between B and C is split 11.
    let layout =
        split(10, Dir::Right, 1.0 / 3.0, leaf(1), split(11, Dir::Right, 0.5, leaf(2), leaf(3)));
    let at_bc = plan(&layout, 11).expect("plan");
    assert_eq!((at_bc.target, at_bc.around), (2, None));
    let shown_bc = shown(&layout, &at_bc, 9, "s").expect("shown");
    assert_eq!(shown_bc.pane_ids(), vec![1, 2, 9, 3]);
    assert!(close(span_of(&shown_bc, Dir::Right, 1).1, 1.0 / 3.0), "A keeps its third");
    // The divider between A and (B | C): the new pane goes right after A.
    let at_a = plan(&layout, 10).expect("plan");
    assert_eq!((at_a.target, at_a.around), (1, None));
    assert_eq!(shown(&layout, &at_a, 9, "s").expect("shown").pane_ids(), vec![1, 9, 2, 3]);
}

#[test]
fn a_nested_first_side_is_wrapped_whole_so_the_new_pane_spans_the_divider() {
    // (X / Y) | B: the divider is split 10, its first side the vertical split 20.
    let layout = split(10, Dir::Right, 0.5, split(20, Dir::Down, 0.5, leaf(1), leaf(2)), leaf(3));
    let plan = plan(&layout, 10).expect("plan");
    assert_eq!(plan.target, 2, "the first side's last pane touches the divider");
    assert_eq!(plan.around, Some(20));
    let shown = shown(&layout, &plan, 9, "split_new").expect("shown");
    assert_eq!(shown.pane_ids(), vec![1, 2, 9, 3]);
    // The new pane has the full height (it is not split with Y alone).
    let Node::Split { a, .. } = &shown else { panic!("split") };
    let Node::Split { a: wrapped, b: new, dir, split_id, .. } = a.as_ref() else { panic!("wrap") };
    assert_eq!((**new).clone(), leaf(9));
    assert_eq!(*dir, Dir::Right);
    assert_eq!(split_id.as_deref(), Some("split_new"));
    assert!(matches!(wrapped.as_ref(), Node::Split { split: Some(20), .. }));
    for pane in [9, 3] {
        assert!(close(span_of(&shown, Dir::Right, pane).1, 1.0 / 3.0), "pane {pane}");
    }
}

#[test]
fn a_nested_horizontal_divider_wraps_a_side_by_side_first_side() {
    // (X | Y) / B
    let layout = split(10, Dir::Down, 0.5, split(20, Dir::Right, 0.5, leaf(1), leaf(2)), leaf(3));
    let plan = plan(&layout, 10).expect("plan");
    assert_eq!((plan.target, plan.around, plan.dir), (2, Some(20), Dir::Down));
    let shown = shown(&layout, &plan, 9, "s").expect("shown");
    assert_eq!(shown.pane_ids(), vec![1, 2, 9, 3]);
    assert!(close(span_of(&shown, Dir::Down, 9).1, 1.0 / 3.0));
}

#[test]
fn a_divider_deep_in_the_tree_is_found() {
    // A | ((X / Y) | B) with the inner divider 11 between (X / Y) and B.
    let inner = split(11, Dir::Right, 0.5, split(20, Dir::Down, 0.5, leaf(4), leaf(5)), leaf(3));
    let layout = split(10, Dir::Right, 0.5, leaf(1), inner);
    let plan = plan(&layout, 11).expect("plan");
    assert_eq!((plan.target, plan.around), (5, Some(20)));
    let shown = shown(&layout, &plan, 9, "s").expect("shown");
    assert_eq!(shown.pane_ids(), vec![1, 4, 5, 9, 3]);
    assert!(close(span_of(&shown, Dir::Right, 1).1, 0.5), "the outer side keeps its half");
}

#[test]
fn an_unknown_split_or_a_provisional_first_side_plans_nothing() {
    let layout = split(10, Dir::Right, 0.5, leaf(1), leaf(2));
    assert_eq!(plan(&layout, 99), None);
    assert_eq!(plan(&leaf(1), 10), None);
    // A first side the daemon has not named yet cannot be wrapped.
    let provisional = Node::Split {
        split: None,
        split_id: Some("p".into()),
        dir: Dir::Down,
        ratio: 0.5,
        a: Box::new(leaf(1)),
        b: Box::new(leaf(2)),
    };
    let layout = split(10, Dir::Right, 0.5, provisional, leaf(3));
    assert_eq!(plan(&layout, 10), None);
}

#[test]
fn split_around_refuses_a_target_that_is_not_the_last_pane() {
    let layout = split(10, Dir::Right, 0.5, split(20, Dir::Down, 0.5, leaf(1), leaf(2)), leaf(3));
    assert_eq!(split_around(&layout, 20, 1, Dir::Right, 0.5, 9, "s"), None);
    assert!(split_around(&layout, 20, 2, Dir::Right, 0.5, 9, "s").is_some());
}

#[test]
fn the_optimistic_operation_answers_the_plan_and_a_split_around() {
    let request: Request = serde_json::from_value(serde_json::json!({
        "op": "insert_at_divider",
        "layout": {"type": "split", "split": 10, "dir": "right", "ratio": 0.5,
                   "a": {"type": "split", "split": 20, "dir": "down", "ratio": 0.5,
                         "a": {"type": "leaf", "pane": 1}, "b": {"type": "leaf", "pane": 2}},
                   "b": {"type": "leaf", "pane": 3}},
        "split": 10
    }))
    .expect("request");
    assert_eq!(
        respond(&request),
        serde_json::json!({"target": 2, "around": 20, "dir": "right", "split": 10, "ratio": DIVIDER_RATIO})
    );
    let split: Request = serde_json::from_value(serde_json::json!({
        "op": "split",
        "screen": {"layout": {"type": "split", "split": 10, "dir": "right", "ratio": 0.5,
                   "a": {"type": "split", "split": 20, "dir": "down", "ratio": 0.5,
                         "a": {"type": "leaf", "pane": 1}, "b": {"type": "leaf", "pane": 2}},
                   "b": {"type": "leaf", "pane": 3}}, "panes": [1, 2, 3]},
        "target": 2, "dir": "right", "ratio": 0.5, "leaf": 9, "split_id": "s", "around": 20
    }))
    .expect("split");
    let answer = respond(&split);
    assert_eq!(answer["pane_at"], 2);
    assert_eq!(answer["layout"]["a"]["split_id"], "s");
    assert_eq!(answer["layout"]["a"]["a"]["split"], 20);
    assert_eq!(answer["layout"]["a"]["b"]["pane"], 9);
}
