use super::*;
use proptest::prelude::*;

const W: Rect = Rect::new(0.0, 0.0, 1200.0, 800.0);
const GAP: f64 = 1.0;

/// A shape: a leaf, or a split of shapes. Laid out like the app: even fractions, `GAP` dividers.
#[derive(Debug, Clone)]
enum Shape {
    Leaf,
    Split(Axis, Vec<Shape>),
}

fn lay(shape: &Shape, slot: Rect, next: &mut u32) -> PaneNode {
    match shape {
        Shape::Leaf => {
            *next += 1;
            PaneNode::Leaf(Leaf {
                pane_id: format!("p{next}"),
                kind: PaneKind::Terminal,
                frame: slot,
                ..Leaf::default()
            })
        }
        Shape::Split(axis, kids) => {
            let spans = even(span(&slot, *axis), kids.len(), GAP);
            PaneNode::Split(Split {
                axis: *axis,
                fractions: vec![1.0 / kids.len() as f64; kids.len()],
                children: kids
                    .iter()
                    .zip(spans)
                    .map(|(k, s)| lay(k, with_span(&slot, *axis, s), next))
                    .collect(),
            })
        }
    }
}

fn shape() -> impl Strategy<Value = Shape> {
    let leaf = Just(Shape::Leaf);
    leaf.prop_recursive(4, 16, 4, |inner| {
        (
            prop::sample::select(vec![Axis::Horizontal, Axis::Vertical]),
            prop::collection::vec(inner, 2..4),
        )
            .prop_map(|(a, k)| Shape::Split(a, k))
    })
}

fn tree(s: &Shape) -> PaneNode {
    lay(s, W, &mut 0)
}

fn ids(n: &PaneNode) -> Vec<String> {
    n.leaves().iter().map(|l| l.pane_id.clone()).collect()
}

fn frames(n: &PaneNode) -> HashMap<String, Rect> {
    n.leaves().iter().map(|l| (l.pane_id.clone(), l.frame)).collect()
}

fn live(panes: Vec<String>) -> LiveTree {
    LiveTree { panes, root: None, bounds: Some(W), divider: GAP }
}

#[test]
fn the_same_tree_is_applied_exactly_with_nothing_to_animate() {
    let s = Shape::Split(
        Axis::Horizontal,
        vec![Shape::Leaf, Shape::Split(Axis::Vertical, vec![Shape::Leaf, Shape::Leaf])],
    );
    let cached = tree(&s);
    let a = reconcile(&cached, &live(ids(&cached)));
    assert_eq!(a.node, cached);
    assert!(a.transitions.is_empty() && a.moved.is_empty());
}

#[test]
fn a_removed_pane_gives_its_space_to_its_sibling_in_one_step() {
    // [p1 | [p2 / p3]]: close p2, p3 takes the whole right column; p1 does not move.
    let s = Shape::Split(
        Axis::Horizontal,
        vec![Shape::Leaf, Shape::Split(Axis::Vertical, vec![Shape::Leaf, Shape::Leaf])],
    );
    let cached = tree(&s);
    let before = frames(&cached);
    let a = reconcile(&cached, &live(vec!["p1".into(), "p3".into()]));
    let after = frames(&a.node);
    assert_eq!(after["p1"], before["p1"]);
    assert_eq!(after["p3"], Rect::new(before["p3"].x, 0.0, before["p3"].width, 800.0));
    assert_eq!(
        a.transitions,
        vec![Transition { kind: TransitionKind::Removed, panes: vec!["p2".into()] }]
    );
    assert_eq!(a.moved.len(), 1);
    assert_eq!(a.moved[0].pane_id, "p3");
}

#[test]
fn the_first_pane_closing_hands_the_window_to_the_rest() {
    let s = Shape::Split(
        Axis::Horizontal,
        vec![Shape::Leaf, Shape::Split(Axis::Vertical, vec![Shape::Leaf, Shape::Leaf])],
    );
    let cached = tree(&s);
    let a = reconcile(&cached, &live(vec!["p2".into(), "p3".into()]));
    let f = frames(&a.node);
    assert_eq!(f["p2"].x, 0.0);
    assert_eq!(f["p2"].width, 1200.0);
    assert_eq!(f["p2"].y + f["p2"].height, frames(&cached)["p2"].max_y());
}

