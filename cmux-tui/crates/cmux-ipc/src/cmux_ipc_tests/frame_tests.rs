use std::collections::HashSet;

use bytes::{Bytes, BytesMut};

use super::{one_of_each_kind, sample_aux};
use crate::{
    Aux, AuxClass, BadMessage, CallAux, CallFlags, Frame, FrameHeader, FrameKind, HEADER_LEN,
    MAX_FRAME_PAYLOAD, PriorityHint,
};

#[test]
fn kind_wire_values_match_the_design() {
    let expected = [
        (FrameKind::Output, 1),
        (FrameKind::Grid, 2),
        (FrameKind::Event, 3),
        (FrameKind::Snapshot, 4),
        (FrameKind::SnapshotMore, 5),
        (FrameKind::Replay, 6),
        (FrameKind::Ring, 7),
        (FrameKind::RingAdvance, 8),
        (FrameKind::Input, 9),
        (FrameKind::SharedBuffer, 10),
        (FrameKind::RingAck, 11),
        (FrameKind::Request, 16),
        (FrameKind::Reply, 17),
        (FrameKind::Error, 18),
        (FrameKind::TypedEvent, 19),
        (FrameKind::Cancel, 20),
    ];
    assert_eq!(expected.len(), FrameKind::ALL.len());
    for (kind, wire) in expected {
        assert_eq!(kind.wire(), wire, "{kind:?}");
        assert_eq!(FrameKind::from_wire(wire), Some(kind));
    }
    let known: HashSet<u8> = expected.iter().map(|(_, wire)| *wire).collect();
    for wire in 0..=u8::MAX {
        if !known.contains(&wire) {
            assert_eq!(FrameKind::from_wire(wire), None, "{wire}");
        }
    }
}

#[test]
fn header_round_trips_for_every_kind() {
    for (index, kind) in FrameKind::ALL.into_iter().enumerate() {
        let stream = if kind.needs_data_stream() { u16::MAX } else { 0 };
        let aux = sample_aux(kind, index as u64);
        for len in [0, 1, MAX_FRAME_PAYLOAD] {
            let header = FrameHeader::new(kind, stream, len, aux).unwrap();
            let bytes = header.encode();
            assert_eq!(bytes[0], 0xFF);
            assert_eq!(bytes[1], kind.wire());
            assert_eq!(FrameHeader::decode(bytes, MAX_FRAME_PAYLOAD), Ok(header), "{kind:?}");
        }
    }
}

#[test]
fn header_fields_sit_at_their_little_endian_offsets() {
    let header = FrameHeader::new(
        FrameKind::Request,
        0x0201,
        0x0105_0403,
        Aux::Call(CallAux {
            request_id: 0x0a09_0807,
            method_id: 0x0c0b,
            priority: PriorityHint::Background,
            flags: CallFlags::MORE.with(CallFlags::URGENT),
        }),
    )
    .unwrap();
    assert_eq!(
        header.encode(),
        [
            0xFF, 16, 0x01, 0x02, 0x03, 0x04, 0x05, 0x01, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 3,
            0b1_1000
        ]
    );
    let output =
        FrameHeader::new(FrameKind::Output, 1, 0, Aux::Offset(0x0807_0605_0403_0201)).unwrap();
    assert_eq!(output.encode()[8..], [1, 2, 3, 4, 5, 6, 7, 8]);
}

#[test]
fn oversize_lengths_are_refused_on_both_sides() {
    let aux = Aux::Offset(0);
    assert_eq!(
        FrameHeader::new(FrameKind::Output, 1, MAX_FRAME_PAYLOAD + 1, aux),
        Err(BadMessage::Oversize { len: MAX_FRAME_PAYLOAD + 1, max: MAX_FRAME_PAYLOAD })
    );
    let mut bytes = FrameHeader::new(FrameKind::Output, 1, 0, aux).unwrap().encode();
    bytes[4..8].copy_from_slice(&(MAX_FRAME_PAYLOAD + 1).to_le_bytes());
    assert_eq!(
        FrameHeader::decode(bytes, MAX_FRAME_PAYLOAD),
        Err(BadMessage::Oversize { len: MAX_FRAME_PAYLOAD + 1, max: MAX_FRAME_PAYLOAD })
    );
    // A peer budget below the protocol limit applies too; one above it does not.
    bytes[4..8].copy_from_slice(&1025u32.to_le_bytes());
    assert_eq!(
        FrameHeader::decode(bytes, 1024),
        Err(BadMessage::Oversize { len: 1025, max: 1024 })
    );
    bytes[4..8].copy_from_slice(&(MAX_FRAME_PAYLOAD + 1).to_le_bytes());
    assert!(matches!(FrameHeader::decode(bytes, u32::MAX), Err(BadMessage::Oversize { .. })));
}

