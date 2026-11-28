//! Parity with CmuxNextDesignTests' MotionCapTests, MotionCategoryPolicyTests, MotionScaleTests and
//! MotionSpringSpecTests, value for value, plus the `motion.*` ops through `ops::call`.

use cmux_design_core::motion::color_transition::{
    self, ColorTransition, Curve, ReduceMotion, Space,
};
use cmux_design_core::motion::policy::{self, MotionPolicy};
use cmux_design_core::motion::scene::{self, SceneMotion, SceneTransformSpace};
use cmux_design_core::motion::spring::{self, Spring, SpringState};
use cmux_design_core::motion::tokens::{
    MotionCategory, MotionFade, MotionKind, MotionLoop, MotionSpeed, MotionSpring, MotionTween,
    OTHER_TUNABLES, scale,
};
use cmux_design_core::ops;
use serde_json::{Value, json};

const CAP: f64 = 0.3;
const TOLERANCE: f64 = 1e-9;
const SPEEDS: [MotionSpeed; 2] = [MotionSpeed::Fast, MotionSpeed::Normal];
const AMBIENT_LIMITS: [(MotionFade, f64); 4] = [
    (MotionFade::FocusFlash, 0.75),
    (MotionFade::Wallpaper, 0.9),
    (MotionFade::HibernateRing, 1.5),
    (MotionFade::Highlight, 1.8),
];
const ENDS_AFTER_THE_CEILING: [(MotionSpring, f64); 3] =
    [(MotionSpring::Settle, 0.262), (MotionSpring::Popover, 0.286), (MotionSpring::PinDrag, 0.256)];

fn all_kinds(speed: MotionSpeed) -> MotionPolicy {
    MotionPolicy { enabled_kinds: MotionKind::ALL.to_vec(), ..MotionPolicy::new(speed, false) }
}

fn ambient_limit(fade: MotionFade) -> Option<f64> {
    AMBIENT_LIMITS.iter().find(|(f, _)| *f == fade).map(|(_, l)| *l)
}

fn tunable(name: &str) -> f64 {
    OTHER_TUNABLES.iter().find(|(n, _)| *n == name).unwrap().1
}

/// `Motion.steadyPulseDuration`.
const STEADY_PULSE_DURATION: f64 = scale::LARGE;

// MotionCapTests

#[test]
fn every_spring_ends_visibly_by_the_cap() {
    for spring in MotionSpring::ALL {
        for speed in SPEEDS {
            let end = all_kinds(speed).spring_duration(*spring);
            assert!(end > 0., "{spring:?} does not animate at {speed:?}");
            assert!(end <= CAP + TOLERANCE, "{spring:?} at {speed:?} ends at {end}");
        }
    }
}

#[test]
fn every_fade_ends_by_the_cap() {
    for fade in MotionFade::ALL {
        for speed in SPEEDS {
            let seconds = all_kinds(speed).fade_duration(*fade);
            if let Some(limit) = ambient_limit(*fade) {
                assert!(seconds > CAP, "{fade:?} is listed ambient but takes {seconds}");
                assert!(seconds <= limit + TOLERANCE, "{fade:?} at {speed:?} takes {seconds}");
            } else {
                assert!(seconds <= CAP + TOLERANCE, "{fade:?} at {speed:?} takes {seconds}");
            }
        }
    }
}

#[test]
fn every_tween_ends_by_the_cap() {
    for tween in MotionTween::ALL {
        for speed in SPEEDS {
            let seconds = all_kinds(speed).tween_duration(*tween);
            assert!(seconds > 0., "{tween:?} does not animate at {speed:?}");
            assert!(seconds <= CAP + TOLERANCE, "{tween:?} at {speed:?} takes {seconds}");
        }
    }
}

#[test]
fn a_timed_motion_that_is_no_token_ends_by_the_cap() {
    for base in [tunable("agentCursorGlideMax"), STEADY_PULSE_DURATION] {
        for speed in SPEEDS {
            let seconds = all_kinds(speed).scaled(base);
            assert!(seconds > 0. && seconds <= CAP + TOLERANCE, "{base} at {speed:?}: {seconds}");
        }
    }
}

