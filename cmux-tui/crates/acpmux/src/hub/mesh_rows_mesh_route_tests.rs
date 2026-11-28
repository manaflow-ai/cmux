use super::*;
use crate::config::{Config, StoreMode};
use crate::session_identity::SessionReceipt;
use serde_json::json;

#[test]
fn mesh_failure_projection_tracks_blocked_turns_and_masks_bounded_refusals() {
    let mut meta: crate::store::SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "child", "name": "child",
        "harness": "fake", "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1,
        "preview": "BLOCKED: cannot create .git"
    }))
    .unwrap();
    for status in [SessionStatus::Idle, SessionStatus::Ready] {
        meta.status = status;
        assert_eq!(mesh_failure_reason(&meta).as_deref(), Some("cannot create .git"));
    }
    for status in [SessionStatus::Running, SessionStatus::Waiting] {
        meta.status = status;
        assert_eq!(mesh_failure_reason(&meta), None, "stale reply while {status}");
    }
    meta.harness_sandbox.failing = true;
    let secret = "https://person:private-password@example.com/repo";
    meta.harness_sandbox.error = Some(format!("{secret} {}", "denied ".repeat(100)));
    let reason = mesh_failure_reason(&meta).unwrap();
    assert_eq!(reason.chars().count(), 512);
    assert!(!reason.contains("private-password"), "{reason}");
    meta.harness_sandbox = Default::default();
    meta.status = SessionStatus::Idle;
    meta.preview = Some("Repository work completed".into());
    assert_eq!(mesh_failure_reason(&meta), None);
}

fn row(peer: &str, id: &str, name: &str) -> RemoteSession {
    RemoteSession {
        peer: peer.into(),
        summary: json!({"sessionId": id, "name": name}).into(),
        receipt: SessionReceipt {
            host_id: peer.into(),
            mux_session_id: id.into(),
            agent_session_id: None,
            generation: 1,
        },
    }
}

/// A name two peers list is ambiguous: it is never sent to the hub to pick one.
#[tokio::test]
async fn a_name_one_or_several_peers_list_never_goes_to_the_mesh_hub() {
    let mut config: Config = serde_json::from_value(json!({})).expect("config");
    config.store.mode = StoreMode::Memory;
    let store =
        crate::store::open(&config.store, std::path::Path::new("/nonexistent")).expect("store");
    let hub = Hub::new(config, store);
    assert!(hub.mesh_may_route("dep-land"));
    hub.remote_sessions.write().insert("p1/s1".into(), row("p1", "s1", "dep-land"));
    assert!(!hub.mesh_may_route("dep-land"), "one peer lists it");
    hub.remote_sessions.write().insert("p2/s2".into(), row("p2", "s2", "dep-land"));
    assert_eq!(hub.remote_matches("dep-land"), 2);
    assert!(hub.resolve_remote("dep-land").is_none(), "ambiguous");
    assert!(!hub.mesh_may_route("dep-land"), "two peers list it");
    assert!(hub.mesh_may_route("other"));
}
