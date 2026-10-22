//! Pane protocol bytes from a peer: binary frames (decode loop over a stream
//! buffer and a re-encode of each message), data frames, JSON envelopes and
//! capability tokens.
#![no_main]

use cmux_pane_protocol::envelope::Envelope;
use cmux_pane_protocol::frame::{self, DataFrame};
use cmux_pane_protocol::token;
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let mut rest = data;
    while let Ok(Some((message, used))) = frame::decode(rest) {
        let _ = frame::encode(&message);
        if used == 0 {
            break;
        }
        rest = rest.get(used..).unwrap_or_default();
    }
    if let Some(header) = data.first_chunk::<4>() {
        let _ = frame::parse_header(*header);
    }
    if let Some(frame) = DataFrame::decode(&bytes::Bytes::copy_from_slice(data)) {
        let _ = frame.encode();
    }
    if let Ok(text) = std::str::from_utf8(data) {
        if let Ok(envelope) = Envelope::decode(text) {
            let _ = envelope.encode();
            let _ = envelope.error_body();
        }
        let _ = token::verify_signature(&[7; 32], text);
    }
});
