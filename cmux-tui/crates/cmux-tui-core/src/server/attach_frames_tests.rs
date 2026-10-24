use super::*;

fn budget() -> Arc<OutboundByteBudget> {
    Arc::new(OutboundByteBudget::new(1 << 20))
}

fn stream(raw: u16) -> ClientStreamId {
    ClientStreamId::new(raw).unwrap()
}

#[test]
fn a_header_round_trips_and_names_its_stream() {
    let header =
        FrameHeader { kind: FrameKind::Output, stream: stream(513), len: 7, offset: 1 << 40 };
    let bytes = header.encode();
    assert_eq!(bytes[0], 0xFF);
    assert_eq!(bytes[1], 1);
    assert_eq!(&bytes[2..4], &513_u16.to_le_bytes());
    assert_eq!(FrameHeader::decode(&bytes), Ok(header));
}

#[test]
fn a_header_with_a_bad_magic_kind_stream_or_size_is_refused() {
    let good =
        FrameHeader { kind: FrameKind::Event, stream: stream(1), len: 0, offset: 0 }.encode();
    let mut bad = good;
    bad[0] = b'{';
    assert_eq!(FrameHeader::decode(&bad), Err(FrameHeaderError::Magic));
    let mut bad = good;
    bad[1] = 0;
    assert_eq!(FrameHeader::decode(&bad), Err(FrameHeaderError::Kind(0)));
    let mut bad = good;
    bad[2..4].copy_from_slice(&0_u16.to_le_bytes());
    assert_eq!(FrameHeader::decode(&bad), Err(FrameHeaderError::Stream));
    let mut bad = good;
    let too_large = FRAME_MAX_PAYLOAD as u32 + 1;
    bad[4..8].copy_from_slice(&too_large.to_le_bytes());
    assert_eq!(FrameHeader::decode(&bad), Err(FrameHeaderError::TooLarge(too_large)));
}

#[test]
fn a_frame_is_its_header_then_its_parts_and_is_charged_until_dropped() {
    let budget = budget();
    let frame = encode_frame(&budget, FrameKind::Output, stream(9), 100, &[b"ab", b"cde"]).unwrap();
    assert_eq!(frame.len(), FRAME_HEADER_LEN + 5);
    let header: [u8; FRAME_HEADER_LEN] = frame.as_bytes()[..FRAME_HEADER_LEN].try_into().unwrap();
    assert_eq!(
        FrameHeader::decode(&header),
        Ok(FrameHeader { kind: FrameKind::Output, stream: stream(9), len: 5, offset: 100 })
    );
    assert_eq!(&frame.as_bytes()[FRAME_HEADER_LEN..], b"abcde");
    assert_eq!(budget.retained_bytes.load(std::sync::atomic::Ordering::Acquire), 21);
    drop(frame);
    assert_eq!(budget.retained_bytes.load(std::sync::atomic::Ordering::Acquire), 0);
}

#[test]
fn a_frame_over_the_global_budget_would_block_instead_of_growing_the_queue() {
    let budget = Arc::new(OutboundByteBudget::new(32));
    let error = encode_frame(&budget, FrameKind::Output, stream(1), 0, &[&[0; 64]]).err().unwrap();
    assert_eq!(error.kind(), std::io::ErrorKind::WouldBlock);
    assert_eq!(budget.retained_bytes.load(std::sync::atomic::Ordering::Acquire), 0);
}

#[test]
fn a_meta_frame_carries_its_meta_length_meta_and_raw_data() {
    let meta = serde_json::json!({"phase": "ready", "cols": 80});
    let frame =
        encode_meta_frame(&budget(), FrameKind::Snapshot, stream(2), 7, &meta, &[b"\xFF\x00raw"])
            .unwrap();
    let payload = &frame.as_bytes()[FRAME_HEADER_LEN..];
    let meta_len = u32::from_le_bytes(payload[..4].try_into().unwrap()) as usize;
    let decoded: serde_json::Value = serde_json::from_slice(&payload[4..4 + meta_len]).unwrap();
    assert_eq!(decoded, meta);
    assert_eq!(&payload[4 + meta_len..], b"\xFF\x00raw");
}

#[test]
fn a_tagged_event_names_its_stream_first_and_stays_valid_json() {
    let tagged = tag_json_object(r#"{"event":"output","surface":3}"#, stream(42)).unwrap();
    assert_eq!(tagged, r#"{"stream":42,"event":"output","surface":3}"#);
    let empty = tag_json_object("{}", stream(1)).unwrap();
    assert_eq!(empty, r#"{"stream":1}"#);
    assert!(tag_json_object("[1]", stream(1)).is_none());
}

#[test]
fn stream_ids_are_one_to_65535() {
    assert!(ClientStreamId::new(0).is_none());
    assert!(serde_json::from_str::<ClientStreamId>("0").is_err());
    assert!(serde_json::from_str::<ClientStreamId>("65536").is_err());
    assert_eq!(serde_json::from_str::<ClientStreamId>("65535").unwrap().get(), 65535);
}

#[test]
fn frames_are_written_only_for_a_stream_that_has_an_id() {
    assert_eq!(StreamFraming::LEGACY.frame_stream(), None);
    assert_eq!(StreamFraming::client(stream(3), false).frame_stream(), None);
    assert_eq!(StreamFraming::client(stream(3), true).frame_stream(), Some(stream(3)));
}
