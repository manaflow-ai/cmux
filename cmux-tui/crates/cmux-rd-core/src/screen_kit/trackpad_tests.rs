//! Ported from CmuxScreenKitTests/ScreenInputTests.swift.
use super::TrackpadAction::{Move, Press, Release};
use super::*;

#[test]
fn a_tap_presses_at_once_and_releases_after_the_drag_window() {
    let mut g = TrackpadGesture::new();
    assert!(g.touch_down(10.0).is_empty());
    assert_eq!(g.touch_up(10.1), [Press]);
    assert!(g.button_held());
    assert_eq!(g.deadline(), Some(10.1 + g.drag_window));
    assert!(g.advance(10.2).is_empty(), "still inside the window");
    assert_eq!(g.advance(10.4), [Release]);
    assert!(!g.button_held() && g.deadline().is_none());
}

#[test]
fn a_double_tap_is_two_clicks() {
    let mut g = TrackpadGesture::new();
    g.touch_down(0.0);
    assert_eq!(g.touch_up(0.08), [Press]);
    assert!(g.touch_down(0.2).is_empty(), "the press carries on into the second touch");
    assert_eq!(g.touch_up(0.28), [Release, Press, Release]);
    assert!(!g.button_held());
}

#[test]
fn tap_and_a_half_drags_with_the_taps_press() {
    let mut g = TrackpadGesture::new();
    g.touch_down(0.0);
    g.touch_up(0.1);
    g.touch_down(0.25);
    assert!(g.deadline().is_none(), "no long press or window while dragging");
    assert!(g.touch_moved(4.0, 0.0, 0.27).is_empty(), "inside the slop");
    assert_eq!(g.touch_moved(6.0, 0.0, 0.3), [Move { dx: 10.0, dy: 0.0, dt: 0.3 - 0.25 }]);
    assert_eq!(g.touch_moved(5.0, 5.0, 0.32), [Move { dx: 5.0, dy: 5.0, dt: 0.32 - 0.3 }]);
    assert!(g.button_held());
    assert_eq!(g.touch_up(0.6), [Release]);
}

#[test]
fn a_still_touch_becomes_a_long_press_drag() {
    let mut g = TrackpadGesture::new();
    g.touch_down(1.0);
    assert_eq!(g.deadline(), Some(1.0 + g.long_press_duration));
    assert!(g.advance(1.2).is_empty());
    assert_eq!(g.advance(1.5), [Press]);
    assert!(g.button_held());
    assert_eq!(g.touch_moved(20.0, 0.0, 1.6).len(), 1);
    assert_eq!(g.touch_up(2.0), [Release]);
}

#[test]
fn moving_moves_without_clicking() {
    let mut g = TrackpadGesture::new();
    g.touch_down(0.0);
    assert_eq!(g.touch_moved(30.0, 40.0, 0.05), [Move { dx: 30.0, dy: 40.0, dt: 0.05 }]);
    assert!(g.deadline().is_none(), "a moving touch never long-presses");
    assert!(g.advance(5.0).is_empty());
    assert!(g.touch_up(0.1).is_empty());
    g.touch_down(10.0);
    assert!(g.touch_up(10.4).is_empty());
}

#[test]
fn a_second_finger_releases_a_held_button() {
    let mut g = TrackpadGesture::new();
    g.touch_down(0.0);
    g.touch_up(0.1);
    assert_eq!(g.cancel(), [Release]);
    g.touch_down(1.0);
    assert!(g.cancel().is_empty(), "nothing was pressed");
}

#[test]
fn a_late_touch_after_the_window_starts_afresh() {
    let mut g = TrackpadGesture::new();
    g.touch_down(0.0);
    g.touch_up(0.1);
    assert_eq!(g.touch_down(0.9), [Release]);
    assert_eq!(g.touch_up(0.95), [Press]);
}

#[test]
fn a_touch_down_during_a_drag_releases_it_first() {
    let mut g = TrackpadGesture::new();
    g.touch_down(0.0);
    g.advance(0.5);
    assert!(g.button_held());
    assert_eq!(g.touch_down(0.6), [Release], "a long-press drag that never saw its touch up");
    assert!(!g.button_held());
}

#[test]
fn acceleration_is_precise_when_slow_and_faster_when_fast() {
    let a = PointerAcceleration::default();
    assert_eq!(a.gain(0.0), 1.0);
    assert_eq!(a.gain(100.0), 1.0);
    assert_eq!(a.gain(10000.0), 3.0);
    let mid = a.gain(700.0);
    assert!(mid > 1.0 && mid < 3.0);
    assert!(a.gain(500.0) < a.gain(900.0), "monotonic");
    assert_eq!(a.delta(1.0, 0.0, 0.1, 4.0), (4.0, 0.0));
    let (dx, dy) = a.delta(30.0, 40.0, 0.01, 2.0);
    assert!((dx - 180.0).abs() < 0.001 && (dy - 240.0).abs() < 0.001);
}

#[test]
fn a_double_tap_clicks_twice_at_one_point() {
    let mut snap = ClickSnap::new();
    let first = snap.point(Point::new(100.0, 100.0), 0.0, 20.0);
    assert_eq!(first, Point::new(100.0, 100.0));
    assert_eq!(
        snap.point(Point::new(108.0, 95.0), 0.3, 20.0),
        first,
        "the second tap lands on the first"
    );
    assert_eq!(
        snap.point(Point::new(140.0, 100.0), 0.5, 20.0),
        Point::new(140.0, 100.0),
        "too far: a new point"
    );
    assert_eq!(
        snap.point(Point::new(141.0, 100.0), 1.5, 20.0),
        Point::new(141.0, 100.0),
        "too late: a new point"
    );
}
