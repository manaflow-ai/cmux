//! Tokens, the spring integrator, timed fades and the speed / Reduce Motion
//! policy. Pure and synchronous: the caller passes time, nothing here reads
//! a clock or a global. Every type is a plain `Copy` value with a C layout
//! (`repr(C)` structs, `repr(u8)` enums) so a C ABI can wrap it later.

use std::f64::consts::PI;

/// Fixed substep of the spring integrator (s). Same as cmux-next.
const SUBSTEP: f64 = 1. / 480.;
/// A stalled frame never moves a spring more than this much time (s).
const MAX_FRAME: f64 = 0.1;

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

    /// The same spring with every time constant multiplied by `scale`.
    pub fn scaled(&self, scale: f64) -> Self {
        Self::new(self.response * scale, self.damping_fraction)
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
pub const GEOMETRY_EPSILON: f32 = 0.25;
/// Settle distance for opacity and other 0..1 values.
pub const UNIT_EPSILON: f32 = 0.001;

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

    /// Advances `dt` seconds with fixed 1/480 s substeps (semi-implicit
    /// Euler): stable at any frame rate. `dt` is capped at 0.1 s so a
    /// stalled frame never teleports.
    pub fn step(&mut self, dt: f64, p: SpringParameters) {
        let (k, c) = (p.stiffness(), p.damping());
        let mut remaining = dt.clamp(0., MAX_FRAME);
        let (mut x, mut v, t) = (self.value as f64, self.velocity as f64, self.target as f64);
        while remaining > 0. {
            let h = remaining.min(SUBSTEP);
            v += (-k * (x - t) - c * v) * h;
            x += v * h;
            remaining -= h;
        }
        self.value = x as f32;
        self.velocity = v as f32;
    }

    pub fn is_settled(&self, epsilon: f32) -> bool {
        (self.value - self.target).abs() < epsilon && self.velocity.abs() < epsilon * 8.
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

/// A CSS / Core Animation timing curve through (0, 0), (x1, y1), (x2, y2),
/// (1, 1) at time fraction `t` (0..=1; x1 and x2 within 0..=1).
fn cubic_bezier(t: f64, x1: f64, y1: f64, x2: f64, y2: f64) -> f64 {
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
        let t = ease_out((self.elapsed / self.duration) as f32);
        self.value = self.from + (self.target - self.from) * t;
        true
    }
}

// ---------------------------------------------------------------------------
// Tokens

/// `ui.animationSpeed`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
#[repr(u8)]
pub enum MotionSpeed {
    /// Default: short springs tuned for a pro tool.
    #[default]
    Fast,
    /// About Apple's system pacing: every time constant x1.5.
    Normal,
    /// No animation: every change applies in one frame, no crossfade.
    Off,
}

impl MotionSpeed {
    /// Multiplier on every spring response and fade duration.
    pub fn time_scale(self) -> f64 {
        match self {
            Self::Fast => 1.,
            Self::Normal => 1.5,
            Self::Off => 0.,
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s.trim().to_ascii_lowercase().as_str() {
            "fast" => Some(Self::Fast),
            "normal" => Some(Self::Normal),
            "off" | "none" | "0" => Some(Self::Off),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Fast => "fast",
            Self::Normal => "normal",
            Self::Off => "off",
        }
    }
}

/// Spring tokens (values at speed `fast`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum MotionSpring {
    /// An existing item moves or resizes: tab reflow and reorder, sidebar
    /// rows, pane and divider frames, pane zoom, sidebar drag gap.
    Move,
    /// Something appears or expands: tab grow-in, group expand, row insert,
    /// palette scale-in.
    Appear,
    /// Something disappears or collapses. Faster than `Appear`.
    Disappear,
    /// Release after direct manipulation; carries pointer velocity and
    /// overshoots slightly (0.8 pt on 200 pt).
    Settle,
    /// Programmatic scroll: tab strip reveal, column reveal, wheel, fling.
    Scroll,
    /// Screen switch slide.
    Screen,
    /// An overlay tracking the pointer between targets: drop zones, ghost.
    Track,
    /// Selection indicator glide (sidebar pill).
    Selection,
    /// Floating panel slide (hover card).
    Panel,
}

impl MotionSpring {
    pub const ALL: [Self; 9] = [
        Self::Move,
        Self::Appear,
        Self::Disappear,
        Self::Settle,
        Self::Scroll,
        Self::Screen,
        Self::Track,
        Self::Selection,
        Self::Panel,
    ];

    pub const fn base(self) -> SpringParameters {
        match self {
            Self::Move => SpringParameters::new(0.20, 0.90),
            Self::Appear => SpringParameters::new(0.18, 0.90),
            Self::Disappear => SpringParameters::new(0.15, 0.90),
            Self::Settle => SpringParameters::new(0.22, 0.85),
            Self::Scroll => SpringParameters::new(0.22, 0.90),
            Self::Screen => SpringParameters::new(0.22, 0.90),
            Self::Track => SpringParameters::new(0.12, 0.90),
            Self::Selection => SpringParameters::new(0.15, 0.90),
            Self::Panel => SpringParameters::new(0.18, 0.85),
        }
    }
}

/// Timed opacity and color changes (ease-out), seconds at speed `fast`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum MotionFade {
    /// Hover fills and hover-revealed buttons.
    Hover,
    /// Focus ring and inactive-pane dim.
    Focus,
    /// A view or panel fades in.
    FadeIn,
    /// A view or panel fades out. Faster than `FadeIn`.
    FadeOut,
    /// Content swap in place; also the Reduce Motion ceiling.
    Crossfade,
    /// Drag lift shadow.
    Lift,
    /// Theme switch recoloring in place.
    Theme,
}

