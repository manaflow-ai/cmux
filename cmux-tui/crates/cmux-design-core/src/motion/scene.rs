//! App scene motion (Motion+AppScene.swift, Motion+ContentTransition.swift, Motion+Settle.swift):
//! named and custom scene motions, loops, the transform space, and the Core Animation each one
//! becomes, as a plain descriptor the app turns into `CAAnimation`s.

use super::policy::MotionPolicy;
use super::spring::{Spring, perceived_duration, settling_time};
use super::tokens::{MotionFade, MotionLoop, MotionSpring, scale};
use cmux_motion::SpringParameters;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

/// `SceneMotion.SceneCurve`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SceneCurve {
    EaseOut,
    EaseInOut,
    Linear,
}

impl SceneCurve {
    pub fn parse(raw: &str) -> Option<Self> {
        match raw {
            "easeOut" => Some(Self::EaseOut),
            "easeInOut" => Some(Self::EaseInOut),
            "linear" => Some(Self::Linear),
            _ => None,
        }
    }
}

/// `SceneMotion`.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum SceneMotion {
    Spring { spring: Spring },
    Timed { seconds: f64, curve: SceneCurve },
}

fn spring(p: SpringParameters) -> SceneMotion {
    SceneMotion::Spring { spring: p.into() }
}

pub const SMOOTH: SceneMotion =
    SceneMotion::Timed { seconds: scale::STANDARD, curve: SceneCurve::EaseOut };
pub const SNAPPY: SceneMotion =
    SceneMotion::Timed { seconds: scale::MICRO, curve: SceneCurve::EaseOut };
pub const BOUNCY: SceneMotion =
    SceneMotion::Spring { spring: Spring { response: 0.45, damping_fraction: 0.6 } };

/// `clampedTime`.
fn clamped_time(seconds: f64) -> f64 {
    seconds.clamp(0.05, 10.)
}

impl SceneMotion {
    /// `named(_:)`.
    pub fn named(name: &str) -> Option<Self> {
        Some(match name {
            "smooth" => SMOOTH,
            "move" => spring(MotionSpring::Move.base()),
            "appear" => spring(MotionSpring::Appear.base()),
            "disappear" => spring(MotionSpring::Disappear.base()),
            "fade" => Self::Timed {
                seconds: MotionFade::FadeIn.base_duration(),
                curve: SceneCurve::EaseOut,
            },
            "snappy" => SNAPPY,
            "bouncy" => BOUNCY,
            _ => return None,
        })
    }

    /// `custom(response:dampingFraction:)`.
    pub fn custom(response: f64, damping_fraction: f64) -> Option<Self> {
        if !(response.is_finite() && damping_fraction.is_finite()) {
            return None;
        }
        Some(spring(SpringParameters::new(clamped_time(response), damping_fraction.clamp(0.3, 1.))))
    }

    /// `timed(seconds:curve:)`: no curve is `easeOut`, an unknown one is nil.
    pub fn timed(seconds: f64, curve: Option<&str>) -> Option<Self> {
        if !seconds.is_finite() {
            return None;
        }
        let curve = match curve {
            None => SceneCurve::EaseOut,
            Some(raw) => SceneCurve::parse(raw)?,
        };
        Some(Self::Timed { seconds: clamped_time(seconds), curve })
    }

    /// `visibleDuration(scale:)`.
    pub fn visible_duration(&self, scale: f64) -> f64 {
        match *self {
            Self::Spring { spring } => {
                perceived_duration(SpringParameters::from(spring).scaled(scale))
            }
            Self::Timed { seconds, .. } => seconds * scale,
        }
    }
}

/// `SceneLoop.Effect`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Effect {
    Pulse,
    Breathe,
    Spin,
    Float,
    Wiggle,
    Bounce,
    Shimmer,
}

impl Effect {
    pub const ALL: [Self; 7] = [
        Self::Pulse,
        Self::Breathe,
        Self::Spin,
        Self::Float,
        Self::Wiggle,
        Self::Bounce,
        Self::Shimmer,
    ];

