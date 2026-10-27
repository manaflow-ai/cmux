//! `cmux.rd/1` clock ping and pong (`ClockPing::decode`, `ClockPong::decode`):
//! both are fixed-size, so a decoded message encodes to the same length and
//! decodes back to itself.
#![no_main]

use cmux_rd_proto::{ClockPing, ClockPong};
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    if let Ok(ping) = ClockPing::decode(data) {
        let encoded = ping.encode();
        assert_eq!(encoded.len(), data.len());
        assert_eq!(ClockPing::decode(&encoded), Ok(ping));
    }
    if let Ok(pong) = ClockPong::decode(data) {
        assert_eq!(pong.encode(), data);
    }
});
