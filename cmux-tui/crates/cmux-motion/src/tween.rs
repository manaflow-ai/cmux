//! Tweens: a value moving from where it is on screen to a target over a
//! fixed duration with a timing curve (Chrome's `views::BoundsAnimator`
//! model for the tab strip). A new target restarts the duration from the
//! current value, with no velocity carried over; setting the target it
//! already has does not restart it. Pure and synchronous like the springs.

use crate::fade::cubic_bezier;
use crate::spring::MAX_FRAME;
use crate::{
    EASE_IN_EASE_OUT_CONTROL_POINTS, EASE_OUT_CONTROL_POINTS, MotionPolicy, MotionTween,
    SpringParameters, SpringValue,
};

/// Chrome's `gfx::Tween::EASE_OUT` (ui/gfx/animation/tween.cc): 1-(1-t)^2,
/// the same curve as `cubic-bezier(1/3, 2/3, 2/3, 1)`. `t` is clamped to
/// 0..=1.
pub fn ease_out_quad(t: f32) -> f32 {
    let t = t.clamp(0., 1.);
    1. - (1. - t) * (1. - t)
}

/// A tween's timing curve.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum TweenCurve {
    /// `ease_out_quad` (Chrome `EASE_OUT`). Its id (0) never moves.
    EaseOutQuad = 0,
    /// Core Animation's `easeOut` (`EASE_OUT_CONTROL_POINTS`), every timed
    /// fade's curve.
    EaseOut = 1,
    /// Core Animation's `easeInEaseOut` (`EASE_IN_EASE_OUT_CONTROL_POINTS`).
    EaseInOut = 2,
    /// Even speed.
    Linear = 3,
}

impl TweenCurve {
    /// The progress at time fraction `t` (clamped to 0..=1).
    pub fn progress(self, t: f32) -> f32 {
        self.progress_f64(f64::from(t)) as f32
    }

    /// `progress` in f64 (the C ABI and f64 hosts).
    pub fn progress_f64(self, t: f64) -> f64 {
        let t = t.clamp(0., 1.);
        match self {
            Self::EaseOutQuad => 1. - (1. - t) * (1. - t),
            Self::EaseOut => {
                let [x1, y1, x2, y2] = EASE_OUT_CONTROL_POINTS;
                cubic_bezier(t, x1, y1, x2, y2)
            }
            Self::EaseInOut => {
                let [x1, y1, x2, y2] = EASE_IN_EASE_OUT_CONTROL_POINTS;
                cubic_bezier(t, x1, y1, x2, y2)
            }
            Self::Linear => t,
        }
    }
}

/// A CSS `cubic-bezier(x1, y1, x2, y2)` timing curve at time fraction `t`
/// (clamped to 0..=1); `x1` and `x2` are clamped to 0..=1, `y1` and `y2` may
/// leave it (overshoot). The color transition's custom curve.
pub fn cubic_bezier_progress(t: f64, x1: f64, y1: f64, x2: f64, y2: f64) -> f64 {
    cubic_bezier(t.clamp(0., 1.), x1.clamp(0., 1.), y1, x2.clamp(0., 1.), y2)
}

/// A spring from rest toward 1 at `time` seconds, with no overshoot: the
/// value is held at its running maximum (clamped to 0..=1), so it never
/// decreases. The color transition's spring curve: a color never passes its
/// target or dips back toward its source.
pub fn spring_progress_monotone(time: f64, spring: SpringParameters) -> f64 {
    let mut reached: f64 = 0.;
    let time = time.max(0.);
    // Sampled at 1/240 s up to `time`: the running maximum of the closed form.
    let step = 1. / 240.;
    let mut t = 0.;
    while t < time {
        t = (t + step).min(time);
        let (x, _) = SpringValue::solve(-1., 0., t, spring);
        reached = reached.max((1. + x).clamp(0., 1.));
    }
    reached
}

/// Seconds until a spring from rest first comes within 0.5% of its target
/// (where `spring_progress_monotone` holds a color); at most 5 s.
pub fn spring_arrival(spring: SpringParameters) -> f64 {
    let step = 1. / 240.;
    let mut t = 0.;
    while t < 5. {
        t += step;
        if 1. + SpringValue::solve(-1., 0., t, spring).0 >= 0.995 {
            return t;
        }
    }
    5.
}

