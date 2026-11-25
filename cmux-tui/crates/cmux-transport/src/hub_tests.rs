use super::*;

const SESSION: [u8; 16] = [0x5e; 16];

fn key() -> HubKey {
    HubKey::derive(&[7; 32], &SESSION)
}

fn header(source: HubRole, epoch: u64, seq: u64) -> HubHeader {
    HubHeader { session: SESSION, pos: HubPos::new(epoch, seq), source, to: HubTo::Viewers }
}

#[test]
fn header_round_trips_and_checks_in_order() {
    let h = HubHeader { to: HubTo::Source(HubRole::Vm), ..header(HubRole::Mac, 3, 9) };
    let bytes = h.encode();
    assert_eq!(bytes.len(), HUB_HEADER_LEN);
    assert_eq!(HubHeader::decode(&bytes), Ok(h));
    assert_eq!(HubHeader::decode(&bytes[..34]), Err(HubHeaderError::Short));
    let mut bad = bytes;
    bad[0] = 2;
    assert_eq!(HubHeader::decode(&bad), Err(HubHeaderError::Version(2)));
    let mut bad = bytes;
    bad[33] = 3;
    assert_eq!(HubHeader::decode(&bad), Err(HubHeaderError::Role(3)));
    let mut bad = bytes;
    bad[34] = 1; // the Mac sending to itself
    assert_eq!(HubHeader::decode(&bad), Err(HubHeaderError::To(1)));
    bad[34] = 9;
    assert_eq!(HubHeader::decode(&bad), Err(HubHeaderError::To(9)));
}

#[test]
fn seal_opens_with_the_key_and_carries_the_inner_triple() {
    let h = header(HubRole::Vm, 1, 42);
    let payload = seal(&key(), &h, b"token").unwrap();
    assert_eq!(payload.len(), HUB_HEADER_LEN + HUB_INNER_LEN + 5 + HUB_TAG_LEN);
    let opened = open(&key(), &payload).unwrap();
    assert_eq!(opened.header, h);
    assert_eq!(
        (opened.inner_session, opened.inner_pos, opened.inner_source),
        (SESSION, h.pos, HubRole::Vm)
    );
    assert_eq!(opened.event, b"token");
    // A relay holds no key: another session's key opens nothing.
    let other = HubKey::derive(&[7; 32], &[1; 16]);
    assert_eq!(open(&other, &payload), Err(HubOpenError::Seal));
}

#[test]
fn a_relay_that_edits_any_header_byte_is_caught() {
    let payload = seal(&key(), &header(HubRole::Mac, 1, 5), b"hello").unwrap();
    for index in 1..HUB_HEADER_LEN {
        let mut edited = payload.clone();
        edited[index] ^= 0x01;
        // Either the header no longer parses (role, to) or the seal fails.
        assert!(open(&key(), &edited).is_err(), "edit at byte {index} went unnoticed");
    }
    // Body edits too.
    let mut edited = payload;
    *edited.last_mut().unwrap() ^= 1;
    assert_eq!(open(&key(), &edited), Err(HubOpenError::Seal));
}

#[test]
fn a_header_moved_onto_another_body_is_caught() {
    let a = seal(&key(), &header(HubRole::Mac, 1, 5), b"five").unwrap();
    let b = seal(&key(), &header(HubRole::Mac, 1, 6), b"six").unwrap();
    let mut spliced = b[..HUB_HEADER_LEN].to_vec();
    spliced.extend_from_slice(&a[HUB_HEADER_LEN..]);
    assert_eq!(open(&key(), &spliced), Err(HubOpenError::Seal));
}

#[test]
fn hub_frames_ride_the_relay_frame() {
    let frame = seal_frame(&key(), &header(HubRole::Mac, 1, 1), b"x").unwrap();
    let bytes = frame.encode().unwrap();
    assert_eq!(bytes[1], 5);
    assert_eq!(bytes.len(), HUB_FRAME_OVERHEAD + 1);
    let back = RelayFrame::decode(&bytes).unwrap();
    assert_eq!(back.kind, FrameKind::Hub);
    assert_eq!(open(&key(), &back.payload).unwrap().event, b"x");
    // A hub frame whose header does not parse is refused at the frame level.
    let mut bad = bytes.clone();
    bad[18] = 9;
    assert_eq!(RelayFrame::decode(&bad), Err(RelayFrameError::BadHub));
    assert_eq!(RelayFrame::decode(&bytes[..18 + 20]), Err(RelayFrameError::BadHub));
}

