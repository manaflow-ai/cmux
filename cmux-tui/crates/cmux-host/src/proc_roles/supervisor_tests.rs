#![cfg(unix)]

use super::*;

/// The app's reader fixture: `LocalServerStatusTests.roles` in
/// Packages/macOS/CmuxNext/Tests/CmuxNextServerTests/LocalServerStatusTests.swift
/// (its first, complete entry). Change both together.
const APP_READER_ROLES_FIXTURE: &str = r#"
{"roles": [
  {"name": "session", "state": "ready", "pid": 41, "restarts": 0, "last_exit": null, "last_error": null, "status_text": "ok"}
]}
"#;

/// The state spellings LocalServerStatus.roleState maps (others read as
/// unavailable in the app).
const APP_READER_STATES: [&str; 8] =
    ["ready", "starting", "backoff", "stopped", "stopping", "exited", "crash-loop", "invalid"];

/// `cmux host roles --json` (the status document) fits the app's reader:
/// the same top-level and entry keys as its fixture, and every state the
/// supervisor can report is one the app maps.
#[test]
fn roles_status_matches_the_app_reader_fixture() {
    use cmux_server_core::role_proc::{RoleHealth, RoleState};
    let fixture: serde_json::Value = serde_json::from_str(APP_READER_ROLES_FIXTURE).unwrap();
    let states = [
        RoleState::Stopped,
        RoleState::Starting,
        RoleState::Ready,
        RoleState::Stopping,
        RoleState::Backoff,
        RoleState::CrashLoop,
        RoleState::Exited,
        RoleState::Invalid,
    ];
    let roles: Vec<RoleHealth> = states
        .iter()
        .map(|state| RoleHealth {
            name: "session".to_owned(),
            state: *state,
            pid: Some(41),
            restarts: 0,
            last_exit: None,
            last_error: None,
            status_text: Some("ok".to_owned()),
        })
        .collect();
    let document = status_document(&roles);
    let keys = |v: &serde_json::Value| {
        v.as_object().unwrap().keys().cloned().collect::<std::collections::BTreeSet<_>>()
    };
    assert_eq!(keys(&document), keys(&fixture));
    let want = keys(&fixture["roles"][0]);
    for entry in document["roles"].as_array().unwrap() {
        assert_eq!(keys(entry), want, "{entry}");
        let state = entry["state"].as_str().unwrap();
        assert!(APP_READER_STATES.contains(&state), "the app does not map state {state}");
    }
    assert_eq!(document["roles"][2], fixture["roles"][0], "a ready role reads like the fixture");
    // The invalid entry of a refused config has the same keys.
    let invalid = status_document(&[RoleHealth::invalid("bad", "reason")]);
    assert_eq!(keys(&invalid["roles"][0]), want);
}
