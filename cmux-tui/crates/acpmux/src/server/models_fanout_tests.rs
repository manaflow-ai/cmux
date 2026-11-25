use super::*;

#[test]
fn a_peers_request_or_a_local_only_one_never_asks_the_peers() {
    assert!(!asks_peers(Origin::Peer, &json!({}), 0));
    for origin in [Origin::Local, Origin::LocalApp, Origin::Web] {
        assert!(!asks_peers(origin, &json!({LOCAL_ONLY: true}), 0));
    }
}

#[test]
fn a_remote_asker_during_a_fan_out_gets_the_local_catalog() {
    assert!(asks_peers(Origin::Web, &json!({}), 0));
    assert!(!asks_peers(Origin::Web, &json!({}), 1));
    // This daemon's own clients are never part of a peer cycle.
    assert!(asks_peers(Origin::Local, &json!({}), 3));
    assert!(asks_peers(Origin::LocalApp, &json!({}), 3));
}
