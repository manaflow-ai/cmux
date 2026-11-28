use super::*;

#[test]
fn workflow_placement_rejects_present_non_string_and_remote_without_local_fallback() {
    for options in [Value::Null, json!([]), json!("local"), json!(true), json!(7)] {
        for kind in ["agent", "machine"] {
            assert!(validate_placement(kind, &options).is_err());
        }
    }
    for on in [
        json!(["ci"]),
        Value::Null,
        json!(true),
        json!(7),
        json!({"host":"ci"}),
        json!("remote-ci"),
    ] {
        assert!(validate_placement("machine", &json!({"on":on})).is_err());
    }
    assert!(validate_placement("machine", &json!({})).is_ok());
    assert!(validate_placement("machine", &json!({"on":"local"})).is_ok());
    assert!(validate_placement("machine", &json!({"on":"ci"})).is_ok());
    assert!(validate_placement("agent", &json!({"on":"paired-machine"})).is_ok());
    assert!(validate_placement("agent", &json!({"on":["ci"]})).is_err());
}

#[test]
fn workflow_activity_identity_accepts_transport_hash_and_safe_registered_legacy() {
    let generated =
        crate::workflow_runs::digest("01912345-1234-7123-8123-123456789abc:18446744073709551615");
    assert!(validate_activity_id(&generated, false).is_ok());
    for id in ["test", "test-lint", "legacy_1"] {
        assert!(validate_activity_id(id, false).is_ok());
    }
    for id in ["", "../test", "a:b", "bad/name", "has space", "nonascii-λ", "line\nfeed"] {
        assert!(validate_activity_id(id, false).is_err());
        assert!(validate_activity_id(id, true).is_err());
    }
    let legacy = format!("legacy-{}", generated);
    assert!(validate_activity_id(&legacy, false).is_err());
    assert!(
        validate_activity_id(&legacy, true).is_ok(),
        "existing safe journal records stay addressable"
    );
}
