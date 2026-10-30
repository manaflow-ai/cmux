//! A session's registry record holds its whole advertised capability list
//! (P-AUSTIN B7a). A daemon advertised 5,765 bytes of capabilities on
//! 2026-10-29 while `put-session` refused any capabilities JSON over 4,096
//! bytes, so no session was recorded and the next launch could not restore
//! the machines it had connected.

use std::path::PathBuf;

use serde_json::{Value, json};

use super::read_sessions;
use crate::workspace_registry::WorkspaceRegistry;

/// The size of the capability list in the failing report, in bytes of JSON.
const REPORTED_CAPABILITY_BYTES: usize = 5_765;

fn temp_root(label: &str) -> PathBuf {
    std::env::temp_dir()
        .join(format!("cmux-session-record-{label}-{}", crate::workspace_registry::new_uuid_v4()))
}

/// This daemon's own advertised list, grown with tokens of the same shape
/// until it is at least `bytes` long as JSON.
fn capabilities_of_at_least(bytes: usize) -> Value {
    let mut names: Vec<String> =
        crate::server::static_capabilities().into_iter().map(str::to_owned).collect();
    let mut index = 0;
    while serde_json::to_string(&names).unwrap().len() < bytes {
        names.push(format!("restore-size-probe-{index}-v1"));
        index += 1;
    }
    json!(names)
}

/// Removes the test's registry folder also when an assertion fails.
struct RemoveOnDrop(PathBuf);

impl Drop for RemoveOnDrop {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[test]
fn a_session_with_its_whole_capability_list_of_5765_bytes_restores_after_reopen() {
    let capabilities = capabilities_of_at_least(REPORTED_CAPABILITY_BYTES);
    assert!(serde_json::to_string(&capabilities).unwrap().len() >= REPORTED_CAPABILITY_BYTES);
    let root = temp_root("capabilities");
    let _cleanup = RemoveOnDrop(root.clone());
    {
        let mut registry = WorkspaceRegistry::open(&root, "session-record").unwrap();
        let (record, created) = registry
            .put_session(
                "remote-1",
                Some("build-box"),
                Some("main"),
                &json!({"kind":"ssh","host":"build-box"}),
                Some(&capabilities),
                None,
            )
            .expect("put-session records the session's whole capability list");
        assert!(created);
        assert_eq!(record.capabilities.as_ref(), Some(&capabilities));
    }
    let registry = WorkspaceRegistry::open(&root, "session-record").unwrap();
    let sessions = read_sessions(&registry.connection.get()).unwrap();
    let restored = sessions
        .iter()
        .find(|session| session.session_id == "remote-1")
        .expect("the recorded session is in the registry after a reopen");
    assert_eq!(restored.capabilities.as_ref(), Some(&capabilities));
    assert_eq!(restored.transport, json!({"kind":"ssh","host":"build-box"}));
}

/// Unique tokens `cap-<n>-v1`, as many as fit in `bytes` of JSON (or one
/// more when `over`).
fn token_list(bytes: usize, over: bool) -> Value {
    let mut names: Vec<String> = Vec::new();
    let mut index = 0;
    loop {
        names.push(format!("cap-{index:08}-v1"));
        let length = serde_json::to_string(&names).unwrap().len();
        if length > bytes {
            if !over {
                names.pop();
            }
            return json!(names);
        }
        index += 1;
    }
}

#[test]
fn a_session_capability_list_is_bounded_by_the_journal_event_budget() {
    let mut registry = WorkspaceRegistry::in_memory("session-record-bound").unwrap();
    let transport = json!({"kind":"ssh","host":"build-box"});
    let largest = token_list(super::MAX_SESSION_CAPABILITIES_BYTES, false);
    let (record, _) = registry
        .put_session("remote-1", None, None, &transport, Some(&largest), None)
        .expect("a list at the bound is recorded");
    assert_eq!(record.capabilities.as_ref(), Some(&largest));
    let error = registry
        .put_session(
            "remote-2",
            None,
            None,
            &transport,
            Some(&token_list(super::MAX_SESSION_CAPABILITIES_BYTES, true)),
            None,
        )
        .unwrap_err()
        .to_string();
    assert!(error.contains("bad request: capabilities is"), "{error}");
}

#[test]
fn a_session_capability_list_holds_only_unique_capability_tokens() {
    let mut registry = WorkspaceRegistry::in_memory("session-record-tokens").unwrap();
    let transport = json!({"kind":"ssh","host":"build-box"});
    for (capabilities, refusal) in [
        (json!({"profiles-v1": true}), "must be an array of strings"),
        (json!(["profiles-v1", 1]), "must be an array of strings"),
        (json!(["Profiles-v1"]), "must be 1-64"),
        (json!(["profiles v1"]), "must be 1-64"),
        (json!([""]), "must be 1-64"),
        (json!(["a".repeat(65)]), "must be 1-64"),
        (json!(["profiles-v1", "profiles-v1"]), "listed twice"),
    ] {
        let error = registry
            .put_session("remote-1", None, None, &transport, Some(&capabilities), None)
            .unwrap_err()
            .to_string();
        assert!(error.contains(refusal), "{capabilities}: {error}");
    }
}