/// A tween token's tuning: seconds and curve.
#[derive(Clone, Copy, Debug, PartialEq)]
#[repr(C)]
pub struct TweenParameters {
    pub duration: f64,
    pub curve: TweenCurve,
}

impl TweenParameters {
    pub const fn new(duration: f64, curve: TweenCurve) -> Self {
        Self { duration, curve }
    }

    /// The same tween with its duration multiplied by `scale`.
    pub fn scaled(&self, scale: f64) -> Self {
        Self::new(self.duration * scale, self.curve)
    }
}

/// One scalar on a tween, in f64 (the state the C ABI passes). `from` is
/// where the running tween started, `elapsed` its time so far.
#[derive(Clone, Copy, Debug, PartialEq)]
#[repr(C)]
pub struct TweenValue {
    pub value: f64,
    pub from: f64,
    pub target: f64,
    pub elapsed: f64,
    pub duration: f64,
}

impl TweenValue {
    pub fn new(value: f64) -> Self {
        Self { value, from: value, target: value, elapsed: 0., duration: 0. }
    }

    /// Sets `target`. The same target as now changes nothing and returns
    /// false (a running tween is not restarted). A new target restarts the
    /// whole `duration` from the current value, with no velocity carried;
    /// a duration that is not positive and finite applies it at once.
    pub fn retarget(&mut self, target: f64, duration: f64) -> bool {
        if target == self.target || target.is_nan() {
            return false;
        }
        self.from = self.value;
        self.target = target;
        self.elapsed = 0.;
        if duration.is_finite() && duration > 0. {
            self.duration = duration;
        } else {
            self.snap();
        }
        true
    }

    pub fn is_moving(&self) -> bool {
        self.value != self.target
    }

    /// Jumps to the target and stops.
    pub fn snap(&mut self) {
        self.value = self.target;
        self.from = self.target;
        self.elapsed = 0.;
        self.duration = 0.;
    }

    pub fn snap_to(&mut self, target: f64) {
        self.target = target;
        self.snap();
    }

    /// Advances `dt` seconds (capped at 0.1 s; NaN and negative refused) on
    /// `curve`. Ends exactly on the target. True while still moving.
    pub fn step(&mut self, dt: f64, curve: TweenCurve) -> bool {
        if !self.is_moving() {
            return false;
        }
        let dt = dt.clamp(0., MAX_FRAME);
        if dt.is_nan() {
            return true;
        }
        self.elapsed += dt;
        // 1e-9 s: twelve 1/60 s frames sum to just under 0.2 s and must end a 200 ms tween.
        if self.duration <= 0. || self.elapsed >= self.duration - 1e-9 {
            self.snap();
            return false;
        }
        let p = curve.progress_f64(self.elapsed / self.duration);
        self.value = self.from + (self.target - self.from) * p;
        true
    }
}

/// A scalar on a tween token (`MotionTween`), f32-facing like `Spring` and
/// `Fade`. The duration is resolved under the policy when the target is
/// set; Reduce Motion, speed off and a switched-off kind apply at once.
#[derive(Clone, Copy, Debug, PartialEq)]
#[repr(C)]
pub struct Tween {
    pub state: TweenValue,
    pub token: MotionTween,
}

impl Tween {
    pub fn new(value: f32, token: MotionTween) -> Self {
        Self { state: TweenValue::new(f64::from(value)), token }
    }

    pub fn value(&self) -> f32 {
        self.state.value as f32
    }

    pub fn target(&self) -> f32 {
        self.state.target as f32
    }

    pub fn is_moving(&self) -> bool {
        self.state.is_moving()
    }

    /// Starts toward `target` from the current value with this token's
    /// duration under `policy`. The same target does not restart.
    pub fn set_target(&mut self, target: f32, policy: &MotionPolicy) {
        self.set_target_with(target, self.token, policy);
    }

    /// As `set_target`, with another token (e.g. `TabClose` for a tab that
    /// was opening).
    pub fn set_target_with(&mut self, target: f32, token: MotionTween, policy: &MotionPolicy) {
        if self.state.retarget(f64::from(target), policy.tween(token)) {
            self.token = token;
        }
    }

    pub fn snap(&mut self) {
        self.state.snap();
    }

    pub fn snap_to(&mut self, target: f32) {
        self.state.snap_to(f64::from(target));
    }

    /// Advances `dt` seconds on the token's curve. True while still moving.
    pub fn step(&mut self, dt: f64) -> bool {
        self.state.step(dt, self.token.base().curve)
    }
}
