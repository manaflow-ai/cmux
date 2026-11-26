//! Parity with ViewerDemandTests.swift.
use super::*;

/// A 16" MacBook Pro's display.
const DISPLAY: i64 = 3456;

#[test]
fn the_rung_covers_the_viewer() {
    assert_eq!(rung(1179, DISPLAY), Some(1280), "an iPhone at fit");
    assert_eq!(rung(960, DISPLAY), Some(960));
    assert_eq!(rung(400, DISPLAY), Some(960));
    assert_eq!(rung(2000, DISPLAY), Some(2560));
    assert_eq!(rung(3000, DISPLAY), None, "3840 is more than the display");
    assert_eq!(rung(9000, 5120), Some(3840));
    assert_eq!(rung(1000, 1080), None, "a rung above the display is full size");
}

#[test]
fn a_smaller_picture_applies_after_six_seconds() {
    let mut d = ViewerDemand::default();
    assert!(!d.report(1179, DISPLAY, false, 0.0));
    assert!(!d.report(1179, DISPLAY, false, 4.0));
    assert_eq!(d.cap, None);
    assert!(d.report(1179, DISPLAY, false, 6.0));
    assert_eq!(d.cap, Some(1280));
    assert!(!d.report(1179, DISPLAY, false, 8.0), "no change while it holds");
}

#[test]
fn a_contradicted_report_restarts_the_hold() {
    let mut d = ViewerDemand::default();
    d.report(1179, DISPLAY, false, 0.0);
    d.report(2000, DISPLAY, false, 2.0);
    assert!(!d.report(1179, DISPLAY, false, 6.0), "the clock started again at 6");
    assert!(d.report(1179, DISPLAY, false, 12.0));
    assert_eq!(d.cap, Some(1280));
}

#[test]
fn a_larger_picture_holds_three_seconds_or_six_after_a_recent_step_down() {
    let mut d = ViewerDemand::default();
    d.report(1179, DISPLAY, false, 0.0);
    d.report(1179, DISPLAY, false, 6.0);
    assert_eq!(d.cap, Some(1280));
    d.report(2000, DISPLAY, false, 10.0);
    assert!(!d.report(2000, DISPLAY, false, 14.0));
    assert!(d.report(2000, DISPLAY, false, 16.0));
    assert_eq!(d.cap, Some(2560));
    d.report(3400, DISPLAY, false, 20.0);
    assert!(d.report(3400, DISPLAY, false, 23.0));
    assert_eq!(d.cap, None, "full size");
}

#[test]
fn a_pinch_raises_at_once() {
    let mut d = ViewerDemand::default();
    d.report(1179, DISPLAY, false, 0.0);
    d.report(1179, DISPLAY, false, 6.0);
    assert!(d.report(3600, DISPLAY, true, 7.0));
    assert_eq!(d.cap, None);
    assert!(!d.report(1179, DISPLAY, true, 8.0), "a pinch out still waits");
    assert_eq!(d.cap, None);
}

#[test]
fn a_report_with_no_size_changes_nothing() {
    let mut d = ViewerDemand::default();
    d.report(1179, DISPLAY, false, 0.0);
    assert!(!d.report(0, DISPLAY, false, 3.0));
    assert!(!d.report(1179, DISPLAY, false, 7.0), "the pending step was dropped");
    assert_eq!(d.cap, None);
}

#[test]
fn fit_scales_the_long_edge_and_keeps_even_sides() {
    let size = Size { w: 3456.0, h: 2234.0 };
    assert_eq!(fit(size, None), size);
    assert_eq!(fit(size, Some(3840)), size);
    assert_eq!(fit(size, Some(1280)), Size { w: 1280.0, h: 828.0 });
    assert_eq!(fit(Size { w: 1080.0, h: 1920.0 }, Some(960)), Size { w: 540.0, h: 960.0 });
}

#[test]
fn only_a_scaling_source_takes_the_cap() {
    assert_eq!(capture_cap(Some(1280), Quality::Auto, true), Some(1280));
    assert_eq!(capture_cap(Some(1280), Quality::Smooth, true), Some(1280));
    assert_eq!(capture_cap(Some(1280), Quality::Auto, false), None, "a loopback source");
    assert_eq!(capture_cap(None, Quality::Auto, true), None);
    assert_eq!(capture_cap(Some(1280), Quality::High, true), None, "a fixed preset");
}

#[test]
fn the_state_round_trips_as_json() {
    let mut d = ViewerDemand::default();
    d.report(1179, DISPLAY, false, 0.0);
    let back: ViewerDemand = serde_json::from_str(&serde_json::to_string(&d).unwrap()).unwrap();
    assert_eq!(back, d);
}
