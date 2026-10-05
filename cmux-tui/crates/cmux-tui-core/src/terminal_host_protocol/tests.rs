use super::*;
use std::sync::{Arc, Mutex, mpsc};

/// Test-only stand-in for a direct pipe reader. The bounded queue models
/// the byte pump, while the mutex is the single parser owner.
struct PipeBytePump {
    tx: Option<mpsc::SyncSender<Vec<u8>>>,
    rx: mpsc::Receiver<Vec<u8>>,
    decoder: Arc<Mutex<FrameDecoder>>,
}

impl PipeBytePump {
    fn new(capacity: usize) -> Self {
        let (tx, rx) = mpsc::sync_channel(capacity);
        Self {
            tx: Some(tx),
            rx,
            decoder: Arc::new(Mutex::new(FrameDecoder::new(MAX_FRAME_PAYLOAD))),
        }
    }

    fn close(&mut self) {
        self.tx.take();
    }

    fn parse_next(&self) -> Result<Option<Vec<Frame>>, ProtocolError> {
        match self.rx.recv() {
            Ok(bytes) => self.decoder.lock().unwrap().push(&bytes).map(Some),
            Err(_) => self.decoder.lock().unwrap().finish().map(|()| None),
        }
    }
}

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
fn fragmented_and_coalesced_frames_decode_without_boundary_assumptions() {
    let first = sample_frame();
    let mut second = Frame::new(MessageKind::ViewerSize, vec![80, 0, 24, 0]);
    second.request_id = 9;
    let mut stream = encode_frame(&first).unwrap();
    stream.extend_from_slice(&encode_frame(&second).unwrap());

    let mut decoder = FrameDecoder::new(1024);
    let mut decoded = Vec::new();
    for byte in &stream {
        decoded.extend(decoder.push(std::slice::from_ref(byte)).unwrap());
    }
    decoder.finish().unwrap();
    assert_eq!(decoded, vec![first.clone(), second.clone()]);

    let mut decoder = FrameDecoder::new(1024);
    assert_eq!(decoder.push(&stream).unwrap(), vec![first, second]);
    decoder.finish().unwrap();
}

#[test]
fn direct_pipe_pump_handles_split_ansi_and_utf8_then_eof() {
    let mut frame = Frame::new(MessageKind::Output, b"\x1b[31mCafe ".to_vec());
    frame.payload.extend_from_slice("é\x1b[0m".as_bytes());
    let encoded = encode_frame(&frame).unwrap();
    let mut pump = PipeBytePump::new(3);
    let tx = pump.tx.as_ref().unwrap();
    tx.send(encoded[..3].to_vec()).unwrap();
    tx.send(encoded[3..HEADER_LEN + 1].to_vec()).unwrap();
    tx.send(encoded[HEADER_LEN + 1..].to_vec()).unwrap();

    assert!(pump.parse_next().unwrap().unwrap().is_empty());
    assert!(pump.parse_next().unwrap().unwrap().is_empty());
    assert_eq!(pump.parse_next().unwrap().unwrap(), vec![frame]);
    pump.close();
    assert_eq!(pump.parse_next().unwrap(), None);
}

#[test]
fn direct_pipe_pump_queue_is_bounded_and_parser_access_is_serialized() {
    let pump = PipeBytePump::new(1);
    pump.tx.as_ref().unwrap().try_send(vec![1]).unwrap();
    assert!(pump.tx.as_ref().unwrap().try_send(vec![2]).is_err());

    let decoder = Arc::clone(&pump.decoder);
    let first = std::thread::spawn(move || decoder.lock().unwrap().buffered_len());
    let decoder = Arc::clone(&pump.decoder);
    let second = std::thread::spawn(move || decoder.lock().unwrap().buffered_len());
    assert_eq!(first.join().unwrap(), 0);
    assert_eq!(second.join().unwrap(), 0);
}

#[test]
fn clear_history_has_a_stable_additive_message_kind() {
    assert_eq!(MessageKind::ClearHistoryAck as u16, 17);
    assert_eq!(MessageKind::try_from(17).unwrap(), MessageKind::ClearHistoryAck);
    assert_eq!(MessageKind::ClearHistory as u16, 107);
    assert_eq!(MessageKind::try_from(107).unwrap(), MessageKind::ClearHistory);
}

#[test]
fn kitty_graphics_limits_have_stable_additive_message_kinds() {
    assert_eq!(MessageKind::KittyGraphicsLimitsAck as u16, 19);
    assert_eq!(MessageKind::try_from(19).unwrap(), MessageKind::KittyGraphicsLimitsAck);
    assert_eq!(MessageKind::SetKittyGraphicsLimits as u16, 109);
    assert_eq!(MessageKind::try_from(109).unwrap(), MessageKind::SetKittyGraphicsLimits);
}