    pub fn parse(raw: &str) -> Option<Self> {
        Some(match raw {
            "pulse" => Self::Pulse,
            "breathe" => Self::Breathe,
            "spin" => Self::Spin,
            "float" => Self::Float,
            "wiggle" => Self::Wiggle,
            "bounce" => Self::Bounce,
            "shimmer" => Self::Shimmer,
            _ => return None,
        })
    }

    pub fn default_period(self) -> f64 {
        match self {
            Self::Pulse => 1.2,
            Self::Breathe => 3.,
            Self::Spin => 2.,
            Self::Float => 3.,
            Self::Wiggle => 0.6,
            Self::Bounce => 0.9,
            Self::Shimmer => 1.6,
        }
    }

    pub fn minimum_period(self) -> f64 {
        match self {
            Self::Pulse | Self::Breathe | Self::Shimmer => MotionLoop::SHORTEST_FLASH_CYCLE,
            Self::Spin | Self::Float | Self::Wiggle | Self::Bounce => 0.1,
        }
    }
}

/// `SceneLoop`.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SceneLoop {
    pub effect: Effect,
    pub period: f64,
    pub amount: f64,
}

impl SceneLoop {
    /// `init?(effect:period:amount:)`.
    pub fn new(effect: &str, period: Option<f64>, amount: Option<f64>) -> Option<Self> {
        let effect = Effect::parse(effect)?;
        let seconds = period.filter(|p| p.is_finite()).unwrap_or(effect.default_period());
        let amount = amount.filter(|a| a.is_finite()).unwrap_or(1.);
        Some(Self {
            effect,
            period: seconds.clamp(effect.minimum_period(), 60.),
            amount: amount.clamp(-10., 10.),
        })
    }
}

/// `SceneTransition`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SceneTransition {
    Opacity,
    Slide,
    Scale,
    Move,
    Pop,
}

/// A `CATransform3D`, fields in its order (`m11, m12, ... m44`).
pub type Transform = [f64; 16];

pub const IDENTITY: Transform = [1., 0., 0., 0., 0., 1., 0., 0., 0., 0., 1., 0., 0., 0., 0., 1.];

/// `CATransform3DConcat(a, b)`: `a` then `b`.
pub fn concat(a: &Transform, b: &Transform) -> Transform {
    let mut out = [0.; 16];
    for i in 0..4 {
        for j in 0..4 {
            out[i * 4 + j] = (0..4).map(|k| a[i * 4 + k] * b[k * 4 + j]).sum();
        }
    }
    out
}

pub fn translation(x: f64, y: f64, z: f64) -> Transform {
    let mut t = IDENTITY;
    t[12] = x;
    t[13] = y;
    t[14] = z;
    t
}

/// `CATransform3DMakeRotation(angle, 0, 0, 1)`.
pub fn rotation_z(angle: f64) -> Transform {
    let (s, c) = angle.sin_cos();
    let mut t = IDENTITY;
    t[0] = c;
    t[1] = s;
    t[4] = -s;
    t[5] = c;
    t
}

pub fn scaling(x: f64, y: f64, z: f64) -> Transform {
    let mut t = IDENTITY;
    t[0] = x;
    t[5] = y;
    t[10] = z;
    t
}

/// `SceneTransformSpace`: a layer's center as a pivot, and whether +y is down.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SceneTransformSpace {
    pub pivot: [f64; 2],
    pub y_down: bool,
}

impl Default for SceneTransformSpace {
    fn default() -> Self {
        Self { pivot: [0., 0.], y_down: true }
    }
}

impl SceneTransformSpace {
    /// `init(layer:)`'s pivot: the bounds center measured from the anchor point.
    pub fn for_layer(size: [f64; 2], anchor: [f64; 2], y_down: bool) -> Self {
        Self { pivot: [size[0] * (0.5 - anchor[0]), size[1] * (0.5 - anchor[1])], y_down }
    }

