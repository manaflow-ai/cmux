use cmux_rd_proto::{
    Arrival, DatagramHeader, DatagramKind, DecodeError, Feedback, FrameBody, HEADER_LEN,
    INPUT_PACKET_PREFIX_LEN, InputEvent, InputPacket, Nack, REF_NONE, flags,
};
use proptest::prelude::*;

#[test]
fn header_golden_vector() {
    let header = DatagramHeader {
        flags: flags::KEYFRAME,
        kind: DatagramKind::Video,
        stream: 2,
        frame: 0x0102_0304,
        index: 1,
        count: 3,
        fec_count: 1,
        transport_seq: 0xbeef,
    };
    let bytes = header.encode();
    assert_eq!(bytes.len(), HEADER_LEN);
    assert_eq!(
        bytes,
        [
            0x11, 0x01, 0x02, 0x00, 0x04, 0x03, 0x02, 0x01, 0x01, 0x00, 0x03, 0x00, 0x01, 0x00,
            0xef, 0xbe
        ]
    );
    let mut datagram = bytes.to_vec();
    datagram.extend_from_slice(b"payload");
    let (decoded, payload) = DatagramHeader::decode(&datagram).expect("decode");
    assert_eq!(decoded, header);
    assert_eq!(payload, b"payload");
}

#[test]
fn header_rejects_bad_input() {
    assert!(matches!(DatagramHeader::decode(&[0x11, 0x01]), Err(DecodeError::Truncated { .. })));
    let mut bytes = DatagramHeader {
        flags: 0,
        kind: DatagramKind::Video,
        stream: 0,
        frame: 1,
        index: 0,
        count: 1,
        fec_count: 0,
        transport_seq: 0,
    }
    .encode();
    bytes[0] = 0x20;
    assert_eq!(DatagramHeader::decode(&bytes), Err(DecodeError::Version(2)));
    bytes[0] = 0x10;
    bytes[1] = 99;
    assert_eq!(DatagramHeader::decode(&bytes), Err(DecodeError::Kind(99)));
    // A parity index on a video datagram is refused.
    bytes[1] = DatagramKind::Video as u8;
    bytes[8] = 1;
    assert!(DatagramHeader::decode(&bytes).is_err());
}

#[test]
fn frame_body_ignores_padding() {
    let body =
        FrameBody { t_capture_us: 42, ref_frame: REF_NONE, access_unit: vec![0, 0, 0, 1, 0x65] };
    let mut bytes = body.encode();
    bytes.resize(bytes.len() + 100, 0);
    assert_eq!(FrameBody::decode(&bytes).expect("decode"), body);
}

#[test]
fn text_is_truncated_on_a_char_boundary() {
    let long = "é".repeat(200);
    let packet = InputPacket { first_seq: 1, events: vec![InputEvent::Text(long)] };
    let decoded = InputPacket::decode(&packet.encode()).expect("decode");
    let InputEvent::Text(text) = &decoded.events[0] else { panic!("text") };
    assert!(text.len() <= cmux_rd_proto::MAX_TEXT_BYTES);
    assert!(text.chars().all(|c| c == 'é'));
}

fn event() -> impl Strategy<Value = InputEvent> {
    prop_oneof![
        (any::<u32>(), any::<bool>()).prop_map(|(usage, down)| InputEvent::Key { usage, down }),
        (any::<i32>(), any::<i32>()).prop_map(|(x, y)| InputEvent::Pointer { x, y }),
        (any::<u8>(), any::<bool>()).prop_map(|(button, down)| InputEvent::Button { button, down }),
        (any::<i32>(), any::<i32>(), any::<bool>())
            .prop_map(|(dx, dy, precise)| InputEvent::Scroll { dx, dy, precise }),
        "[a-zA-Z0-9 é]{0,300}".prop_map(InputEvent::Text),
    ]
}

proptest! {
    #[test]
    fn input_round_trips(first_seq in any::<u32>(), events in proptest::collection::vec(event(), 0..20)) {
        let packet = InputPacket { first_seq, events };
        let encoded = packet.encode();
        let expected_len: usize =
            INPUT_PACKET_PREFIX_LEN + packet.events.iter().map(InputEvent::encoded_len).sum::<usize>();
        prop_assert_eq!(encoded.len(), expected_len);
        let decoded = InputPacket::decode(&encoded).expect("decode");
        // Text longer than MAX_TEXT_BYTES arrives cut on a character boundary.
        let truncated: Vec<InputEvent> = packet
            .events
            .iter()
            .map(|e| match e {
                InputEvent::Text(t) => {
                    let mut end = t.len().min(cmux_rd_proto::MAX_TEXT_BYTES);
                    while !t.is_char_boundary(end) {
                        end -= 1;
                    }
                    InputEvent::Text(t[..end].to_owned())
                }
                other => other.clone(),
            })
            .collect();
        prop_assert_eq!(decoded, InputPacket { first_seq, events: truncated });
    }

    #[test]
    fn feedback_round_trips(
        acked in any::<u32>(),
        decode_us in any::<u32>(),
        need in any::<bool>(),
        arrivals in proptest::collection::vec((any::<u16>(), any::<u32>()), 0..50),
        nacks in proptest::collection::vec((any::<u32>(), proptest::collection::vec(any::<u16>(), 0..10)), 0..4),
    ) {
        let feedback = Feedback {
            acked_frame: acked,
            decode_us,
            need_recovery: need,
            arrivals: arrivals.into_iter().map(|(transport_seq, arrival_us)| Arrival { transport_seq, arrival_us }).collect(),
            nacks: nacks.into_iter().map(|(frame, indexes)| Nack { frame, indexes }).collect(),
        };
        prop_assert_eq!(Feedback::decode(&feedback.encode()).expect("decode"), feedback);
    }

    #[test]
    fn decoders_never_panic(bytes in proptest::collection::vec(any::<u8>(), 0..300)) {
        let _ = DatagramHeader::decode(&bytes);
        let _ = InputPacket::decode(&bytes);
        let _ = Feedback::decode(&bytes);
        let _ = FrameBody::decode(&bytes);
    }
}

