//! A request that may go only to a peer that listed a feature is sent on the link that listed it
//! (`Peer::lists_on`): after a reconnect to an older build it fails instead of reaching that build
//! (review of #26747: a held prompt checked against a peer that holds it, then sent to a
//! reconnected one that would run it unapproved).

use super::*;

fn listing(peer: &Peer, features: &[&str]) {
    *peer.features.lock_or_recover() = features.iter().map(|f| (*f).to_owned()).collect();
}

#[tokio::test]
async fn a_request_bound_to_a_feature_never_goes_to_a_reconnected_link_without_it() {
    let (tx, _rx) = mpsc::channel(8);
    let peer = Peer::new("p", "ws://127.0.0.1:9", None, None, tx);
    peer.connected.store(true, Ordering::SeqCst);
    let feature = crate::author::QUEUE_APPROVAL_FEATURE;
    listing(&peer, &["trustGate", feature]);
    let on = peer.lists_on(feature).expect("link A lists it");

    // Link A ends: the list goes with it, and until the next handshake nothing is listed.
    peer.link_ended();
    assert_eq!(peer.lists_on(feature), None, "a link that ended still lists it");
    // Link B is an older build.
    listing(&peer, &["trustGate"]);
    assert_eq!(peer.lists_on(feature), None);

    let sent = tokio::time::timeout(
        std::time::Duration::from_secs(5),
        peer.request_on(method::SESSION_PROMPT, json!({"sessionId": "far-1"}), Some(on)),
    )
    .await
    .expect("a request on an ended link fails at once");
    assert!(sent.is_err(), "the held prompt went out on the reconnected link: {sent:?}");
    assert_eq!(peer.pending_requests().await, 0, "no entry left behind");
}
