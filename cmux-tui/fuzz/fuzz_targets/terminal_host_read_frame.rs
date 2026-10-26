//! The terminal-host wire (CMTH frames between the daemon and each terminal
//! host): `terminal_host_protocol::read_frame` over a byte stream, and the
//! incremental `FrameDecoder` the nonblocking readers use, on the same bytes.
//!
//! Properties, beyond "no crash, leak or hang":
//! - a stream `read_frame` reads to a clean end decodes to the same frames in
//!   `FrameDecoder`, fed in two pieces split at the middle, with nothing left
//!   over (the two readers agree);
//! - every decoded frame encodes back to the exact bytes it came from.

#![no_main]

use std::io::Cursor;

use cmux_tui_core::terminal_host_protocol::{
    FrameDecoder, MAX_FRAME_PAYLOAD, decode_host_launch_failure, decode_terminal_exit,
    encode_frame, read_frame,
};
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let mut cursor = Cursor::new(data);
    let mut frames = Vec::new();
    let clean_end = loop {
        match read_frame(&mut cursor, MAX_FRAME_PAYLOAD) {
            Ok(Some(frame)) => frames.push(frame),
            Ok(None) => break true,
            Err(_) => break false,
        }
    };

    let mut offset = 0usize;
    for frame in &frames {
        let _ = decode_terminal_exit(&frame.payload);
        let _ = decode_host_launch_failure(&frame.payload);
        let encoded = encode_frame(frame).expect("a decoded frame encodes");
        let end = offset + encoded.len();
        assert!(data.get(offset..end) == Some(encoded.as_slice()), "frame re-encodes differently");
        offset = end;
    }

    let mut decoder = FrameDecoder::new(MAX_FRAME_PAYLOAD);
    let (head, tail) = data.split_at(data.len() / 2);
    let decoded = decoder.push(head).and_then(|mut first| {
        first.extend(decoder.push(tail)?);
        Ok(first)
    });
    if clean_end {
        let decoded = decoded.expect("FrameDecoder accepts a stream read_frame accepts");
        assert!(decoded == frames, "FrameDecoder and read_frame disagree");
        decoder.finish().expect("nothing left after a clean end");
    }
});
