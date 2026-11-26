//! ScreenGeometry and SplitRoom invariants (the random Swift-answered cases live in
//! `tests/data/layout_geometry_screen_vectors.json`).

use super::screen::{
    Column, FloatingPane, ScreenGeometry, ScreenLayout, ScreenStyle, SplitPlacement, SplitRefusal,
    fits, floating_pane_rect, split_placement,
};
use super::split_layout::SplitNode;
use super::{Rect, Size, SplitAxis};

fn leaf(pane: &str) -> SplitNode {
    SplitNode::Leaf { pane: pane.into() }
}

fn column(id: &str, width: f64, pane: &str) -> Column {
    Column { id: id.into(), width, root: leaf(pane), dock: None, rows: Vec::new() }
}

const VIEWPORT: Size = Size { width: 1200., height: 800. };

#[test]
fn a_lone_split_pane_lies_inside_the_viewport() {
    let layout = ScreenLayout::Splits(leaf("a"));
    let geometry = ScreenGeometry::compute(&layout, VIEWPORT, &ScreenStyle::default(), 2.);
    let frame = geometry.panes["a"];
    assert!(!geometry.is_columns);
    assert!(frame.width() > 0. && frame.height() > 0.);
    assert!(frame.min_x() >= 0. && frame.max_x() <= VIEWPORT.width);
    assert!(frame.min_y() >= 0. && frame.max_y() <= VIEWPORT.height);
    assert_eq!(geometry.snap_offsets, vec![0.]);
}

#[test]
fn columns_lay_out_left_to_right_in_order() {
    let layout = ScreenLayout::Columns(vec![column("c1", 0.5, "a"), column("c2", 0.5, "b")]);
    let geometry = ScreenGeometry::compute(&layout, VIEWPORT, &ScreenStyle::default(), 2.);
    assert!(geometry.is_columns);
    assert_eq!(geometry.column_order, vec!["c1".to_string(), "c2".to_string()]);
    let (one, two) = (geometry.columns["c1"], geometry.columns["c2"]);
    assert!(one.max_x() <= two.min_x());
    assert!(geometry.panes["a"].max_x() <= geometry.panes["b"].min_x());
    assert!(geometry.max_offset() >= 0.);
}

#[test]
fn a_floating_card_keeps_its_pane_below_the_bar_and_inside_the_rim() {
    let card = Rect::new(10., 20., 200., 100.);
    assert_eq!(floating_pane_rect(card), Rect::new(15., 34., 190., 81.));
    assert_eq!(floating_pane_rect(Rect::new(0., 0., 4., 4.)), Rect::new(5., 14., 0., 0.));
}

#[test]
fn a_floating_frame_snaps_each_edge_to_the_pixel_grid() {
    let pane = FloatingPane { pane: "f".into(), frame: Rect::new(0.1, 0.1, 0.3, 0.3) };
    let rect = pane.rect(Size { width: 333., height: 333. }, 2.);
    assert_eq!(rect, Rect::new(33.5, 33.5, 99.5, 99.5));
}

#[test]
fn fits_allows_half_a_point_and_ignores_width_when_it_scrolls() {
    let container = Size { width: 100., height: 100. };
    assert!(fits(Size { width: 100.5, height: 100.5 }, container, false));
    assert!(!fits(Size { width: 100.6, height: 10. }, container, false));
    assert!(fits(Size { width: 1000., height: 10. }, container, true));
    assert!(!fits(Size { width: 10., height: 101. }, container, true));
}

#[test]
fn an_unknown_pane_or_an_unmeasured_viewport_splits() {
    let style = ScreenStyle::default();
    let layout = ScreenLayout::Splits(leaf("a"));
    let zero = Size { width: 0., height: 800. };
    assert_eq!(
        split_placement("a", SplitAxis::Horizontal, &layout, zero, &style, None),
        SplitPlacement::Split
    );
    assert_eq!(
        split_placement("zz", SplitAxis::Horizontal, &layout, VIEWPORT, &style, None),
        SplitPlacement::Split
    );
    assert_eq!(
        split_placement("a", SplitAxis::Horizontal, &layout, VIEWPORT, &style, None),
        SplitPlacement::Split
    );
}

#[test]
fn a_tiny_screen_refuses_the_split() {
    let style = ScreenStyle::default();
    let tiny = Size { width: 20., height: 20. };
    let splits = ScreenLayout::Splits(leaf("a"));
    assert_eq!(
        split_placement("a", SplitAxis::Vertical, &splits, tiny, &style, None),
        SplitPlacement::Refused(SplitRefusal::NotEnoughRoom)
    );
    let columns = ScreenLayout::Columns(vec![column("c1", 1., "a")]);
    assert_eq!(
        split_placement("a", SplitAxis::Vertical, &columns, tiny, &style, None),
        SplitPlacement::Refused(SplitRefusal::NotEnoughRoom)
    );
}
