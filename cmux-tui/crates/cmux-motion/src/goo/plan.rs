//! Event plans (gooey-tabs.md "Event plans"): an event's keyframes, sampled
//! once per event from the blob's two edge tracks, for Core Animation to
//! play. Every frame is a pure function of the tracks' state at its time, so
//! a retarget (which keeps position and velocity) gives a plan that starts
//! exactly where the running one is: nothing snaps. The plan never walks the
//! tabs: its cost is constant in the tab count.
//!
//! On top of the edges, a frame adds the goo, all of it proportional to the
//! edges' velocity, so it is zero at rest and in level `off`:
//! - stretch (select, reorder, snap, absorb): the leading edge runs ahead and
//!   the trailing one lags, up to `stretch` of the width (and never more than
//!   the width at most);
//! - the fillets swell with speed, up to `feet_scale`;
//! - lean: the top corners shear toward the travel, up to `lean` of the
//!   height;
//! - the settle wobble: the top edge dips by up to `wobble_amplitude` while
//!   the blob moves, so an under-damped settle bobs it;
//! - fillets shrink before the width does (a pinch, a bud), and the top,
//!   baseline, corner and fillets go from `rest_from` to `rest_to` with the
//!   edges' progress (close the last tab: the blob sinks into the card).

use std::f64::consts::TAU;

use super::{Blob, GOO_KEYFRAMES_MAX, GooTuning, Outline, Shape, Track, clamp01, rest_outline};
use crate::GEOMETRY_EPSILON;
use crate::goo::track::sanitize_hz;

/// The longest plan (s).
const PLAN_SECONDS_MAX: f64 = 10.;

/// What happened to the strip.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum GooEvent {
    #[default]
    Select = 0,
    Open = 1,
    Close = 2,
    CloseLast = 3,
    Reorder = 4,
    Snap = 5,
    Absorb = 6,
}

impl GooEvent {
    /// The event for a raw value; an unknown one is `Select`.
    pub const fn from_raw(raw: u32) -> Self {
        match raw {
            1 => Self::Open,
            2 => Self::Close,
            3 => Self::CloseLast,
            4 => Self::Reorder,
            5 => Self::Snap,
            6 => Self::Absorb,
            _ => Self::Select,
        }
    }

    fn stretches(self) -> bool {
        matches!(self, Self::Select | Self::Reorder | Self::Snap | Self::Absorb)
    }
}

/// One plan's inputs.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PlanInput {
    pub event: GooEvent,
    /// The blob as it was when the event came (its top, baseline, radii).
    pub rest_from: Blob,
    /// The blob at rest after the event; the last keyframe is exactly it.
    pub rest_to: Blob,
    pub left: Track,
    pub right: Track,
    pub tuning: GooTuning,
    pub hz: f64,
    pub reduce_motion: bool,
}

/// The blob's outline at media time `t` of a plan.
pub fn frame(input: &PlanInput, t: f64) -> Outline {
    let tuning = input.tuning.sanitized();
    let (left, right) = (input.left.sanitized(), input.right.sanitized());
    let (l, vl) = left.state(t);
    let (r, vr) = right.state(t);
    let (from, to) = (input.rest_from.shape(), input.rest_to.shape());

    // Progress of the edges from where they started to their targets.
    let travel = (left.x0 - left.target).abs() + (right.x0 - right.target).abs();
    let p = if travel > 0.5 {
        clamp01(1. - ((l - left.target).abs() + (r - right.target).abs()) / travel)
    } else {
        1.
    };
    let mix = |a: f64, b: f64| a + (b - a) * p;
    let top = mix(from.top, to.top);
    let baseline = mix(from.baseline, to.baseline);
    let corner = mix(from.corner, to.corner);
    let (mut feet_l, mut feet_t) =
        (mix(from.feet_leading, to.feet_leading), mix(from.feet_trailing, to.feet_trailing));

    // Fillets shrink before the width: full until 60% of the target width,
    // then as the square of the share.
    let (lo, hi) = (l.min(r), l.max(r));
    let target_w = right.target - left.target;
    if target_w >= 1. {
        let s = clamp01((hi - lo) / (0.6 * target_w));
        feet_l *= s * s;
        feet_t *= s * s;
    }

    let tau = tuning.wobble.response / TAU;
    let v = (vl + vr) * 0.5;
    let height = (baseline - top).max(0.);
    let (mut lo, mut hi) = (lo, hi);
    if input.event.stretches() && tuning.stretch > 0. {
        let w = target_w.max(0.);
        let ext = (tuning.stretch * v.abs() * tau * 2.).min(tuning.stretch * w);
        lo -= ext * 0.5;
        hi += ext * 0.5;
    }
    let lean_max = tuning.lean * height;
    let lean = (tuning.lean * v * tau).clamp(-lean_max, lean_max);
    let speed = (v.abs() * tau / 12.).min(4.);
    let dip = tuning.wobble_amplitude * speed.tanh();
    // The fillets swell with speed (full: up to 1.4x), back to 1x at rest.
    let swell = 1. + (tuning.feet_scale - 1.) * speed.tanh();
    let (feet_l, feet_t) = (feet_l * swell, feet_t * swell);
    let top = (top + dip).min(baseline);
    Shape::new(lo, hi, top, baseline, corner, feet_l, feet_t).outline(lean)
}

/// The plan for `input`: calls `emit(outline, key_time)` for each keyframe
/// in order (at most `capacity`, and at most `GOO_KEYFRAMES_MAX`), key
/// times 0...1 over the returned duration. Sampled at `hz` from the later
/// of the two tracks' starts until both rest; a longer plan is spread over
/// the keyframes it has. The last keyframe is exactly `rest_to`'s rest
/// outline. Reduce motion: one keyframe (`rest_to`) and duration 0. A zero
/// capacity writes nothing. Returns (count, duration).
pub fn plan(
    input: &PlanInput,
    capacity: usize,
    mut emit: impl FnMut(&Outline, f64),
) -> (usize, f64) {
    let capacity = capacity.min(GOO_KEYFRAMES_MAX);
    if capacity == 0 {
        return (0, 0.);
    }
    let end = rest_outline(&input.rest_to);
    if input.reduce_motion {
        emit(&end, 0.);
        return (1, 0.);
    }
    let (left, right) = (input.left.sanitized(), input.right.sanitized());
    let t0 = left.start.max(right.start);
    let eps = f64::from(GEOMETRY_EPSILON);
    let rest_end = (left.start + left.rest_time(eps)).max(right.start + right.rest_time(eps));
    let duration = (rest_end - t0).clamp(0., PLAN_SECONDS_MAX);
    let hz = sanitize_hz(input.hz);
    // Frames at hz, both ends included, capped by the capacity.
    let wanted = (duration * hz).ceil() + 1.;
    let count = (0..capacity).take_while(|i| (*i as f64) < wanted).count().max(1);
    if count == 1 || duration <= 0. {
        emit(&end, 0.);
        return (1, 0.);
    }
    let last = count.saturating_sub(1);
    let span = last as f64;
    for i in 0..count {
        let key = i as f64 / span;
        if i == last {
            emit(&end, 1.);
        } else {
            emit(&frame(input, t0 + key * duration), key);
        }
    }
    (count, duration)
}

#[cfg(test)]
mod tests {
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
            (1..120).map(|i| width(&frame(&input, 5. + i as f64 / 240.))).fold(0., f64::max)
                - rest_w
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
}
