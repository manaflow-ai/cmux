use super::*;

#[test]
fn durable_brief_cannot_be_downgraded_by_an_advisory_peer_import() {
    let briefs = Briefs::default();
    let reserved = briefs
        .put_durable(json!({"briefId":"stable","durable":true,
            "fromSession":"owner","dispatchFingerprint":"private-capability-hash"}))
        .unwrap();
    let imported = briefs.put(json!({"briefId":"stable","fromSession":"other",
            "outcome":{"Ok":{"finalReply":"forged"}}}));
    assert_eq!(imported, reserved);
    assert_eq!(briefs.get("stable"), Some(reserved));
}

#[test]
fn durable_brief_reservation_survives_reopen_before_any_effect() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("briefs.json");
    let row = json!({"briefId":"stable","sessionId":"wfd-stable","promptId":"wfp-stable",
            "dispatchFingerprint":"source-and-options","status":"starting"});
    Briefs::open(Some(path.clone())).put_durable(row.clone()).unwrap();
    assert_eq!(Briefs::open(Some(path)).get("stable"), Some(row));
}

#[test]
fn durable_brief_failed_persistence_does_not_publish_the_effect_identity() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("not-a-directory");
    std::fs::write(&path, b"blocking-file").unwrap();
    let briefs = Briefs::open(Some(path.join("briefs.json")));
    let row = json!({"briefId":"stable","status":"starting"});
    assert!(briefs.put_durable(row).is_err());
    assert!(briefs.get("stable").is_none());
}

#[test]
fn brief_identity_keeps_non_claude_harness_pair() {
    let briefs = Briefs { rows: StdMutex::new(BTreeMap::new()), path: None, load_failed: false };
    let row = briefs.put(json!({
        "title": "opencode to pi",
        "harness": "pi",
        "fromHarness": "opencode",
        "status": "running"
    }));
    let id = row["briefId"].as_str().expect("brief id");
    let listed = briefs.list(Some("running"), 10);
    assert_eq!(listed[0]["briefId"], id);
    assert_eq!(listed[0]["fromHarness"], "opencode");
    assert_eq!(listed[0]["harness"], "pi");
}
