//! Springs: tuning (`SpringParameters`), the closed-form damped harmonic
//! oscillator (`SpringValue`) and the token-driven `Spring` with direct
//! manipulation. Pure and synchronous: the caller passes time, nothing here
//! reads a clock or a global. Every type is a plain `Copy` value with a C
//! layout (`repr(C)` structs, `repr(u8)` enums) so a C ABI can wrap it.

use std::f64::consts::PI;

use crate::tokens::{SETTLE_GEOMETRY, SETTLE_UNIT, SETTLE_VELOCITY_FACTOR};
use crate::{MotionPolicy, MotionSpring};

/// Sampling step of the duration probes (`visible_end`) (s).
const SUBSTEP: f64 = 1. / 480.;
/// A stalled frame never moves a spring or a fade more than this much time (s).
pub(crate) const MAX_FRAME: f64 = 0.1;

// ---------------------------------------------------------------------------
// Springs

/// Spring tuning in SwiftUI terms (`.spring(response:dampingFraction:)`),
/// mass 1.
#[derive(Clone, Copy, Debug, PartialEq)]
#[repr(C)]
pub struct SpringParameters {
    /// Seconds for one undamped oscillation; smaller is stiffer.
    pub response: f64,
    /// 1 is critically damped; below 1 overshoots.
    pub damping_fraction: f64,
}

impl SpringParameters {
    pub const fn new(response: f64, damping_fraction: f64) -> Self {
        Self { response, damping_fraction }
    }

    /// Angular frequency (rad/s).
    pub fn omega(&self) -> f64 {
        2. * PI / self.response.max(0.001)
    }

    /// `CASpringAnimation.stiffness` for mass 1.
    pub fn stiffness(&self) -> f64 {
        self.omega() * self.omega()
    }

    /// `CASpringAnimation.damping` for mass 1.
    pub fn damping(&self) -> f64 {
        2. * self.damping_fraction * self.omega()
    }

    /// This tuning with a non-finite or non-positive response, or a
    /// non-finite or non-positive damping fraction, replaced by
    /// `fallback`'s. A damping of 0 or less (or NaN) is an undamped spring
    /// that never settles, so the clock would never idle.
    pub fn finite_or(self, fallback: SpringParameters) -> Self {
        let response = if self.response.is_finite() && self.response > 0. {
            self.response
        } else {
            fallback.response
        };
        let damping_fraction = if self.damping_fraction.is_finite() && self.damping_fraction > 0. {
            self.damping_fraction
        } else {
            fallback.damping_fraction
        };
        Self::new(response, damping_fraction)
    }

    /// The same spring with every time constant multiplied by `scale`.
    pub fn scaled(&self, scale: f64) -> Self {
        Self::new(self.response * scale, self.damping_fraction)
    }

    /// SwiftUI `Spring(duration:bounce:)`: `duration` is the perceptual
    /// duration (the response); `bounce` 0 is critically damped, above 0
    /// overshoots (0.15 is a subtle bounce), below 0 is over-damped.
    pub fn from_duration_bounce(duration: f64, bounce: f64) -> Self {
        let damping_fraction = if bounce >= 0. { 1. - bounce } else { 1. / (1. + bounce) };
        Self::new(duration, damping_fraction)
    }

    /// SwiftUI's bounce for this damping fraction (0 critically damped).
    pub fn bounce(&self) -> f64 {
        if self.damping_fraction <= 1. {
            1. - self.damping_fraction
        } else {
            1. / self.damping_fraction - 1.
        }
    }

    /// The same response with `bounce` (SwiftUI semantics).
    pub fn with_bounce(&self, bounce: f64) -> Self {
        Self::from_duration_bounce(self.response, bounce)
    }

    /// Closed-form position of a unit step (0 -> 1, from rest) after `t`
    /// seconds. Used as an easing curve for GPUI's timed `Animation`.
    pub fn step_response(&self, t: f64) -> f64 {
        if t <= 0. {
            return 0.;
        }
        let w = self.omega();
        let z = self.damping_fraction.max(0.);
        if z < 1. {
            let wd = w * (1. - z * z).sqrt();
            1. - (-z * w * t).exp() * ((wd * t).cos() + z * w / wd * (wd * t).sin())
        } else if z == 1. {
            1. - (-w * t).exp() * (1. + w * t)
        } else {
            let s = w * (z * z - 1.).sqrt();
            let r1 = -z * w + s;
            let r2 = -z * w - s;
            1. - (r2 * (r1 * t).exp() - r1 * (r2 * t).exp()) / (r2 - r1)
        }
    }