#[test]
fn terminate_receipt_has_a_stable_additive_message_kind() {
    assert_eq!(MessageKind::TerminateAck as u16, 21);
    assert_eq!(MessageKind::try_from(21).unwrap(), MessageKind::TerminateAck);
    assert_eq!(MessageKind::DetachAck as u16, 22);
    assert_eq!(MessageKind::try_from(22).unwrap(), MessageKind::DetachAck);
    assert_eq!(MessageKind::InputAck as u16, 23);
    assert_eq!(MessageKind::try_from(23).unwrap(), MessageKind::InputAck);
    assert_eq!(MessageKind::Terminate as u16, 104);
    assert_eq!(MessageKind::try_from(104).unwrap(), MessageKind::Terminate);
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

#[test]
fn launch_activation_has_a_stable_additive_message_kind() {
    assert_eq!(MessageKind::Activate as u16, 110);
    assert_eq!(MessageKind::try_from(110).unwrap(), MessageKind::Activate);
    assert_eq!(MessageKind::Detach as u16, 111);
    assert_eq!(MessageKind::try_from(111).unwrap(), MessageKind::Detach);
}

#[test]
fn clear_history_ack_statuses_are_stable() {
    assert_eq!(CLEAR_HISTORY_ACK_OK, 0);
    assert_eq!(CLEAR_HISTORY_ACK_PRESERVATION_FAILED, 1);
    assert_eq!(CLEAR_HISTORY_ACK_FAILED, CLEAR_HISTORY_ACK_PRESERVATION_FAILED);
    assert_eq!(CLEAR_HISTORY_ACK_STREAM_TIMEOUT, 2);
    assert_eq!(CLEAR_HISTORY_ACK_FALLBACK_UNREPRESENTABLE, 3);
    assert_eq!(CLEAR_HISTORY_ACK_KNOWN_NOT_DELIVERED, 4);
    assert_eq!(CLEAR_HISTORY_ACK_AMBIGUOUS, 5);
    assert_eq!(CLEAR_HISTORY_ACK_FALLBACK_WRITE_TIMEOUT, 6);
}

#[test]
fn exit_payload_round_trips_strict_outcomes() {
    for exit in [
        TerminalExit { outcome: TerminalExitOutcome::Exit { code: 23 }, exited_at_ms: 1234 },
        TerminalExit {
            outcome: TerminalExitOutcome::Signal { signal: 9, core_dumped: true },
            exited_at_ms: 5678,
        },
        TerminalExit {
            outcome: TerminalExitOutcome::Unknown { reason: "wait failed".to_string() },
            exited_at_ms: 9012,
        },
    ] {
        assert_eq!(decode_terminal_exit(&encode_terminal_exit(&exit)).unwrap(), exit);
    }

    let mut unknown_kind = encode_terminal_exit(&TerminalExit::unknown("unknown"));
    unknown_kind[2] = 99;
    assert!(matches!(
        decode_terminal_exit(&unknown_kind),
        Err(ProtocolError::MalformedExitPayload)
    ));
    let invalid_code = encode_terminal_exit(&TerminalExit {
        outcome: TerminalExitOutcome::Exit { code: -1 },
        exited_at_ms: 1,
    });
    assert!(matches!(
        decode_terminal_exit(&invalid_code),
        Err(ProtocolError::MalformedExitPayload)
    ));
    assert!(matches!(
        decode_terminal_exit(&[1, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        Err(ProtocolError::MalformedExitPayload)
    ));
    assert!(
        serde_json::from_value::<TerminalExitOutcome>(serde_json::json!({
            "kind":"exit",
            "code":0,
            "signal":9,
        }))
        .is_err(),
        "outcome variants reject fields belonging to another variant"
    );
    assert!(
        serde_json::from_value::<TerminalExit>(serde_json::json!({
            "outcome":{"kind":"exit","code":0},
            "exited_at_ms":1,
            "incarnation":"private",
        }))
        .is_err(),
        "durable exit records reject unknown private/public fields"
    );
}

#[cfg(unix)]
#[test]
fn native_exit_status_retains_exit_code_signal_and_core_flag() {
    use std::os::unix::process::ExitStatusExt;

    let exited = TerminalExit::from_exit_status(&std::process::ExitStatus::from_raw(37 << 8));
    assert_eq!(exited.outcome, TerminalExitOutcome::Exit { code: 37 });

    let signaled =
        TerminalExit::from_exit_status(&std::process::ExitStatus::from_raw(libc::SIGABRT | 0x80));
    assert_eq!(
        signaled.outcome,
        TerminalExitOutcome::Signal { signal: libc::SIGABRT, core_dumped: true }
    );
}

#[cfg(unix)]
#[test]
fn cmux_pty_native_child_retains_real_exit_and_signal_status() {
    fn run(script: &str) -> TerminalExitOutcome {
        let pty = cmux_pty::open(cmux_pty::PtySize {
            rows: 24,
            cols: 80,
            pixel_width: 0,
            pixel_height: 0,
        })
        .unwrap();
        let mut command = cmux_pty::PtyCommand::new("/bin/sh");
        command.args(["-c", script]);
        let mut spawned = pty.spawn(command).unwrap();
        wait_for_native_child_status(spawned.child.as_mut()).outcome
    }

    assert_eq!(run("exit 17"), TerminalExitOutcome::Exit { code: 17 });
    assert_eq!(
        run("kill -TERM $$"),
        TerminalExitOutcome::Signal { signal: libc::SIGTERM, core_dumped: false }
    );
}

#[test]
fn malformed_headers_poison_the_incremental_decoder() {
    let mut bad_magic = encode_frame(&sample_frame()).unwrap();
    bad_magic[0] = b'X';
    let mut decoder = FrameDecoder::new(1024);
    assert!(matches!(decoder.push(&bad_magic), Err(ProtocolError::InvalidMagic(_))));
    assert!(matches!(decoder.push(&[]), Err(ProtocolError::DecoderFailed)));

    let mut unknown_kind = encode_frame(&sample_frame()).unwrap();
    unknown_kind[6..8].copy_from_slice(&999u16.to_le_bytes());
    let mut decoder = FrameDecoder::new(1024);
    assert!(matches!(decoder.push(&unknown_kind), Err(ProtocolError::UnknownMessageKind(999))));

    let mut zero_version = encode_frame(&sample_frame()).unwrap();
    zero_version[4..6].copy_from_slice(&0u16.to_le_bytes());
    let mut decoder = FrameDecoder::new(1024);
    assert!(matches!(decoder.push(&zero_version), Err(ProtocolError::InvalidVersion(0))));
}

#[test]
fn oversized_length_is_rejected_before_payload_is_buffered() {
    let mut encoded = encode_frame(&sample_frame()).unwrap();
    encoded[12..16].copy_from_slice(&65u32.to_le_bytes());
    encoded.truncate(HEADER_LEN);
    let mut decoder = FrameDecoder::new(64);
    assert!(matches!(
        decoder.push(&encoded),
        Err(ProtocolError::PayloadTooLarge { len: 65, max: 64 })
    ));
    assert_eq!(decoder.buffered_len(), HEADER_LEN);
}

#[test]
fn async_header_helper_owns_payload_length_validation() {
    let encoded = encode_frame(&sample_frame()).unwrap();
    assert_eq!(frame_payload_len(&encoded[..HEADER_LEN], 64).unwrap(), 3);
    assert!(matches!(
        frame_payload_len(&encoded[..HEADER_LEN - 1], 64),
        Err(ProtocolError::Truncated { expected: HEADER_LEN, actual })
            if actual == HEADER_LEN - 1
    ));

    let mut oversized = encoded[..HEADER_LEN].to_vec();
    oversized[12..16].copy_from_slice(&65u32.to_le_bytes());
    assert!(matches!(
        frame_payload_len(&oversized, 64),
        Err(ProtocolError::PayloadTooLarge { len: 65, max: 64 })
    ));

    oversized[12..16].copy_from_slice(&u32::try_from(MAX_FRAME_PAYLOAD + 1).unwrap().to_le_bytes());
    assert!(matches!(
        frame_payload_len(&oversized, usize::MAX),
        Err(ProtocolError::PayloadTooLarge {
            len,
            max: MAX_FRAME_PAYLOAD,
        }) if len == MAX_FRAME_PAYLOAD + 1
    ));
}

#[test]
fn incomplete_header_and_payload_are_reported_as_truncated() {
    let encoded = encode_frame(&sample_frame()).unwrap();
    let mut decoder = FrameDecoder::new(1024);
    decoder.push(&encoded[..8]).unwrap();
    assert!(matches!(
        decoder.finish(),
        Err(ProtocolError::Truncated { expected: HEADER_LEN, actual: 8 })
    ));

    let mut decoder = FrameDecoder::new(1024);
    decoder.push(&encoded[..HEADER_LEN + 1]).unwrap();
    assert!(matches!(
        decoder.finish(),
        Err(ProtocolError::Truncated { expected, actual })
            if expected == HEADER_LEN + 3 && actual == HEADER_LEN + 1
    ));

    let error = read_frame(&mut &encoded[..HEADER_LEN + 2], 1024).unwrap_err();
    assert!(matches!(
        error,
        ProtocolError::Truncated { expected, actual }
            if expected == HEADER_LEN + 3 && actual == HEADER_LEN + 2
    ));
}

#[test]
fn encoder_enforces_the_global_payload_budget() {
    let frame = Frame::new(MessageKind::Input, vec![0; MAX_FRAME_PAYLOAD + 1]);
    assert!(matches!(
        encode_frame(&frame),
        Err(ProtocolError::PayloadTooLarge { len, max })
            if len == MAX_FRAME_PAYLOAD + 1 && max == MAX_FRAME_PAYLOAD
    ));
}

#[test]
fn clipboard_read_messages_have_stable_additive_kinds() {
    assert_eq!(MessageKind::ClipboardReadRequest as u16, 24);
    assert_eq!(MessageKind::try_from(24).unwrap(), MessageKind::ClipboardReadRequest);
    assert_eq!(MessageKind::ClipboardReadReply as u16, 112);
    assert_eq!(MessageKind::try_from(112).unwrap(), MessageKind::ClipboardReadReply);
    assert!(matches!(MessageKind::try_from(25), Err(ProtocolError::UnknownMessageKind(25))));
    assert!(matches!(MessageKind::try_from(113), Err(ProtocolError::UnknownMessageKind(113))));
}
