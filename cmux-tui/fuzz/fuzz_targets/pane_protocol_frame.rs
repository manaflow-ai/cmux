//! The pane protocol's byte-stream framing (`cmux_pane_protocol::frame`) and
//! the JSON envelope of a text message (`envelope::Envelope::decode`): what
//! a third-party pane provider writes to its socket. Chromium's Mojo rule
//! applies: the decoder validates every message and a bad one is an error for
//! that peer, never a crash of cmux.
//!
//! Properties, beyond "no crash, leak or hang":
//! - each frame `decode` takes encodes back to exactly the bytes it consumed;
//! - a binary message's data frame encodes back to the message body;
//! - an envelope that decodes encodes to text that decodes again (a relay
//!   that re-sends what it accepted never sends something it would refuse).

#![no_main]

use bytes::Bytes;
use cmux_pane_protocol::envelope::Envelope;
use cmux_pane_protocol::frame::{self, DataFrame, Message};
use libfuzzer_sys::fuzz_target;

fn check_envelope(text: &str) {
    if let Ok(envelope) = Envelope::decode(text) {
        let encoded = envelope.encode();
        assert!(Envelope::decode(&encoded).is_ok(), "re-encoded envelope is refused: {encoded}");
    }
}

fuzz_target!(|data: &[u8]| {
    if let Some(header) = data.first_chunk::<4>() {
        let _ = frame::parse_header(*header);
    }

    let mut rest = data;
    while let Ok(Some((message, consumed))) = frame::decode(rest) {
        let encoded = frame::encode(&message).expect("a decoded message encodes");
        assert!(rest.get(..consumed) == Some(encoded.as_slice()), "frame re-encodes differently");
        match &message {
            Message::Text(text) => check_envelope(text),
            Message::Binary(body) => {
                if let Some(data_frame) = DataFrame::decode(body) {
                    assert!(data_frame.encode() == *body, "data frame re-encodes differently");
                }
            }
            Message::Close(..) => {}
        }
        let Some(next) = rest.get(consumed..) else { break };
        rest = next;
    }

    // The whole input as one envelope and as one data frame body as well, so
    // the envelope decoder sees inputs that are not behind a valid header.
    if let Ok(text) = std::str::from_utf8(data) {
        check_envelope(text);
    }
    let _ = DataFrame::decode(&Bytes::copy_from_slice(data));
});
