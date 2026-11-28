use super::*;
use crate::REMOTE_PROTOCOL_VERSION;

#[test]
fn ours_holds_the_version_this_build_writes() {
    assert!(ProtocolRange::ours().contains(REMOTE_PROTOCOL_VERSION));
    assert!(REMOTE_PROTOCOL_MIN <= REMOTE_PROTOCOL_VERSION);
}

#[test]
fn the_window_keeps_n_minus_1() {
    // Once a version newer than the first ranged one ships, the floor stays at or below the one
    // before it, so the previous build keeps talking to this one.
    if REMOTE_PROTOCOL_VERSION > 5 {
        assert!(REMOTE_PROTOCOL_MIN < REMOTE_PROTOCOL_VERSION);
    }
}

#[test]
fn an_older_peer_still_in_range_speaks_its_version() {
    let ours = ProtocolRange { min: 4, max: 6 };
    assert_eq!(ours.negotiate(ProtocolRange::exactly(5)), Ok(5));
}

#[test]
fn a_newer_peer_that_still_serves_ours_speaks_ours() {
    // N+1 with a floor of N.
    let ours = ProtocolRange { min: 4, max: 5 };
    assert_eq!(ours.negotiate(ProtocolRange::of_peer(6, Some(5))), Ok(5));
}

#[test]
fn a_peer_too_old_is_told_to_update_itself() {
    let ours = ProtocolRange { min: 5, max: 6 };
    let refusal = ours.negotiate(ProtocolRange::exactly(4)).unwrap_err();
    assert_eq!(refusal.code(), "version.incompatible");
    assert_eq!(refusal.update(), UpdateSide::Peer);
    let message = refusal.message("the client", "the relay");
    assert!(message.contains("update the client"), "{message}");
    assert!(message.contains("4") && message.contains("5..=6"), "{message}");
}

#[test]
fn a_peer_too_new_asks_this_side_to_update() {
    let ours = ProtocolRange::exactly(5);
    let refusal = ours.negotiate(ProtocolRange::of_peer(7, Some(6))).unwrap_err();
    assert_eq!(refusal.update(), UpdateSide::This);
    assert!(refusal.message("the daemon", "this client").contains("update this client"));
}

#[test]
fn a_floor_above_the_peers_newest_is_ignored() {
    assert_eq!(ProtocolRange::of_peer(5, Some(9)), ProtocolRange::exactly(5));
    assert_eq!(ProtocolRange::of_peer(6, None), ProtocolRange::exactly(6));
}