impl MotionFade {
    pub const ALL: [Self; 7] = [
        Self::Hover,
        Self::Focus,
        Self::FadeIn,
        Self::FadeOut,
        Self::Crossfade,
        Self::Lift,
        Self::Theme,
    ];

    pub const fn base(self) -> f64 {
        match self {
            Self::Hover => 0.08,
            Self::Focus => 0.10,
            Self::FadeIn => 0.12,
            Self::FadeOut => 0.08,
            Self::Crossfade => 0.10,
            Self::Lift => 0.12,
            Self::Theme => 0.16,
        }
    }
}

/// Repeating indicators. Speed does not scale them; `off` and Reduce Motion
/// stop them.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum MotionLoop {
    Spinner,
    Pulse,
    Flash,
}

impl MotionLoop {
    pub const fn period(self) -> f64 {
        match self {
            Self::Spinner => 0.9,
            Self::Pulse => 1.8,
            Self::Flash => 0.6,
        }
    }
}

/// Resolves tokens for one speed setting and Reduce Motion state.
///
/// - `off`: nothing animates. Wins over Reduce Motion.
/// - Reduce Motion: movement (position, size, scale, scroll) is instant;
///   fades stay, capped at one crossfade (0.1 s); loops stop.
/// - `normal`: every time constant is 1.5x `fast`; damping is unchanged.
#[derive(Clone, Copy, Debug, PartialEq)]
#[repr(C)]
pub struct MotionPolicy {
    pub speed: MotionSpeed,
    pub reduce_motion: bool,
    /// Extra time multiplier for screen recordings (`CMUX2_ANIM_SCALE`); 1
    /// normally. Not part of the cmux-next contract.
    pub debug_scale: f64,
}

impl Default for MotionPolicy {
    fn default() -> Self {
        Self::new(MotionSpeed::Fast, false)
    }
}

impl MotionPolicy {
    pub fn new(speed: MotionSpeed, reduce_motion: bool) -> Self {
        Self { speed, reduce_motion, debug_scale: 1. }
    }

    fn scale(&self) -> f64 {
        self.speed.time_scale() * self.debug_scale.max(1.)
    }

    /// Position, size, scale and scroll animate. When false, snap.
    pub fn animates_movement(&self) -> bool {
        self.speed != MotionSpeed::Off && !self.reduce_motion
    }

    /// Opacity and color changes animate. When false, apply at once.
    pub fn animates_fades(&self) -> bool {
        self.speed != MotionSpeed::Off
    }

    /// Spinners and pulses run.
    pub fn animates_loops(&self) -> bool {
        self.speed != MotionSpeed::Off && !self.reduce_motion
    }

    /// The spring for `token`. `off` returns the `fast` spring so a caller
    /// that steps anyway never divides by zero; callers snap when
    /// `animates_movement` is false (`Spring::step` does).
    pub fn spring(&self, token: MotionSpring) -> SpringParameters {
        if self.speed == MotionSpeed::Off {
            token.base()
        } else {
            token.base().scaled(self.scale())
        }
    }

    /// Seconds for a fade; 0 applies at once. Reduce Motion caps it at one
    /// crossfade.
    pub fn fade(&self, token: MotionFade) -> f64 {
        if !self.animates_fades() {
            return 0.;
        }
        let scaled = token.base() * self.scale();
        if self.reduce_motion { scaled.min(MotionFade::Crossfade.base()) } else { scaled }
    }

    /// Seconds that stand in for a spring when only a timed API exists:
    /// the spring's visible end. 0 when movement does not animate.
    pub fn spring_duration(&self, token: MotionSpring) -> f64 {
        if self.animates_movement() { self.spring(token).visible_end() } else { 0. }
    }

    /// Period of a loop, or `None` when loops are stopped.
    pub fn period(&self, token: MotionLoop) -> Option<f64> {
        self.animates_loops().then(|| token.period())
    }
}

#[cfg(test)]
#[path = "spring_tests.rs"]
mod tests;