    /// Seconds until a unit step stays within 0.5% of its target: the last
    /// visible pixel of a 200 pt move, what a viewer reads as the length.
    /// Simulated with the app's own stepper (cmux-next `perceivedDuration`).
    /// Timed APIs use it as the token's ease-out equivalent.
    pub fn visible_end(&self) -> f64 {
        let mut s = SpringValue::new(0.);
        s.target = 1.;
        let mut elapsed = 0.;
        let mut last_outside = 0.;
        while elapsed < 3. {
            s.step(SUBSTEP, *self);
            elapsed += SUBSTEP;
            if (1. - s.value).abs() > 0.005 {
                last_outside = elapsed;
            }
            if elapsed > last_outside + 0.25 {
                break;
            }
        }
        last_outside
    }

    /// The visible end as a display at `hz` shows it: the first frame from
    /// which a step stays within 0.5% of its target (the spec's table).
    pub fn visible_end_at(&self, hz: f64) -> f64 {
        let mut s = SpringValue::new(0.);
        s.target = 1.;
        let dt = 1. / hz;
        let (mut frame, mut last_outside) = (0u32, 0u32);
        while (frame as f64) * dt < 3. {
            s.step(dt, *self);
            frame += 1;
            if (1. - s.value).abs() > 0.005 {
                last_outside = frame;
            }
            if (frame - last_outside) as f64 * dt > 0.25 {
                break;
            }
        }
        (last_outside + 1) as f64 * dt
    }

    /// Seconds until a `travel` pt move stops at `hz` frames per second
    /// (within 0.25 pt and 2 pt/s, the display-link stop rule).
    pub fn rest_time(&self, travel: f32, hz: f64) -> f64 {
        let mut s = SpringValue::new(0.);
        s.target = travel;
        let dt = 1. / hz;
        let mut elapsed = 0.;
        while elapsed < 5. {
            elapsed += dt;
            if !s.advance(dt, *self, GEOMETRY_EPSILON) {
                break;
            }
        }
        elapsed
    }
}

/// Settle distance for geometry (pt): 0.25 pt is invisible after pixel
/// snapping at 2x. Velocity must also be under 8x this (2 pt/s).
/// (design-tokens.json `motion.settle`.)
pub const GEOMETRY_EPSILON: f32 = SETTLE_GEOMETRY;
/// Settle distance for opacity and other 0..1 values.
pub const UNIT_EPSILON: f32 = SETTLE_UNIT;

/// One scalar driven by a damped spring toward `target`. Retargeting keeps
/// `value` and `velocity` (units per second), so an interrupted animation
/// continues from where it is on screen with its momentum.
#[derive(Clone, Copy, Debug, PartialEq)]
#[repr(C)]
pub struct SpringValue {
    pub value: f32,
    pub velocity: f32,
    pub target: f32,
}

impl SpringValue {
    pub fn new(value: f32) -> Self {
        Self { value, velocity: 0., target: value }
    }

    /// Advances `dt` seconds with the closed-form solution of the damped
    /// harmonic oscillator (under-, critically or over-damped) from the
    /// current displacement and velocity, so the path is exact and the same
    /// at every frame rate: two 60 Hz frames land where four 120 Hz frames
    /// do. `dt` is capped at 0.1 s so a stalled frame never teleports.
    pub fn step(&mut self, dt: f64, p: SpringParameters) {
        let t = dt.clamp(0., MAX_FRAME);
        // A NaN dt stays NaN through clamp: refuse it too.
        if t.is_nan() || t <= 0. {
            return;
        }
        let target = f64::from(self.target);
        let (x, v) = Self::solve(f64::from(self.value) - target, f64::from(self.velocity), t, p);
        self.value = (target + x) as f32;
        self.velocity = v as f32;
    }

