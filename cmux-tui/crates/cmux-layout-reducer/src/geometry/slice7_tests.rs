//! Canvas invariants: camera, camera springs, arranging, dragging, handles, placing and the screen (the
//! random Swift-answered cases live in `tests/data/layout_geometry_slice7_vectors.json`).

use super::canvas::*;
use super::edge_motion::Spring;
use super::{Point, Rect, Size};
use std::collections::BTreeMap;

fn rect(x: f64, y: f64, w: f64, h: f64) -> Rect {
    Rect { x, y, w, h }
}

fn point(x: f64, y: f64) -> Point {
    Point { x, y }
}

fn size(width: f64, height: f64) -> Size {
    Size { width, height }
}

fn frames(list: &[(&str, Rect)]) -> BTreeMap<String, Rect> {
    list.iter().map(|(id, frame)| ((*id).to_owned(), *frame)).collect()
}

#[test]
fn a_camera_clamps_its_zoom_and_keeps_the_anchor_still() {
    assert_eq!(Camera::new(point(0., 0.), f64::NAN).zoom, 1.);
    assert_eq!(Camera::new(point(0., 0.), 9.).zoom, ZOOM_MAX);
    assert_eq!(Camera::new(point(0., 0.), 0.).zoom, ZOOM_MIN);
    let camera = Camera::new(point(100., 100.), 1.);
    let zoomed = camera.zoomed_to(2., Some(point(200., 100.)));
    assert_eq!((zoomed.center, zoomed.zoom), (point(150., 100.), 2.));
    assert_eq!(camera.visible_rect(size(200., 100.)), rect(0., 50., 200., 100.));
    assert_eq!(zoomed.panned(size(20., -10.)).center, point(140., 105.));
}

#[test]
fn revealing_moves_only_as_far_as_it_must_and_fitting_never_zooms_in() {
    let camera = Camera::new(point(100., 100.), 1.);
    let viewport = size(200., 200.);
    assert_eq!(camera.revealing(rect(50., 50., 10., 10.), viewport, 20.), camera);
    let right = camera.revealing(rect(250., 50., 30., 30.), viewport, 20.);
    assert_eq!(right.center, point(200., 100.));
    let fit = camera.fitting(rect(0., 0., 100., 50.), viewport, 0.);
    assert_eq!((fit.center, fit.zoom), (point(50., 25.), 1.));
    let big = camera.fitting(rect(0., 0., 800., 400.), viewport, 0.);
    assert_eq!(big.zoom, 0.25);
}

#[test]
fn camera_springs_settle_on_the_target() {
    let mut motion = CameraMotion::default();
    motion.retarget(Camera::new(point(300., 0.), 2.), true);
    assert!(motion.is_moving());
    let spring = Spring { response: 0.3, damping_fraction: 1. };
    let mut frames = 0;
    while motion.advance(1. / 60., spring) {
        frames += 1;
        assert!(frames < 600, "the camera never settled");
    }
    assert!(!motion.is_moving());
    assert_eq!(motion.shown(), motion.target());
    motion.retarget(Camera::new(point(0., 0.), 1.), false);
    assert_eq!(motion.shown(), Camera::default());
}

#[test]
fn arranging_moves_only_the_panes_that_change() {
    let canvas = frames(&[("a", rect(0., 0., 100., 50.)), ("b", rect(30., 200., 60., 80.))]);
    let left = arranged(Arrangement::AlignLeft, &canvas, None, GAP);
    assert_eq!(left, frames(&[("b", rect(0., 200., 60., 80.))]));
    let widths = arranged(Arrangement::EqualizeWidths, &canvas, Some("b"), GAP);
    assert_eq!(widths, frames(&[("a", rect(0., 0., 60., 50.))]));
    let spread = arranged(Arrangement::DistributeHorizontally, &canvas, None, GAP);
    assert_eq!(spread, frames(&[("b", rect(116., 200., 60., 80.))]));
    let tidy = arranged(Arrangement::Tidy, &canvas, None, GAP);
    assert_eq!(tidy, frames(&[("b", rect(0., 66., 60., 80.))]));
    assert!(
        arranged(Arrangement::Tidy, &frames(&[("a", rect(5., 5., 1., 1.))]), None, GAP).is_empty()
    );
}

#[test]
fn a_drag_moves_or_resizes_and_keeps_the_minimum() {
    let start = rect(0., 0., 100., 100.);
    assert_eq!(dragged_frame(start, 0, size(10., 10.), size(5., 6.)), rect(5., 6., 100., 100.));
    let squeezed = dragged_frame(
        start,
        resize_edges::LEFT | resize_edges::TOP,
        size(40., 30.),
        size(90., 90.),
    );
    assert_eq!(squeezed, rect(60., 70., 40., 30.));
    let grown = dragged_frame(
        start,
        resize_edges::RIGHT | resize_edges::BOTTOM,
        size(1., 1.),
        size(20., 10.),
    );
    assert_eq!(grown, rect(0., 0., 120., 110.));
}

#[test]
fn handles_ring_a_pane_and_the_band_above_moves_it() {
    let screen =
        CanvasScreen::new(frames(&[("a", rect(0., 0., 100., 100.))]), None, Camera::default());
    assert_eq!(handle_hit(&screen, 8., point(50., 50.)), None);
    assert_eq!(
        handle_hit(&screen, 8., point(50., -4.)),
        Some(Handle { pane: "a".into(), edges: 0 })
    );
    let corner = handle_hit(&screen, 8., point(-4., -4.)).expect("corner");
    assert_eq!(corner.edges, resize_edges::LEFT | resize_edges::TOP);
    let bottom = handle_hit(&screen, 8., point(50., 100.)).expect("bottom");
    assert_eq!(bottom.edges, resize_edges::BOTTOM);
    assert_eq!(handle_hit(&screen, 8., point(50., 120.)), None);
}

#[test]
fn a_placed_pane_goes_beside_its_anchor_one_gap_away() {
    let size = size(100., 50.);
    assert_eq!(placed_frame(size, None, &[], GAP), rect(0., 0., 100., 50.));
    let anchor = rect(0., 0., 100., 50.);
    assert_eq!(placed_frame(size, Some(anchor), &[anchor], GAP), rect(116., 0., 100., 50.));
    let crowded = [anchor, rect(116., 0., 100., 50.)];
    assert_eq!(placed_frame(size, Some(anchor), &crowded, GAP), rect(0., 66., 100., 50.));
}

#[test]
fn the_screen_orders_reconciles_and_finds_panes() {
    let mut screen = CanvasScreen::new(
        frames(&[("a", rect(0., 0., 100., 50.)), ("b", rect(50., 0., 100., 50.))]),
        Some(vec!["b".into(), "gone".into()]),
        Camera::default(),
    );
    assert_eq!(screen.order, ["b", "a"]);
    assert_eq!(screen.pane_at(point(60., 10.)), Some("a"));
    screen.bring_to_front("b");
    assert_eq!(screen.pane_at(point(60., 10.)), Some("b"));
    assert_eq!(screen.content_bounds(), Some(rect(0., 0., 150., 50.)));
    assert!(!screen.reconcile(&["a".into(), "b".into()], None));
    assert!(screen.reconcile(&["b".into(), "c".into()], Some("b")));
    assert_eq!(screen.order, ["b", "c"]);
    assert_eq!(screen.frames["c"], rect(166., 0., 100., 50.));
    let seeded = CanvasScreen::seeded(BTreeMap::new(), size(800., 600.));
    assert_eq!(seeded.camera.center, point(400., 300.));
    assert_eq!(CanvasScreen::default().content_bounds(), None);
}
