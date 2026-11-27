//! FloatingPaneCorners, DropPreviewLayout and ShownResizeRange invariants (the random Swift-answered
//! cases live in `tests/data/layout_geometry_slice5_vectors.json`).

use super::drop_preview::{NEW_PANE, NEW_SPLIT, drop_preview};
use super::drop_zones::PaneDropZone;
use super::floating_corners::FloatingPaneCorners;
use super::screen::{Column, ScreenGeometry, ScreenLayout, ScreenStyle};
use super::shown_range::ShownResizeRange;
use super::split_layout::SplitNode;
use super::{Size, SplitAxis};

fn leaf(pane: &str) -> SplitNode {
    SplitNode::Leaf { pane: pane.into() }
}

fn split(id: &str, axis: SplitAxis, ratio: f64, a: SplitNode, b: SplitNode) -> SplitNode {
    SplitNode::Split { split: id.into(), axis, ratio, a: Box::new(a), b: Box::new(b) }
}

const SIZE: Size = Size { width: 400., height: 300. };

#[test]
fn corners_nest_inside_the_window_curve_and_fit_the_card() {
    let flush = FloatingPaneCorners::new(SIZE, 0., 0., 0., 0., 16., 4.);
    assert_eq!(flush, FloatingPaneCorners::uniform(16.));
    let inset = FloatingPaneCorners::new(SIZE, 6., 0., 20., 10., 16., 4.);
    assert_eq!((inset.top_left, inset.top_right), (10., 4.));
    assert_eq!((inset.bottom_left, inset.bottom_right), (6., 4.));
    assert_eq!(inset.largest(), 10.);
    assert_eq!(inset.content_radius(3.), 7.);
    assert_eq!(inset.content_radius(30.), 0.);
    let tiny = FloatingPaneCorners::new(Size { width: 10., height: 6. }, 0., 0., 0., 0., 16., 0.);
    assert_eq!(tiny.largest(), 3.);
    let negative = FloatingPaneCorners::new(SIZE, 0., 0., 0., 0., -5., 0.);
    assert_eq!(negative.largest(), 0.);
}

#[test]
fn a_drop_splits_the_target_with_the_new_pane_on_the_zone_side() {
    let layout = ScreenLayout::Splits(split("s", SplitAxis::Horizontal, 0.3, leaf("a"), leaf("b")));
    let preview =
        drop_preview("b", PaneDropZone::Top, &layout, None, false, true).expect("preview");
    let ScreenLayout::Splits(root) = &preview.layout else { panic!("splits") };
    let want = split(
        "s",
        SplitAxis::Horizontal,
        0.3,
        leaf("a"),
        split(NEW_SPLIT, SplitAxis::Vertical, 0.5, leaf(NEW_PANE), leaf("b")),
    );
    assert_eq!(root, &want);
    assert!(preview.ratio_changes.is_empty());
    assert!(drop_preview("b", PaneDropZone::Center, &layout, None, true, true).is_none());
    assert!(drop_preview("zz", PaneDropZone::Left, &layout, None, true, true).is_none());
}

#[test]
fn an_even_drop_equalizes_the_run_and_drops_the_emptied_pane() {
    let layout = ScreenLayout::Splits(split(
        "s1",
        SplitAxis::Horizontal,
        0.2,
        leaf("a"),
        split("s2", SplitAxis::Horizontal, 0.5, leaf("b"), leaf("c")),
    ));
    let preview =
        drop_preview("a", PaneDropZone::Right, &layout, Some("c"), true, true).expect("p");
    // c leaves (b takes s2's place), a splits: a, new, b share three cells.
    let ScreenLayout::Splits(root) = &preview.layout else { panic!("splits") };
    let SplitNode::Split { split: id, ratio, .. } = root else { panic!("split") };
    assert_eq!(id, "s1");
    assert!((ratio - 2. / 3.).abs() < 1e-12);
    assert!(preview.ratio_changes.iter().all(|change| change.split != NEW_SPLIT));
    // The dragged pane itself is never removed.
    let same = drop_preview("a", PaneDropZone::Left, &layout, Some("a"), false, true).expect("p");
    assert!(matches!(&same.layout, ScreenLayout::Splits(root) if root.contains("a")));
}

#[test]
fn a_column_with_rows_is_not_predicted() {
    let mut column = Column {
        id: "c".into(),
        width: 1.,
        root: split("r", SplitAxis::Vertical, 0.5, leaf("a"), leaf("b")),
        dock: None,
        rows: Vec::new(),
    };
    column.rows = ["a", "b"]
        .iter()
        .map(|pane| super::screen::LayoutRow { id: (*pane).into(), height: 500, root: leaf(pane) })
        .collect();
    let layout = ScreenLayout::Columns(vec![column]);
    assert!(drop_preview("a", PaneDropZone::Left, &layout, None, false, true).is_none());
}

#[test]
fn shown_ratio_bounds_come_from_the_divider_minimums() {
    let layout = ScreenLayout::Splits(split("s", SplitAxis::Horizontal, 0.5, leaf("a"), leaf("b")));
    let style = ScreenStyle::default();
    let geometry =
        ScreenGeometry::compute(&layout, Size { width: 1000., height: 600. }, &style, 2.);
    let range =
        ShownResizeRange { geometry: &geometry, style: &style, scale: 2., strip_offset: None };
    let bounds = range.ratio("s").expect("bounds");
    assert!(bounds.lower > 0. && bounds.lower < 0.5 && bounds.upper > 0.5 && bounds.upper < 1.);
    assert!(range.ratio("nope").is_none());
}

#[test]
fn a_trade_moves_only_the_shared_divider() {
    let columns: Vec<Column> = ["a", "b", "c"]
        .iter()
        .map(|pane| Column {
            id: format!("c{pane}"),
            width: 0.3,
            root: leaf(pane),
            dock: None,
            rows: Vec::new(),
        })
        .collect();
    let layout = ScreenLayout::Columns(columns.clone());
    let style = ScreenStyle::default();
    let viewport = Size { width: 1500., height: 800. };
    let geometry = ScreenGeometry::compute(&layout, viewport, &style, 2.);
    let range =
        ShownResizeRange { geometry: &geometry, style: &style, scale: 2., strip_offset: None };
    let (left, right) = range.trade(&columns[0], &columns[1], 0.05, &layout).expect("trade");
    assert!(left > 0.3 && right < 0.3);
    assert!(range.trade(&columns[0], &columns[1], 0., &layout).is_none());
    assert!(range.width(&columns[0]).is_some());
    assert!(range.dock_width(&columns[0]).is_none());
}
