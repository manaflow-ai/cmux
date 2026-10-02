//! Tests for `spring.rs`.

use super::*;

fn ms(s: f64) -> f64 {
    (s * 1000.).round()
}

/// Visible end and 120 Hz rest from plans/cmux-next/motion.md.
const TABLE: [(MotionSpring, f64, f64); 9] = [
    (MotionSpring::Move, 192., 250.),
    (MotionSpring::Appear, 175., 225.),
    (MotionSpring::Disappear, 142., 200.),
    (MotionSpring::Settle, 175., 342.),
    (MotionSpring::Scroll, 208., 267.),
    (MotionSpring::Screen, 208., 267.),
    (MotionSpring::Track, 117., 167.),
    (MotionSpring::Selection, 142., 200.),
    (MotionSpring::Panel, 142., 283.),
];

#[test]
fn tokens_match_the_spec() {
    for (token, visible, rest) in TABLE {
        let p = token.base();
        let v = ms(p.visible_end_at(120.));
        let r = ms(p.rest_time(200., 120.));
        assert!((v - visible).abs() <= 1., "{token:?} visible end {v} ms, spec {visible} ms");
        assert!((r - rest).abs() <= 1., "{token:?} rest {r} ms, spec {rest} ms");
        println!("{token:?}: visible end {v} ms (spec {visible}), rest {r} ms (spec {rest})");
    }
    // Structural ordering: disappear < appear < move.
    let ve = |t: MotionSpring| t.base().visible_end();
    assert!(ve(MotionSpring::Disappear) < ve(MotionSpring::Appear));
    assert!(ve(MotionSpring::Appear) < ve(MotionSpring::Move));
}

#[test]
fn fade_tokens_match_the_spec() {
    let p = MotionPolicy::default();
    assert_eq!(p.fade(MotionFade::Hover), 0.08);
    assert_eq!(p.fade(MotionFade::Focus), 0.10);
    assert_eq!(p.fade(MotionFade::FadeIn), 0.12);
    assert_eq!(p.fade(MotionFade::FadeOut), 0.08);
    for t in MotionFade::ALL {
        assert!(p.fade(t) <= 0.16, "{t:?}");
    }
}

#[test]
fn spring_settles_without_visible_overshoot() {
    for token in MotionSpring::ALL {
        let mut s = Spring::new(0., token);
        s.set_target(200.);
        let policy = MotionPolicy::default();
        let mut peak = 0f32;
        let mut frames = 0;
        while s.step(1. / 120., &policy) {
            peak = peak.max(s.value());
            frames += 1;
            assert!(frames < 120, "{token:?} never settled");
        }
        assert_eq!(s.value(), 200.);
        assert_eq!(s.velocity(), 0.);
        let overshoot = peak - 200.;
        // Damping 0.9 overshoots ~0.1 pt; settle/panel (0.85) ~0.8 pt.
        assert!(overshoot < 1.0, "{token:?} overshoot {overshoot}");
    }
}

#[test]
fn closed_form_matches_the_stepper() {
    for token in MotionSpring::ALL {
        let p = token.base();
        let mut s = SpringValue::new(0.);
        s.target = 1.;
        for frame in 1..=60 {
            s.step(1. / 120., p);
            let exact = p.step_response(frame as f64 / 120.);
            let err = (s.value as f64 - exact).abs();
            // Semi-implicit Euler leads the exact curve slightly in the
            // first frames of the stiffest springs.
            assert!(err < 0.04, "{token:?} frame {frame} error {err}");
        }
    }
}

#[test]
fn retarget_keeps_position_and_velocity() {
    let policy = MotionPolicy::default();
    let mut s = Spring::new(0., MotionSpring::Move);
    s.set_target(200.);
    for _ in 0..6 {
        s.step(1. / 120., &policy);
    }
    let (x, v) = (s.value(), s.velocity());
    assert!(x > 0. && x < 200. && v > 0.);
    // Reverse mid-flight: nothing jumps, momentum carries for a moment.
    s.set_target(-100.);
    assert_eq!((s.value(), s.velocity()), (x, v));
    s.step(1. / 120., &policy);
    // One frame moves no more than the largest frame of the first move.
    assert!((s.value() - x).abs() < 20., "continuous: {} -> {}", x, s.value());
    while s.step(1. / 120., &policy) {}
    assert_eq!(s.value(), -100.);
}

