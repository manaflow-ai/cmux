use super::*;
use crate::screen_layout::{AGENT_CHAT, Dock, Edge, Row};

fn leaf(pane: &str) -> Node {
    Node::leaf(pane)
}

fn h(split: &str, ratio: f64, a: Node, b: Node) -> Node {
    Node::split(split, Axis::Horizontal, ratio, a, b)
}

fn v(split: &str, ratio: f64, a: Node, b: Node) -> Node {
    Node::split(split, Axis::Vertical, ratio, a, b)
}

fn column(id: &str, width: f64, root: Node) -> Column {
    Column { id: id.into(), width, root, dock: None, rows: Vec::new() }
}

fn docked(id: &str, width: f64, root: Node, mode: &str) -> Column {
    Column {
        dock: Some(Dock {
            edge: Edge::Left,
            mode: mode.into(),
            role: Some(AGENT_CHAT.into()),
            is_pinned: true,
            allows_tabs: true,
        }),
        ..column(id, width, root)
    }
}

/// `EqualizeColumnsTests.homeDock`.
fn home(width: f64) -> Column {
    docked("home", width, leaf("chat"), "docked")
}

fn ids(items: &[&str]) -> Vec<String> {
    items.iter().map(|item| (*item).to_owned()).collect()
}

fn screen(layout: Layout, viewport: f64) -> EqualizeScreen {
    let visible_panes = layout.panes().into_iter().collect();
    EqualizeScreen {
        layout,
        zoomed: false,
        visible_panes,
        viewport_width: Some(viewport),
        gap: 8.0,
        minimum_widths: BTreeMap::new(),
    }
}

fn width_of(values: &[EqualizeValue], id: &str) -> Option<f64> {
    values.iter().find_map(|value| match value {
        EqualizeValue::Width { column, width } if column == id => Some(*width),
        _ => None,
    })
}

fn ratio_in(values: &[EqualizeValue], id: &str) -> Option<f64> {
    values.iter().find_map(|value| match value {
        EqualizeValue::Ratio { split, ratio } if split == id => Some(*ratio),
        _ => None,
    })
}

fn equalized(outcome: EqualizeOutcome) -> Vec<EqualizeValue> {
    match outcome {
        EqualizeOutcome::Equalize(values) => values,
        EqualizeOutcome::NothingToEqualize => panic!("nothing to equalize"),
    }
}

// MARK: SplitNode

#[test]
fn split_helpers_walk_the_tree() {
    let tree = h("s1", 0.3, leaf("a"), v("s2", 0.5, leaf("b"), h("s3", 0.5, leaf("c"), leaf("d"))));
    assert_eq!(tree.splits(), ids(&["s1", "s2", "s3"]));
    assert!(tree.has_same_shape(&tree.setting_ratio(0.9, "s2")));
    assert!(!tree.has_same_shape(&h("s1", 0.3, leaf("a"), leaf("b"))));
    let (axis, a, b) = tree.node_for("s3").unwrap();
    assert_eq!((axis, a, b), (Axis::Horizontal, &leaf("c"), &leaf("d")));
    assert!(tree.node_for("nope").is_none());
    // s1's chain: a | (s2 counts as one cell) = 1/2.
    assert_eq!(tree.equalized_ratio("s1"), Some(0.5));
    let chain = h("x", 0.5, leaf("a"), h("y", 0.5, leaf("b"), leaf("c")));
    assert_eq!(chain.equalized_ratio("x"), Some(1.0 / 3.0));
    let replaced =
        chain.replacing_leaf("c", &|leaf_node| v("n", 0.5, leaf_node.clone(), leaf("new")));
    assert_eq!(
        replaced,
        h("x", 0.5, leaf("a"), h("y", 0.5, leaf("b"), v("n", 0.5, leaf("c"), leaf("new"))))
    );
}

// MARK: Split sizing

#[test]
fn splitting_a_chain_pane_evens_the_whole_chain() {
    let root = h("x", 0.5, leaf("a"), leaf("b"));
    assert_eq!(
        even_split_changes("b", Axis::Horizontal, &root),
        vec![RatioChange { split: "x".into(), ratio: 1.0 / 3.0 }]
    );
    assert!(
        even_split_changes("b", Axis::Vertical, &root).is_empty(),
        "across the chain: no change"
    );
    assert!(
        even_split_changes("a", Axis::Horizontal, &leaf("a")).is_empty(),
        "a lone pane has no chain"
    );
}

