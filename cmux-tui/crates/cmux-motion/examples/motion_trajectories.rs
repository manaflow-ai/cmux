//! Prints the motion parity corpus as JSON: every chrome spring token
//! resolved under bounce `none` and `subtle`, and the frame-by-frame path
//! of a 200 pt move (and a mid-flight retarget to 50 pt) at 60 and 120 Hz
//! until the spring rests. cmux-next macOS prints the same corpus from its
//! own spring (`debug.motion {action: "trajectory"}`);
//! `scripts/cmux-next/motion-parity.py RUST.json SWIFT.json` compares them.
//! Tween tokens (`tweens`) add the path of a 200 pt tween, of a retarget to
//! 50 pt after 5 frames (restarts from the value on screen) and of the same
//! target set again after 5 frames (no restart), at 60 and 120 Hz.
//!
//! `cargo run -p cmux-motion --example motion_trajectories`

use cmux_motion::{
    AnimationSwitches, GEOMETRY_EPSILON, MotionBounce, MotionPolicy, MotionSpeed, MotionSpring,
    MotionTween, SpringParameters, SpringValue, TweenParameters, TweenValue,
};

/// Tween tokens both ports have, by their spec name.
const TWEENS: [(&str, MotionTween); 3] = [
    ("tabOpen", MotionTween::TabOpen),
    ("tabClose", MotionTween::TabClose),
    ("tabMove", MotionTween::TabMove),
];

/// Frames of a tween from 0 toward 200 until it ends; after `at` frames
/// the target is set to `to` (50 restarts, 200 again does not).
fn tween_path(p: TweenParameters, hz: f64, retarget: Option<(usize, f64)>) -> Vec<f32> {
    let mut s = TweenValue::new(0.);
    s.retarget(200., p.duration);
    let mut out = Vec::new();
    for frame in 0..(3. * hz) as usize {
        if let Some((_, to)) = retarget.filter(|(at, _)| *at == frame) {
            s.retarget(to, p.duration);
        }
        let moving = s.step(1. / hz, p.curve);
        out.push(s.value as f32);
        if !moving {
            break;
        }
    }
    out
}

/// Tokens both ports have, by their spec name.
const TOKENS: [(&str, MotionSpring); 13] = [
    ("move", MotionSpring::Move),
    ("appear", MotionSpring::Appear),
    ("disappear", MotionSpring::Disappear),
    ("settle", MotionSpring::Settle),
    ("scroll", MotionSpring::Scroll),
    ("screen", MotionSpring::Screen),
    ("track", MotionSpring::Track),
    ("selection", MotionSpring::Selection),
    ("panel", MotionSpring::Panel),
    ("pinDrag", MotionSpring::PinDrag),
    ("zoom", MotionSpring::Zoom),
    ("exit", MotionSpring::Exit),
    ("tabOpen", MotionSpring::TabOpen),
];

/// Frames until rest (at most 3 s) from 0 toward 200, retargeting to
/// `retarget` after `at` frames when given.
fn path(p: SpringParameters, hz: f64, retarget: Option<(usize, f32)>) -> Vec<f32> {
    let mut s = SpringValue::new(0.);
    s.target = 200.;
    let dt = 1. / hz;
    let mut out = Vec::new();
    for frame in 0..(3. * hz) as usize {
        if let Some((_, to)) = retarget.filter(|(at, _)| *at == frame) {
            s.target = to;
        }
        let moving = s.advance(dt, p, GEOMETRY_EPSILON);
        out.push(s.value);
        if !moving {
            break;
        }
    }
    out
}

fn list(values: &[f32]) -> String {
    values.iter().map(|v| format!("{v:.4}")).collect::<Vec<_>>().join(",")
}

fn main() {
    let mut tokens = Vec::new();
    let mut paths = Vec::new();
    for bounce in [MotionBounce::None, MotionBounce::Subtle] {
        let policy = MotionPolicy::new(MotionSpeed::Fast, false)
            .with_animations(AnimationSwitches { bounce, ..AnimationSwitches::DEFAULT });
        for (name, token) in TOKENS {
            let p = policy.spring(token);
            tokens.push(format!(
                "{{\"token\":\"{name}\",\"bounce\":\"{}\",\"response\":{:.9},\"damping_fraction\":{:.9},\"visible_end\":{:.6}}}",
                bounce.as_str(),
                p.response,
                p.damping_fraction,
                p.visible_end()
            ));
            for hz in [60., 120.] {
                for (case, retarget) in [("move", None), ("retarget", Some((5, 50.)))] {
                    paths.push(format!(
                        "{{\"token\":\"{name}\",\"bounce\":\"{}\",\"hz\":{hz},\"case\":\"{case}\",\"values\":[{}]}}",
                        bounce.as_str(),
                        list(&path(p, hz, retarget))
                    ));
                }
            }
        }
    }
    let mut tweens = Vec::new();
    let policy = MotionPolicy::new(MotionSpeed::Fast, false);
    for (name, token) in TWEENS {
        let p = token.base();
        let seconds = policy.tween(token);
        for hz in [60., 120.] {
            for (case, retarget) in
                [("move", None), ("retarget", Some((5, 50.))), ("same", Some((5, 200.)))]
            {
                tweens.push(format!(
                    "{{\"token\":\"{name}\",\"duration\":{seconds:.9},\"hz\":{hz},\"case\":\"{case}\",\"values\":[{}]}}",
                    list(&tween_path(p, hz, retarget))
                ));
            }
        }
    }
    println!(
        "{{\"port\":\"rust\",\"tokens\":[{}],\"paths\":[{}],\"tweens\":[{}]}}",
        tokens.join(","),
        paths.join(","),
        tweens.join(",")
    );
}