    /// Displacement from the target and velocity `time` seconds after a
    /// state with displacement `x0` and velocity `v0`, for `p` (mass 1).
    /// The one spring solution every port uses (macOS calls it through
    /// cmux-app-ffi).
    pub fn solve(x0: f64, v0: f64, time: f64, p: SpringParameters) -> (f64, f64) {
        let p = p.finite_or(MotionSpring::Move.base());
        let w0 = p.omega();
        let zeta = p.damping_fraction.max(0.);
        let t = time;
        if (zeta - 1.).abs() < 1e-4 {
            let decay = (-w0 * t).exp();
            let b = v0 + w0 * x0;
            return ((x0 + b * t) * decay, (v0 - w0 * b * t) * decay);
        }
        if zeta < 1. {
            let wd = w0 * (1. - zeta * zeta).sqrt();
            let decay = (-zeta * w0 * t).exp();
            let (s, c) = (wd * t).sin_cos();
            let b = (v0 + zeta * w0 * x0) / wd;
            return (
                decay * (x0 * c + b * s),
                decay * (v0 * c - (w0 * w0 * x0 + zeta * w0 * v0) / wd * s),
            );
        }
        let root = (zeta * zeta - 1.).sqrt();
        let (r1, r2) = (-w0 * (zeta - root), -w0 * (zeta + root));
        let c2 = (v0 - r1 * x0) / (r2 - r1);
        let c1 = x0 - c2;
        let (e1, e2) = ((r1 * t).exp(), (r2 * t).exp());
        (c1 * e1 + c2 * e2, c1 * r1 * e1 + c2 * r2 * e2)
    }

    pub fn is_settled(&self, epsilon: f32) -> bool {
        (self.value - self.target).abs() < epsilon
            && self.velocity.abs() < epsilon * SETTLE_VELOCITY_FACTOR
    }

    pub fn is_moving(&self) -> bool {
        self.value != self.target || self.velocity != 0.
    }

    /// Jumps to the target and stops.
    pub fn snap(&mut self) {
        self.value = self.target;
        self.velocity = 0.;
    }

    pub fn snap_to(&mut self, target: f32) {
        self.target = target;
        self.snap();
    }

    /// Steps and snaps once settled. True while still moving.
    pub fn advance(&mut self, dt: f64, p: SpringParameters, epsilon: f32) -> bool {
        if !self.is_moving() {
            return false;
        }
        self.step(dt, p);
        if self.is_settled(epsilon) {
            self.snap();
            return false;
        }
        true
    }
}

/// `SpringValue::advance` on f64 state, for hosts whose geometry is f64
/// (macOS `CGFloat`, through cmux-app-ffi): steps `dt` seconds in closed
/// form and snaps to `target` once within `epsilon` and moving slower than
/// `epsilon` times the settle velocity factor. True while still moving.
pub fn advance_spring(
    value: &mut f64,
    velocity: &mut f64,
    target: f64,
    dt: f64,
    p: SpringParameters,
    epsilon: f64,
) -> bool {
    if *value == target && *velocity == 0. {
        return false;
    }
    let t = dt.clamp(0., MAX_FRAME);
    if t > 0. {
        let (x, v) = SpringValue::solve(*value - target, *velocity, t, p);
        (*value, *velocity) = (target + x, v);
    }
    if (*value - target).abs() < epsilon
        && velocity.abs() < epsilon * f64::from(SETTLE_VELOCITY_FACTOR)
    {
        (*value, *velocity) = (target, 0.);
        return false;
    }
    true
}

/// What a `Spring` animates. It decides whether a move toward 0 is a
/// collapse (faster `disappear`) or an ordinary move.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Default)]
#[repr(u8)]
pub enum SpringKind {
    /// A width, height, scale or opacity: 0 means gone, so a move to 0
    /// (tab close, collapse, fade out) uses `disappear`. The default, and
    /// the behavior of every spring before this kind existed.
    #[default]
    Size,
    /// A position or offset (pane edge, x, gap, scroll offset): 0 and
    /// negative values are ordinary places, so every move uses the
    /// spring's own token and never switches to `disappear` (motion.md:
    /// neighbors of a closing tab `move`, scroll reveal `scroll`).
    Position,
}

