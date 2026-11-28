use super::*;
use crate::screen_layout::{Dock, Edge, Row};

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

fn dock(edge: Edge, pinned: bool, role: Option<&str>) -> Option<Dock> {
    Some(Dock {
        edge,
        mode: "docked".into(),
        role: role.map(str::to_owned),
        is_pinned: pinned,
        allows_tabs: true,
    })
}

fn row(id: &str, height: i64, root: Node) -> Row {
    Row { id: id.into(), height, root }
}

const EVEN: Sizing = Sizing { even: true, fits: false };
const FITS: Sizing = Sizing { even: false, fits: true };

#[test]
fn sibling_takes_the_parents_place() {
    let layout = Layout::Splits(h("s1", 0.3, leaf("a"), v("s2", 0.5, leaf("b"), leaf("c"))));
    assert_eq!(
        removing_split_pane("a", &layout),
        Some(Layout::Splits(v("s2", 0.5, leaf("b"), leaf("c"))))
    );
    assert_eq!(
        removing_split_pane("c", &layout),
        Some(Layout::Splits(h("s1", 0.3, leaf("a"), leaf("b"))))
    );
    assert_eq!(removing_split_pane("z", &layout), None);
    assert_eq!(removing_split_pane("a", &Layout::Splits(leaf("a"))), None);
}

#[test]
fn a_columns_only_pane_takes_its_column_and_a_lone_column_is_splits_again() {
    let layout = Layout::Columns(vec![
        column("c1", 0.5, leaf("a")),
        column("c2", 0.5, h("s", 0.5, leaf("b"), leaf("c"))),
    ]);
    assert_eq!(
        removing_split_pane("a", &layout),
        Some(Layout::Splits(h("s", 0.5, leaf("b"), leaf("c"))))
    );
    let three = Layout::Columns(vec![
        column("c1", 0.3, leaf("a")),
        column("c2", 0.3, leaf("b")),
        column("c3", 0.3, leaf("c")),
    ]);
    let Some(Layout::Columns(after)) = removing_split_pane("b", &three) else { panic!("columns") };
    assert_eq!(after.iter().map(|c| c.id.as_str()).collect::<Vec<_>>(), ["c1", "c3"]);
    assert_eq!(
        removing_split_pane("a", &Layout::Columns(vec![column("c1", 1.0, leaf("a"))])),
        None
    );
}

#[test]
fn a_lone_pinned_dock_stays_and_unpinned_docks_scroll_again() {
    let mut pinned = column("d", 0.25, leaf("d"));
    pinned.dock = dock(Edge::Left, true, None);
    let layout = Layout::Columns(vec![pinned.clone(), column("c", 0.75, leaf("a"))]);
    assert_eq!(removing_split_pane("a", &layout), Some(Layout::Columns(vec![pinned.clone()])));

    let mut loose = column("e", 0.25, leaf("e"));
    loose.dock = dock(Edge::Right, false, None);
    let layout = Layout::Columns(vec![pinned.clone(), column("c", 0.5, leaf("a")), loose]);
    let Some(Layout::Columns(after)) = removing_split_pane("a", &layout) else { panic!("columns") };
    assert_eq!(after[0].dock, pinned.dock);
    assert_eq!(after[1].dock, None);

    // A lone column left with rows fills the width and never docks.
    let mut rows = column("r", 0.4, v("cs", 0.5, leaf("x"), leaf("y")));
    rows.rows = vec![row("r1", 300, leaf("x")), row("r2", 300, leaf("y"))];
    rows.dock = dock(Edge::Right, false, None);
    let layout = Layout::Columns(vec![column("c", 0.6, leaf("a")), rows]);
    let Some(Layout::Columns(after)) = removing_split_pane("a", &layout) else { panic!("columns") };
    assert_eq!(after.len(), 1);
    assert_eq!(after[0].width, 1.0);
    assert_eq!(after[0].dock, None);
}

#[test]
fn the_chat_panes_close_releases_its_role() {
    let mut chat = column("d", 0.3, v("s", 0.5, leaf("chat"), leaf("b")));
    chat.dock = dock(Edge::Right, true, Some(AGENT_CHAT));
    let layout = Layout::Columns(vec![column("c", 0.7, leaf("a")), chat]);
    let Some(Layout::Columns(after)) = removing_split_pane("chat", &layout) else {
        panic!("columns")
    };
    assert_eq!(after[1].dock.as_ref().and_then(|d| d.role.clone()), None);
    let Some(Layout::Columns(after)) = removing_split_pane("b", &layout) else { panic!("columns") };
    assert_eq!(after[1].dock.as_ref().and_then(|d| d.role.as_deref()), Some(AGENT_CHAT));
}

