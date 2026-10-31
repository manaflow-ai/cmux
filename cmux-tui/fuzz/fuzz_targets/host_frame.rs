//! The terminal-host data plane (`CMTH` frames, cmux-tui-core
//! `terminal_host_protocol`): the bytes a host, daemon or renderer reads from
//! its local peer.
//!
//! Input: byte 0 picks the payload limit, bytes 1..3 seed the chunk sizes, the
//! rest is the stream. The stream goes through `FrameDecoder::push` in those
//! chunks and through `read_frame` on one reader.
//!
//! Oracle: no panic; the incremental and blocking decoders return the same
//! frames and agree on the first error kind; the decoder never holds more than
//! one header plus the payload limit; a decoder that failed stays failed;
//! every decoded frame encodes back to the bytes it came from; the payload
//! decoders (exit, launch failure, snapshot, colors) on each frame's payload
//! never panic.
#![no_main]

use cmux_tui_core::terminal_host_protocol::{
    FrameDecoder, HEADER_LEN, MAX_FRAME_PAYLOAD, ProtocolError, decode_host_launch_failure,
    decode_terminal_exit, encode_frame, read_frame,
};
use cmux_tui_core::terminal_host_runtime::{
    decode_host_snapshot_payload, decode_terminal_color_overrides,
};
use libfuzzer_sys::fuzz_target;

fn kind(error: &ProtocolError) -> String {
    let text = format!("{error:?}");
    text.split(['(', ' ', '{']).next().unwrap_or_default().to_string()
}

fuzz_target!(|data: &[u8]| {
    if data.len() < 3 {
        return;
    }
    let max_payload = match data[0] % 4 {
        0 => 0,
        1 => 64,
        2 => 4096,
        _ => MAX_FRAME_PAYLOAD,
    };
    let (seed_a, seed_b) = (usize::from(data[1]) + 1, usize::from(data[2]) + 1);
    let stream = &data[3..];

    let mut decoder = FrameDecoder::new(max_payload);
    let mut incremental = Vec::new();
    let mut incremental_error = None;
    let mut offset = 0;
    let mut turn = 0usize;
    while offset < stream.len() {
        let size = if turn % 2 == 0 { seed_a } else { seed_b };
        let end = stream.len().min(offset + size);
        match decoder.push(&stream[offset..end]) {
            Ok(frames) => incremental.extend(frames),
            Err(error) => {
                incremental_error = Some(kind(&error));
                assert!(
                    matches!(decoder.push(&[]), Err(ProtocolError::DecoderFailed)),
                    "a failed decoder accepted more input"
                );
                break;
            }
        }
        assert!(
            decoder.buffered_len() <= HEADER_LEN + max_payload,
            "decoder buffered {} bytes past one frame",
            decoder.buffered_len()
        );
        offset = end;
        turn += 1;
    }
    let finished = incremental_error.is_none() && decoder.finish().is_ok();

    let mut reader = stream;
    let mut blocking = Vec::new();
    let mut blocking_error = None;
    loop {
        match read_frame(&mut reader, max_payload) {
            Ok(Some(frame)) => blocking.push(frame),
            Ok(None) => break,
            Err(error) => {
                blocking_error = Some(kind(&error));
                break;
            }
        }
    }

    assert_eq!(incremental.len(), blocking.len(), "the two decoders found different frames");
    for (a, b) in incremental.iter().zip(&blocking) {
        assert!(a == b, "the two decoders decoded one frame differently");
    }
    // read_frame names a short stream Truncated; the incremental decoder only
    // learns that at finish().
    match (&incremental_error, &blocking_error) {
        (Some(a), Some(b)) => assert_eq!(a, b, "the two decoders failed differently"),
        (None, Some(b)) => assert!(b == "Truncated" && !finished, "only read_frame failed: {b}"),
        (Some(a), None) => panic!("only the incremental decoder failed: {a}"),
        (None, None) => assert!(finished, "finish() failed on a stream read_frame took whole"),
    }

    let mut consumed = 0;
    for frame in &blocking {
        let encoded = encode_frame(frame).expect("a decoded frame must encode");
        assert_eq!(
            &stream[consumed..consumed + encoded.len()],
            encoded.as_slice(),
            "a decoded frame encodes to other bytes"
        );
        consumed += encoded.len();
        let _ = decode_terminal_exit(&frame.payload);
        let _ = decode_host_launch_failure(&frame.payload);
        let _ = decode_host_snapshot_payload(&frame.payload);
        let _ = decode_terminal_color_overrides(&frame.payload);
    }
});