/// A spring tuned by a token, with direct-manipulation support (cmux-next
/// tab `Spring`): `follow` tracks the pointer exactly and estimates its
/// velocity; `release` hands that velocity to the `settle` spring. For a
/// `SpringKind::Size` spring (the default) a move to 0 (close, collapse)
/// uses `disappear`; a `SpringKind::Position` spring (`Spring::position`)
/// always uses its token.
#[derive(Clone, Copy, Debug, PartialEq)]
#[repr(C)]
pub struct Spring {
    pub state: SpringValue,
    pub token: MotionSpring,
    pub epsilon: f32,
    /// Size (a move to 0 is a disappear) or position (never).
    pub kind: SpringKind,
    /// Last pointer sample for `follow` (plain fields so the type stays
    /// C-compatible).
    has_sample: bool,
    sample_value: f32,
    sample_time: f64,
}

impl Spring {
    pub fn new(value: f32, token: MotionSpring) -> Self {
        Self {
            state: SpringValue::new(value),
            token,
            epsilon: GEOMETRY_EPSILON,
            kind: SpringKind::Size,
            has_sample: false,
            sample_value: 0.,
            sample_time: 0.,
        }
    }

    /// A position or offset (pane edge, x, gap, scroll offset): geometry
    /// settle distance, and a move to 0 or below keeps `token`.
    pub fn position(value: f32, token: MotionSpring) -> Self {
        Self::new(value, token).with_kind(SpringKind::Position)
    }

    /// A 0..1 value (opacity, progress) with a finer settle distance. It is
    /// a `Size`: a move to 0 uses `disappear`.
    pub fn unit(value: f32, token: MotionSpring) -> Self {
        Self { epsilon: UNIT_EPSILON, ..Self::new(value, token) }
    }

    /// The same spring with another kind.
    pub fn with_kind(self, kind: SpringKind) -> Self {
        Self { kind, ..self }
    }

    pub fn value(&self) -> f32 {
        self.state.value
    }

    pub fn velocity(&self) -> f32 {
        self.state.velocity
    }

    pub fn target(&self) -> f32 {
        self.state.target
    }

    /// Retargets from the current value and velocity (no jump, no queue).
    pub fn set_target(&mut self, target: f32) {
        self.has_sample = false;
        self.state.target = target;
    }

    /// The token this step uses: `disappear` while a `Size` spring
    /// collapses toward 0, else `token`.
    pub fn active_token(&self) -> MotionSpring {
        if self.kind == SpringKind::Size
            && self.state.target <= 0.001
            && self.state.value > self.state.target
        {
            MotionSpring::Disappear
        } else {
            self.token
        }
    }

    pub fn is_moving(&self) -> bool {
        self.state.is_moving()
    }

    pub fn snap(&mut self) {
        self.state.snap();
        self.has_sample = false;
        self.end_release();
    }

    pub fn snap_to(&mut self, target: f32) {
        self.state.target = target;
        self.snap();
    }

    /// Direct manipulation: the value is exactly `value` (no lag) and the
    /// velocity is estimated from samples so a release carries it. `time` is
    /// seconds on any monotonic clock.
    pub fn follow(&mut self, value: f32, time: f64) {
        if self.has_sample && time > self.sample_time {
            let instant = (value - self.sample_value) / (time - self.sample_time) as f32;
            // Light smoothing: pointer events jitter at high rates.
            self.state.velocity = self.state.velocity * 0.4 + instant * 0.6;
        }
        (self.has_sample, self.sample_value, self.sample_time) = (true, value, time);
        self.state.value = value;
        self.state.target = value;
    }

    /// Ends direct manipulation at `time`: the next steps use `settle` from
    /// the pointer's velocity, or from rest if the pointer had stopped (no
    /// sample in the last 50 ms). Set the landing target after this.
    pub fn release(&mut self, time: f64) {
        if self.has_sample && time - self.sample_time > 0.05 {
            self.state.velocity = 0.;
        }
        self.has_sample = false;
        self.token = MotionSpring::Settle;
    }

    /// Advances `dt` seconds under `policy`. True while still moving. When
    /// the policy does not animate movement, snaps at once.
    pub fn step(&mut self, dt: f64, policy: &MotionPolicy) -> bool {
        self.has_sample = false;
        if !policy.animates_movement() {
            if self.is_moving() {
                self.snap();
            }
            return false;
        }
        let p = policy.spring(self.active_token());
        if self.state.advance(dt, p, self.epsilon) {
            return true;
        }
        self.end_release();
        false
    }

    /// A release spring is for that release only; later changes use `move`.
    fn end_release(&mut self) {
        if self.token == MotionSpring::Settle {
            self.token = MotionSpring::Move;
        }
    }
}
