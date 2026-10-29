//! The log rebuilds a session's settings (`cargo test -p acpmux meta_replay`).

use serde_json::json;

use super::*;

fn meta() -> SessionMeta {
    serde_json::from_value(json!({
        "schema": "acpmux.session.v1", "id": "s", "name": "old", "harness": "claude",
        "family": "claude", "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 2,
    }))
    .unwrap()
}

fn rec(seq: u64, kind: &str, msg: serde_json::Value) -> EventRecord {
    EventRecord { seq, at: seq, dir: "mux".into(), kind: kind.into(), msg, host_seq: None }
}

#[test]
fn meta_replay_rebuilds_the_settings_in_log_order() {
    let mut m = meta();
    for r in [
        rec(1, "renamed", json!({"from": "old", "to": "first"})),
        rec(2, "renamed", json!({"from": "first", "to": "second"})),
        rec(3, "tags", json!({"tags": {"lane": "fast", "k": "v"}, "expires": {"k": 99}})),
        rec(4, "policy", json!({"policy": "deny-all"})),
        rec(5, "rules", json!({"rules": {"autoApprove": ["execute"]}})),
        rec(6, "titled", json!({"title": "A title"})),
    ] {
        apply(&mut m, &r);
    }
    assert_eq!(m.name, "second");
    assert_eq!(m.tags["lane"], Tag { value: "fast".into(), expires_at: None });
    assert_eq!(m.tags["k"].expires_at, Some(99));
    assert_eq!(m.permission_policy.as_deref(), Some("deny-all"));
    assert_eq!(m.permission_rules, Some(json!({"autoApprove": ["execute"]})));
    assert_eq!(m.title.as_deref(), Some("A title"));
    // Cleared rules come back cleared.
    apply(&mut m, &rec(7, "rules", json!({"rules": null})));
    assert_eq!(m.permission_rules, None);
}

#[test]
fn meta_replay_a_record_the_saved_record_holds_changes_nothing() {
    let mut m = meta();
    apply(&mut m, &rec(1, "tags", json!({"tags": {"lane": "fast"}})));
    let once = m.clone();
    apply(&mut m, &rec(1, "tags", json!({"tags": {"lane": "fast"}})));
    assert_eq!(m, once);
}