#[test]
fn the_cap_changes_no_time_under_it() {
    let (fast, normal) = (all_kinds(MotionSpeed::Fast), all_kinds(MotionSpeed::Normal));
    let s = MotionSpeed::Normal.time_scale();
    for spring in MotionSpring::ALL {
        let code = spring.base();
        assert_eq!(fast.spring(*spring), code, "{spring:?} at fast is not its token");
        let longer = code.scaled(s);
        if spring::perceived_duration(longer) <= CAP {
            assert_eq!(normal.spring(*spring), longer, "{spring:?} at normal");
        }
    }
    for fade in MotionFade::ALL {
        let code = fade.base_duration();
        assert_eq!(fast.fade_duration(*fade), code, "{fade:?} at fast is not its token");
        if code * s <= CAP || ambient_limit(*fade).is_some() {
            assert_eq!(normal.fade_duration(*fade), code * s, "{fade:?} at normal");
        }
    }
    assert_eq!(fast.scaled(0.1), 0.1);
    assert_eq!(normal.scaled(0.1), 0.1 * s);
}

#[test]
fn the_ambient_fades_are_the_ones_of_the_scale() {
    let mut listed: Vec<_> = AMBIENT_LIMITS.iter().map(|(f, _)| f.as_str()).collect();
    let mut ambient: Vec<_> =
        MotionFade::ALL.iter().filter(|f| f.is_ambient()).map(|f| f.as_str()).collect();
    listed.sort_unstable();
    ambient.sort_unstable();
    assert_eq!(listed, ambient);
}

#[test]
fn the_speed_does_not_scale_a_loop() {
    for lp in MotionLoop::ALL {
        let fast = all_kinds(MotionSpeed::Fast).period(*lp);
        assert!(fast.is_some(), "{lp:?} does not run at fast");
        assert_eq!(all_kinds(MotionSpeed::Normal).period(*lp), fast, "{lp:?}");
    }
}

#[test]
fn an_exit_ends_sooner_than_its_enter() {
    for pair in policy::pairs() {
        for speed in SPEEDS {
            let p = all_kinds(speed);
            let (enter, exit) = (p.seconds(pair.enter), p.seconds(pair.exit));
            assert!(enter > 0. && exit > 0., "a side of {} does not animate", pair.name);
            if pair.equal_because.is_some() {
                assert!((exit - enter).abs() <= TOLERANCE, "{} at {speed:?}", pair.name);
            } else {
                assert!(exit < enter - TOLERANCE, "{} at {speed:?}: {exit} vs {enter}", pair.name);
            }
        }
    }
}

#[test]
fn only_the_tab_pair_is_equal() {
    let pairs = policy::pairs();
    let equal: Vec<_> =
        pairs.iter().filter(|p| p.equal_because.is_some()).map(|p| p.name).collect();
    assert_eq!(equal, ["tab open and close"]);
    let mut names: Vec<_> = pairs.iter().map(|p| p.name).collect();
    names.dedup();
    assert_eq!(names.len(), 6);
}

// MotionCategoryPolicyTests (the marquee stays in Swift)

fn base(
    enabled: bool,
    disabled: &[MotionCategory],
    reduce: bool,
    speed: MotionSpeed,
) -> MotionPolicy {
    MotionPolicy {
        enabled_kinds: vec![MotionKind::NewTab, MotionKind::NewWorkspace],
        animations_enabled: enabled,
        disabled_categories: disabled.to_vec(),
        ..MotionPolicy::new(speed, reduce)
    }
}

fn plain() -> MotionPolicy {
    base(true, &[], false, MotionSpeed::Fast)
}

fn is_still(p: &MotionPolicy) -> bool {
    !p.animates_movement()
        && !p.animates_fades()
        && !p.animates_loops()
        && p.fade_duration(MotionFade::FadeIn) == 0.
        && p.fade_duration(MotionFade::Hover) == 0.
        && p.spring_duration(MotionSpring::Move) == 0.
        && p.period(MotionLoop::Spinner).is_none()
        && p.tween_duration(MotionTween::TabOpen) == 0.
        && p.tween_duration(MotionTween::TabMove) == 0.
        && !p.animates(MotionKind::NewTab)
}

