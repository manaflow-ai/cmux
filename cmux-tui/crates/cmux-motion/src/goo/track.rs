//! One edge or scalar in flight (gooey-tabs.md "The spring track"): a
//! closed-form spring from `(x0, v0)` toward `target`, started at `start`
//! (media time). `SpringValue::solve` is the step, so a track is exact at any
//! frame rate and under-damped springs ring as they should.

use super::{GooSpring, finite_or};
use crate::{GEOMETRY_EPSILON, SpringValue};

/// How many velocity units per settle unit still count as at rest
/// (design-tokens.json `motion.settle`, the same rule `SpringValue` uses).
const VELOCITY_FACTOR: f64 = 8.;
/// The backward scan's step when finding a rest time (s).
const REST_SCAN_STEP: f64 = 1. / 480.;
/// No track is in flight longer than this (s).
const REST_TIME_MAX: f64 = 30.;
/// The backward scan's most steps (10 s).
const REST_SCAN_STEPS: u32 = 4800;

/// A spring in flight. Plain data: the host keeps it and retargets it.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Track {
    pub x0: f64,
    pub v0: f64,
    pub target: f64,
    /// Media time (s) at which the track is at `x0` with velocity `v0`.
    pub start: f64,
    pub spring: GooSpring,
}

impl Track {
    pub const fn new(x0: f64, v0: f64, target: f64, start: f64, spring: GooSpring) -> Self {
        Self { x0, v0, target, start, spring }
    }

    /// A track resting at `x` from `start`.
    pub const fn at_rest(x: f64, start: f64, spring: GooSpring) -> Self {
        Self::new(x, 0., x, start, spring)
    }

    /// This track with every field finite: a non-finite target is `x0`, a
    /// non-finite `x0` the target, a non-finite velocity or start 0.
    pub fn sanitized(&self) -> Self {
        let target = finite_or(self.target, finite_or(self.x0, 0.));
        Self {
            x0: finite_or(self.x0, target),
            v0: if self.v0.is_finite() { self.v0.clamp(-1.0e7, 1.0e7) } else { 0. },
            target,
            start: if self.start.is_finite() { self.start } else { 0. },
            spring: self.spring.sanitized(),
        }
    }

    /// Value and velocity at media time `t`. Before `start` (or for a NaN
    /// `t`) the track is at `x0`; at `+inf` it rests on the target.
    pub fn state(&self, t: f64) -> (f64, f64) {
        let s = self.sanitized();
        let dt = t - s.start;
        if dt.is_nan() || dt <= 0. {
            return (s.x0, s.v0);
        }
        if dt.is_infinite() {
            return (s.target, 0.);
        }
        let (x, v) = SpringValue::solve(s.x0 - s.target, s.v0, dt, s.spring.params());
        if x.is_finite() && v.is_finite() { (s.target + x, v) } else { (s.target, 0.) }
    }

    /// Seconds from `start` after which `|x - target| < epsilon` and
    /// `|v| < 8 * epsilon` hold for good. A non-positive or non-finite
    /// epsilon is the geometry settle (0.25 pt).
    pub fn rest_time(&self, epsilon: f64) -> f64 {
        let s = self.sanitized();
        let eps =
            if epsilon.is_finite() && epsilon > 0. { epsilon } else { f64::from(GEOMETRY_EPSILON) };
        let bound = s.rest_bound(eps);
        if bound <= 0. {
            return 0.;
        }
        // The bound holds for good; walk back to the last time it does not.
        let out = |dt: f64| {
            let (x, v) = s.state(s.start + dt);
            (x - s.target).abs() >= eps || v.abs() >= eps * VELOCITY_FACTOR
        };
        let mut t = bound;
        for _ in 0..REST_SCAN_STEPS {
            if t <= 0. {
                return 0.;
            }
            if out(t) {
                return (t + REST_SCAN_STEP).min(bound);
            }
            t -= REST_SCAN_STEP;
        }
        t.max(0.)
    }

    /// An upper bound (s) on the rest time from the decay envelope.
    fn rest_bound(&self, eps: f64) -> f64 {
        let p = self.spring.params();
        let w = p.omega();
        let z = p.damping_fraction;
        let x0 = self.x0 - self.target;
        let v0 = self.v0;
        if x0.abs() < f64::EPSILON && v0.abs() < f64::EPSILON {
            return 0.;
        }
        let (amplitude, rate) = if z < 1. {
            let wd = w * (1. - z * z).sqrt();
            let b = (v0 + z * w * x0) / wd;
            (x0.hypot(b), z * w)
        } else {
            // Critical or over-damped: the slow root, halved to cover the
            // t * e^(-wt) term, and a generous amplitude.
            let slow = w * (z - (z * z - 1.).max(0.).sqrt());
            ((x0.abs() + v0.abs() / w) * 4., (slow * 0.5).max(1.0e-3))
        };
        let need = (amplitude / eps).max(amplitude * w / (eps * VELOCITY_FACTOR));
        if need.is_nan() || need <= 1. {
            return 0.;
        }
        let t = need.ln() / rate;
        if t.is_finite() { t.clamp(0., REST_TIME_MAX) } else { REST_TIME_MAX }
    }

    /// Values from `start` to rest at `hz`, at most `out.len()`: the last
    /// written value is the target when the buffer reaches rest. Returns how
    /// many it wrote.
    pub fn sample(&self, hz: f64, out: &mut [f64]) -> usize {
        let s = self.sanitized();
        let hz = sanitize_hz(hz);
        let rest = s.rest_time(f64::from(GEOMETRY_EPSILON));
        let mut written = 0usize;
        for (i, slot) in out.iter_mut().enumerate() {
            let dt = i as f64 / hz;
            if dt >= rest {
                *slot = s.target;
                written = written.saturating_add(1);
                break;
            }
            *slot = s.state(s.start + dt).0;
            written = written.saturating_add(1);
        }
        written
    }

    /// The interruption rule: the track restarted at `t` from its state
    /// there toward `target` on `spring`, velocity kept, so a new gesture
    /// mid-animation never snaps. A non-finite `t` restarts at `start`.
    pub fn retarget(&self, t: f64, target: f64, spring: GooSpring) -> Track {
        let s = self.sanitized();
        let t = if t.is_finite() { t } else { s.start };
        let (x, v) = s.state(t);
        Track { x0: x, v0: v, target: finite_or(target, x), start: t, spring: spring.sanitized() }
    }
}

/// A frame rate: finite, 1 to 480 Hz; 120 when it is not a number.
pub(crate) fn sanitize_hz(hz: f64) -> f64 {
    if hz.is_finite() && hz >= 1. { hz.min(480.) } else { 120. }
}

#[cfg(test)]
#[path = "track_tests.rs"]
mod tests;
