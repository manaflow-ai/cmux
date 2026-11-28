use super::*;

fn on(params: Value) -> Enrollment {
    Enrollment { enabled: true, ..Enrollment::default() }.with(&params).unwrap()
}

#[test]
fn reads_without_fields() {
    assert!(!writes(&json!({})));
    assert!(!writes(&json!({"name": "mini"})));
    assert!(writes(&json!({"enabled": false})));
    assert!(writes(&json!({"hours": null})));
}

#[test]
fn off_always_narrows_on_and_widening_do_not() {
    let off = Enrollment::default();
    let own = on(json!({}));
    assert!(only_narrows(&own, &off));
    assert!(!only_narrows(&off, &own), "turning on lets work in");
    assert!(!only_narrows(&own, &on(json!({"teams": ["t2"]}))), "another team");
    assert!(only_narrows(&on(json!({"teams": ["t2"]})), &own), "dropping a team");
    assert!(!only_narrows(&own, &on(json!({"idleSecs": 60}))), "shorter idle bar");
    assert!(only_narrows(&own, &on(json!({"idleSecs": 900}))), "longer idle bar");
    assert!(only_narrows(&own, &on(json!({"agents": ["claude"]}))), "any agent to one");
    assert!(!only_narrows(&on(json!({"agents": ["claude"]})), &own), "one agent to any");
    assert!(!only_narrows(&own, &on(json!({"hours": {"from": 20, "to": 8}}))), "hours change");
}

#[test]
fn with_replaces_named_fields_and_rejects_bad_types() {
    let e = on(json!({"teams": ["t"], "hours": {"from": 20, "to": 8}, "idleSecs": 120}));
    assert_eq!(e.policy.teams, vec!["t".to_owned()]);
    assert_eq!(e.idle_secs, 120);
    let cleared = e.with(&json!({"hours": null})).unwrap();
    assert_eq!(cleared.policy.hours, None);
    assert_eq!(cleared.policy.teams, e.policy.teams, "unnamed fields stay");
    assert!(e.with(&json!({"enabled": "yes"})).is_err());
    assert!(e.with(&json!({"teams": "t"})).is_err());
    assert!(e.with(&json!({"idleSecs": -1})).is_err());
}

#[test]
fn saved_value_round_trips_and_keeps_policy_when_off() {
    let e = on(json!({"teams": ["t"], "agents": ["codex"], "idleSecs": 300}));
    assert_eq!(Enrollment::from_value(&e.to_value()), e);
    let off = e.with(&json!({"enabled": false})).unwrap();
    let back = Enrollment::from_value(&off.to_value());
    assert!(!back.enabled);
    assert_eq!(back.policy, e.policy, "off keeps the rules for the next on");
    assert_eq!(Enrollment::resolve(Some(&json!(false))), Enrollment::default());
}
