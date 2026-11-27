//! Timed fades: Core Animation's ease curves and `Fade`, a timed opacity
//! or color change that retargets from the value on screen.

use crate::spring::MAX_FRAME;
use crate::{MotionFade, MotionPolicy};

// ---------------------------------------------------------------------------
// Timed fades

/// Control points of Core Animation's `easeOut`
/// (`CAMediaTimingFunction(name: .easeOut)`, the curve of cmux-next's
/// `Motion.fadeCurve`): a cubic Bezier from (0, 0) to (1, 1) through
/// (0, 0) and (0.58, 1).
pub const EASE_OUT_CONTROL_POINTS: [f64; 4] = [0., 0., 0.58, 1.];

/// Core Animation's `easeOut`, used by every timed fade: the progress at
/// time fraction `t` (0..=1). Solves the curve's x for `t` (Newton, then
/// bisection), then evaluates its y; within 1e-5 of `CAMediaTimingFunction`
/// (whose own solver stops at a coarser tolerance: 7e-6 at most here).
pub fn ease_out(t: f32) -> f32 {
    let [x1, y1, x2, y2] = EASE_OUT_CONTROL_POINTS;
    cubic_bezier(f64::from(t.clamp(0., 1.)), x1, y1, x2, y2) as f32
}

/// Control points of Core Animation's `easeInEaseOut`
/// (`CAMediaTimingFunction(name: .easeInEaseOut)`): a cubic Bezier from
/// (0, 0) to (1, 1) through (0.42, 0) and (0.58, 1). cmux-next uses it for
/// the hover marquee's scroll (`Motion.marqueeAnimation`).
pub const EASE_IN_EASE_OUT_CONTROL_POINTS: [f64; 4] = [0.42, 0., 0.58, 1.];

/// Core Animation's `easeInEaseOut` at time fraction `t` (0..=1), solved
/// like `ease_out`; within 1e-5 of `CAMediaTimingFunction`.
pub fn ease_in_ease_out(t: f32) -> f32 {
    let [x1, y1, x2, y2] = EASE_IN_EASE_OUT_CONTROL_POINTS;
    cubic_bezier(f64::from(t.clamp(0., 1.)), x1, y1, x2, y2) as f32
}

/// A CSS / Core Animation timing curve through (0, 0), (x1, y1), (x2, y2),
/// (1, 1) at time fraction `t` (0..=1; x1 and x2 within 0..=1).
pub(crate) fn cubic_bezier(t: f64, x1: f64, y1: f64, x2: f64, y2: f64) -> f64 {
    if t <= 0. {
        return 0.;
    }
    if t >= 1. {
        return 1.;
    }
    // B(s) = 3(1-s)^2 s p1 + 3(1-s) s^2 p2 + s^3, as a polynomial in s.
    let coefficients = |p1: f64, p2: f64| {
        let c = 3. * p1;
        let b = 3. * (p2 - p1) - c;
        (1. - c - b, b, c)
    };
    let (ax, bx, cx) = coefficients(x1, x2);
    let (ay, by, cy) = coefficients(y1, y2);
    let x = |s: f64| ((ax * s + bx) * s + cx) * s;
    let dx = |s: f64| (3. * ax * s + 2. * bx) * s + cx;
    let y = |s: f64| ((ay * s + by) * s + cy) * s;
    const EPSILON: f64 = 1e-9;
    let mut s = t;
    for _ in 0..8 {
        let error = x(s) - t;
        if error.abs() < EPSILON {
            return y(s);
        }
        let slope = dx(s);
        if slope.abs() < 1e-12 {
            break;
        }
        s -= error / slope;
    }
    // x is monotonic in s on 0..=1: bisection always converges.
    let (mut lo, mut hi) = (0., 1.);
    s = t;
    for _ in 0..64 {
        let v = x(s);
        if (v - t).abs() < EPSILON {
            break;
        }
        if v < t {
            lo = s;
        } else {
            hi = s;
        }
        s = (lo + hi) / 2.;
    }
    y(s)
}

/// A timed opacity or color change with ease-out. Retargeting restarts the
/// curve from the value on screen (as AppKit does for timed animators), so
/// a fade never jumps and never queues.
#[derive(Clone, Copy, Debug, PartialEq)]
#[repr(C)]
pub struct Fade {
    pub token: MotionFade,
    from: f32,
    target: f32,
    value: f32,
    elapsed: f64,
    duration: f64,
}

impl Fade {
    pub fn new(value: f32, token: MotionFade) -> Self {
        Self { token, from: value, target: value, value, elapsed: 0., duration: 0. }
    }

    pub fn value(&self) -> f32 {
        self.value
    }

    pub fn target(&self) -> f32 {
        self.target
    }

    pub fn is_moving(&self) -> bool {
        self.value != self.target
    }

    /// Starts toward `target` from the current value with this token's
    /// duration under `policy` (0 applies at once).
    pub fn set_target(&mut self, target: f32, policy: &MotionPolicy) {
        self.set_target_with(target, self.token, policy);
    }

    /// As `set_target`, with another token (e.g. `fadeIn` vs `fadeOut`).
    pub fn set_target_with(&mut self, target: f32, token: MotionFade, policy: &MotionPolicy) {
        if target == self.target && self.is_moving() {
            return;
        }
        self.token = token;
        self.from = self.value;
        self.target = target;
        self.elapsed = 0.;
        self.duration = policy.fade(token);
        if self.duration <= 0. {
            self.value = target;
        }
    }

    pub fn snap_to(&mut self, target: f32) {
        self.from = target;
        self.target = target;
        self.value = target;
    }

    /// Advances `dt` seconds. True while still moving.
    pub fn step(&mut self, dt: f64) -> bool {
        if !self.is_moving() {
            return false;
        }
        self.elapsed += dt.clamp(0., MAX_FRAME);
        if self.duration <= 0. || self.elapsed >= self.duration {
            self.value = self.target;
            return false;
        }
        let t = self.token.curve().progress((self.elapsed / self.duration) as f32);
        self.value = self.from + (self.target - self.from) * t;
        true
    }
}