    /// `transform(scale:degrees:offset:)`: about the pivot, offset in web terms (+y down).
    pub fn transform(&self, scale: f64, degrees: f64, offset: [f64; 2]) -> Transform {
        let sign = if self.y_down { 1. } else { -1. };
        let [px, py] = self.pivot;
        let mut t = translation(px + offset[0], py + offset[1] * sign, 0.);
        if degrees != 0. {
            t = concat(&rotation_z(degrees * std::f64::consts::PI / 180. * sign), &t);
        }
        if scale != 1. {
            t = concat(&scaling(scale, scale, 1.), &t);
        }
        concat(&translation(-px, -py, 0.), &t)
    }
}

/// A `CAMediaTimingFunction`.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Timing {
    EaseOut,
    EaseIn,
    EaseInEaseOut,
    Linear,
    ControlPoints([f64; 4]),
}

/// `Motion.fadeCurve`.
pub const FADE_CURVE: Timing = Timing::EaseOut;

/// One Core Animation, described.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Animation {
    /// `basic`, `spring`, `keyframe`, `group` or `transition`.
    pub kind: String,
    pub key_path: Option<String>,
    pub duration: f64,
    pub from: Option<Value>,
    pub to: Option<Value>,
    pub values: Vec<Value>,
    pub timing: Option<Timing>,
    pub timings: Vec<Timing>,
    pub additive: bool,
    pub autoreverses: bool,
    pub repeat_forever: bool,
    /// False keeps the end state (`isRemovedOnCompletion = false`).
    pub removed_on_completion: bool,
    /// `backwards` or `forwards`.
    pub fill: Option<String>,
    /// A spring's `mass`, `stiffness`, `damping`.
    pub mass: Option<f64>,
    pub stiffness: Option<f64>,
    pub damping: Option<f64>,
    /// A keyframe animation's `calculationMode` (`linear`).
    pub calculation_mode: Option<String>,
    /// A transition's type (`fade`, `push`) and subtype (`fromBottom`, `fromTop`).
    pub transition: Option<String>,
    pub subtype: Option<String>,
    pub animations: Vec<Animation>,
}

impl Animation {
    fn new(kind: &str, key_path: Option<&str>) -> Self {
        Self {
            kind: kind.into(),
            key_path: key_path.map(Into::into),
            removed_on_completion: true,
            ..Self::default()
        }
    }
}

fn transform_value(t: Transform) -> Value {
    json!(t)
}

/// `sceneAnimation(_:_:from:to:additive:in:)`.
pub fn scene_animation(
    policy: &MotionPolicy,
    motion: SceneMotion,
    key_path: &str,
    from: Value,
    to: Value,
    additive: bool,
) -> Option<Animation> {
    if !policy.animates_movement() {
        return None;
    }
    let ts = policy.speed.time_scale();
    let mut animation = match motion {
        SceneMotion::Spring { spring } => {
            let spring = SpringParameters::from(spring).scaled(ts);
            let mut a = Animation::new("spring", Some(key_path));
            a.mass = Some(1.);
            a.stiffness = Some(spring.stiffness());
            a.damping = Some(spring.damping());
            a.duration = settling_time(spring, 0.002);
            a
        }
        SceneMotion::Timed { seconds, curve } => {
            let mut a = Animation::new("basic", Some(key_path));
            a.duration = seconds * ts;
            a.timing = Some(match curve {
                SceneCurve::EaseOut => Timing::EaseOut,
                SceneCurve::EaseInOut => Timing::EaseInEaseOut,
                SceneCurve::Linear => Timing::Linear,
            });
            a
        }
    };
    animation.from = Some(from);
    animation.to = Some(to);
    animation.additive = additive;
    Some(animation)
}

/// `sceneCrossfade(_:on:in:)`.
pub fn scene_crossfade(policy: &MotionPolicy, motion: SceneMotion) -> Option<Animation> {
    if !policy.animates_movement() {
        return None;
    }
    let mut a = Animation::new("transition", None);
    a.transition = Some("fade".into());
    a.duration = motion.visible_duration(policy.speed.time_scale());
    a.timing = Some(FADE_CURVE);
    Some(a)
}