#[test]
fn split_sizing_reads_the_setting_and_the_pane_the_move_closes() {
    let layout = Layout::Splits(h("x", 0.3, leaf("a"), h("y", 0.5, leaf("b"), leaf("c"))));
    assert!(split_sizing_changes(&layout, "a", Axis::Horizontal, None, false).is_empty());
    let changes = split_sizing_changes(&layout, "a", Axis::Horizontal, None, true);
    // Four cells after the split: x becomes 2/4, y is already even.
    assert_eq!(changes, vec![RatioChange { split: "x".into(), ratio: 0.5 }]);
    // Without c, the tree is x(a, b): a splits into two of three.
    let pruned = split_sizing_changes(&layout, "a", Axis::Horizontal, Some("c"), true);
    assert_eq!(pruned, vec![RatioChange { split: "x".into(), ratio: 2.0 / 3.0 }]);
    let rows = Column {
        rows: vec![
            Row { id: "r1".into(), height: 500, root: h("t", 0.5, leaf("a"), leaf("b")) },
            Row { id: "r2".into(), height: 500, root: leaf("c") },
        ],
        ..column("c1", 1.0, v("rs", 0.5, h("t", 0.5, leaf("a"), leaf("b")), leaf("c")))
    };
    let columns = Layout::Columns(vec![rows]);
    assert_eq!(
        split_sizing_changes(&columns, "a", Axis::Horizontal, None, true),
        vec![RatioChange { split: "t".into(), ratio: 2.0 / 3.0 }],
        "a row's own tree, not the compat chain"
    );
}

// MARK: Equalize (EqualizeColumnsTests)

#[test]
fn home_chat_and_one_column_get_the_same_width() {
    for viewport in [1440.0, 1920.0, 2560.0] {
        let values = equalized(equalize(&screen(
            Layout::Columns(vec![home(0.3), column("c1", 1.0, leaf("p1"))]),
            viewport,
        )));
        let each = (viewport - 3.0 * 8.0) / 2.0;
        let fraction = (each + 8.0) / (viewport - 8.0);
        assert_eq!(width_of(&values, "home"), Some(fraction), "{viewport}");
        assert_eq!(width_of(&values, "c1"), None, "the one strip column keeps the whole strip");
    }
}

#[test]
fn home_chat_and_two_columns_even_their_splits_too() {
    let layout = Layout::Columns(vec![
        home(0.5),
        column("c1", 0.7, v("v", 0.8, leaf("p1"), leaf("p2"))),
        column("c2", 0.3, leaf("p3")),
    ]);
    let values = equalized(equalize(&screen(layout, 1920.0)));
    assert_eq!(ratio_in(&values, "v"), Some(0.5), "the split inside a column is even too");
    assert_eq!(width_of(&values, "c1"), Some(0.5));
    assert_eq!(width_of(&values, "c2"), Some(0.5));
}

#[test]
fn narrow_window_keeps_the_chat_at_its_minimum() {
    let mut s = screen(
        Layout::Columns(vec![
            home(0.2),
            column("c1", 0.8, leaf("p1")),
            column("c2", 0.2, leaf("p2")),
        ]),
        900.0,
    );
    s.minimum_widths.insert("home".into(), 400.0);
    let values = equalized(equalize(&s));
    let home_width = width_of(&values, "home").unwrap();
    assert!(home_width >= (400.0 + 8.0) / (900.0 - 8.0) - 1e-9, "{home_width}");
}

#[test]
fn plain_columns_get_the_same_width() {
    let layout = Layout::Columns(vec![
        column("c1", 0.33, leaf("p1")),
        column("c2", 0.5, leaf("p2")),
        column("c3", 0.17, leaf("p3")),
    ]);
    let values = equalized(equalize(&screen(layout, 1500.0)));
    for id in ["c1", "c2", "c3"] {
        assert_eq!(width_of(&values, id), Some(1.0 / 3.0), "{id}");
    }
}

#[test]
fn too_many_columns_share_by_the_ones_in_view() {
    let columns: Vec<Column> =
        (1..=8).map(|n| column(&format!("c{n}"), 0.5, leaf(&format!("p{n}")))).collect();
    let mut s = screen(Layout::Columns(columns), 1200.0);
    s.visible_panes = ["p1", "p2"].into_iter().map(str::to_owned).collect();
    s.minimum_widths = (1..=8).map(|n| (format!("c{n}"), 200.0)).collect();
    assert_eq!(equalize(&s), EqualizeOutcome::Equalize(Vec::new()), "two in view: each keeps half");
}

#[test]
fn split_screen_equalizes_its_splits() {
    let s = screen(Layout::Splits(h("h", 0.8, leaf("a"), leaf("b"))), 1200.0);
    assert_eq!(
        equalize(&s),
        EqualizeOutcome::Equalize(vec![EqualizeValue::Ratio { split: "h".into(), ratio: 0.5 }])
    );
}

#[test]
fn lone_chat_has_nothing_to_equalize() {
    let s = screen(Layout::Columns(vec![home(0.4)]), 1400.0);
    assert_eq!(equalize(&s), EqualizeOutcome::NothingToEqualize);
}