#[test]
fn large_frames_without_parity_are_accepted_and_large_fec_blocks_refused() {
    let header = |count: u16, fec_count: u16, index: u16, kind: DatagramKind| {
        DatagramHeader {
            flags: 0,
            kind,
            stream: 0,
            frame: 1,
            index,
            count,
            fec_count,
            transport_seq: 0,
        }
        .encode()
    };
    assert!(DatagramHeader::decode(&header(300, 0, 299, DatagramKind::Video)).is_ok());
    assert!(DatagramHeader::decode(&header(300, 1, 300, DatagramKind::Fec)).is_err());
    assert!(DatagramHeader::decode(&header(254, 1, 254, DatagramKind::Fec)).is_ok());
    assert!(DatagramHeader::decode(&header(4097, 0, 0, DatagramKind::Video)).is_err());
}

#[test]
fn stream_frames_split_at_any_chunk_boundary() {
    use cmux_rd_proto::{STREAM_CONTROL, STREAM_DATAGRAM, StreamDeframer, encode_stream_frame};
    let mut bytes = Vec::new();
    encode_stream_frame(STREAM_CONTROL, br#"{"t":"stop"}"#, &mut bytes).expect("control");
    encode_stream_frame(STREAM_DATAGRAM, &[7u8; 40], &mut bytes).expect("datagram");
    assert_eq!(&bytes[..5], &[1, 12, 0, 0, 0]);
    for chunk in 1..bytes.len() {
        let mut d = StreamDeframer::default();
        let mut frames = Vec::new();
        for part in bytes.chunks(chunk) {
            d.extend(part);
            while let Some(f) = d.next_frame().expect("frame") {
                frames.push(f);
            }
        }
        assert_eq!(frames.len(), 2);
        assert_eq!(frames[0], (STREAM_CONTROL, br#"{"t":"stop"}"#.to_vec()));
        assert_eq!(frames[1], (STREAM_DATAGRAM, vec![7u8; 40]));
        assert_eq!(d.buffered(), 0);
    }
}

#[test]
fn stream_refuses_unknown_types_and_oversized_lengths() {
    use cmux_rd_proto::{MAX_STREAM_FRAME, StreamDeframer, encode_stream_frame};
    assert!(encode_stream_frame(9, b"x", &mut Vec::new()).is_err());
    let mut d = StreamDeframer::default();
    d.extend(&[9, 1, 0, 0, 0, 0]);
    assert!(d.next_frame().is_err());
    // The failure is sticky.
    d.extend(&[1, 0, 0, 0, 0]);
    assert!(d.next_frame().is_err());
    let mut d = StreamDeframer::default();
    d.extend(&[2]);
    d.extend(&((MAX_STREAM_FRAME as u32) + 1).to_le_bytes());
    assert!(d.next_frame().is_err());
}

#[test]
fn many_small_frames_in_one_chunk_are_all_read() {
    use cmux_rd_proto::{STREAM_CONTROL, StreamDeframer, encode_stream_frame};
    let mut bytes = Vec::new();
    for _ in 0..100_000 {
        encode_stream_frame(STREAM_CONTROL, b"", &mut bytes).expect("control");
    }
    bytes.extend_from_slice(&[STREAM_CONTROL, 3, 0]);
    let mut d = StreamDeframer::default();
    d.extend(&bytes);
    let mut n = 0;
    while let Some((kind, payload)) = d.next_frame().expect("frame") {
        assert_eq!((kind, payload.len()), (STREAM_CONTROL, 0));
        n += 1;
    }
    assert_eq!(n, 100_000);
    // Only the partial frame stays, and it completes with the next chunk.
    assert_eq!(d.buffered(), 3);
    d.extend(&[0, 0, b'a', b'b', b'c']);
    assert_eq!(d.next_frame().expect("frame"), Some((STREAM_CONTROL, b"abc".to_vec())));
    assert_eq!(d.buffered(), 0);
}

/// The stream carrier bytes of `{"t":"stop"}` then a 3-byte datagram. The
/// same vector is pinned in cmux-rd-host's src/wire.rs tests (which also
/// round-trip it through the host's writer and reader).
#[test]
fn stream_framing_matches_the_golden_vector() {
    use cmux_rd_proto::{STREAM_CONTROL, STREAM_DATAGRAM, StreamDeframer, encode_stream_frame};
    const GOLDEN: &[u8] = &[
        1, 12, 0, 0, 0, b'{', b'"', b't', b'"', b':', b'"', b's', b't', b'o', b'p', b'"', b'}', 2,
        3, 0, 0, 0, 7, 7, 7,
    ];
    let mut bytes = Vec::new();
    encode_stream_frame(STREAM_CONTROL, br#"{"t":"stop"}"#, &mut bytes).expect("control");
    encode_stream_frame(STREAM_DATAGRAM, &[7, 7, 7], &mut bytes).expect("datagram");
    assert_eq!(bytes, GOLDEN);
    let mut d = StreamDeframer::default();
    d.extend(GOLDEN);
    assert_eq!(d.next_frame().expect("frame"), Some((STREAM_CONTROL, br#"{"t":"stop"}"#.to_vec())));
    assert_eq!(d.next_frame().expect("frame"), Some((STREAM_DATAGRAM, vec![7, 7, 7])));
}