#[test]
fn a_new_pane_splits_its_neighbour_evenly() {
    let cached = tree(&Shape::Split(Axis::Horizontal, vec![Shape::Leaf, Shape::Leaf]));
    let a = reconcile(&cached, &live(vec!["p1".into(), "p2".into(), "n".into()]));
    let f = frames(&a.node);
    assert_eq!(f["p1"], frames(&cached)["p1"]);
    assert!((f["p2"].width - f["n"].width).abs() < 1e-9);
    assert_eq!(f["n"].max_x(), 1200.0);
    assert_eq!(
        a.transitions,
        vec![Transition { kind: TransitionKind::Added, panes: vec!["n".into()] }]
    );
}

#[test]
fn an_explicit_live_tree_with_a_flipped_axis_is_restructured() {
    let cached = tree(&Shape::Split(Axis::Horizontal, vec![Shape::Leaf, Shape::Leaf]));
    let root = LiveNode::Split {
        axis: Axis::Vertical,
        children: vec![
            LiveNode::Leaf { pane_id: "p1".into(), kind: PaneKind::Terminal },
            LiveNode::Leaf { pane_id: "p2".into(), kind: PaneKind::Terminal },
        ],
    };
    let a = reconcile(
        &cached,
        &LiveTree { root: Some(root), bounds: Some(W), divider: GAP, ..LiveTree::default() },
    );
    assert!(a.transitions.iter().any(|t| t.kind == TransitionKind::Restructured));
    assert_eq!(a.moved.len(), 2);
}

#[test]
fn strip_keeps_survivors_and_lists_only_changes() {
    let cached = vec![
        TabSlot { id: "a".into(), x: 0.0, width: 100.0 },
        TabSlot { id: "b".into(), x: 102.0, width: 80.0 },
        TabSlot { id: "c".into(), x: 184.0, width: 90.0 },
    ];
    let same = reconcile_strip(&cached, &["a".into(), "b".into(), "c".into()], 120.0);
    assert_eq!(same.tabs, cached);
    assert!(same.changes.is_empty());
    let closed = reconcile_strip(&cached, &["a".into(), "c".into(), "d".into()], 120.0);
    assert_eq!(closed.tabs[0], cached[0]);
    assert_eq!(closed.tabs[1], TabSlot { id: "c".into(), x: 102.0, width: 90.0 });
    assert_eq!(closed.tabs[2].x, 194.0);
    let kinds: Vec<_> = closed.changes.iter().map(|c| (c.id.as_str(), c.kind)).collect();
    assert_eq!(
        kinds,
        [("c", ChangeKind::Moved), ("d", ChangeKind::Added), ("b", ChangeKind::Removed)]
    );
}

#[test]
fn rows_keep_measured_heights() {
    let cached = vec![
        RowHeight { id: "a".into(), height: 31.5 },
        RowHeight { id: "b".into(), height: 44.0 },
    ];
    let r = reconcile_rows(&cached, &["b".into(), "z".into()], 28.0);
    assert_eq!(
        r.rows,
        vec![
            RowHeight { id: "b".into(), height: 44.0 },
            RowHeight { id: "z".into(), height: 28.0 }
        ]
    );
    assert_eq!((r.added, r.removed), (vec!["z".to_string()], vec!["a".to_string()]));
}

fn idr(id: &str, r: Rect) -> IdRect {
    IdRect { id: id.into(), x: r.x, y: r.y, width: r.width, height: r.height }
}

#[test]
fn shift_score_is_zero_when_still_and_grows_with_the_move() {
    let a = vec![idr("a", Rect::new(0.0, 0.0, 100.0, 100.0))];
    assert_eq!(shift_score(&a, &a, &W), 0.0);
    let small = shift_score(&a, &[idr("a", Rect::new(10.0, 0.0, 100.0, 100.0))], &W);
    let big = shift_score(&a, &[idr("a", Rect::new(300.0, 0.0, 100.0, 100.0))], &W);
    assert!(0.0 < small && small < big);
    // A vanished or new element is not a shift.
    assert_eq!(shift_score(&a, &[idr("b", Rect::new(300.0, 0.0, 1.0, 1.0))], &W), 0.0);
}

