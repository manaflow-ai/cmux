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
#[path = "plan_tests.rs"]
mod tests;
