use cmux_rd_proto::{
    Arrival, DatagramHeader, DatagramKind, DecodeError, Feedback, FrameBody, HEADER_LEN,
    InputEvent, InputPacket, Nack, REF_NONE, flags,
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
        "[a-zA-Z0-9 ]{0,40}".prop_map(InputEvent::Text),
    ]
}

proptest! {
    #[test]
    fn input_round_trips(first_seq in any::<u32>(), events in proptest::collection::vec(event(), 0..20)) {
        let packet = InputPacket { first_seq, events };
        prop_assert_eq!(InputPacket::decode(&packet.encode()).expect("decode"), packet);
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
