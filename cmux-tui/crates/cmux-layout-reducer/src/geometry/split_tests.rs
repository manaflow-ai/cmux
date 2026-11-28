//! The Swift split and strip drag tests, ported (CmuxNextAppTests `DividerResizeMathTests`' push,
//! trade and uniform cases, `UniformEdgeTests`).

use super::split_layout::{DividerDragValue, DividerGeometry, PushResize, SplitNode};
use super::strip_math::{StripColumn, StripStart, UniformEdge, UniformTarget};
use super::{Rect, SplitAxis};
use std::collections::BTreeMap;

fn leaf(pane: &str) -> SplitNode {
    SplitNode::Leaf { pane: pane.into() }
}

fn split(id: &str, axis: SplitAxis, ratio: f64, a: SplitNode, b: SplitNode) -> SplitNode {
    SplitNode::Split { split: id.into(), axis, ratio, a: Box::new(a), b: Box::new(b) }
}

fn divider(id: &str, container: Rect, leading: f64, minimum_a: f64) -> DividerGeometry {
    DividerGeometry {
        id: id.into(),
        axis: SplitAxis::Horizontal,
        frame: Rect::new(container.min_x() + leading, 0., 1., 100.),
        hit_frame: Rect::new(0., 0., 0., 0.),
        container,
        minimum_a,
        minimum_b: 100.,
    }
}

fn split_values(targets: &[DividerDragValue]) -> (BTreeMap<String, f64>, BTreeMap<String, f64>) {
    let (mut ratios, mut widths) = (BTreeMap::new(), BTreeMap::new());
    for target in targets {
        match target {
            DividerDragValue::Ratio { id, value } => ratios.insert(id.clone(), *value),
            DividerDragValue::Width { id, value } => widths.insert(id.clone(), *value),
        };
    }
    (ratios, widths)
}

#[test]
fn push_grows_only_the_pane_before_the_divider() {
    let h = SplitAxis::Horizontal;
    let tree = split("x", h, 1. / 3., leaf("p1"), split("y", h, 0.5, leaf("p2"), leaf("p3")));
    let outer = Rect::new(0., 0., 601., 100.);
    let inner = Rect::new(201., 0., 400., 100.);
    let dividers = [divider("x", outer, 200., 100.), divider("y", inner, 199.5, 100.)];
    let push =
        PushResize::new("y", "c", false, &[tree], 601., &dividers, 2000., 0., 1.).expect("push");
    let (ratios, widths) = split_values(&push.targets(50.));
    assert!((widths["c"] * 2000. - 651.).abs() < 0.01);
    let (x, y) = (ratios["x"], ratios["y"]);
    assert!((x * 650. - 200.).abs() < 0.01);
    assert!((y * (650. - 200. - 1.) - 249.5).abs() < 0.01);
    assert!(((1. - y) * 449. - 199.5).abs() < 0.01);
}

#[test]
fn push_stops_at_the_pane_minimum() {
    let tree = split("x", SplitAxis::Horizontal, 0.5, leaf("p1"), leaf("p2"));
    let container = Rect::new(0., 0., 401., 100.);
    let dividers = [divider("x", container, 200., 150.)];
    let push =
        PushResize::new("x", "c", false, &[tree], 401., &dividers, 2000., 0., 1.).expect("push");
    let (_, widths) = split_values(&push.targets(-500.));
    assert!((widths["c"] * 2000. - 351.).abs() < 0.01);
}

#[test]
fn a_vertical_divider_or_a_docked_column_does_not_push() {
    let divider = [divider("x", Rect::new(0., 0., 400., 400.), 200., 100.)];
    let vertical = split("x", SplitAxis::Vertical, 0.5, leaf("p1"), leaf("p2"));
    assert_eq!(PushResize::new("x", "c", false, &[vertical], 400., &divider, 2000., 0., 1.), None);
    let horizontal = split("x", SplitAxis::Horizontal, 0.5, leaf("p1"), leaf("p2"));
    assert_eq!(PushResize::new("x", "c", true, &[horizontal], 400., &divider, 2000., 0., 1.), None);
}

fn strip() -> StripStart {
    let column = |id: &str, width| StripColumn { id: id.into(), width, minimum: 200. };
    StripStart {
        columns: vec![column("a", 0.4), column("b", 0.3), column("c", 0.3)],
        viewport: 1000.,
        gap: 0.,
    }
}

