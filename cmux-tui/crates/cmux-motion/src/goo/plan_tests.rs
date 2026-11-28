use super::*;
use crate::goo::{GooLevel, GooSpring};

fn blob(left: f64, right: f64) -> Blob {
    Blob {
        left,
        right,
        top: 6.,
        baseline: 36.,
        corner_radius: 8.,
        feet_radius: 8.,
        skips_leading: false,
    }
}

fn select(level: GooLevel, from: (f64, f64), to: (f64, f64)) -> PlanInput {
    let tuning = GooTuning::for_level(level);
    PlanInput {
        event: GooEvent::Select,
        rest_from: blob(from.0, from.1),
        rest_to: blob(to.0, to.1),
        left: Track::new(from.0, 0., to.0, 5., tuning.select),
        right: Track::new(from.1, 0., to.1, 5., tuning.select),
        tuning,
        hz: 120.,
        reduce_motion: false,
    }
}

fn collect(input: &PlanInput, capacity: usize) -> (Vec<(Outline, f64)>, f64) {
    let mut v = Vec::new();
    let (n, d) = plan(input, capacity, |o, k| v.push((*o, k)));
    assert_eq!(n, v.len());
    (v, d)
}

#[test]
fn goo_plan_count_within_capacity_and_ends_at_rest_to() {
    for level in [GooLevel::Off, GooLevel::Subtle, GooLevel::Full] {
        for capacity in [0, 1, 2, 7, 120, 500] {
            let input = select(level, (0., 120.), (400., 560.));
            let (frames, duration) = collect(&input, capacity);
            assert!(frames.len() <= capacity.min(GOO_KEYFRAMES_MAX), "{level:?} {capacity}");
            if capacity == 0 {
                assert!(frames.is_empty());
                continue;
            }
            let (last, key) = frames.last().copied().expect("a keyframe");
            assert_eq!(last, rest_outline(&input.rest_to));
            assert!((0. ..=PLAN_SECONDS_MAX).contains(&duration));
            assert!(frames.windows(2).all(|w| w[0].1 < w[1].1), "key times increase");
            assert!(frames.iter().all(|(o, k)| o.is_finite() && (0. ..=1.).contains(k)));
            if frames.len() > 1 {
                assert_eq!(key, 1.);
                assert_eq!(frames[0].1, 0.);
            }
        }
    }
}

#[test]
fn goo_reduce_motion_is_one_keyframe() {
    let mut input = select(GooLevel::Full, (0., 120.), (400., 560.));
    input.reduce_motion = true;
    let (frames, duration) = collect(&input, 120);
    assert_eq!(frames.len(), 1);
    assert_eq!(duration, 0.);
    assert_eq!(frames[0].0, rest_outline(&input.rest_to));
}

fn max_deviation(a: &Outline, b: &Outline) -> f64 {
    a.p.iter().zip(&b.p).map(|(p, q)| p.sub(*q).len()).fold(0., f64::max)
}

/// Level off: the outline is exactly the edges' rest-shaped blob at every
/// frame (no stretch, lean or wobble), and the edges never pass their targets.
#[test]
fn goo_level_off_has_no_stretch_or_wobble() {
    let input = select(GooLevel::Off, (0., 120.), (400., 560.));
    for i in 0..200 {
        let t = 5. + i as f64 / 240.;
        let (l, _) = input.left.state(t);
        let (r, _) = input.right.state(t);
        assert!(l <= 400. + 1e-9 && r <= 560. + 1e-9, "off never overshoots");
        let plain = Shape::new(l, r, 6., 36., 8., 8., 8.).outline(0.);
        assert!(max_deviation(&frame(&input, t), &plain) < 1e-9, "frame {i}");
    }
}

