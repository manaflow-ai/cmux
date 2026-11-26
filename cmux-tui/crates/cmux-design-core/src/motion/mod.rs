//! Motion choices CmuxNextDesign/Motion and CmuxNextDesignTokens make on top of cmux-motion:
//! the token tables, the spring admission and settle math, the app's policy (cap, categories,
//! master switch), the pairs, scene motions and loops, and the color transition.
//!
//! Ops: `motion.NAME` (see [`call`]).

pub mod policy;
pub mod spring;
pub mod tokens;

use crate::ops::{OpError, OpResult, parse, reply};
use serde::Deserialize;
use serde_json::{Value, json};

use policy::{MotionPolicy, Side};
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
        _ => Err(OpError::Unknown),
    }
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
