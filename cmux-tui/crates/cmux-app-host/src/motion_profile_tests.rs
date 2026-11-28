use super::*;

fn parse(value: Value) -> (MotionProfile, Vec<Problem>) {
    MotionProfile::parse(&value)
}

#[test]
fn a_block_parses_into_presets_springs_and_fades() {
    let (profile, problems) = parse(json!({
        "presets": { "drawer": { "duration": 0.32, "bounce": 0.1 } },
        "springs": { "move": { "duration": 0.2 } },
        "fades": { "fadeIn": 0.16 },
    }));
    assert!(problems.is_empty(), "{problems:?}");
    assert_eq!(profile.presets["drawer"], SpringSpec { duration: 0.32, bounce: 0.1 });
    assert_eq!(profile.springs["move"], SpringSpec { duration: 0.2, bounce: 0.0 });
    assert_eq!(profile.fades["fadeIn"], 0.16);
}

#[test]
fn duration_and_bounce_convert_to_response_and_damping_fraction() {
    let spec = SpringSpec::new(0.3, 0.25);
    assert_eq!(spec.response(), 0.3);
    assert_eq!(spec.damping_fraction(), 0.75);
    assert_eq!(SpringSpec::new(0.15, 0.0).damping_fraction(), 1.0, "bounce 0 is critical");
}

#[test]
fn numbers_clamp_to_the_motion_contract() {
    let (profile, problems) = parse(json!({
        "presets": { "slow": { "duration": 99, "bounce": 2 }, "fast": { "duration": 0, "bounce": -1 } },
        "fades": { "hover": 0 },
    }));
    assert!(problems.is_empty(), "{problems:?}");
    assert_eq!(
        profile.presets["slow"],
        SpringSpec { duration: TIME_RANGE.1, bounce: BOUNCE_RANGE.1 }
    );
    assert_eq!(profile.presets["fast"], SpringSpec { duration: TIME_RANGE.0, bounce: 0.0 });
    assert!((profile.presets["slow"].damping_fraction() - DAMPING_RANGE.0).abs() < 1e-12);
    assert_eq!(profile.fades["hover"], TIME_RANGE.0);
}

#[test]
fn a_bad_entry_is_left_out_and_named_the_rest_apply() {
    let (profile, problems) = parse(json!({
        "presets": { "smooth": { "duration": 0.2 }, "9lives": { "duration": 0.2 }, "ok": { "duration": 0.2 } },
        "springs": { "move": { "response": 0.2 }, "appear": "fast", "panel": {}, "zoom": { "duration": 0.4 } },
        "fades": { "fadeIn": "slow", "fadeOut": 0.1 },
        "loops": {},
    }));
    let paths: Vec<&str> = problems.iter().map(|p| p.path.as_str()).collect();
    assert_eq!(
        paths,
        [
            "motion.loops",
            "motion.presets.9lives",
            "motion.presets.smooth",
            "motion.springs.appear",
            "motion.springs.move.response",
            "motion.springs.panel",
            "motion.fades.fadeIn",
        ]
    );
    assert_eq!(profile.presets.keys().collect::<Vec<_>>(), ["ok"]);
    assert_eq!(profile.springs.keys().collect::<Vec<_>>(), ["zoom"]);
    assert_eq!(profile.fades.keys().collect::<Vec<_>>(), ["fadeOut"]);
}

#[test]
fn no_block_or_an_empty_one_overrides_nothing() {
    assert!(MotionProfile::default().is_empty());
    let (profile, problems) = parse(json!({}));
    assert!(profile.is_empty() && problems.is_empty());
    let (profile, problems) = parse(json!("bouncy"));
    assert!(profile.is_empty());
    assert_eq!(problems[0].path, "motion");
}

#[test]
fn presets_are_capped() {
    let presets: Map<String, Value> =
        (0..MAX_PRESETS + 3).map(|i| (format!("p{i:03}"), json!({ "duration": 0.2 }))).collect();
    let (profile, problems) = parse(json!({ "presets": presets }));
    assert_eq!(profile.presets.len(), MAX_PRESETS);
    assert_eq!(problems.len(), 3);
}

#[test]
fn a_preset_is_a_motion_contract_spring() {
    let (profile, _) =
        parse(json!({ "presets": { "drawer": { "duration": 0.32, "bounce": 0.1 } } }));
    let animation = profile.preset_animation("drawer").expect("preset");
    let motion = crate::motion::Motion::parse(&animation).expect("a cmux.motion/1 value");
    assert_eq!(motion, crate::motion::Motion::Spring { response: 0.32, damping_fraction: 0.9 });
    assert!(profile.preset_animation("nope").is_none());
}

#[test]
fn the_canonical_json_round_trips() {
    let (profile, _) = parse(json!({
        "presets": { "drawer": { "duration": 0.32, "bounce": 0.1 } },
        "fades": { "fadeIn": 0.16 },
    }));
    let canonical = profile.to_json();
    assert_eq!(canonical["presets"]["drawer"]["dampingFraction"], json!(0.9));
    let mut again = canonical.clone();
    for spec in again["presets"].as_object_mut().into_iter().flat_map(|m| m.values_mut()) {
        let spec = spec.as_object_mut().expect("object");
        spec.remove("response");
        spec.remove("dampingFraction");
    }
    assert_eq!(MotionProfile::parse(&again).0, profile);
}
