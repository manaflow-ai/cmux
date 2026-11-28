use super::*;
use serde_json::json;

fn derived(features: Value) -> (BTreeMap<String, Value>, BTreeMap<String, Value>) {
    let features: BTreeMap<String, Value> =
        features.as_object().unwrap().iter().map(|(k, v)| (k.clone(), v.clone())).collect();
    let (mut defaults, mut enforced) = (BTreeMap::new(), BTreeMap::new());
    settings_from_features(&features, &mut defaults, &mut enforced);
    (defaults, enforced)
}

#[test]
fn sandbox_required_forces_seatbelt_and_on_only_defaults_it() {
    let (defaults, enforced) =
        derived(json!({"sandbox.local": {"value": "required", "mode": "enforced"}}));
    assert_eq!(enforced.get("sessions.sandbox"), Some(&json!(true)));
    assert!(defaults.is_empty());
    let (defaults, enforced) = derived(json!({"sandbox.local": "on"}));
    assert_eq!(defaults.get("sessions.sandbox"), Some(&json!(true)));
    assert!(enforced.is_empty());
}

#[test]
fn agent_lists_fill_the_lockdown_lists_without_turning_lockdown_on() {
    let (_, enforced) = derived(json!({
        "agents.harnesses": {"value": ["claude", "codex"], "mode": "enforced"},
        "agents.models": {"value": ["claude-opus-*", "gpt-5"], "mode": "enforced"},
    }));
    assert_eq!(enforced.get("sessions.lockdownHarnesses"), Some(&json!("claude, codex")));
    assert_eq!(enforced.get("sessions.lockdownModels"), Some(&json!("claude-opus-, gpt-5")));
    assert_eq!(enforced.get("sessions.lockdown"), None);
}

#[test]
fn a_team_that_set_no_keys_changes_nothing() {
    let (defaults, enforced) = derived(json!({"agents.harnesses": {"value": []}}));
    assert!(defaults.is_empty() && enforced.is_empty());
}

#[test]
fn features_survive_the_saved_layer_round_trip() {
    let doc = json!({
        "managed": true,
        "team": "t1",
        "team_name": "Acme",
        "version": 3,
        "defaults": {},
        "enforced": {},
        "features": {"projection.syncBack": {"value": false, "mode": "enforced"}},
    });
    let layer = TeamPolicyLayer::from_device_policy(&doc, Schema::embedded()).unwrap();
    assert_eq!(feature_value(&layer.features, "projection.syncBack"), Some(json!(false)));
    let again =
        TeamPolicyLayer::from_device_policy(&layer.to_device_policy(), Schema::embedded()).unwrap();
    assert_eq!(again.features, layer.features);
}

mod owner_op_tests {
    use super::*;

    fn args(op: &str) -> serde_json::Map<String, Value> {
        json!({"route": "read", "body": {"op": op, "params": {}}}).as_object().unwrap().clone()
    }

    fn managed() -> Value {
        json!({"status": 200, "reply": {"ok": true, "value": {
            "managed": true, "team": "t-1", "team_name": "Acme", "version": 3,
            "defaults": {}, "enforced": {"browser.searchEngine": "duckduckgo"}}}})
    }

    #[test]
    fn a_managed_read_is_the_layer() {
        let layer = TeamPolicyLayer::from_owner_op(
            &args("team.device.policy"),
            &managed(),
            Schema::embedded(),
        )
        .unwrap();
        assert_eq!(layer.team_id, "t-1");
        assert_eq!(layer.version, 3);
        assert_eq!(layer.enforced.get("browser.searchEngine"), Some(&json!("duckduckgo")));
    }

    #[test]
    fn an_unmanaged_read_clears_the_layer() {
        let answer = json!({"status": 200, "reply": {"ok": true, "value": {"managed": false}}});
        let layer = TeamPolicyLayer::from_owner_op(
            &args("team.device.policy"),
            &answer,
            Schema::embedded(),
        );
        assert_eq!(layer, Some(TeamPolicyLayer::default()));
    }

    #[test]
    fn the_body_as_json_text_counts() {
        let args =
            json!({"route": "read", "body_json": r#"{"op":"team.device.policy","params":{}}"#});
        let layer = TeamPolicyLayer::from_owner_op(
            args.as_object().unwrap(),
            &managed(),
            Schema::embedded(),
        );
        assert_eq!(layer.map(|l| l.team_id), Some("t-1".into()));
    }

    #[test]
    fn other_calls_and_refusals_change_nothing() {
        let schema = Schema::embedded();
        assert_eq!(TeamPolicyLayer::from_owner_op(&args("feed.list"), &managed(), schema), None);
        let mut ops = args("team.device.policy");
        ops.insert("route".into(), json!("ops"));
        assert_eq!(TeamPolicyLayer::from_owner_op(&ops, &managed(), schema), None);
        for answer in [
            json!({"status": 401, "reply": null}),
            json!({"status": 200, "reply": {"error": {"code": "forbidden", "message": "no"}}}),
            json!({"status": 200, "reply": {"ok": false, "value": {"managed": false}}}),
            json!({"status": 200, "reply": {"ok": true}}),
        ] {
            let read = TeamPolicyLayer::from_owner_op(&args("team.device.policy"), &answer, schema);
            assert_eq!(read, None, "{answer}");
        }
    }
}