#[test]
fn rows_refold_their_chain_in_f32() {
    let mut col = column("c", 1.0, v("k2", 0.6, v("k1", 0.5, leaf("x"), leaf("y")), leaf("z")));
    col.rows =
        vec![row("r1", 300, leaf("x")), row("r2", 300, leaf("y")), row("r3", 400, leaf("z"))];
    let after = removing_row_pane("y", &col);
    assert_eq!(after.rows.len(), 2);
    let ratio = f64::from(300f32 / 700f32);
    // The emptied row's split goes (k1); k2 joins what is left.
    assert_eq!(after.root, v("k2", ratio, leaf("x"), leaf("z")));

    // Down to one row: the column's tree is that row's.
    let after = removing_row_pane("x", &removing_row_pane("y", &col));
    assert!(after.rows.is_empty());
    assert_eq!(after.root, leaf("z"));

    // A pane inside a row's tree: the row keeps its height, the chain refolds.
    col.rows[1].root = h("rs", 0.5, leaf("y"), leaf("w"));
    col.root = v("k2", 0.6, v("k1", 0.5, leaf("x"), h("rs", 0.5, leaf("y"), leaf("w"))), leaf("z"));
    let after = removing_row_pane("w", &col);
    assert_eq!(after.rows[1].root, leaf("y"));
    assert_eq!(
        after.root,
        v("k2", f64::from(600f32 / 1000f32), v("k1", 0.5, leaf("x"), leaf("y")), leaf("z"))
    );
}

#[test]
fn successor_is_the_sibling_then_the_row_above_then_the_left_column() {
    let layout = Layout::Splits(h("s", 0.5, leaf("a"), v("t", 0.5, leaf("b"), leaf("c"))));
    assert_eq!(successor("a", &layout).as_deref(), Some("b"));
    assert_eq!(successor("c", &layout).as_deref(), Some("b"));

    let mut rows = column("r", 0.5, v("k", 0.5, leaf("x"), leaf("y")));
    rows.rows = vec![row("r1", 300, leaf("x")), row("r2", 300, leaf("y"))];
    let layout =
        Layout::Columns(vec![column("c1", 0.5, leaf("a")), rows, column("c3", 0.5, leaf("z"))]);
    assert_eq!(successor("y", &layout).as_deref(), Some("x"));
    assert_eq!(successor("x", &layout).as_deref(), Some("y"));
    assert_eq!(successor("z", &layout).as_deref(), Some("x"));
    assert_eq!(successor("a", &layout).as_deref(), Some("x"));
}

#[test]
fn even_sizing_equalizes_the_closed_panes_chain() {
    let old = Layout::Splits(h(
        "s1",
        0.2,
        leaf("a"),
        h("s2", 0.3, leaf("b"), h("s3", 0.5, leaf("c"), leaf("d"))),
    ));
    let new = removing_split_pane("a", &old).unwrap_or_else(|| old.clone());
    let changes = split_changes(&old, &new, "a");
    assert_eq!(changes, vec![RatioChange { split: "s2".into(), ratio: 1.0 / 3.0 }]);
    // Across an axis change the chain stops.
    let old = Layout::Splits(v(
        "s0",
        0.5,
        leaf("t"),
        h("s1", 0.2, leaf("a"), h("s2", 0.3, leaf("b"), leaf("c"))),
    ));
    let new = removing_split_pane("a", &old).unwrap_or_else(|| old.clone());
    assert_eq!(
        split_changes(&old, &new, "a"),
        vec![RatioChange { split: "s2".into(), ratio: 0.5 }]
    );
}

#[test]
fn fit_screen_shares_the_viewport_while_columns_fit() {
    let old = Layout::Columns(vec![
        column("c1", 0.3, leaf("a")),
        column("c2", 0.3, leaf("b")),
        column("c3", 0.4, leaf("c")),
    ]);
    let new = removing_split_pane("a", &old).unwrap_or_else(|| old.clone());
    assert_eq!(
        column_resizes(&old, &new),
        vec![
            ColumnResize { column: "c2".into(), width: 0.5 },
            ColumnResize { column: "c3".into(), width: 0.5 }
        ]
    );
    let wide = Layout::Columns(vec![
        column("c1", 0.6, leaf("a")),
        column("c2", 0.6, leaf("b")),
        column("c3", 0.6, leaf("c")),
    ]);
    let new = removing_split_pane("a", &wide).unwrap_or_else(|| wide.clone());
    assert!(column_resizes(&wide, &new).is_empty());
}

