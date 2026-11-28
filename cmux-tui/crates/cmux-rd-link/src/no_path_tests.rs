use super::*;

#[test]
fn host_candidates_only_and_nothing_heard_says_there_is_no_path_and_no_relay() {
    // The viewer's side of the measured failure: 4 host candidates each, nothing heard.
    let why = handshake_timeout([4, 0, 0], [4, 0, 0], 0);
    assert!(why.starts_with("no network path between the two machines"), "{why}");
    assert!(why.contains("public address (STUN)"), "{why}");
    assert!(why.contains("relay (TURN) server"), "{why}");
    assert!(why.ends_with(
        "(the secure handshake timed out; local host 4 srflx 0 relay 0; \
             peer host 4 srflx 0 relay 0; heard 0)"
    ));
}

#[test]
fn heard_but_not_answered_says_one_way() {
    // The host's side: it heard the viewer 39 times, the viewer heard nothing.
    let why = handshake_timeout([4, 0, 0], [4, 0, 0], 39);
    assert!(why.contains("one way only"), "{why}");
    assert!(why.contains("heard 39)"), "{why}");
}

#[test]
fn names_the_missing_relay_or_the_failed_one() {
    assert!(
        handshake_timeout([4, 1, 0], [4, 1, 0], 0).contains("no relay (TURN) server was offered")
    );
    assert!(
        handshake_timeout([4, 1, 1], [4, 1, 0], 0).contains("relay (TURN) path did not connect")
    );
}