#[test]
fn floating_dock_keeps_its_width() {
    let layout = Layout::Columns(vec![
        docked("home", 0.3, leaf("chat"), "overlay"),
        column("c1", 0.7, leaf("p1")),
        column("c2", 0.3, leaf("p2")),
    ]);
    let values = equalized(equalize(&screen(layout, 1600.0)));
    assert_eq!(width_of(&values, "home"), None);
    assert_eq!(width_of(&values, "c1"), Some(0.5));
    assert_eq!(width_of(&values, "c2"), Some(0.5));
}

#[test]
fn equalize_split_reads_the_first_screen_holding_it() {
    let first = Layout::Columns(vec![column(
        "c1",
        1.0,
        h("x", 0.9, leaf("a"), h("y", 0.5, leaf("b"), leaf("c"))),
    )]);
    let second = Layout::Splits(h("x", 0.5, leaf("d"), leaf("e")));
    assert_eq!(equalize_split(&[first.clone(), second.clone()], "x"), Some(1.0 / 3.0));
    assert_eq!(equalize_split(&[second, first], "x"), Some(0.5));
    assert_eq!(equalize_split(&[], "x"), None);
}

#[test]
fn fraction_for_pixel_width_clamps_and_survives_a_tiny_viewport() {
    assert_eq!(fraction_for_pixel_width(100.0, 8.0, 8.0), DEFAULT_COLUMN_WIDTH);
    assert_eq!(fraction_for_pixel_width(10_000.0, 1000.0, 0.0), 1.0);
    assert_eq!(fraction_for_pixel_width(1.0, 1000.0, 0.0), 0.1);
}

// MARK: New column (NewColumnKeepsWidthTests, ColumnAddFocusTests, HomeLoneDockTests)

#[test]
fn a_new_column_takes_the_modes_width() {
    let uneven = vec![
        column("c0", 0.45, leaf("p0")),
        column("c1", 0.8, leaf("p1")),
        column("c2", 0.3, leaf("p2")),
    ];
    let visible = ids(&["c0", "c1"]);
    let plan = |mode| new_column_plan(mode, &uneven, Some("c1"), &visible, 2.0 / 3.0, None);
    assert_eq!(plan(NewColumnWidthMode::Fixed), 2.0 / 3.0);
    assert_eq!(plan(NewColumnWidthMode::MatchCurrent), 0.8);
    assert_eq!(plan(NewColumnWidthMode::FitScreen), 1.0 / 3.0);
    let lone = vec![column("c0", 1.0, leaf("p0"))];
    assert_eq!(
        new_column_plan(NewColumnWidthMode::FitScreen, &lone, Some("c0"), &[], 0.5, None),
        0.5,
        "an anchor out of view still shares"
    );
    assert_eq!(new_column_plan(NewColumnWidthMode::MatchCurrent, &lone, None, &[], 0.5, None), 1.0);
    assert_eq!(
        new_column_plan(NewColumnWidthMode::Fixed, &lone, None, &[], 5.0, None),
        1.0,
        "clamped"
    );
}

#[test]
fn a_fixed_column_beside_full_width_ones_is_its_width() {
    let columns = vec![column("c0", 1.0, leaf("p0")), column("c1", 1.0, leaf("p1"))];
    let width = new_column_plan(
        NewColumnWidthMode::Fixed,
        &columns,
        Some("c1"),
        &ids(&["c1"]),
        2.0 / 3.0,
        None,
    );
    assert_eq!(width, 2.0 / 3.0);
}

#[test]
fn a_column_beside_the_lone_dock_fills_the_strip() {
    let lone = vec![home(0.5)];
    for mode in
        [NewColumnWidthMode::MatchCurrent, NewColumnWidthMode::FitScreen, NewColumnWidthMode::Fixed]
    {
        assert_eq!(new_column_plan(mode, &lone, Some("home"), &[], 0.5, None), 1.0, "{mode:?}");
    }
    let beside = vec![home(0.5), column("c1", 0.5, leaf("p1"))];
    let visible = ids(&["c1"]);
    assert_eq!(
        new_column_plan(
            NewColumnWidthMode::MatchCurrent,
            &beside,
            Some("c1"),
            &visible,
            0.5,
            Some("p1")
        ),
        1.0,
        "dragging out the only strip pane leaves the dock alone"
    );
    assert_eq!(
        new_column_plan(NewColumnWidthMode::MatchCurrent, &beside, Some("c1"), &visible, 0.5, None),
        0.5
    );
}