#[test]
fn the_largest_event_fits_one_frame() {
    let event = vec![0u8; HUB_MAX_EVENT];
    let frame = seal_frame(&key(), &header(HubRole::Mac, 1, 1), &event).unwrap();
    assert_eq!(frame.payload.len(), RELAY_FRAME_MAX_PAYLOAD);
    assert!(frame.encode().is_ok());
    assert_eq!(
        seal(&key(), &header(HubRole::Mac, 1, 1), &[0; HUB_MAX_EVENT + 1]),
        Err(HubSealError::TooLarge(HUB_MAX_EVENT + 1))
    );
}

#[test]
fn relay_rule_forwards_the_newer_copy_once() {
    let mut rule = HubRelayRule::default();
    assert_eq!(rule.route(&header(HubRole::Mac, 1, 1)), HubRoute::Viewers);
    // The VM's copy of the same event: dropped.
    assert_eq!(rule.route(&header(HubRole::Vm, 1, 1)), HubRoute::Drop);
    assert_eq!(rule.route(&header(HubRole::Vm, 1, 2)), HubRoute::Viewers);
    assert_eq!(rule.route(&header(HubRole::Mac, 1, 2)), HubRoute::Drop);
    // Older: dropped. A new epoch beats any sequence of the old one.
    assert_eq!(rule.route(&header(HubRole::Mac, 1, 0)), HubRoute::Drop);
    assert_eq!(rule.route(&header(HubRole::Vm, 2, 0)), HubRoute::Viewers);
    assert_eq!(rule.route(&header(HubRole::Mac, 1, 99)), HubRoute::Drop);
    assert_eq!((rule.forwarded, rule.dropped), (3, 4));
    // Mac-to-VM sync passes as is, without touching the viewer high-water.
    let sync = HubHeader { to: HubTo::Source(HubRole::Vm), ..header(HubRole::Mac, 1, 1) };
    assert_eq!(rule.route(&sync), HubRoute::Source(HubRole::Vm));
    assert_eq!(rule.high(), Some(HubPos::new(2, 0)));
}

#[test]
fn lockstep_new_client_against_old_and_new_relays() {
    // New relay: upgraded and echoed the hub subprotocol.
    assert_eq!(hub_join_outcome(101, Some("cmux-hub.v1")), HubJoin::Hub);
    // An older Worker has no hub route.
    assert_eq!(hub_join_outcome(404, None), HubJoin::Fallback(HubFallback::NoRoute));
    // Something upgraded without the hub subprotocol: not a hub.
    assert_eq!(hub_join_outcome(101, None), HubJoin::Fallback(HubFallback::NoSubprotocol));
    assert_eq!(
        hub_join_outcome(101, Some("cmux-relay.v1")),
        HubJoin::Fallback(HubFallback::NoSubprotocol)
    );
    assert_eq!(hub_join_outcome(503, None), HubJoin::Fallback(HubFallback::Off));
    assert_eq!(hub_join_outcome(403, None), HubJoin::Fallback(HubFallback::Refused(403)));
    // A two-party LinkRelay refuses kind 5 with bad_frame:kind.
    assert!(relay_error_means_no_hub("bad_frame:kind"));
    assert!(!relay_error_means_no_hub("too_large"));
}

#[test]
fn lockstep_a_kind_past_hub_is_unknown() {
    // A pre-hub decoder refuses kind 5 as `kind`, as this one refuses any kind
    // it does not know: never misread as datagrams (kind 4 is LinkRelay's
    // tagged datagrams, cmux#54189, so the hub must not share it).
    let mut bytes =
        seal_frame(&key(), &header(HubRole::Mac, 1, 1), b"x").unwrap().encode().unwrap();
    bytes[1] = 6;
    assert_eq!(RelayFrame::decode(&bytes), Err(RelayFrameError::Kind(6)));
}
