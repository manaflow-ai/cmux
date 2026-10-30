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

#[test]
fn a_session_with_its_whole_capability_list_of_5765_bytes_restores_after_reopen() {
    let capabilities = capabilities_of_at_least(REPORTED_CAPABILITY_BYTES);
    assert!(serde_json::to_string(&capabilities).unwrap().len() >= REPORTED_CAPABILITY_BYTES);
    let root = temp_root("capabilities");
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
    drop(registry);
    let _ = std::fs::remove_dir_all(&root);
}