#[test]
fn a_split_screen_counts_as_one_full_width_column() {
    let layout = Layout::Splits(h("x", 0.5, leaf("a"), leaf("b")));
    let visible: BTreeSet<String> = ["a".to_owned()].into();
    assert_eq!(
        new_column_width(Some(&layout), "a", &visible, NewColumnWidthMode::MatchCurrent, 0.5, None),
        1.0
    );
    assert_eq!(
        new_column_width(Some(&layout), "a", &visible, NewColumnWidthMode::FitScreen, 0.5, None),
        0.5
    );
    assert_eq!(
        new_column_width(None, "a", &visible, NewColumnWidthMode::MatchCurrent, 0.5, None),
        1.0
    );
}

// MARK: Pane placement

fn frame(width: f64, height: f64) -> Frame {
    Frame { x: 0.0, y: 0.0, width, height }
}

#[test]
fn auto_layout_splits_the_largest_pane_along_its_longer_side() {
    let layout = Layout::Splits(h("x", 0.5, leaf("a"), v("y", 0.5, leaf("b"), leaf("c"))));
    let frames: BTreeMap<String, Frame> = [
        ("a".to_owned(), frame(400.0, 800.0)),
        ("b".to_owned(), frame(400.0, 400.0)),
        ("c".to_owned(), frame(400.0, 400.0)),
    ]
    .into();
    assert_eq!(
        auto_split(&layout, &frames, &[]),
        Some(AutoSplit { pane: "a".into(), axis: Axis::Vertical })
    );
    let tie: BTreeMap<String, Frame> =
        [("b".to_owned(), frame(400.0, 400.0)), ("c".to_owned(), frame(400.0, 400.0))].into();
    assert_eq!(
        auto_split(&layout, &tie, &ids(&["c"])),
        Some(AutoSplit { pane: "c".into(), axis: Axis::Horizontal }),
        "a tie goes to the recent pane"
    );
    assert_eq!(
        auto_split(&layout, &BTreeMap::new(), &ids(&["b"])),
        Some(AutoSplit { pane: "b".into(), axis: Axis::Horizontal }),
        "nothing shown: the most recent pane"
    );
    let docks_only = Layout::Columns(vec![home(0.5)]);
    assert_eq!(auto_split(&docks_only, &BTreeMap::new(), &[]), None);
}

#[test]
fn a_new_pane_is_a_tab_unless_auto_layout_splits() {
    let layout = Layout::Splits(h("x", 0.5, leaf("a"), leaf("b")));
    let frames: BTreeMap<String, Frame> = [("b".to_owned(), frame(800.0, 400.0))].into();
    assert_eq!(
        pane_plan(&layout, "a", &[], &frames, NewPanePlacement::Tab, true),
        PanePlan::Tab("a".into())
    );
    assert_eq!(
        pane_plan(&layout, "a", &[], &frames, NewPanePlacement::Split, false),
        PanePlan::Tab("a".into())
    );
    assert_eq!(
        pane_plan(&layout, "a", &[], &frames, NewPanePlacement::Split, true),
        PanePlan::Split(AutoSplit { pane: "b".into(), axis: Axis::Horizontal })
    );
}

// MARK: Main pane, chat placement (MainPaneLayoutTests, ChatLinkReusesRightPaneTests)

#[test]
fn main_pane_follows_the_override_then_the_setting() {
    for setting in [false, true] {
        assert_eq!(main_pane_is_on(setting, MainPaneOverride::Setting), setting);
        assert!(main_pane_is_on(setting, MainPaneOverride::On));
        assert!(!main_pane_is_on(setting, MainPaneOverride::Off));
    }
    assert_eq!(main_pane_side(&ChatColumnPlacement::Here), None);
    assert_eq!(main_pane_side(&ChatColumnPlacement::BesideDock), None);
    assert_eq!(main_pane_side(&ChatColumnPlacement::DockChat), Some(ChatColumnPlacement::DockChat));
    let tab = ChatColumnPlacement::Tab("p".into());
    assert_eq!(main_pane_side(&tab), Some(tab));
}

#[test]
fn a_dock_pick_opens_beside_the_dock_only_with_a_strip() {
    assert_eq!(dock_pick(false, false), DockPick::Usual);
    assert_eq!(dock_pick(false, true), DockPick::Usual);
    assert_eq!(dock_pick(true, false), DockPick::Beside { closes_page: true });
    assert_eq!(dock_pick(true, true), DockPick::Beside { closes_page: false });
}

#[test]
fn a_split_screen_is_one_implicit_column() {
    let root = h("x", 0.5, leaf("a"), leaf("b"));
    let splits = Layout::Splits(root.clone());
    assert_eq!(chat_columns("s1", &splits, "a"), vec![column("implicit:s1", 1.0, root)]);
    assert!(chat_columns("s1", &splits, "z").is_empty());
    let columns = vec![home(0.3), column("c1", 0.7, leaf("p1"))];
    assert_eq!(chat_columns("s1", &Layout::Columns(columns.clone()), "z"), columns);
}