#[test]
fn follow_and_release_carry_pointer_velocity() {
    let policy = MotionPolicy::default();
    let mut s = Spring::new(0., MotionSpring::Move);
    for i in 0..10 {
        s.follow(i as f32 * 10., i as f64 / 120.);
    }
    // 10 pt per 1/120 s = 1200 pt/s.
    assert_eq!(s.value(), 90.);
    assert!((s.velocity() - 1200.).abs() < 50., "{}", s.velocity());
    s.release(9. / 120. + 0.01);
    assert_eq!(s.active_token(), MotionSpring::Settle);
    s.set_target(90.);
    s.step(1. / 120., &policy);
    assert!(s.value() > 90., "release carries velocity past the drop point");
    while s.step(1. / 120., &policy) {}
    assert_eq!(s.value(), 90.);
    assert_eq!(s.token, MotionSpring::Move, "settle is for one release only");

    // A pointer that stopped before release lands from rest.
    let mut s = Spring::new(0., MotionSpring::Move);
    s.follow(0., 0.);
    s.follow(10., 0.01);
    s.release(0.2);
    assert_eq!(s.velocity(), 0.);
}

#[test]
fn moves_to_zero_use_disappear() {
    let mut s = Spring::new(120., MotionSpring::Appear);
    s.set_target(0.);
    assert_eq!(s.active_token(), MotionSpring::Disappear);
    s.set_target(100.);
    assert_eq!(s.active_token(), MotionSpring::Appear);
}

#[test]
fn normal_scales_time_by_one_and_a_half() {
    let fast = MotionPolicy::new(MotionSpeed::Fast, false);
    let normal = MotionPolicy::new(MotionSpeed::Normal, false);
    let f = fast.spring(MotionSpring::Move);
    let n = normal.spring(MotionSpring::Move);
    assert!((n.response - f.response * 1.5).abs() < 1e-9);
    assert_eq!(n.damping_fraction, f.damping_fraction);
    assert!((n.visible_end() / f.visible_end() - 1.5).abs() < 0.03);
    assert!((normal.fade(MotionFade::Hover) - 0.12).abs() < 1e-9);
}

#[test]
fn off_applies_everything_in_one_frame() {
    let off = MotionPolicy::new(MotionSpeed::Off, false);
    assert!(!off.animates_movement() && !off.animates_fades() && !off.animates_loops());
    let mut s = Spring::new(0., MotionSpring::Move);
    s.set_target(200.);
    assert!(!s.step(1. / 120., &off));
    assert_eq!(s.value(), 200.);
    let mut f = Fade::new(0., MotionFade::FadeIn);
    f.set_target(1., &off);
    assert_eq!(f.value(), 1.);
    assert!(!f.step(0.));
    assert_eq!(off.spring_duration(MotionSpring::Move), 0.);
    // Off wins over Reduce Motion: no crossfade either.
    let both = MotionPolicy::new(MotionSpeed::Off, true);
    assert_eq!(both.fade(MotionFade::Crossfade), 0.);
    assert_eq!(off.period(MotionLoop::Spinner), None);
}

#[test]
fn reduce_motion_snaps_movement_and_caps_fades() {
    let reduced = MotionPolicy::new(MotionSpeed::Normal, true);
    assert!(!reduced.animates_movement());
    assert!(reduced.animates_fades());
    assert_eq!(reduced.period(MotionLoop::Pulse), None);
    let mut s = Spring::new(0., MotionSpring::Screen);
    s.set_target(500.);
    assert!(!s.step(1. / 120., &reduced));
    assert_eq!(s.value(), 500.);
    for t in MotionFade::ALL {
        assert!(reduced.fade(t) <= 0.1 + 1e-9, "{t:?}");
        assert!(reduced.fade(t) > 0.);
    }
    assert_eq!(reduced.spring_duration(MotionSpring::Move), 0.);
}

#[test]
fn fade_is_ease_out_and_retargets_from_the_presented_value() {
    let policy = MotionPolicy::default();
    let mut f = Fade::new(0., MotionFade::FadeIn);
    f.set_target(1., &policy);
    assert!(f.step(0.03));
    let mid = f.value();
    // Ease-out: a quarter of the time covers more than a quarter.
    assert!(mid > 0.25 && mid < 1.);
    f.set_target_with(0., MotionFade::FadeOut, &policy);
    assert_eq!(f.value(), mid, "no jump on retarget");
    assert!(f.step(0.01));
    assert!(f.value() < mid);
    assert!(!f.step(0.08));
    assert_eq!(f.value(), 0.);
    // Same target while moving does not restart the curve.
    f.set_target(1., &policy);
    f.step(0.06);
    let v = f.value();
    f.set_target(1., &policy);
    f.step(0.06);
    assert_eq!(f.value(), 1.);
    assert!(v < 1.);
}

#[test]
fn stalled_frames_do_not_teleport() {
    let p = MotionSpring::Move.base();
    let mut s = SpringValue::new(0.);
    s.target = 200.;
    s.step(5., p);
    let mut t = SpringValue::new(0.);
    t.target = 200.;
    t.step(0.1, p);
    assert_eq!(s, t);
}
