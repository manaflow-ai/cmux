use super::*;
use serde_json::json;

fn view_of(value: Value) -> Option<Value> {
    let facts: Facts = serde_json::from_value(value).unwrap();
    view(&facts).map(|view| serde_json::to_value(view).unwrap())
}

fn cloud(extra: Value) -> Value {
    let mut base = json!({
        "enabled": true,
        "home": "cloud",
        "shape": {"vcpu": 2.0, "memory_gib": 4.0},
        "plan_ceiling": {"vcpu": 4.0, "memory_gib": 16.0}
    });
    for (key, value) in extra.as_object().unwrap() {
        base[key] = value.clone();
    }
    base
}

#[test]
fn off_by_default_draws_the_old_row() {
    assert_eq!(view_of(json!({})), None);
    assert_eq!(view_of(cloud(json!({"enabled": false}))), None);
}

#[test]
fn the_setting_is_read_flat_or_nested_and_only_true_turns_it_on() {
    assert!(!enabled(&json!({})));
    assert!(enabled(&json!({"cloud.moreRoom": true})));
    assert!(enabled(&json!({"cloud": {"moreRoom": true}})));
    assert!(!enabled(&json!({"cloud.moreRoom": "true"})));
    assert!(!enabled(&json!({"cloud.moreRoom": false, "cloud": {"moreRoom": true}})));
}

#[test]
fn a_cloud_computer_on_auto_reads_its_size_and_offers_one_step_up() {
    assert_eq!(
        view_of(cloud(json!({}))),
        Some(json!({
            "now": {"vcpu": 2.0, "memory_gib": 4.0},
            "more_room": "offered",
            "raises_to": {"vcpu": 8.0, "memory_gib": 32.0}
        }))
    );
}

#[test]
fn asked_once_it_reads_on_and_offers_nothing_more() {
    let shown = view_of(cloud(
        json!({"more_room": true, "plan_ceiling": {"vcpu": 8.0, "memory_gib": 32.0}}),
    ));
    assert_eq!(shown, Some(json!({"now": {"vcpu": 2.0, "memory_gib": 4.0}, "more_room": "on"})));
}

#[test]
fn the_top_step_or_an_unknown_ceiling_offers_nothing() {
    let top = view_of(cloud(json!({"plan_ceiling": {"vcpu": 32.0, "memory_gib": 64.0}})));
    assert_eq!(top.unwrap()["more_room"], "hidden");
    let unknown = view_of(cloud(json!({"plan_ceiling": null})));
    assert_eq!(unknown.unwrap()["more_room"], "hidden");
}

#[test]
fn a_ceiling_between_steps_rises_to_the_next_step() {
    assert_eq!(step_above(Shape { vcpu: 6.0, memory_gib: 24.0 }), Some(PLAN_STEPS[1]));
    assert_eq!(step_above(Shape { vcpu: 8.0, memory_gib: 48.0 }), Some(PLAN_STEPS[2]));
    assert_eq!(step_above(PLAN_STEPS[2]), None);
}

#[test]
fn without_a_cloud_computer_there_is_no_size_and_no_button() {
    let local = view_of(cloud(json!({"home": "this_mac"})));
    assert_eq!(local, Some(json!({"more_room": "hidden"})));
    let unmade = view_of(cloud(json!({"shape": null})));
    assert_eq!(unmade, Some(json!({"more_room": "hidden"})));
}

#[test]
fn a_pin_from_the_cli_reads_as_the_pin_and_offers_nothing() {
    let pinned =
        view_of(cloud(json!({"size": {"mode": "pinned", "vcpu": 8.0, "memory_gib": 16.0}})));
    assert_eq!(
        pinned,
        Some(json!({
            "now": {"vcpu": 2.0, "memory_gib": 4.0},
            "pinned": {"vcpu": 8.0, "memory_gib": 16.0},
            "more_room": "hidden"
        }))
    );
}

#[test]
fn a_spend_pause_reads_the_size_but_offers_no_more_room() {
    for phase in ["paused_spend_cap", "paused_pool_spent"] {
        let paused = view_of(cloud(json!({"phase": phase}))).unwrap();
        assert_eq!(paused["more_room"], "hidden", "{phase}");
        assert_eq!(paused["now"], json!({"vcpu": 2.0, "memory_gib": 4.0}), "{phase}");
    }
    assert_eq!(view_of(cloud(json!({"phase": "sleeping"}))).unwrap()["more_room"], "offered");
}