#[test]
fn bad_headers_get_typed_errors() {
    let good = FrameHeader::new(
        FrameKind::Reply,
        0,
        0,
        Aux::Call(CallAux {
            request_id: 1,
            method_id: 1,
            priority: PriorityHint::Control,
            flags: CallFlags::empty(),
        }),
    )
    .unwrap()
    .encode();
    let mut bytes = good;
    bytes[0] = 0xFE;
    assert_eq!(
        FrameHeader::decode(bytes, MAX_FRAME_PAYLOAD),
        Err(BadMessage::BadMagic { found: 0xFE })
    );
    let mut bytes = good;
    bytes[1] = 12;
    assert_eq!(
        FrameHeader::decode(bytes, MAX_FRAME_PAYLOAD),
        Err(BadMessage::UnknownKind { kind: 12 })
    );
    let mut bytes = good;
    bytes[14] = 4;
    assert_eq!(
        FrameHeader::decode(bytes, MAX_FRAME_PAYLOAD),
        Err(BadMessage::UnknownPriority { hint: 4 })
    );
    let mut bytes = good;
    bytes[15] = 0b10_0000;
    assert_eq!(
        FrameHeader::decode(bytes, MAX_FRAME_PAYLOAD),
        Err(BadMessage::UnknownFlags { flags: 0b10_0000 })
    );
    let mut bytes = FrameHeader::new(FrameKind::Output, 1, 0, Aux::Offset(0)).unwrap().encode();
    bytes[2] = 0;
    assert_eq!(
        FrameHeader::decode(bytes, MAX_FRAME_PAYLOAD),
        Err(BadMessage::DataOnControlStream { kind: FrameKind::Output })
    );
}

#[test]
fn stream_zero_carries_calls_and_shared_buffers_only() {
    for kind in FrameKind::ALL {
        let aux = sample_aux(kind, 1);
        let on_zero = FrameHeader::new(kind, 0, 0, aux);
        if kind.aux_class() == AuxClass::Call || kind == FrameKind::SharedBuffer {
            assert!(on_zero.is_ok(), "{kind:?}");
        } else {
            assert_eq!(on_zero, Err(BadMessage::DataOnControlStream { kind }));
        }
        assert!(FrameHeader::new(kind, 7, 0, aux).is_ok(), "{kind:?}");
    }
}

#[test]
fn aux_must_match_the_kind() {
    assert_eq!(
        FrameHeader::new(FrameKind::Input, 1, 0, Aux::Offset(0)),
        Err(BadMessage::AuxMismatch { kind: FrameKind::Input })
    );
    assert_eq!(
        FrameHeader::new(FrameKind::Request, 0, 0, Aux::FlowId(0)),
        Err(BadMessage::AuxMismatch { kind: FrameKind::Request })
    );
}

#[test]
fn call_flags_refuse_undefined_bits() {
    for bits in 0..=u8::MAX {
        let flags = CallFlags::from_wire(bits);
        assert_eq!(flags.is_some(), bits < 0b10_0000, "{bits:#b}");
    }
    let more = CallFlags::empty().with(CallFlags::MORE);
    assert!(more.contains(CallFlags::MORE));
    assert!(!more.contains(CallFlags::BINARY));
}

#[test]
fn frame_encodes_header_then_payload() {
    for frame in one_of_each_kind() {
        let mut out = BytesMut::new();
        frame.encode_into(&mut out);
        assert_eq!(out.len(), HEADER_LEN + frame.payload().len());
        assert_eq!(out[..HEADER_LEN], frame.header().encode());
        assert_eq!(&out[HEADER_LEN..], frame.payload().as_ref());
        assert_eq!(frame.header().len() as usize, frame.payload().len());
    }
    let empty = Frame::new(FrameKind::RingAck, 1, Aux::Offset(9), Bytes::new()).unwrap();
    assert!(empty.header().is_empty());
}

#[test]
fn bad_message_reasons_are_distinct() {
    let all = [
        BadMessage::BadMagic { found: 0 },
        BadMessage::UnknownKind { kind: 0 },
        BadMessage::Oversize { len: 0, max: 0 },
        BadMessage::AuxMismatch { kind: FrameKind::Output },
        BadMessage::DataOnControlStream { kind: FrameKind::Output },
        BadMessage::UnknownPriority { hint: 0 },
        BadMessage::UnknownFlags { flags: 0 },
        BadMessage::FramesNotNegotiated,
        BadMessage::LineTooLong { max: 0 },
        BadMessage::InvalidUtf8 { valid_up_to: 0 },
        BadMessage::Truncated { have: 0, need: 0 },
    ];
    let reasons: HashSet<&str> = all.iter().map(BadMessage::reason).collect();
    assert_eq!(reasons.len(), all.len());
    for bad in all {
        assert!(!bad.to_string().is_empty());
    }
}
