use super::*;

#[test]
fn replay_is_only_what_the_peer_lacks_and_duplicates_drop() {
    let mut log = ReplayLog::<u32, Vec<u8>>::default();
    let mut peer = Cursors::<u32>::default();
    for i in 0..5u8 {
        log.record(7, vec![i; 10], false);
    }
    // The peer got 1..=3; 4 and 5 were lost with the carrier.
    for sequence in 1..=3 {
        assert_eq!(peer.accept(7, sequence, true), Inbound::Deliver);
    }
    let missing = log.resume_from(7, peer.get(7).unwrap());
    assert_eq!(missing.iter().map(|(s, _)| *s).collect::<Vec<_>>(), vec![4, 5]);
    assert_eq!(log.bytes(), 20, "acked bytes are released by the resume");
    // A late copy of 3 is a duplicate; 5 before 4 is a gap.
    assert_eq!(peer.accept(7, 3, true), Inbound::Duplicate);
    assert_eq!(peer.accept(7, 5, true), Inbound::Gap { expected: 4 });
    assert_eq!(peer.accept(7, 4, true), Inbound::Deliver);
    assert_eq!(peer.accept(7, 5, true), Inbound::Deliver);
}

#[test]
fn a_closed_stream_is_forgotten_once_its_last_frame_is_acked() {
    let mut log = ReplayLog::<u32, Vec<u8>>::default();
    log.record(1, vec![0; 4], false);
    let last = log.record(1, vec![0; 2], true);
    assert_eq!(log.ack(1, last - 1), 4);
    assert_eq!(log.streams().count(), 1);
    assert_eq!(log.ack(1, last), 2);
    assert_eq!(log.streams().count(), 0);
    assert_eq!(log.bytes(), 0);
    let mut cursors = Cursors::<u32>::default();
    cursors.open(2);
    cursors.close(2);
    assert_eq!(cursors.accept(2, 1, false), Inbound::Unknown);
}
