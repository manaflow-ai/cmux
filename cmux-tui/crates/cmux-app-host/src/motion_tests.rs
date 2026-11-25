use super::*;

fn canonical(key: &str, value: Value) -> Result<Value, String> {
    normalize_prop(key, &value).expect("a motion prop")
}

#[test]
fn tokens_pass_through() {
    for token in MOTION_TOKENS {
        assert_eq!(canonical("animation", json!(token)), Ok(json!(token)));
    }
    assert!(canonical("animation", json!("wobbly")).is_err());
}

#[test]
fn spring_fills_damping_and_clamps() {
    assert_eq!(
        canonical("animation", json!({"spring": {"response": 0.3}})),
        Ok(json!({"spring": {"response": 0.3, "dampingFraction": 1.0}}))
    );
    assert_eq!(
        canonical("animation", json!({"spring": {"response": 99, "dampingFraction": 0}})),
        Ok(json!({"spring": {"response": 10.0, "dampingFraction": 0.3}}))
    );
    assert!(canonical("animation", json!({"spring": {}})).is_err());
    assert!(canonical("animation", json!({"spring": {"response": 0.3, "mass": 1}})).is_err());
}

#[test]
fn timed_curve_defaults_and_refuses_unknown() {
    assert_eq!(
        canonical("animation", json!({"duration": 0.2})),
        Ok(json!({"duration": 0.2, "curve": "easeOut"}))
    );
    assert_eq!(
        canonical("animation", json!({"duration": 0, "curve": "linear"})),
        Ok(json!({"duration": 0.05, "curve": "linear"}))
    );
    assert!(canonical("animation", json!({"duration": 0.2, "curve": "bezier"})).is_err());
    assert!(canonical("animation", json!({"duration": "fast"})).is_err());
}

#[test]
fn loop_fills_period_and_clamps_amount() {
    assert_eq!(
        canonical("loop", json!({"effect": "pulse"})),
        Ok(json!({"effect": "pulse", "period": 1.2, "amount": 1.0}))
    );
    assert_eq!(
        canonical("loop", json!({"effect": "spin", "period": 1000, "amount": -50})),
        Ok(json!({"effect": "spin", "period": 60.0, "amount": -10.0}))
    );
    assert!(canonical("loop", json!({"effect": "explode"})).is_err());
}

#[test]
fn transitions_are_tokens() {
    for t in TRANSITIONS {
        assert_eq!(canonical("transition", json!(t)), Ok(json!(t)));
    }
    assert!(canonical("transition", json!("zoom")).is_err());
    assert!(canonical("contentTransition", json!({"kind": "opacity"})).is_err());
    assert!(canonical("contentTransition", json!("numericText")).is_ok());
    assert!(normalize_prop("opacity", &json!(1)).is_none());
}

#[test]
fn timed_transitions_canonicalize() {
    assert_eq!(
        canonical("transition", json!({"kind": "slide", "motion": {"duration": 0.3}})),
        Ok(json!({"kind": "slide", "motion": {"duration": 0.3, "curve": "easeOut"}}))
    );
    assert_eq!(
        canonical("transition", json!({"kind": "pop", "motion": {"spring": {"response": 99}}})),
        Ok(
            json!({"kind": "pop", "motion": {"spring": {"response": 10.0, "dampingFraction": 1.0}}})
        )
    );
    assert_eq!(
        canonical("transition", json!({"kind": "scale", "motion": "bouncy"})),
        Ok(json!({"kind": "scale", "motion": "bouncy"}))
    );
    // No motion is the bare kind, so renderers keep today's timing.
    assert_eq!(canonical("transition", json!({"kind": "move"})), Ok(json!("move")));
    assert_eq!(canonical("transition", json!({"kind": "move", "motion": null})), Ok(json!("move")));
    assert!(canonical("transition", json!({"kind": "zoom", "motion": "move"})).is_err());
    assert!(canonical("transition", json!({"motion": "move"})).is_err());
    assert!(canonical("transition", json!({"kind": "slide", "motion": "wobbly"})).is_err());
    assert!(canonical("transition", json!({"kind": "slide", "delay": 1})).is_err());
    assert!(canonical("transition", json!(3)).is_err());
}

#[test]
fn batch_rewrites_in_place_and_keeps_deletes() {
    let mut ops = json!([
        {"op": "create", "id": "a", "type": "Text", "props": {
            "text": "hi", "animation": {"spring": {"response": 0.2}}, "transition": "zoom"}},
        {"op": "update", "id": "b", "props": {"loop": null, "animation": "move"}},
        {"op": "remove", "id": "c"}
    ]);
    let refused = sanitize_scene_ops(&mut ops);
    assert_eq!(refused.len(), 1);
    assert!(refused[0].contains("node a: transition"), "{refused:?}");
    assert_eq!(
        ops[0]["props"]["animation"],
        json!({"spring": {"response": 0.2, "dampingFraction": 1.0}})
    );
    assert_eq!(ops[0]["props"]["transition"], Value::Null);
    assert_eq!(ops[0]["props"]["text"], json!("hi"));
    assert_eq!(ops[1]["props"]["loop"], Value::Null);
    assert_eq!(ops[1]["props"]["animation"], json!("move"));
}

/// The SDK's TypeScript types (js/src/view.ts) list the same vocabulary as these tables.
#[test]
fn typescript_types_match() {
    let view = include_str!("../js/src/view.ts");
    let union = |name: &str| -> Vec<String> {
        let start = view
            .find(&format!("export type {name} ="))
            .unwrap_or_else(|| panic!("{name} in view.ts"));
        let line = &view[start..];
        let line = &line[..line.find('\n').unwrap_or(line.len())];
        line.split('"').skip(1).step_by(2).map(str::to_string).collect()
    };
    let effects: Vec<String> = LOOP_EFFECTS.iter().map(|(e, _)| e.to_string()).collect();
    assert_eq!(union("LoopEffect"), effects);
    assert_eq!(union("Transition"), TRANSITIONS.iter().map(|t| t.to_string()).collect::<Vec<_>>());
    assert!(
        view.contains("export type TimedTransition = { kind: Transition; motion?: Motion | null }"),
        "view.ts types {{kind, motion}} as Transition's timed form"
    );
    let motion_start = view.find("export type Motion =").expect("Motion in view.ts");
    let motion = &view[motion_start
        ..motion_start + view[motion_start..].find("export type Offset").expect("Offset")];
    let tokens: Vec<&str> = motion
        .lines()
        .filter(|l| l.trim_start().starts_with("| \""))
        .flat_map(|l| l.split('"').skip(1).step_by(2))
        .collect();
    assert_eq!(tokens, MOTION_TOKENS);
    for curve in CURVES {
        assert!(motion.contains(&format!("\"{curve}\"")), "{curve} in Motion");
    }
}
