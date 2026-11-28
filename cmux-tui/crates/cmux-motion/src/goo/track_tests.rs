use super::*;
use crate::goo::{GooLevel, GooTuning};

fn full() -> GooSpring {
    GooTuning::for_level(GooLevel::Full).select
}

#[test]
fn goo_track_starts_at_x0_and_rests_on_target() {
    let tr = Track::new(0., 0., 200., 1., full());
    assert_eq!(tr.state(1.), (0., 0.));
    assert_eq!(tr.state(0.5), (0., 0.));
    let rest = tr.rest_time(0.25);
    assert!((0.2..5.).contains(&rest), "{rest}");
    let (x, v) = tr.state(1. + rest);
    assert!((x - 200.).abs() < 0.25 && v.abs() < 2., "{x} {v}");
    // Under-damped: it passes its target on the way.
    let peak = (0..2000).map(|i| tr.state(1. + i as f64 / 1000.).0).fold(0., f64::max);
    assert!(peak > 210., "full select overshoots: {peak}");
    // And stays in after the rest time.
    for i in 0..400 {
        let (x, _) = tr.state(1. + rest + i as f64 / 200.);
        assert!((x - 200.).abs() < 0.25, "out again at {i}: {x}");
    }
}

#[test]
fn goo_retarget_keeps_position_and_velocity_continuous() {
    for spring in [full(), GooTuning::for_level(GooLevel::Subtle).select, GooSpring::new(0.3, 1.)] {
        let a = Track::new(0., 0., 300., 2., spring);
        for t in [2.01, 2.05, 2.13, 2.4] {
            let b = a.retarget(t, -50., spring);
            let (xa, va) = a.state(t);
            let (xb, vb) = b.state(t);
            assert_eq!((xa, va), (xb, vb));
            // Just after: the same value and slope.
            let h = 1e-6;
            let (xb2, _) = b.state(t + h);
            assert!((xb2 - xa - va * h).abs() < 1e-3, "{xb2} {xa} {va}");
            assert!((b.state(t + h).1 - va).abs() < 1., "velocity jumps");
        }
    }
}

#[test]
fn goo_track_is_garbage_safe() {
    let bad = [f64::NAN, f64::INFINITY, f64::NEG_INFINITY, -1e300, 1e300, 0.];
    for &x0 in &bad {
        for &v0 in &bad {
            for &target in &bad {
                for &r in &bad {
                    let tr = Track::new(x0, v0, target, 0., GooSpring::new(r, r));
                    for &t in &bad {
                        let (x, v) = tr.state(t);
                        assert!(x.is_finite() && v.is_finite());
                        let rt = tr.rest_time(t);
                        assert!(rt.is_finite() && rt >= 0.);
                        let re = tr.retarget(t, x0, GooSpring::new(r, v0));
                        assert!(re.state(1.).0.is_finite());
                    }
                    let mut out = [0.; 4];
                    assert!(tr.sample(r, &mut out) <= 4);
                    assert_eq!(tr.sample(60., &mut []), 0);
                }
            }
        }
    }
}

#[test]
fn goo_sample_ends_on_target() {
    let tr = Track::new(10., 0., 110., 0., GooTuning::for_level(GooLevel::Subtle).select);
    let mut out = [0.; 512];
    let n = tr.sample(120., &mut out);
    assert!((11..512).contains(&n), "{n}");
    assert_eq!(out.get(n - 1), Some(&110.));
    assert_eq!(out.first(), Some(&10.));
}