fn is_moving(p: &MotionPolicy) -> bool {
    p.animates_movement()
        && p.animates_fades()
        && p.animates_loops()
        && p.fade_duration(MotionFade::FadeIn) > 0.
        && p.spring_duration(MotionSpring::Move) > 0.
        && p.period(MotionLoop::Spinner).is_some()
        && p.tween_duration(MotionTween::TabMove) > 0.
}

#[test]
fn one_category_off_stops_only_that_category() {
    for off in MotionCategory::ALL {
        let p = base(true, &[*off], false, MotionSpeed::Fast);
        assert!(is_still(&p.for_category(*off)), "{off:?} still animates");
        for other in MotionCategory::ALL.iter().filter(|c| *c != off) {
            assert!(is_moving(&p.for_category(*other)), "{other:?} stopped with {off:?} off");
        }
    }
}

#[test]
fn the_master_switch_overrides_every_category() {
    let p = base(false, &[], false, MotionSpeed::Fast);
    for c in MotionCategory::ALL {
        assert!(is_still(&p.for_category(*c)), "{c:?}");
    }
    assert!(!p.category_animates());
}

#[test]
fn turning_the_master_switch_back_on_restores_only_the_categories_that_are_on() {
    let p = base(true, &[MotionCategory::Sidebar, MotionCategory::Web], false, MotionSpeed::Fast);
    assert!(is_still(&p.for_category(MotionCategory::Sidebar)));
    assert!(is_still(&p.for_category(MotionCategory::Web)));
    assert!(is_moving(&p.for_category(MotionCategory::Tabs)));
}

#[test]
fn every_category_animates_by_default() {
    for c in MotionCategory::ALL {
        assert!(is_moving(&plain().for_category(*c)), "{c:?}");
    }
}

#[test]
fn reduce_motion_still_applies_inside_an_on_category() {
    for c in MotionCategory::ALL {
        let p = base(true, &[], true, MotionSpeed::Fast).for_category(*c);
        assert!(!p.animates_movement());
        assert!(!p.animates_loops());
        assert!(p.fade_duration(MotionFade::FadeIn) <= MotionFade::Crossfade.base_duration());
        assert_eq!(p.fade_duration(MotionFade::Hover), 0.);
    }
}

#[test]
fn speed_off_still_stops_every_category() {
    for c in MotionCategory::ALL {
        assert!(is_still(&base(true, &[], false, MotionSpeed::Off).for_category(*c)));
    }
}

#[test]
fn web_pages_get_off_when_their_category_or_the_master_switch_is_off() {
    let web = MotionCategory::Web;
    assert_eq!(plain().for_category(web).web_motion_value(), "full");
    assert_eq!(
        base(true, &[], true, MotionSpeed::Fast).for_category(web).web_motion_value(),
        "reduced"
    );
    assert_eq!(
        base(true, &[web], false, MotionSpeed::Fast).for_category(web).web_motion_value(),
        "off"
    );
    assert_eq!(
        base(false, &[], false, MotionSpeed::Fast).for_category(web).web_motion_value(),
        "off"
    );
    let tabs_off = base(true, &[MotionCategory::Tabs], false, MotionSpeed::Fast);
    assert_eq!(tabs_off.for_category(web).web_motion_value(), "full");
}

#[test]
fn every_category_has_its_own_config_key() {
    let mut keys: Vec<_> = MotionCategory::ALL.iter().map(|c| c.as_str()).collect();
    keys.sort_unstable();
    keys.dedup();
    assert_eq!(keys.len(), MotionCategory::ALL.len());
    for taken in MotionKind::ALL.iter().map(|k| k.as_str()).chain(["bounce", "enabled"]) {
        assert!(!keys.contains(&taken), "{taken}");
    }
}

// MotionScaleTests

fn on_scale(seconds: f64) -> bool {
    seconds == 0. || scale::STEPS.iter().any(|s| (s - seconds).abs() < 1e-9)
}

#[test]
fn the_scale_is_sorted_and_ends_at_the_ceiling() {
    assert!(scale::STEPS.windows(2).all(|w| w[0] < w[1]));
    assert_eq!(scale::STEPS, [scale::QUICK, scale::MICRO, scale::STANDARD, scale::LARGE]);
    assert_eq!(scale::STEPS, [0.08, 0.12, 0.18, 0.24]);
    assert_eq!(scale::CEILING, scale::LARGE);
}