/// `sceneLoopAnimation(_:in:)`.
pub fn scene_loop_animation(
    policy: &MotionPolicy,
    lp: SceneLoop,
    space: SceneTransformSpace,
) -> Option<Animation> {
    if !policy.animates_loops() {
        return None;
    }
    let period = lp.period * policy.speed.time_scale();
    let amount = lp.amount;
    let swing = |key_path: &str, to: Value| {
        let mut a = Animation::new("basic", Some(key_path));
        a.from = Some(if key_path == "opacity" { json!(0) } else { transform_value(IDENTITY) });
        a.to = Some(to);
        a.duration = period / 2.;
        a.autoreverses = true;
        a.timing = Some(Timing::EaseInEaseOut);
        a
    };
    let keyframes = |values: Vec<Value>| {
        let mut a = Animation::new("keyframe", Some("transform"));
        a.values = values;
        a.duration = period;
        a
    };
    let mut animation = match lp.effect {
        Effect::Pulse => {
            swing("transform", transform_value(space.transform(1. + 0.06 * amount, 0., [0., 0.])))
        }
        Effect::Breathe => swing("opacity", json!(-(0.4 * amount).min(1.))),
        Effect::Float => {
            swing("transform", transform_value(space.transform(1., 0., [0., -4. * amount])))
        }
        Effect::Spin => {
            let turns = amount;
            let steps = ((36. * turns.abs()).ceil() as i64).max(1);
            let mut a = keyframes(
                (0..=steps)
                    .map(|i| {
                        transform_value(space.transform(
                            1.,
                            360. * turns * i as f64 / steps as f64,
                            [0., 0.],
                        ))
                    })
                    .collect(),
            );
            a.calculation_mode = Some("linear".into());
            a
        }
        Effect::Wiggle => {
            let angle = 6. * amount;
            let mut a = keyframes(
                [0., angle, 0., -angle, 0.]
                    .iter()
                    .map(|d| transform_value(space.transform(1., *d, [0., 0.])))
                    .collect(),
            );
            a.timings = vec![Timing::EaseInEaseOut; 4];
            a
        }
        Effect::Bounce => {
            let mut a = keyframes(
                [0., -8. * amount, 0.]
                    .iter()
                    .map(|y| transform_value(space.transform(1., 0., [0., *y])))
                    .collect(),
            );
            a.timings = vec![Timing::EaseOut, Timing::EaseIn];
            a
        }
        Effect::Shimmer => return None,
    };
    animation.additive = true;
    animation.repeat_forever = true;
    animation.removed_on_completion = false;
    Some(animation)
}

/// `sceneShimmerAnimation(_:travel:band:)`.
pub fn scene_shimmer_animation(
    policy: &MotionPolicy,
    lp: SceneLoop,
    travel: f64,
    band: f64,
) -> Option<Animation> {
    if !(policy.animates_loops() && lp.effect == Effect::Shimmer && travel > 0.) {
        return None;
    }
    let mut a = Animation::new("basic", Some("position.x"));
    a.from = Some(json!(-band / 2.));
    a.to = Some(json!(travel + band / 2.));
    a.duration = lp.period * policy.speed.time_scale();
    a.timing = Some(Timing::ControlPoints([0.45, 0., 0.55, 1.]));
    a.repeat_forever = true;
    a.removed_on_completion = false;
    Some(a)
}

/// `sceneTransition(...)`'s result: the `transform` and `opacity` animations it adds.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TransitionAnimations {
    pub transform: Option<Animation>,
    pub opacity: Option<Animation>,
}

