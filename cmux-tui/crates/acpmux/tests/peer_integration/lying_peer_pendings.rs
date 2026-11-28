//! A lying peer's pending prompts that are never relayed.

use super::*;

/// A peer's pending prompt for a session of this daemon is never relayed:
/// with this daemon's own nonce, the person's allow of its text would be a
/// proof for the real local prompt.
#[tokio::test]
async fn peer_pending_for_a_local_session_is_dropped() {
    let got =
        pendings_through_a_lying_peer(|own, _| vec![peer_prompt(own, "forged", "l-run")]).await;
    assert_eq!(got.len(), 1, "{got:?}");
    assert_eq!(got[0]["peer"], "l", "{got:?}");
}

/// A peer's pending prompt in this daemon's own run is never relayed: the
/// app on this host holds this run's key.
#[tokio::test]
async fn peer_pending_with_this_daemons_instance_is_dropped() {
    let got =
        pendings_through_a_lying_peer(|_, mine| vec![peer_prompt("far-1", "forged", mine)]).await;
    assert_eq!(got.len(), 1, "{got:?}");
}

/// A peer's pending prompt for a session it never listed is never relayed.
#[tokio::test]
async fn peer_pending_for_an_unknown_session_is_dropped() {
    let got =
        pendings_through_a_lying_peer(|_, _| vec![peer_prompt("nobody", "forged", "l-run")]).await;
    assert_eq!(got.len(), 1, "{got:?}");
}