#[test]
fn every_fade_is_a_step_of_the_scale() {
    for fade in MotionFade::ALL {
        let seconds = fade.base_duration();
        if ambient_limit(*fade).is_some() {
            assert!(seconds > scale::CEILING, "{fade:?}");
        } else {
            assert!(on_scale(seconds), "{fade:?} fades over {seconds}");
        }
    }
}

#[test]
fn every_spring_ends_visibly_by_the_ceiling() {
    for s in MotionSpring::ALL {
        let end = spring::perceived_duration(s.base());
        assert!(end > 0.);
        match ENDS_AFTER_THE_CEILING.iter().find(|(t, _)| t == s) {
            Some((_, limit)) => {
                assert!(end > scale::CEILING, "{s:?} ends at {end}: take it off the list");
                assert!(end <= *limit, "{s:?} ends at {end}");
            }
            None => assert!(end <= scale::CEILING, "{s:?} ends at {end}"),
        }
    }
}

#[test]
fn the_reduce_motion_ceiling_is_quick() {
    assert_eq!(MotionFade::Crossfade.base_duration(), scale::QUICK);
}

#[test]
fn other_timed_transitions_are_on_the_scale() {
    assert!(on_scale(tunable("agentCursorGlideMax")));
    assert!(on_scale(STEADY_PULSE_DURATION));
}

// MotionSpringSpecTests

fn spec_motion() -> Value {
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../../plans/cmux-next/spec-proposals/visuals/design-tokens.json"
    );
    let root: Value = serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
    root["motion"].clone()
}

#[test]
fn the_screen_switch_spring_is_gone_and_the_spec_holds_no_bounce() {
    assert!(MotionSpring::parse("screen").is_none());
    let motion = spec_motion();
    assert!(motion["springs"].get("screen").is_none());
    assert!(motion.get("bounce").is_none());
    assert!(motion.get("structural").is_none());
}

#[test]
fn every_spring_of_the_spec_is_this_ports_spring() {
    let springs = spec_motion()["springs"].as_object().unwrap().clone();
    assert!(springs.len() >= 12);
    for (name, entry) in springs {
        let response = entry["value"]["response"].as_f64().unwrap();
        let damping = entry["value"]["dampingFraction"].as_f64().unwrap();
        assert!(damping >= 1., "{name} passes its target");
        let own = MotionSpring::parse(&name).unwrap_or_else(|| panic!("{name}")).base();
        assert_eq!((own.response, own.damping_fraction), (response, damping), "{name}");
    }
}

// Pinned outputs (the current Rust values the Swift callers will read)

#[test]
fn pinned_spring_math() {
    let p = MotionSpring::Settle.base();
    assert_eq!(spring::admitted(p, -5., 10.), 0.);
    assert!(spring::admitted(p, 5., 10.) > 0.);
    assert_eq!(spring::admitted(p, 5., 0.), 0.);
    let (v, _) = spring::solve(1., 0., 0., p);
    assert_eq!(v, 1.);
    let (v, _) = spring::solve(1., 0., 10., p);
    assert!(v.abs() < 1e-9);
    let mut state = SpringState { value: 0., velocity: 0., target: 1. };
    let mut steps = 0;
    while spring::advance(&mut state, 1. / 120., p, 0.001, false) {
        steps += 1;
        assert!(steps < 10_000);
    }
    assert_eq!(state.value, 1.);
    assert_eq!(
        Spring::from(p),
        Spring { response: p.response, damping_fraction: p.damping_fraction }
    );
}

#[test]
fn pinned_scene_motions() {
    assert_eq!(SceneMotion::named("smooth"), Some(scene::SMOOTH));
    assert_eq!(SceneMotion::named("snappy"), Some(scene::SNAPPY));
    assert_eq!(SceneMotion::named("bouncy"), Some(scene::BOUNCY));
    assert_eq!(SceneMotion::named("nope"), None);
    let identity = SceneTransformSpace::default().transform(1., 0., [0., 0.]);
    assert_eq!(identity, scene::IDENTITY);
    let moved = SceneTransformSpace::default().transform(1., 0., [3., 4.]);
    assert_eq!((moved[12], moved[13]), (3., 4.));
}

