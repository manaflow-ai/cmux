use super::*;
use crate::goo::{GooLevel, rest_outline};

fn slot() -> Blob {
    Blob {
        left: 100.,
        right: 260.,
        top: 6.,
        baseline: 36.,
        corner_radius: 8.,
        feet_radius: 8.,
        skips_leading: false,
    }
}

fn tab_above(gap: f64) -> RoundedRect {
    RoundedRect::new(110., 6. - gap - 30., 160., 30., 8.)
}

#[test]
fn goo_drag_neck_hysteresis_breaks_past_capture() {
    for level in [GooLevel::Subtle, GooLevel::Full] {
        let t = GooTuning::for_level(level);
        assert!(t.break_distance > t.capture_distance && t.capture_distance > 0.);
        // Going out: holds until the break, then snaps.
        let mut attached = true;
        let mut broke_at = None;
        for i in 0..400 {
            let gap = i as f64 * 0.25;
            let n = drag_neck(&slot(), &tab_above(gap), attached, &t);
            if attached && !n.attached {
                broke_at = Some(gap);
            }
            attached = n.attached;
        }
        let broke_at = broke_at.expect("the neck breaks");
        assert!((broke_at - t.break_distance).abs() <= 0.25, "{level:?} broke at {broke_at}");
        // Between capture and break a detached tab stays detached, an attached one stays attached.
        let mid = (t.capture_distance + t.break_distance) * 0.5;
        assert!(!drag_neck(&slot(), &tab_above(mid), false, &t).attached);
        assert!(drag_neck(&slot(), &tab_above(mid), true, &t).attached);
        // Jitter on the break boundary does not flicker once broken.
        let mut state = false;
        for j in 0..50 {
            let gap = t.break_distance + if j % 2 == 0 { -0.5 } else { 0.5 };
            state = drag_neck(&slot(), &tab_above(gap), state, &t).attached;
            assert!(!state, "re-attached at {gap}");
        }
        // Coming back: absorbed only inside capture.
        let back = drag_neck(&slot(), &tab_above(t.capture_distance - 0.5), false, &t);
        assert!(back.attached);
        // And jitter on the capture boundary does not flicker once absorbed.
        let mut state = true;
        for j in 0..50 {
            let gap = t.capture_distance + if j % 2 == 0 { -0.5 } else { 0.5 };
            state = drag_neck(&slot(), &tab_above(gap), state, &t).attached;
            assert!(state, "let go at {gap}");
        }
    }
}

#[test]
fn goo_drag_neck_reaches_the_tab_and_detached_is_rest() {
    let t = GooTuning::for_level(GooLevel::Full);
    let n = drag_neck(&slot(), &tab_above(20.), true, &t);
    assert!(n.attached);
    let top = n.outline.p.iter().map(|p| p.y).fold(f64::MAX, f64::min);
    assert!(top < 6. - 19., "the neck reaches the tab: {top}");
    assert!(n.outline.is_finite());
    let far = drag_neck(&slot(), &tab_above(200.), true, &t);
    assert!(!far.attached);
    assert_eq!(far.outline, rest_outline(&slot()));
}

#[test]
fn goo_level_off_never_necks() {
    let t = GooTuning::for_level(GooLevel::Off);
    for gap in [0., 1., 5., 50.] {
        let n = drag_neck(&slot(), &tab_above(gap), true, &t);
        assert!(!n.attached);
        assert_eq!(n.outline, rest_outline(&slot()));
    }
}

#[test]
fn goo_drag_neck_is_garbage_safe() {
    let bad = [f64::NAN, f64::INFINITY, f64::NEG_INFINITY, -10., 0., 1e300];
    let mut tuning = GooTuning::for_level(GooLevel::Full);
    for &a in &bad {
        tuning.break_distance = a;
        tuning.capture_distance = -a;
        for &b in &bad {
            let n = drag_neck(&slot(), &RoundedRect::new(a, b, a, b, a), a > 0., &tuning);
            assert!(n.outline.is_finite());
        }
    }
}