/// The widths `targets` set, by column, rounded to a thousandth.
fn widths(targets: &[DividerDragValue]) -> Vec<(String, f64)> {
    let (_, widths) = split_values(targets);
    widths.into_iter().map(|(id, w)| (id, (w * 1000.).round() / 1000.)).collect()
}

fn expect(pairs: &[(&str, f64)]) -> Vec<(String, f64)> {
    pairs.iter().map(|(id, w)| (id.to_string(), *w)).collect()
}

#[test]
fn trade_moves_width_between_neighbors_and_keeps_the_rest() {
    assert_eq!(widths(&strip().trading("a", 0.45)), expect(&[("a", 0.45), ("b", 0.25)]));
    // b may give up only down to its 200 pt minimum.
    assert_eq!(widths(&strip().trading("a", 0.8)), expect(&[("a", 0.5), ("b", 0.2)]));
    // The last column has no neighbor to trade with.
    assert_eq!(widths(&strip().trading("c", 0.5)), expect(&[("c", 0.5)]));
}

#[test]
fn uniform_gives_every_column_one_width_at_least_the_widest_minimum() {
    assert_eq!(widths(&strip().uniform(0.35)), expect(&[("a", 0.35), ("b", 0.35), ("c", 0.35)]));
    assert_eq!(widths(&strip().uniform(0.1)), expect(&[("a", 0.2), ("b", 0.2), ("c", 0.2)]));
}

/// Columns of `widths` points from x = 8 with 8 pt gaps, the dragged one at `index`.
fn solver(widths: &[f64], index: usize, camera: f64, shown: Option<f64>) -> UniformEdge {
    let left = 8. + widths[..index].iter().fold(0., |sum, w| sum + w + 8.);
    let content = 8. + widths.iter().fold(0., |sum, w| sum + w + 8.);
    UniformEdge { widths: widths.to_vec(), index, left, content, viewport: 1000., camera, shown }
}

#[test]
fn a_strip_that_fits_shares_the_pointers_travel_among_the_columns_up_to_the_edge() {
    let solver = solver(&[300., 300., 300.], 1, 0., None);
    let width = solver.width(solver.edge(300.) + 30.).expect("width");
    assert!((width - 315.).abs() < 0.01, "every column is {width} pt");
    assert_eq!(solver.presented(width), 0.);
}

#[test]
fn a_camera_with_room_takes_the_shift_and_the_width_takes_the_pointers_travel() {
    let solver = solver(&[600., 600., 600.], 1, 100., None);
    let width = solver.width(solver.edge(600.) + 30.).expect("width");
    assert!((width - 630.).abs() < 0.01, "every column is {width} pt");
    assert!((solver.presented(width) - 130.).abs() < 0.01);
}

#[test]
fn a_camera_at_the_strips_start_shares_what_it_cannot_take() {
    let solver = solver(&[600., 600., 600.], 1, 10., None);
    let place = solver.edge(600.) - 30.;
    let width = solver.width(place).expect("width");
    assert!((solver.edge(width) - place).abs() < 0.01);
    assert_eq!(solver.presented(width), 0.);
}

#[test]
fn a_camera_mid_spring_shows_the_edge_under_the_pointer_in_this_frame() {
    let solver = solver(&[600., 600., 600.], 0, 100., Some(0.));
    let width = solver.width(638.).expect("width");
    assert!((width - 630.).abs() < 0.01, "every column is {width} pt");
}

#[test]
fn at_the_strips_end_the_last_columns_edge_holds_at_its_limit() {
    let solver = solver(&[600., 600., 600.], 2, 832., None);
    assert_eq!(solver.width(solver.edge(600.) - 30.), Some(600.));
}

#[test]
fn at_the_strips_end_a_second_columns_edge_holds_rather_than_spring_back() {
    let solver = solver(&[600., 600., 600.], 1, 832., None);
    assert!((solver.edge(600.) - 384.).abs() < 0.01);
    assert_eq!(solver.width(354.), Some(600.));
}

#[test]
fn the_first_command_frame_at_the_strips_end_keeps_the_widths_when_no_uniform_width_holds() {
    let solver = solver(&[600., 300., 600.], 1, 532., None);
    assert_eq!(solver.target(354.), UniformTarget::Keep);
}

#[test]
fn a_clamp_that_stops_a_camera_mid_spring_is_no_spring_back() {
    let solver = solver(&[600., 600., 600.], 1, 832., Some(812.));
    let width = solver.width(solver.edge(590.)).expect("width");
    assert!((width - 590.).abs() < 0.01, "every column is {width} pt");
}
