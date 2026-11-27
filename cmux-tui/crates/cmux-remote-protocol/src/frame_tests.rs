use super::*;

#[test]
fn session_close_has_a_canonical_wire_shape() {
    let frame = WireFrame {
        session: SessionId([8; 16]),
        generation: 2,
        lane: Lane::Control,
        flags: FrameFlags::RELIABLE.union(FrameFlags::SESSION_CLOSE),
        sequence: 4,
        acknowledgement: 3,
        stream: 0,
        payload: Vec::new(),
    };
    assert_eq!(WireFrame::decode(&frame.encode().unwrap()).unwrap(), frame);

    let mut invalid = frame.clone();
    invalid.stream = 1;
    assert_eq!(invalid.encode(), Err(FrameDecodeError::InvalidSessionClose));

    invalid = frame;
    invalid.flags = FrameFlags::SESSION_CLOSE;
    assert_eq!(invalid.encode(), Err(FrameDecodeError::InvalidSessionClose));
}

#[test]
fn heartbeat_has_a_canonical_wire_shape() {
    let frame = WireFrame {
        session: SessionId([8; 16]),
        generation: 2,
        lane: Lane::Control,
        flags: FrameFlags::RELIABLE.union(FrameFlags::HEARTBEAT_REQUEST),
        sequence: 4,
        acknowledgement: 3,
        stream: 0,
        payload: Vec::new(),
    };
    assert_eq!(WireFrame::decode(&frame.encode().unwrap()).unwrap(), frame);

    let mut invalid = frame;
    invalid.flags = invalid.flags.union(FrameFlags::HEARTBEAT_RESPONSE);
    assert_eq!(invalid.encode(), Err(FrameDecodeError::InvalidHeartbeat));
}

fn data_frame() -> WireFrame {
    WireFrame {
        session: SessionId([3; 16]),
        generation: 1,
        lane: Lane::Control,
        flags: FrameFlags::RELIABLE,
        sequence: 1,
        acknowledgement: 0,
        stream: 0,
        payload: b"hello".to_vec(),
    }
}

/// The frame with its version byte (after the 4-byte magic) set to `version`.
fn with_version(version: u8) -> Vec<u8> {
    let mut encoded = data_frame().encode().unwrap();
    encoded[4] = version;
    encoded
}

#[test]
fn encode_writes_the_current_version() {
    assert_eq!(data_frame().encode().unwrap()[4], REMOTE_PROTOCOL_VERSION);
}

#[test]
fn decode_reads_every_version_in_the_supported_range() {
    for version in REMOTE_PROTOCOL_MIN_VERSION..=REMOTE_PROTOCOL_VERSION {
        assert_eq!(WireFrame::decode(&with_version(version)).unwrap(), data_frame(), "v{version}");
    }
}

#[test]
fn decode_refuses_versions_outside_the_range() {
    for version in [0, REMOTE_PROTOCOL_MIN_VERSION - 1, REMOTE_PROTOCOL_VERSION + 1, u8::MAX] {
        assert_eq!(
            WireFrame::decode(&with_version(version)),
            Err(FrameDecodeError::UnsupportedVersion(version)),
            "v{version}"
        );
    }
}
