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