#[test]
fn show_names_the_superseded_splits_and_columns() {
    let old = Layout::Columns(vec![
        column("c1", 0.3, leaf("a")),
        column("c2", 0.3, h("s", 0.2, leaf("b"), h("t", 0.4, leaf("c"), leaf("d")))),
        column("c3", 0.4, leaf("e")),
    ]);
    let shown =
        show("a", &old, Sizing { even: true, fits: true }).unwrap_or_else(|| panic!("shows"));
    assert_eq!(shown.successor.as_deref(), Some("b"));
    assert_eq!(shown.columns, ["c1", "c2", "c3"]);
    let shown = show("b", &old, EVEN).unwrap_or_else(|| panic!("shows"));
    assert_eq!(shown.splits, ["t"]);
    assert!(shown.columns.is_empty());
}

#[test]
fn overlay_applies_landed_sizes_then_each_pending_close_in_order() {
    let layout = Layout::Splits(h(
        "s1",
        0.2,
        leaf("a"),
        h("s2", 0.3, leaf("b"), h("s3", 0.5, leaf("c"), leaf("d"))),
    ));
    let landed = Landed { ratios: [("s3".to_owned(), 0.7)].into(), widths: BTreeMap::new() };
    let shown = overlaying_pane_closes(&layout, &["a".into(), "zz".into()], &landed, EVEN);
    assert_eq!(
        shown,
        Layout::Splits(h("s2", 1.0 / 3.0, leaf("b"), h("s3", 0.5, leaf("c"), leaf("d"))))
    );
    let shown = overlaying_pane_closes(&layout, &["a".into()], &landed, Sizing::default());
    assert_eq!(shown, Layout::Splits(h("s2", 0.3, leaf("b"), h("s3", 0.7, leaf("c"), leaf("d")))));
}

#[test]
fn landed_closes_are_noted_then_flushed_once_nothing_is_pending() {
    let before = Layout::Columns(vec![
        column("c1", 0.3, leaf("a")),
        column("c2", 0.3, leaf("b")),
        column("c3", 0.4, leaf("c")),
    ]);
    let daemon = removing_split_pane("a", &before).unwrap_or_else(|| before.clone());
    let old = [Screen { id: "w".into(), zoomed: false, layout: before }];
    let new = [Screen { id: "w".into(), zoomed: false, layout: daemon.clone() }];
    let mut landed = Landed::default();
    note_landed_closes(&old, &new, &["a".into()], &["a".to_owned()].into(), &mut landed, FITS);
    assert_eq!(landed.widths, [("c2".to_owned(), 0.5), ("c3".to_owned(), 0.5)].into());

    // A close still pending on the screen holds the flush.
    let held =
        flush_landed_close_sizes(std::slice::from_ref(&daemon), &["b".to_owned()].into(), &landed);
    assert!(held.widths.is_empty());
    assert_eq!(held.landed, landed);

    let flush = flush_landed_close_sizes(std::slice::from_ref(&daemon), &BTreeSet::new(), &landed);
    assert_eq!(
        flush.widths,
        vec![
            ColumnResize { column: "c2".into(), width: 0.5 },
            ColumnResize { column: "c3".into(), width: 0.5 }
        ]
    );
    assert_eq!(flush.landed, Landed::default());
}

#[test]
fn close_sizing_skips_landed_closes_and_zoomed_screens() {
    let before = Layout::Splits(h("s1", 0.2, leaf("a"), h("s2", 0.3, leaf("b"), leaf("c"))));
    let after = removing_split_pane("a", &before).unwrap_or_else(|| before.clone());
    let old = [Screen { id: "w".into(), zoomed: false, layout: before }];
    let new = [Screen { id: "w".into(), zoomed: false, layout: after.clone() }];
    let intents = close_sizing(&old, &new, &BTreeSet::new(), EVEN);
    assert_eq!(intents.ratios, vec![RatioChange { split: "s2".into(), ratio: 0.5 }]);
    assert!(close_sizing(&old, &new, &["a".to_owned()].into(), EVEN).ratios.is_empty());
    let zoomed = [Screen { id: "w".into(), zoomed: true, layout: after }];
    assert!(close_sizing(&old, &zoomed, &BTreeSet::new(), EVEN).ratios.is_empty());
}

#[test]
fn clamped_ratio_keeps_the_split_range() {
    assert_eq!(clamped_ratio(0.01), SPLIT_RATIO_MIN);
    assert_eq!(clamped_ratio(0.99), SPLIT_RATIO_MAX);
    assert_eq!(clamped_ratio(0.4), 0.4);
}
