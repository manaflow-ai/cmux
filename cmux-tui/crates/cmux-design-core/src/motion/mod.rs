//! Motion choices CmuxNextDesign/Motion and CmuxNextDesignTokens make on top of cmux-motion:
//! the token tables, the spring admission and settle math, the app's policy (cap, categories,
//! master switch), the pairs, scene motions and loops, and the color transition.
//!
//! Ops: `motion.NAME` (see [`call`]).

pub mod color_transition;
pub mod policy;
pub mod scene;
pub mod spring;
pub mod tokens;

use crate::ops::{OpError, OpResult, parse, reply};
use serde::Deserialize;
use serde_json::{Value, json};

use color_transition::ColorTransition;
use policy::{MotionPolicy, Side};
use scene::{SceneLoop, SceneMotion, SceneTransformSpace, SceneTransition};
use spring::{Spring, SpringState};
use tokens::{MotionFade, MotionLoop, MotionSpring, MotionTween};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PolicyRequest {
    #[serde(default)]
    policy: MotionPolicy,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SpringRequest {
    spring: Spring,
    #[serde(default)]
    velocity: f64,
    #[serde(default)]
    distance: f64,
    #[serde(default)]
    fraction: f64,
    #[serde(default)]
    displacement: f64,
    #[serde(default)]
    time: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct AdvanceRequest {
    state: SpringState,
    dt: f64,
    spring: Spring,
    epsilon: f64,
    #[serde(default)]
    admits: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SecondsRequest {
    #[serde(default)]
    policy: MotionPolicy,
    side: Side,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SceneMotionRequest {
    name: Option<String>,
    response: Option<f64>,
    damping_fraction: Option<f64>,
    seconds: Option<f64>,
    curve: Option<String>,
    scale: Option<f64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SceneLoopRequest {
    effect: String,
    period: Option<f64>,
    amount: Option<f64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TransformRequest {
    #[serde(default)]
    space: SceneTransformSpace,
    scale: Option<f64>,
    #[serde(default)]
    degrees: f64,
    #[serde(default)]
    offset: [f64; 2],
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SceneAnimationRequest {
    #[serde(default)]
    policy: MotionPolicy,
    motion: SceneMotion,
    #[serde(default)]
    key_path: String,
    #[serde(default)]
    from: Value,
    #[serde(default)]
    to: Value,
    #[serde(default)]
    additive: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LoopAnimationRequest {
    #[serde(default)]
    policy: MotionPolicy,
    #[serde(rename = "loop")]
    scene_loop: SceneLoop,
    #[serde(default)]
    space: SceneTransformSpace,
    #[serde(default)]
    travel: f64,
    #[serde(default)]
    band: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TransitionRequest {
    #[serde(default)]
    policy: MotionPolicy,
    transition: SceneTransition,
    entering: bool,
    opacity: f32,
    #[serde(default)]
    space: SceneTransformSpace,
    motion: Option<SceneMotion>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct BurstRequest {
    #[serde(default)]
    policy: MotionPolicy,
    lifetime: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RollRequest {
    #[serde(default)]
    policy: MotionPolicy,
    upward: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SettleRequest {
    #[serde(default)]
    policy: MotionPolicy,
    key_path: String,
    #[serde(default)]
    from: Value,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ColorRequest {
    #[serde(default)]
    transition: ColorTransition,
    #[serde(default)]
    speed_off: bool,
    #[serde(default)]
    system_reduce_motion: bool,
    #[serde(default)]
    t: f64,
    count: Option<usize>,
    #[serde(default)]
    from: [f64; 4],
    #[serde(default)]
    to: [f64; 4],
}

/// Runs `motion.NAME`.
pub fn call(name: &str, request: &Value) -> OpResult {
    match name {
        "tokens" => reply(&tokens::table()),
        "spring.admitted" => {
            let r: SpringRequest = parse(request)?;
            reply(&spring::admitted(r.spring.into(), r.velocity, r.distance))
        }
        "spring.settlingTime" => {
            let r: SpringRequest = parse(request)?;
            reply(&spring::settling_time(r.spring.into(), r.fraction))
        }
        "spring.perceivedDuration" => {
            let r: SpringRequest = parse(request)?;
            reply(&spring::perceived_duration(r.spring.into()))
        }
        "spring.solve" => {
            let r: SpringRequest = parse(request)?;
            let (value, velocity) =
                spring::solve(r.displacement, r.velocity, r.time, r.spring.into());
            reply(&json!({ "value": value, "velocity": velocity }))
        }
        "spring.advance" => {
            let mut r: AdvanceRequest = parse(request)?;
            let moving = spring::advance(&mut r.state, r.dt, r.spring.into(), r.epsilon, r.admits);
            reply(&json!({ "state": r.state, "moving": moving }))
        }
        "policy" => {
            let r: PolicyRequest = parse(request)?;
            reply(&policy_reply(&r.policy))
        }
        "seconds" => {
            let r: SecondsRequest = parse(request)?;
            reply(&r.policy.seconds(r.side))
        }
        "pairs" => reply(&policy::pairs()),
        "scene.motion" => {
            let r: SceneMotionRequest = parse(request)?;
            let motion = if let Some(name) = r.name {
                SceneMotion::named(&name)
            } else if let (Some(response), Some(damping)) = (r.response, r.damping_fraction) {
                SceneMotion::custom(response, damping)
            } else if let Some(seconds) = r.seconds {
                SceneMotion::timed(seconds, r.curve.as_deref())
            } else {
                None
            };
            let visible = motion.map(|m| m.visible_duration(r.scale.unwrap_or(1.)));
            reply(&json!({ "motion": motion, "visibleDuration": visible }))
        }
        "scene.loop" => {
            let r: SceneLoopRequest = parse(request)?;
            reply(&SceneLoop::new(&r.effect, r.period, r.amount))
        }
        "scene.transform" => {
            let r: TransformRequest = parse(request)?;
            reply(&r.space.transform(r.scale.unwrap_or(1.), r.degrees, r.offset))
        }
        "scene.animation" => {
            let r: SceneAnimationRequest = parse(request)?;
            reply(&scene::scene_animation(
                &r.policy,
                r.motion,
                &r.key_path,
                r.from,
                r.to,
                r.additive,
            ))
        }
        "scene.crossfade" => {
            let r: SceneAnimationRequest = parse(request)?;
            reply(&scene::scene_crossfade(&r.policy, r.motion))
        }
        "scene.loopAnimation" => {
            let r: LoopAnimationRequest = parse(request)?;
            reply(&scene::scene_loop_animation(&r.policy, r.scene_loop, r.space))
        }
        "scene.shimmer" => {
            let r: LoopAnimationRequest = parse(request)?;
            reply(&scene::scene_shimmer_animation(&r.policy, r.scene_loop, r.travel, r.band))
        }
        "scene.transition" => {
            let r: TransitionRequest = parse(request)?;
            reply(&scene::scene_transition(
                &r.policy,
                r.transition,
                r.entering,
                r.opacity,
                r.space,
                r.motion,
            ))
        }
        "scene.burst" => {
            let r: BurstRequest = parse(request)?;
            reply(&scene::scene_burst_animation(&r.policy, r.lifetime))
        }
        "rollInPlace" => {
            let r: RollRequest = parse(request)?;
            reply(&scene::roll_in_place(&r.policy, r.upward))
        }
        "settle" => {
            let r: SettleRequest = parse(request)?;
            reply(&scene::settle_animation(&r.policy, &r.key_path, r.from))
        }
        "colorTransition.resolve" => {
            let r: ColorRequest = parse(request)?;
            reply(&color_reply(&r.transition.resolved(r.speed_off, r.system_reduce_motion)))
        }
        "colorTransition.describe" => {
            let r: ColorRequest = parse(request)?;
            reply(&color_reply(&r.transition))
        }
        "colorTransition.progress" => {
            let r: ColorRequest = parse(request)?;
            reply(&r.transition.progress(r.t))
        }
        "colorTransition.samples" => {
            let r: ColorRequest = parse(request)?;
            reply(&r.transition.progress_samples(r.count.unwrap_or(color_transition::KEYFRAMES)))
        }
        "colorTransition.mix" => {
            let r: ColorRequest = parse(request)?;
            reply(&r.transition.mix(r.from, r.to, r.t))
        }
        _ => Err(OpError::Unknown),
    }
}

/// A color transition's derived values.
fn color_reply(t: &ColorTransition) -> Value {
    json!({
        "transition": t,
        "seconds": t.seconds(),
        "isInstant": t.is_instant(),
        "mixesInSRGB": t.mixes_in_srgb(),
        "keyframeProgress": t.keyframe_progress(),
        "cssDuration": t.css_duration(),
        "cssEasing": t.css_easing(),
    })
}

/// Everything a policy decides, per token.
fn policy_reply(p: &MotionPolicy) -> Value {
    let springs: serde_json::Map<String, Value> = MotionSpring::ALL
        .iter()
        .map(|t| {
            let s = Spring::from(p.spring(*t));
            (t.as_str().to_string(), json!({ "spring": s, "duration": p.spring_duration(*t) }))
        })
        .collect();
    let fades: serde_json::Map<String, Value> = MotionFade::ALL
        .iter()
        .map(|t| (t.as_str().to_string(), json!(p.fade_duration(*t))))
        .collect();
    let loops: serde_json::Map<String, Value> =
        MotionLoop::ALL.iter().map(|t| (t.as_str().to_string(), json!(p.period(*t)))).collect();
    let tweens: serde_json::Map<String, Value> = MotionTween::ALL
        .iter()
        .map(|t| (t.as_str().to_string(), json!(p.tween_duration(*t))))
        .collect();
    json!({
        "categoryAnimates": p.category_animates(),
        "animatesMovement": p.animates_movement(),
        "animatesFades": p.animates_fades(),
        "animatesLoops": p.animates_loops(),
        "springs": springs,
        "fades": fades,
        "loops": loops,
        "tweens": tweens,
        "webMotion": p.web_motion_value(),
    })
}