#[test]
fn pinned_color_transition() {
    let t = ColorTransition::default();
    assert_eq!(t.seconds(), color_transition::DEFAULT_DURATION);
    assert_eq!(t.css_duration(), "200ms");
    assert_eq!(t.css_easing(), "cubic-bezier(0, 0, 0.58, 1)");
    assert_eq!(t.progress(0.), 0.);
    assert_eq!(t.progress(1.), 1.);
    assert_eq!(t.keyframe_progress().len(), color_transition::KEYFRAMES);
    assert_eq!(*t.keyframe_progress().last().unwrap(), 1.);
    let off = t.resolved(true, false);
    assert!(off.is_instant());
    assert_eq!(off.css_duration(), "0ms");
    let reduced = t.resolved(false, true);
    assert_eq!(reduced.seconds(), color_transition::REDUCED_MOTION_CAP);
    let instant =
        ColorTransition { reduce_motion: ReduceMotion::Instant, ..t }.resolved(false, true);
    assert!(instant.is_instant());
    let sprung = ColorTransition {
        curve: Curve::Spring { spring: Spring { response: 0.2, damping_fraction: 1. } },
        ..t
    };
    assert_eq!(sprung.resolved(false, true).curve, Curve::EaseOut);
    assert!(sprung.css_easing().starts_with("linear(0, "));
    let bezier =
        ColorTransition { curve: Curve::CubicBezier { x1: 1.5, y1: 0.1234, x2: -1., y2: 1. }, ..t };
    assert_eq!(bezier.css_easing(), "cubic-bezier(1, 0.123, 0, 1)");
    assert_eq!(color_transition::css(0.5), "0.5");
    assert_eq!(color_transition::css(2.), "2");
    let srgb = ColorTransition { space: Space::Srgb, ..t };
    assert_eq!(srgb.mix([0., 0., 0., 1.], [1., 1., 1., 1.], 0.5), [0.5, 0.5, 0.5, 1.]);
    assert_eq!(t.mix([0.2, 0.4, 0.6, 1.], [0.2, 0.4, 0.6, 1.], 0.5)[3], 1.);
}

// The ops

fn call(op: &str, request: Value) -> Value {
    ops::call(op, &request).unwrap_or_else(|e| panic!("{op}: {e:?}"))
}

#[test]
fn ops_round_trip() {
    let tokens = call("motion.tokens", json!({}));
    assert!(tokens.is_object());
    let p = call(
        "motion.policy",
        json!({ "policy": { "speed": "normal", "enabledKinds": ["newTab"] } }),
    );
    assert_eq!(p["webMotion"], "full");
    assert_eq!(
        p["fades"]["crossfade"],
        json!(all_kinds(MotionSpeed::Normal).fade_duration(MotionFade::Crossfade))
    );
    let off = call("motion.policy", json!({ "policy": { "animationsEnabled": false } }));
    assert_eq!(off["webMotion"], "off");
    assert_eq!(off["loops"]["spinner"], Value::Null);
    assert_eq!(call("motion.pairs", json!({})).as_array().unwrap().len(), 6);
    let seconds = call("motion.seconds", json!({ "side": { "fade": "fadeIn" } }));
    assert_eq!(seconds, json!(MotionPolicy::default().fade_duration(MotionFade::FadeIn)));
    let css = call("motion.colorTransition.describe", json!({}));
    assert_eq!(css["cssDuration"], "200ms");
    let motion = call("motion.scene.motion", json!({ "name": "smooth" }));
    assert!(motion["visibleDuration"].as_f64().unwrap() > 0.);
    let none = call("motion.scene.motion", json!({ "name": "nope" }));
    assert_eq!(none["motion"], Value::Null);
    let settled = call(
        "motion.spring.advance",
        json!({
            "state": { "value": 1, "velocity": 0, "target": 1 }, "dt": 0.008,
            "spring": { "response": 0.2, "dampingFraction": 1 }, "epsilon": 0.001
        }),
    );
    assert_eq!(settled["moving"], false);
    assert!(ops::call("motion.nope", &json!({})).is_err());
}
