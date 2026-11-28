use super::*;
use serde_json::json;

#[test]
fn a_client_with_no_list_hears_what_it_always_heard() {
    let features = ClientFeatures::default();
    features.note(&json!({"protocolVersion": 1, "_meta": {"acpmux": {"peerRowBatches": true}}}));
    assert!(!features.listed());
    assert!(features.hears_any(&["peerStateEvents"]));
}

#[test]
fn a_client_that_lists_hears_only_what_it_listed() {
    let features = ClientFeatures::default();
    features.note(&json!({"_meta": {"acpmux": {"features": ["chat-presence-v1"]}}}));
    assert!(features.listed());
    assert!(features.hears_any(&["chat-presence-v1"]));
    assert!(features.hears_any(&["peerStateEvents", "chat-presence-v1"]));
    assert!(!features.hears_any(&["peerStateEvents"]));
    assert!(!features.hears_any(&[UNSENT_FEATURE]));
    // An empty list is a list: nothing gated.
    features.note(&json!({"_meta": {"acpmux": {"features": []}}}));
    assert!(!features.hears_any(&["chat-presence-v1"]));
}

#[test]
fn this_build_lists_every_gate_it_sends() {
    let own = own();
    for id in [
        UNSENT_FEATURE,
        crate::capabilities::SESSION_MESSAGES,
        crate::capabilities::CHAT_PRESENCE,
        crate::capabilities::CONNECTIONS_EVENTS,
        crate::peer_states::STATE_EVENTS_FEATURE,
        "peer-state-events-v1",
        "start-mode-v1",
        "harnessInventoryWatch",
    ] {
        assert!(own.contains(&id), "{id} not in this build's own list");
    }
}

/// Every gate a send site names is an id this daemon defines, so a typo never silently stops a
/// notification for a client that lists its features.
#[test]
fn every_gate_names_a_defined_id() {
    let capabilities = crate::capabilities::ids();
    let features: Vec<&str> = crate::peer::PEER_FEATURES.iter().map(|f| f.id).collect();
    for id in ["peer-state-events-v1", "start-mode-v1", "chat-presence-v1", "connections-events-v1"]
    {
        assert!(capabilities.contains(&id), "{id}");
    }
    for id in [UNSENT_FEATURE, "harnessInventoryWatch", "harnessInventory", "peerStateEvents"] {
        assert!(features.contains(&id), "{id}");
    }
}

/// A peer's method a feature gates is found by its name, and one no feature gates is not.
#[test]
fn a_gated_method_names_its_features() {
    use crate::rpc::method;
    assert_eq!(crate::peer::features_gating(method::MUX_PAUSE), vec![crate::hub::pause::FEATURE]);
    assert_eq!(crate::peer::features_gating(method::MUX_UNSENT), vec![UNSENT_FEATURE]);
    assert!(crate::peer::features_gating("_acpmux/controls").contains(&"linkControls"));
    assert!(crate::peer::features_gating(method::MUX_INFO).is_empty());
    let mut put_status = crate::peer::features_gating(method::MUX_FILE_PUT_STATUS);
    put_status.sort_unstable();
    assert_eq!(put_status.len(), 2);
}

#[test]
fn new_presence_notifications_require_explicit_negotiation() {
    let features = ClientFeatures::default();
    let id = crate::hub::presence::PEER_FEATURE;
    assert!(!features.lists(id));
    features.note(&json!({"_meta": {"acpmux": {"features": []}}}));
    assert!(!features.lists(id));
    features.note(&json!({"_meta": {"acpmux": {"features": [id]}}}));
    assert!(features.lists(id));
}
