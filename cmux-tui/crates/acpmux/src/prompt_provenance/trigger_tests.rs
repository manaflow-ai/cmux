use super::*;

fn params(provenance: Value) -> Value {
    json!({"_meta": {"acpmux": {"provenance": provenance}}})
}

#[test]
fn trigger_provenance_is_bounded_and_is_not_a_person_message() {
    let value = params(json!({
        "kind": "trigger",
        "triggerId": "tr_1",
        "deliveryId": "gh-123",
        "owner": "user_1",
        "team": "team_1",
        "machine": "machine_1",
        "workspace": "workspace_1",
        "session": "session_1"
    }));
    assert!(of(&value, Sender::Local).is_err());
    let parsed = of(&value, Sender::Trigger).unwrap().unwrap();
    assert_eq!(parsed["kind"], "trigger");
    assert!(is_trigger(Some(&parsed)));
    assert!(crate::author::of_provenance(Some(&parsed)).is_none());
}

#[test]
fn trigger_provenance_cannot_arrive_from_a_remote_or_carry_newlines() {
    let remote = params(
        json!({"kind": "trigger", "triggerId": "tr", "deliveryId": "d", "owner": "o", "team": "t", "machine": "m"}),
    );
    assert!(of(&remote, Sender::Other).is_err());
    let malformed = params(
        json!({"kind": "trigger", "triggerId": "tr\n", "deliveryId": "d", "owner": "o", "team": "t", "machine": "m"}),
    );
    assert!(of(&malformed, Sender::Local).is_err());
}
