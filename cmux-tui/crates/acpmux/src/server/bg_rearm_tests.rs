use super::*;
use crate::rpc::method;

/// Old vs new, both sides of the handoff (Leo's 12:31Z rule: a versioned message, both sides in
/// one change). An old peer lists no `bgRearm`, so this daemon never forwards it the method
/// (`peer_forward.rs` refuses it `peer_feature_unsupported`) and rebalance holds a session with
/// waits instead of moving it there; a message of a version this daemon does not speak, older or
/// newer, is refused whole and names the one it speaks.
#[test]
fn bg_rearm_is_versioned_and_gated_by_its_peer_feature() {
    assert_eq!(crate::peer::features_gating(method::MUX_BG_REARM), [FEATURE]);
    assert!(speaks(&json!({"version": VERSION, "sessionId": "s"})).is_ok());
    for v in [json!(null), json!(0), json!(VERSION + 1), json!("1")] {
        let e = speaks(&json!({"version": v, "sessionId": "s"})).unwrap_err();
        let data = e.data.clone().unwrap();
        assert_eq!(
            (data["reason"].clone(), data["version"].clone()),
            (json!("bgRearm.version"), json!(VERSION))
        );
    }
    assert!(speaks(&json!({"sessionId": "s"})).is_err(), "an unversioned (pre-v1) message");
    // A new daemon serves and lists it; the session row carries the waits under its capability.
    assert!(crate::capabilities::ids().contains(&crate::capabilities::SESSION_BG_WAITS));
    let ids: Vec<&str> = crate::peer::PEER_FEATURES.iter().map(|f| f.id).collect();
    assert!(ids.contains(&FEATURE));
}
