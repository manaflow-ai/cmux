//! The remote session wire frame (cmux-remote-protocol `WireFrame`): the
//! datagram every remote link carries.
//!
//! Oracle: no panic; a decoded frame encodes back to exactly the bytes it was
//! decoded from (no two encodings of one frame, no ignored byte), and its
//! payload is within `MAX_FRAME_PAYLOAD`.
#![no_main]

use cmux_remote_protocol::{MAX_FRAME_PAYLOAD, WireFrame};
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let Ok(frame) = WireFrame::decode(data) else { return };
    assert!(frame.payload.len() <= MAX_FRAME_PAYLOAD, "payload past the limit decoded");
    let encoded = frame.encode().expect("a decoded frame must encode");
    assert!(encoded == data, "a decoded frame encodes to other bytes");
});
