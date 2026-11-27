//! SharedEdgeMotion, DividerMouseCatchers and scroll routing invariants (the random Swift-answered cases
//! live in `tests/data/layout_geometry_slice6_vectors.json`).

use super::Rect;
use super::edge_motion::*;

const SPRING: Spring = Spring { response: 0.3, damping_fraction: 1. };

fn rect(x: f64, y: f64, w: f64, h: f64) -> Rect {
    Rect { x, y, w, h }
}

#[test]
fn a_resting_frame_jumps_and_a_moving_one_keeps_its_offset() {
    let mut resting = AnimatedFrame::new(rect(0., 0., 100., 50.));
    place(&mut resting, rect(10., 0., 100., 50.), false);
    assert_eq!((resting.x.value, resting.x.target), (10., 10.));
    let mut moving = AnimatedFrame::new(rect(0., 0., 100., 50.));
    moving.x.value = 4.;
    place(&mut moving, rect(10., 0., 100., 50.), false);
    assert_eq!((moving.x.value, moving.x.target), (14., 10.));
    let mut kept = AnimatedFrame::new(rect(0., 0., 100., 50.));
    kept.alpha = SpringValue { value: 0.2, velocity: 1., target: 0. };
    place(&mut kept, rect(0., 0., 100., 50.), true);
    assert_eq!((kept.alpha.value, kept.alpha.target), (0.2, 1.));
    place(&mut kept, rect(0., 0., 120., 50.), true);
    assert_eq!((kept.width.value, kept.width.target), (100., 120.));
    assert_eq!(kept.alpha, SpringValue::at(1.));
}

#[test]
fn seeding_gives_only_the_moved_edges_a_speed() {
    let after = rect(0., 0., 100., 50.);
    let mut frame = AnimatedFrame::new(after);
    frame.width.value = 80.;
    let moved = MovedEdges::new(Some(rect(0., 0., 80., 50.)), after);
    assert!(moved.max_x && !moved.min_x && !moved.min_y && !moved.max_y);
    seed(&mut frame, moved, 10.);
    assert_eq!((frame.x.velocity, frame.width.velocity), (0., 200.));
    assert!(!MovedEdges::new(None, after).any());
}

#[test]
fn a_settled_edge_pair_never_dips_and_a_squeezed_one_does() {
    let still = Edges::new(SpringValue::at(0.), SpringValue::at(100.));
    assert_eq!(lowest(&still, SPRING), 0.);
    let squeezed = Edges::new(
        SpringValue { value: 20., velocity: 0., target: 0. },
        SpringValue { value: 60., velocity: 0., target: 100. },
    );
    assert_eq!(lowest(&squeezed, SPRING), -40.);
    // An admitted velocity never points away from the target.
    assert_eq!(SPRING.admitted(-50., 10.), 0.);
    assert_eq!(SPRING.admitted(1e9, 10.), 2. * std::f64::consts::PI / 0.3 * 10.);
}

#[test]
fn a_shown_edge_lands_on_a_device_pixel() {
    let shown = ShownPixels { shift: 0.25, scale: 2. };
    assert_eq!(shown.edge(10.3), 10.25);
    assert_eq!(ShownPixels { shift: 0., scale: 0. }.edge(10.3), 10.3);
}

#[test]
fn catchers_need_an_active_visible_window_and_an_overlapping_page() {
    let areas = [
        MouseArea { id: "a".into(), rect: rect(100., 0., 8., 100.) },
        MouseArea { id: "b".into(), rect: rect(500., 0., 8., 100.) },
    ];
    let pages = [rect(0., 0., 101., 100.)];
    let wanted = wanted_catchers(&areas, &pages, true, true);
    assert_eq!(wanted.iter().map(|area| area.id.as_str()).collect::<Vec<_>>(), ["a"]);
    assert!(wanted_catchers(&areas, &pages, false, true).is_empty());
    assert!(wanted_catchers(&areas, &pages, true, false).is_empty());
}

#[test]
fn a_notch_goes_to_rows_then_the_area_then_columns() {
    let all = ScrollFacts {
        rows: true,
        area_forward: true,
        area_back: true,
        columns: true,
        columns_take_either_axis: true,
        claims_whole_gesture: false,
    };
    assert_eq!(notch_route(0., -3., all), ScrollRoute::Rows { direction: 1 });
    assert_eq!(notch_route(3., 0., all), ScrollRoute::Area { direction: -1 });
    let columns =
        ScrollFacts { columns: true, columns_take_either_axis: true, ..Default::default() };
    assert_eq!(notch_route(0., 2., columns), ScrollRoute::Columns { direction: -1 });
    assert_eq!(notch_route(1., 1., columns), ScrollRoute::PassThrough);
    let claims = ScrollFacts { claims_whole_gesture: true, ..Default::default() };
    assert_eq!(notch_route(1., 0., claims), ScrollRoute::Claimed);
}

#[test]
fn a_trackpad_gesture_locks_on_its_first_moving_delta() {
    let facts = ScrollFacts { rows: true, columns: true, ..Default::default() };
    assert_eq!(undecided_lock(0., 0., false, facts), GestureLock::Undecided { forwards: true });
    assert_eq!(
        undecided_lock(0., 0., true, facts),
        GestureLock::Ended { forwards: true, consume_momentum: false }
    );
    assert_eq!(
        undecided_lock(-5., 1., false, facts),
        GestureLock::Horizontal { vertical_deltas: false }
    );
    assert_eq!(undecided_lock(1., 1., false, facts), GestureLock::Vertical);
    let either =
        ScrollFacts { columns: true, columns_take_either_axis: true, ..Default::default() };
    assert_eq!(
        undecided_lock(0., 4., false, either),
        GestureLock::Horizontal { vertical_deltas: true }
    );
}
