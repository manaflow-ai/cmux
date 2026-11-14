use super::owner;
use crate::server::{ConnAuth, Origin};
use serde_json::json;

#[test]
fn only_the_peer_tokens_own_link_is_the_owner() {
    let plain = json!({"sessionId": "s"});
    let via = |v: &str| json!({"sessionId": "s", "_meta": {"acpmux": {"via": v}}});
    assert!(owner(Origin::Peer, ConnAuth::PeerToken, &plain));
    assert!(owner(Origin::Peer, ConnAuth::PeerToken, &via("app")));
    assert!(!owner(Origin::Peer, ConnAuth::PeerToken, &via("web")));
    assert!(!owner(Origin::Peer, ConnAuth::PeerToken, &via("device")));
    for auth in
        [ConnAuth::Device, ConnAuth::ReadOnlyDevice, ConnAuth::ListenerToken, ConnAuth::None]
    {
        assert!(!owner(Origin::Peer, auth, &plain), "{auth:?}");
        assert!(!owner(Origin::Peer, auth, &via("app")), "{auth:?}");
    }
    for auth in [ConnAuth::ListenerToken, ConnAuth::PeerToken] {
        assert!(!owner(Origin::Web, auth, &plain), "{auth:?}");
    }
}

/// A local chat: a teammate through the carrier (its grant checked before, by the carrier
/// gate) stops it; every other Web or paired-device proof is refused as before.
#[tokio::test]
async fn a_teammate_through_the_carrier_stops_a_local_chat_and_no_other_web_client_does() {
    let dir = std::env::temp_dir();
    let cfg: crate::config::Config = serde_json::from_value(json!({
        "harnesses": {"claude": {"kind": "claude-stdio", "argv": ["claude"]}},
        "defaultHarness": "claude", "store": {"mode": "memory"}
    }))
    .unwrap();
    let store = crate::store::open(&cfg.store, &dir).unwrap();
    let meta: crate::store::SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "local-1", "name": "local-1",
        "harness": "claude", "cwd": dir, "status": "idle", "createdAt": 1, "updatedAt": 1
    }))
    .unwrap();
    store.save(&meta).unwrap();
    let hub = crate::hub::Hub::new(cfg, store);
    let params = json!({"sessionId": "local-1"});
    assert!(!hub.resolve("local-1").unwrap().meta().remote_origin);
    assert!(super::check(&hub, Origin::Web, ConnAuth::CarrierTeam, &params).is_ok());
    for auth in [ConnAuth::ListenerToken, ConnAuth::Device, ConnAuth::ReadOnlyDevice] {
        let e = super::check(&hub, Origin::Web, auth, &params).unwrap_err();
        assert_eq!(e.data.unwrap()["reason"], super::REASON, "{auth:?}");
    }
    let via_web = json!({"sessionId": "local-1", "_meta": {"acpmux": {"via": "web"}}});
    for auth in [ConnAuth::PeerToken, ConnAuth::CarrierOwner] {
        let e = super::check(&hub, Origin::Peer, auth, &via_web).unwrap_err();
        assert_eq!(e.data.unwrap()["reason"], super::REASON, "{auth:?}");
    }
}
