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
    // The title first: a rename of an untitled chat names it, and a name keeps its title
    // (`meta_replay_a_generated_title_keeps_a_harness_title_and_a_name`).
    for r in [
        rec(1, "titled", json!({"title": "A title"})),
        rec(2, "renamed", json!({"from": "old", "to": "first"})),
        rec(3, "renamed", json!({"from": "first", "to": "second"})),
        rec(4, "tags", json!({"tags": {"lane": "fast", "k": "v"}, "expires": {"k": 99}})),
        rec(5, "policy", json!({"policy": "deny-all"})),
        rec(6, "rules", json!({"rules": {"autoApprove": ["execute"]}})),
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
    let tags = rec(1, "tags", json!({"tags": {"lane": "fast"}, "expires": {}}));
    apply(&mut m, &tags);
    assert_eq!(m.tags["lane"].value, "fast");
    let once = m.clone();
    apply(&mut m, &tags);
    assert_eq!(m, once);
}

/// A `tags` record from before the records carried each tag's expiry is skipped: rebuilt from
/// it, a tag that expires (a trust wait's) would last forever.
#[test]
fn meta_replay_skips_a_tags_record_without_expiry() {
    let mut m = meta();
    m.tags.insert("trust".into(), Tag { value: "wait".into(), expires_at: Some(50) });
    let saved = m.clone();
    apply(&mut m, &rec(1, "tags", json!({"tags": {"trust": "wait", "lane": "fast"}})));
    assert_eq!(m, saved, "an old tags record rebuilt the tags without their expiry");
}

/// A logged generated title does not replace a harness title or the person's name, as the live
/// answer does not (`titles.rs` `apply_generated_title`).
#[test]
fn meta_replay_a_generated_title_keeps_a_harness_title_and_a_name() {
    for kept in [super::super::titles::HARNESS, super::super::titles::NAMED] {
        let mut m = meta();
        m.title = Some("kept".into());
        m.title_source = Some(kept.into());
        apply(&mut m, &rec(1, "titled", json!({"title": "generated"})));
        assert_eq!(m.title.as_deref(), Some("kept"), "{kept}");
        assert_eq!(m.title_source.as_deref(), Some(kept));
    }
    // A title from the first prompt gives way.
    let mut m = meta();
    m.title = Some("the prompt".into());
    m.title_source = Some("prompt".into());
    apply(&mut m, &rec(1, "titled", json!({"title": "generated"})));
    assert_eq!(m.title.as_deref(), Some("generated"));
}
