//! `cmux.rd/1` input packet (`InputPacket::decode`): every limit the decoder
//! checks (text and service lengths, UTF-8, flag bits, booleans) is one the
//! encoder keeps, so a decoded packet encodes back to the same bytes.
#![no_main]

use cmux_rd_proto::{
    INPUT_PACKET_PREFIX_LEN, InputEvent, InputPacket, MAX_SERVICE_BYTES, MAX_TEXT_BYTES,
};
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let Ok(packet) = InputPacket::decode(data) else { return };
    for event in &packet.events {
        match event {
            InputEvent::Text(text) => assert!(text.len() <= MAX_TEXT_BYTES),
            InputEvent::Service { bytes, .. } => assert!(bytes.len() <= MAX_SERVICE_BYTES),
            _ => {}
        }
    }
    let encoded = packet.encode();
    let lengths: usize = packet.events.iter().map(InputEvent::encoded_len).sum();
    assert_eq!(encoded.len(), INPUT_PACKET_PREFIX_LEN + lengths);
    assert_eq!(encoded, data);
});
