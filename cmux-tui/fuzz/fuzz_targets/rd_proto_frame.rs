//! `cmux.rd/1` frame body (`FrameBody::decode`): the declared length bounds
//! the access unit, trailing padding is ignored, and the body re-encodes to
//! the bytes it was read from.
#![no_main]

use cmux_rd_proto::{FRAME_PREFIX_LEN, FrameBody};
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let Ok(body) = FrameBody::decode(data) else { return };
    let used = FRAME_PREFIX_LEN + body.access_unit.len();
    assert!(used <= data.len());
    assert_eq!(body.encode(), &data[..used]);
});