proptest! {
    /// Whatever closes and opens, every surviving pane not reported as moved keeps its cached
    /// frame exactly, every live pane appears once, and leaves stay inside the window without
    /// overlapping.
    #[test]
    fn reconcile_never_moves_a_survivor_silently(s in shape(), drop_mask in any::<u32>(), new in 0usize..3) {
        let cached = tree(&s);
        let all = ids(&cached);
        let mut keep: Vec<String> = all.iter().enumerate().filter(|(i, _)| drop_mask & (1 << (i % 32)) == 0).map(|(_, id)| id.clone()).collect();
        keep.extend((0..new).map(|i| format!("new{i}")));
        let a = reconcile(&cached, &live(keep.clone()));
        let before = frames(&cached);
        let after = frames(&a.node);
        let mut got = ids(&a.node);
        got.sort();
        let mut want = keep.clone();
        want.sort();
        prop_assert_eq!(got, want);
        let moved: HashSet<&str> = a.moved.iter().map(|m| m.pane_id.as_str()).collect();
        for (id, f) in &after {
            if let Some(b) = before.get(id) {
                prop_assert!(moved.contains(id.as_str()) || f == b, "{id} moved silently: {b:?} -> {f:?}");
            }
            prop_assert!(f.x >= W.x - 1e-6 && f.max_x() <= W.max_x() + 1e-6 && f.y >= W.y - 1e-6 && f.max_y() <= W.max_y() + 1e-6);
        }
        let leaves = a.node.leaves();
        for (i, x) in leaves.iter().enumerate() {
            for y in &leaves[i + 1..] {
                prop_assert!(x.frame.intersection_area(&y.frame) < 1e-6, "{} overlaps {}", x.pane_id, y.pane_id);
            }
        }
        // Nothing closed and nothing opened: nothing moves and nothing animates.
        if keep.len() == all.len() && new == 0 {
            prop_assert!(a.moved.is_empty() && a.transitions.is_empty());
            prop_assert_eq!(&a.node, &cached);
        }
    }

    /// Survivors of the tab strip keep their width always, and their x when nothing before them
    /// changed.
    #[test]
    fn strip_survivors_keep_width(widths in prop::collection::vec(20.0f64..200.0, 1..12), mask in any::<u16>()) {
        let mut x = 0.0;
        let cached: Vec<TabSlot> = widths.iter().enumerate().map(|(i, w)| {
            let t = TabSlot { id: format!("t{i}"), x, width: *w };
            x += w + 2.0;
            t
        }).collect();
        let live: Vec<String> = cached.iter().enumerate().filter(|(i, _)| mask & (1 << i) == 0).map(|(_, t)| t.id.clone()).collect();
        let r = reconcile_strip(&cached, &live, 100.0);
        let first_gone = cached.iter().position(|t| !live.contains(&t.id)).unwrap_or(cached.len());
        for t in &r.tabs {
            let c = cached.iter().find(|c| c.id == t.id).unwrap();
            prop_assert_eq!(t.width, c.width);
            let i = cached.iter().position(|c| c.id == t.id).unwrap();
            if i < first_gone {
                prop_assert_eq!(t.x, c.x);
            }
        }
    }

    /// The score is never negative and 0 for identical layouts.
    #[test]
    fn shift_score_bounds(rects in prop::collection::vec((0.0f64..1000.0, 0.0f64..700.0, 1.0f64..400.0, 1.0f64..400.0), 0..8), dx in -50.0f64..50.0) {
        let a: Vec<IdRect> = rects.iter().enumerate().map(|(i, r)| idr(&format!("r{i}"), Rect::new(r.0, r.1, r.2, r.3))).collect();
        prop_assert_eq!(shift_score(&a, &a, &W), 0.0);
        let b: Vec<IdRect> = a.iter().map(|r| IdRect { x: r.x + dx, ..r.clone() }).collect();
        prop_assert!(shift_score(&a, &b, &W) >= 0.0);
    }
}
