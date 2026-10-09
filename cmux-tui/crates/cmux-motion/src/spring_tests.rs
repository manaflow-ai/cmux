//! Tests for `spring.rs`.

use super::*;

/// Steps `s` to rest at 120 Hz and checks every frame against a bare
/// integrator tuned by `token`: the spring really ran that token.
fn assert_runs_token(s: Spring, token: MotionSpring) {
    assert_runs_token_while(s, token, |_| true);
}

/// As `assert_runs_token`, checking only the frames that start while
/// `checked` holds; the rest still has to settle.
fn assert_runs_token_while(mut s: Spring, token: MotionSpring, checked: impl Fn(&Spring) -> bool) {
    let policy = MotionPolicy::default();
    let mut reference = s.state;
    let mut frames = 0;
    loop {
        if !checked(&s) {
            while s.step(1. / 120., &policy) {
                frames += 1;
                assert!(frames < 120, "never settled");
            }
            break;
        }
        assert_eq!(s.active_token(), token, "frame {frames}");
        let moving = s.step(1. / 120., &policy);
        reference.step(1. / 120., policy.spring(token));
        if !moving {
            break;
        }
        assert_eq!(s.state, reference, "frame {frames}");
        frames += 1;
        assert!(frames < 120, "never settled");
    }
    assert_eq!(s.value(), s.target());
}

#[test]
fn positions_to_zero_and_below_keep_their_token() {
    for token in [MotionSpring::Move, MotionSpring::Scroll, MotionSpring::Settle] {
        for target in [0., -0.0005, -80.] {
            let mut s = Spring::position(120., token);
            assert_eq!(s.kind, SpringKind::Position);
            assert_eq!(s.epsilon, GEOMETRY_EPSILON);
            s.set_target(target);
            assert_eq!(s.active_token(), token, "{token:?} to {target}");
            assert_runs_token(s, token);
        }
    }
    // From below 0 up to 0, and with the kind set on an existing spring.
    let mut s = Spring::new(-40., MotionSpring::Move).with_kind(SpringKind::Position);
    s.set_target(0.);
    assert_runs_token(s, MotionSpring::Move);
}

#[test]
fn sizes_to_zero_still_use_disappear() {
    assert_eq!(SpringKind::default(), SpringKind::Size);
    for mut s in [
        Spring::new(120., MotionSpring::Move),
        Spring::new(120., MotionSpring::Appear).with_kind(SpringKind::Size),
        Spring::unit(1., MotionSpring::Appear),
    ] {
        assert_eq!(s.kind, SpringKind::Size);
        s.set_target(0.);
        assert_eq!(s.active_token(), MotionSpring::Disappear);
        // Until the collapse first reaches 0; the ~0.1% overshoot below 0
        // then returns on `token`, as before `SpringKind` (and in Swift).
        assert_runs_token_while(s, MotionSpring::Disappear, |s| s.value() > s.target());
    }
    // Growing from 0 is not a disappear.
    let mut s = Spring::new(0., MotionSpring::Appear);
    s.set_target(80.);
    assert_runs_token(s, MotionSpring::Appear);
}

#[test]
fn position_retarget_through_zero_is_continuous() {
    let policy = MotionPolicy::default();
    let mut s = Spring::position(0., MotionSpring::Move);
    s.set_target(200.);
    for _ in 0..6 {
        s.step(1. / 120., &policy);
    }
    let (x, v) = (s.value(), s.velocity());
    assert!(x > 0. && x < 200. && v > 0.);
    s.set_target(-100.);
    assert_eq!((s.value(), s.velocity()), (x, v), "no jump on retarget");
    let mut next = s;
    next.step(1. / 120., &policy);
    // One frame moves no more than the largest frame of the first move.
    assert!((next.value() - x).abs() < 20., "continuous: {x} -> {}", next.value());
    // Through 0 and below on `move` all the way, from the same state.
    assert_runs_token(s, MotionSpring::Move);

    // A drag released toward a negative offset settles, then moves again,
    // and stays a position throughout.
    let mut s = Spring::position(0., MotionSpring::Move);
    for i in 0..10 {
        s.follow(-(i as f32) * 10., i as f64 / 120.);
    }
    s.release(9. / 120. + 0.01);
    s.set_target(-120.);
    assert_eq!(s.active_token(), MotionSpring::Settle);
    while s.step(1. / 120., &policy) {}
    assert_eq!((s.value(), s.token, s.kind), (-120., MotionSpring::Move, SpringKind::Position));
}