#[test]
fn goo_full_stretches_and_subtle_barely() {
    let width = |o: &Outline| {
        let xs = o.p.iter().map(|p| p.x);
        xs.clone().fold(f64::MIN, f64::max) - xs.fold(f64::MAX, f64::min)
    };
    let rest_w = width(&rest_outline(&blob(0., 120.)));
    let peak = |level| {
        let input = select(level, (0., 120.), (400., 520.));
        (1..120).map(|i| width(&frame(&input, 5. + i as f64 / 240.))).fold(0., f64::max) - rest_w
    };
    let (subtle, full) = (peak(GooLevel::Subtle), peak(GooLevel::Full));
    assert!(full > 25., "full stretches: {full}");
    assert!(subtle > 2., "subtle stretches: {subtle}");
    assert!(subtle < full * 0.5, "subtle stretches a little: {subtle}");
}

/// A retarget mid-plan starts the next plan exactly where the outline
/// is: the first keyframe of the new plan equals the old frame at that time.
#[test]
fn goo_retarget_plan_starts_where_the_old_one_is() {
    for level in [GooLevel::Subtle, GooLevel::Full] {
        let a = select(level, (0., 120.), (400., 520.));
        let now = 5.13;
        let mut b = a;
        b.left = a.left.retarget(now, 800., a.tuning.select);
        b.right = a.right.retarget(now, 920., a.tuning.select);
        b.rest_to = blob(800., 920.);
        let (frames, _) = collect(&b, 120);
        assert!(max_deviation(&frames[0].0, &frame(&a, now)) < 1e-6, "{level:?}");
        // And it moves on smoothly: no frame jumps more than its travel allows.
        for w in frames.windows(2) {
            assert!(max_deviation(&w[0].0, &w[1].0) < 120., "{level:?}");
        }
    }
}

#[test]
fn goo_plan_is_garbage_safe() {
    let bad = [f64::NAN, f64::INFINITY, f64::NEG_INFINITY, -5., 0., 1e300];
    for &a in &bad {
        for &b in &bad {
            let tuning = GooTuning {
                stretch: a,
                lean: b,
                wobble_amplitude: a,
                wobble: GooSpring::new(a, b),
                ..GooTuning::for_level(GooLevel::Full)
            };
            let input = PlanInput {
                event: GooEvent::from_raw(7),
                rest_from: Blob {
                    left: a,
                    right: b,
                    top: a,
                    baseline: b,
                    corner_radius: a,
                    feet_radius: b,
                    skips_leading: true,
                },
                rest_to: blob(a, b),
                left: Track::new(a, b, a, b, GooSpring::new(a, b)),
                right: Track::new(b, a, b, a, GooSpring::new(b, a)),
                tuning,
                hz: a,
                reduce_motion: false,
            };
            let (frames, d) = collect(&input, 120);
            assert!(d.is_finite() && !frames.is_empty());
            assert!(frames.iter().all(|(o, k)| o.is_finite() && k.is_finite()));
        }
    }
}

/// Close the last tab: the blob sinks into the card's top, fillets flat.
#[test]
fn goo_close_last_sinks_into_the_card() {
    let tuning = GooTuning::for_level(GooLevel::Full);
    let from = blob(0., 120.);
    let to = Blob {
        left: 60.,
        right: 60.,
        top: 36.,
        baseline: 36.,
        corner_radius: 8.,
        feet_radius: 0.,
        skips_leading: true,
    };
    let input = PlanInput {
        event: GooEvent::CloseLast,
        rest_from: from,
        rest_to: to,
        left: Track::new(0., 0., 60., 0., tuning.close),
        right: Track::new(120., 0., 60., 0., tuning.close),
        tuning,
        hz: 120.,
        reduce_motion: false,
    };
    let (frames, _) = collect(&input, 120);
    let last = frames.last().map(|f| f.0).expect("frames");
    assert!(last.p.iter().all(|p| (p.y - 36.).abs() < 1e-9 && (p.x - 60.).abs() < 1e-9));
    for w in frames.windows(2) {
        assert!(max_deviation(&w[0].0, &w[1].0) < 40., "no pop");
    }
}
