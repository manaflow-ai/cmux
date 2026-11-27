use super::*;
use crate::config::{Config, StoreMode};
use crate::session_identity::SessionReceipt;
use serde_json::json;

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
