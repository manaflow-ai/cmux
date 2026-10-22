//! Terminal host protocol bytes (daemon <-> cmux-tui-host over a socket):
//! the incremental frame decoder fed in chunks, the blocking reader, and the
//! payload decoders of the frames that carry structured data.
#![no_main]

use cmux_tui_core::terminal_host_protocol::{
    FrameDecoder, decode_host_launch_failure, decode_terminal_exit, read_frame,
};
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let Some((&shape, bytes)) = data.split_first() else { return };
    let max_payload = 1 << (8 + (shape & 0x0f));
    let chunk = 1 + usize::from(shape >> 4) * 5;
    let mut decoder = FrameDecoder::new(max_payload);
    for piece in bytes.chunks(chunk) {
        match decoder.push(piece) {
            Ok(frames) => {
                for frame in frames {
                    let _ = decode_terminal_exit(&frame.payload);
                    let _ = decode_host_launch_failure(&frame.payload);
                }
            }
            Err(_) => break,
        }
    }
    let mut reader = bytes;
    while let Ok(Some(_)) = read_frame(&mut reader, max_payload) {}
    let _ = decode_terminal_exit(bytes);
    let _ = decode_host_launch_failure(bytes);
});