/// `sceneTransition(_:entering:opacity:in:window:motion:)`.
pub fn scene_transition(
    policy: &MotionPolicy,
    transition: SceneTransition,
    entering: bool,
    opacity: f32,
    space: SceneTransformSpace,
    motion: Option<SceneMotion>,
) -> TransitionAnimations {
    let mut out = TransitionAnimations::default();
    if !policy.animates_movement() {
        return out;
    }
    let away = match transition {
        SceneTransition::Opacity => None,
        SceneTransition::Slide => {
            Some(space.transform(1., 0., [0., if entering { 8. } else { -8. }]))
        }
        SceneTransition::Scale => Some(space.transform(0.9, 0., [0., 0.])),
        SceneTransition::Move => {
            Some(space.transform(1., 0., [if entering { -12. } else { 12. }, 0.]))
        }
        SceneTransition::Pop => Some(space.transform(0.6, 0., [0., 0.])),
    };
    let chosen = motion.unwrap_or(match (transition, entering) {
        (SceneTransition::Pop, true) => BOUNCY,
        (_, true) => spring(MotionSpring::Appear.base()),
        (_, false) => spring(MotionSpring::Disappear.base()),
    });
    let ends =
        |hidden: Value, shown: Value| if entering { (hidden, shown) } else { (shown, hidden) };
    if let Some(away) = away {
        let (from, to) = ends(transform_value(away), transform_value(IDENTITY));
        out.transform = scene_animation(policy, chosen, "transform", from, to, true);
    }
    let base =
        policy.fade_duration(if entering { MotionFade::FadeIn } else { MotionFade::FadeOut });
    let fade = match motion {
        Some(m) => {
            if base > 0. {
                m.visible_duration(policy.speed.time_scale())
            } else {
                0.
            }
        }
        None => base,
    };
    if fade > 0. {
        let (from, to) = ends(json!(-opacity), json!(0f32));
        let mut a = Animation::new("basic", Some("opacity"));
        a.from = Some(from);
        a.to = Some(to);
        a.duration = fade;
        a.timing = Some(match motion {
            Some(SceneMotion::Timed { curve: SceneCurve::Linear, .. }) => Timing::Linear,
            Some(SceneMotion::Timed { curve: SceneCurve::EaseInOut, .. }) => Timing::EaseInEaseOut,
            _ => FADE_CURVE,
        });
        a.additive = true;
        out.opacity = Some(a);
    }
    for a in [&mut out.transform, &mut out.opacity].into_iter().flatten() {
        if entering {
            a.fill = Some("backwards".into());
        } else {
            a.fill = Some("forwards".into());
            a.removed_on_completion = false;
        }
    }
    out
}

/// `sceneBurstAnimation(lifetime:)`: one 0.1 s burst, then the particles' lifetime (at most 30 s).
pub fn scene_burst_animation(policy: &MotionPolicy, lifetime: f64) -> Option<Animation> {
    if !policy.animates_loops() {
        return None;
    }
    let mut burst = Animation::new("basic", Some("birthRate"));
    burst.from = Some(json!(1f32));
    burst.to = Some(json!(1f32));
    burst.duration = 0.1;
    let mut life = Animation::new("group", None);
    life.duration = burst.duration + lifetime.clamp(0., 30.);
    life.animations = vec![burst];
    Some(life)
}

/// `rollInPlace(_:upward:)`: a push from below (`upward`) or above over the `fadeIn` fade; a
/// crossfade in place when movement does not animate (`crossfadeInPlace`, the `crossfade` fade);
/// nil when the change applies at once.
pub fn roll_in_place(policy: &MotionPolicy, upward: bool) -> Option<Animation> {
    let mut a = Animation::new("transition", None);
    a.timing = Some(FADE_CURVE);
    if !policy.animates_movement() {
        let seconds = policy.fade_duration(MotionFade::Crossfade);
        if seconds <= 0. {
            return None;
        }
        a.transition = Some("fade".into());
        a.duration = seconds;
        return Some(a);
    }
    let seconds = policy.fade_duration(MotionFade::FadeIn);
    if seconds <= 0. {
        return None;
    }
    a.transition = Some("push".into());
    a.subtype = Some(if upward { "fromBottom" } else { "fromTop" }.into());
    a.duration = seconds;
    Some(a)
}

/// `settleAnimation(_:from:)`: `keyPath` eases from `from` to the model value over the `settle` fade.
pub fn settle_animation(policy: &MotionPolicy, key_path: &str, from: Value) -> Option<Animation> {
    let seconds = policy.fade_duration(MotionFade::Settle);
    if !(policy.animates_movement() && seconds > 0.) {
        return None;
    }
    let mut a = Animation::new("basic", Some(key_path));
    a.from = Some(from);
    a.duration = seconds;
    a.timing = Some(FADE_CURVE);
    Some(a)
}
