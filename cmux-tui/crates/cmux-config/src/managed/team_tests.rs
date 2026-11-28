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
