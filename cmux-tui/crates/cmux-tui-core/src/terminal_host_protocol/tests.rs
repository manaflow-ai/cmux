use super::*;

fn sample_frame() -> Frame {
    Frame {
        version: PROTOCOL_VERSION,
        kind: MessageKind::Output,
        flags: 0x1122_3344,
        request_id: 0x0102_0304_0506_0708,
        sequence: 0x1112_1314_1516_1718,
        payload: vec![0xaa, 0xbb, 0xcc],
    }
}

#[test]
fn golden_frame_is_explicit_little_endian() {
    let encoded = encode_frame(&sample_frame()).unwrap();
    assert_eq!(
        encoded,
        vec![
            b'C', b'M', b'T', b'H', // magic
            0x04, 0x00, // version
            0x06, 0x00, // output
            0x44, 0x33, 0x22, 0x11, // flags
            0x03, 0x00, 0x00, 0x00, // payload length
            0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01, // request id
            0x18, 0x17, 0x16, 0x15, 0x14, 0x13, 0x12, 0x11, // sequence
            0xaa, 0xbb, 0xcc,
        ]
    );
    let decoded = read_frame(&mut encoded.as_slice(), MAX_FRAME_PAYLOAD).unwrap().unwrap();
    assert_eq!(decoded, sample_frame());
}

#[test]
fn launch_failure_has_a_stable_bounded_wire_format() {
    assert_eq!(MessageKind::LaunchFailed as u16, 20);
    assert_eq!(MessageKind::try_from(20).unwrap(), MessageKind::LaunchFailed);

    let failure = HostLaunchFailure::bounded(
        HostLaunchFailureKind::PtyCapacityExhausted,
        "terminal launch failed: PTY capacity exhausted".into(),
    );
    let payload = encode_host_launch_failure(&failure).unwrap();
    assert_eq!(decode_host_launch_failure(&payload).unwrap(), failure);
    assert_eq!(failure.kind.reason_code(), "pty_capacity_exhausted");
    let error = anyhow::Error::new(failure);
    assert_eq!(
        error.downcast_ref::<HostLaunchFailure>().map(|failure| failure.kind),
        Some(HostLaunchFailureKind::PtyCapacityExhausted)
    );

    let oversized = format!("{}é", "x".repeat(MAX_LAUNCH_FAILURE_MESSAGE_BYTES));
    let bounded = HostLaunchFailure::bounded(HostLaunchFailureKind::LaunchFailed, oversized);
    assert!(bounded.message.len() <= MAX_LAUNCH_FAILURE_MESSAGE_BYTES);
    assert!(bounded.message.is_char_boundary(bounded.message.len()));
    assert_eq!(
        decode_host_launch_failure(&encode_host_launch_failure(&bounded).unwrap()).unwrap(),
        bounded
    );

    let mut wrong_version = payload.clone();
    wrong_version[..2].copy_from_slice(&(LAUNCH_FAILURE_PAYLOAD_VERSION + 1).to_le_bytes());
    assert!(matches!(
        decode_host_launch_failure(&wrong_version),
        Err(ProtocolError::MalformedLaunchFailurePayload)
    ));

    let mut unknown_kind = payload.clone();
    unknown_kind[2..4].copy_from_slice(&u16::MAX.to_le_bytes());
    assert!(matches!(
        decode_host_launch_failure(&unknown_kind),
        Err(ProtocolError::MalformedLaunchFailurePayload)
    ));

    let mut invalid_utf8 = payload;
    *invalid_utf8.last_mut().unwrap() = 0xff;
    assert!(matches!(
        decode_host_launch_failure(&invalid_utf8),
        Err(ProtocolError::MalformedLaunchFailurePayload)
    ));
    assert!(matches!(
        decode_host_launch_failure(&[0; LAUNCH_FAILURE_PAYLOAD_HEADER_LEN]),
        Err(ProtocolError::MalformedLaunchFailurePayload)
    ));
    assert!(matches!(
        decode_host_launch_failure(&vec![
            0;
            LAUNCH_FAILURE_PAYLOAD_HEADER_LEN
                + MAX_LAUNCH_FAILURE_MESSAGE_BYTES
                + 1
        ]),
        Err(ProtocolError::MalformedLaunchFailurePayload)
    ));
}
