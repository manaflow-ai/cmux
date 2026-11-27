//! A settings read never carries a secret policy value (#21017: `settings.*`
//! reads are "deterministic and redact secret values"). `SECRET_POLICY_KEYS`
//! names the forced policy keys whose values never leave the owner; the
//! cold-start cache has always shown them as present only, and the
//! `settings.snapshot` reply, which every socket client may ask for, holds
//! itself to the same rule.

use std::collections::BTreeMap;

use cmux_config::managed::SECRET_POLICY_KEYS;
use cmux_config::{Domains, FileRead, ManagedPreferences, Schema, State, TeamPolicyLayer};
use serde_json::{Value, json};

/// The forced `EnrollmentToken` an MDM profile sets.
const TOKEN: &str = "enroll-secret-9f3c1d7b";

/// A state whose MDM profile forces a secret policy key and one setting.
fn managed_state() -> State {
    let forced: BTreeMap<String, Value> = BTreeMap::from([
        ("EnrollmentToken".to_string(), json!(TOKEN)),
        ("ManagedTeam".to_string(), json!("Manaflow")),
    ]);
    let managed = ManagedPreferences { forced, recommended: BTreeMap::new() };
    State::new(
        Schema::embedded(),
        FileRead::Text(String::new()),
        managed,
        TeamPolicyLayer::default(),
        Domains::default(),
        1,
    )
}

#[test]
fn the_settings_snapshot_shows_a_secret_policy_value_as_present_only() {
    let snapshot = managed_state().snapshot().to_json();
    let policy = &snapshot["policy"];
    assert_eq!(policy["EnrollmentToken"], json!("<set>"), "{policy}");
    assert_eq!(
        policy["ManagedTeam"],
        json!("Manaflow"),
        "a policy key that is not secret is shown"
    );
}

#[test]
fn no_settings_read_carries_a_secret_policy_value() {
    let state = managed_state();
    let reads = [
        ("settings.snapshot", state.snapshot().to_json()),
        ("settings.list", Value::Array(state.list(None).iter().map(|row| row.to_json()).collect())),
    ];
    for (name, read) in reads {
        let text = serde_json::to_string(&read).expect("serialises");
        assert!(!text.contains(TOKEN), "{name} carries the forced EnrollmentToken: {text}");
    }
}

#[test]
fn the_cold_start_cache_shows_a_secret_policy_value_as_present_only() {
    let document = cmux_config::cache::cache_document(&managed_state());
    assert_eq!(document["policy"]["EnrollmentToken"], json!("<set>"), "{document}");
}

#[test]
fn every_secret_policy_key_is_a_policy_key_the_reader_honors() {
    for key in SECRET_POLICY_KEYS {
        assert!(
            cmux_config::managed::POLICY_KEYS.iter().any(|policy| policy.name == key),
            "{key} is not a policy key, so no read ever shows it"
        );
    }
}
