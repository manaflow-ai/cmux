//! Pins the Swift these rules replaced (`AgentPaneCloudRepick.init?(params:)`,
//! `AgentPaneHandOff.refusedHere`, `AgentPaneCloudStart.progress`/`fields`,
//! `CloudMachineSession.confirmedCredentialHarnesses`) and their Swift tests.

use serde_json::json;

use super::*;

#[test]
fn a_repick_names_a_machine_or_a_name() {
    let machine = repick(&json!({"machine": "m_zesty"}));
    assert_eq!(machine, Some(Repick { machine: Some("m_zesty".into()), name: None }));
    let name = repick(&json!({"name": "zesty-indigo-lemur"}));
    assert_eq!(name, Some(Repick { machine: None, name: Some("zesty-indigo-lemur".into()) }));
    let both = repick(&json!({"machine": "m", "name": "n"}));
    assert_eq!(both, Some(Repick { machine: Some("m".into()), name: Some("n".into()) }));
}

#[test]
fn a_repick_refuses_anything_else() {
    let long = "a".repeat(129);
    for bad in [
        json!({}),
        Value::Null,
        json!([]),
        json!({"machine": ""}),
        json!({"name": 3}),
        json!({"name": null}),
        json!({"machine": "a", "other": "b"}),
        json!({"name": "a\nb"}),
        json!({"name": "a\u{7f}"}),
        json!({"name": "café"}),
        json!({"machine": long}),
    ] {
        assert_eq!(repick(&bad), None, "{bad}");
    }
    assert!(repick(&json!({"machine": "a".repeat(128)})).is_some());
}

#[test]
fn refused_here_is_the_panes_own_codes_and_transport() {
    for code in REFUSED_HERE {
        assert_eq!(refused_here(Some(false), Some(code)).as_deref(), Some(code));
    }
    let outside = refused_here(Some(false), Some("transport.path_outside_roots"));
    assert_eq!(outside.as_deref(), Some("transport.path_outside_roots"));
    // The App's own failure, a success, or a reply with no code.
    assert_eq!(refused_here(Some(false), Some("cloud_clone_failed")), None);
    assert_eq!(refused_here(Some(true), Some("unsupported")), None);
    assert_eq!(refused_here(None, Some("unsupported")), None);
    assert_eq!(refused_here(Some(false), None), None);
}

#[test]
fn the_clone_row_fields_match_the_pages_names() {
    let seed = SeedProgress {
        phase: "copy".into(),
        bytes_done: Some(3),
        bytes_total: Some(4),
        files_done: Some(1),
        files_total: Some(2),
        fallback_code: Some("seed.needs_github".into()),
        install_url: Some("https://x.test".into()),
        ..SeedProgress::default()
    };
    let fields = Value::Object(seed_fields(&seed));
    let progress =
        json!({"received_bytes": 3, "bytes_total": 4, "files_done": 1, "files_total": 2});
    let expected = json!({"progress": progress, "fallback": "seed.needs_github", "install_url": "https://x.test"});
    assert_eq!(fields, expected);
    let bare = seed_fields(&SeedProgress { phase: "clone".into(), ..SeedProgress::default() });
    assert!(bare.is_empty(), "no counts: no progress");
}

#[test]
fn the_app_s_seed_progress_decodes() {
    let text = r#"{"phase":"clone","bytesDone":5,"objectsTotal":9,"installURL":"https://i.test"}"#;
    let seed: SeedProgress = serde_json::from_str(text).expect("decodes");
    assert_eq!(seed.bytes_done, Some(5));
    assert_eq!(seed.objects_total, Some(9));
    assert_eq!(seed.install_url.as_deref(), Some("https://i.test"));
    let fields = Value::Object(seed_fields(&seed));
    let expected = json!({"progress": {"received_bytes": 5, "total_objects": 9}, "install_url": "https://i.test"});
    assert_eq!(fields, expected);
}

#[test]
fn a_bare_push_is_its_key_and_step() {
    let facts = Progress { key: "k".into(), step: "machine".into(), ..Progress::default() };
    assert_eq!(progress(&facts), json!({"key": "k", "step": "machine"}));
    // Nothing left on this Mac is no clone field.
    let left = Progress {
        key: "k".into(),
        step: "folder".into(),
        left_on_mac: Some(0),
        ..Progress::default()
    };
    assert_eq!(progress(&left), json!({"key": "k", "step": "folder"}));
}

#[test]
fn a_full_push_nests_the_clone_and_setup_rows() {
    let facts: Progress = serde_json::from_value(json!({
        "key": "k", "step": "folder", "folder": "/p", "machine": "m", "size": "large",
        "cloneState": "running", "clonePhase": "copy", "cloneStartedAt": 1.5, "cloneFinishedAt": 2.0,
        "cloneProgress": {"phase": "copy", "filesDone": 1, "fallbackCode": "seed.needs_github"},
        "leftOnMac": 7, "environmentId": "env_1",
        "setupState": "running", "setupStatus": "installing", "setupStartedAt": 3.0, "setupFinishedAt": 4.25,
        "setupError": "boom", "setupHasScript": true
    }))
    .expect("decodes");
    let expected = json!({
        "key": "k", "step": "folder", "folder": "/p", "machine": "m", "size": "large",
        "clone": {
            "state": "running", "phase": "copy", "startedAt": 1.5, "finishedAt": 2.0,
            "progress": {"files_done": 1}, "fallback": "seed.needs_github", "left_on_mac": 7
        },
        "environmentId": "env_1",
        "setup": {
            "state": "running", "status": "installing", "startedAt": 3.0, "finishedAt": 4.25,
            "error": "boom", "hasScript": true
        }
    });
    assert_eq!(progress(&facts), expected);
}

#[test]
fn credential_harnesses_need_the_capability_and_a_subscription_for_most() {
    let caps: Vec<String> = ["gemini", "opencode", "grok"]
        .iter()
        .map(|harness| format!("{ENDPOINT_HARNESS_PREFIX}{harness}"))
        .chain(["something-else".to_owned()])
        .collect();
    assert_eq!(credential_harnesses(false, &caps, true), None);
    assert_eq!(credential_harnesses(false, &caps, false), None);
    let key: Vec<_> =
        credential_harnesses(true, &caps, false).expect("supported").into_iter().collect();
    assert_eq!(key, ["gemini", "grok"]);
    let subscription: Vec<_> =
        credential_harnesses(true, &caps, true).expect("supported").into_iter().collect();
    assert_eq!(subscription, ["gemini", "grok", "opencode"]);
    assert_eq!(credential_harnesses(true, &[], true), Some(BTreeSet::new()));
}
