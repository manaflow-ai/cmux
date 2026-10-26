//! The `cmux link` line contract (`dial::parse_request`, `dial::parse_line`)
//! for every frame the link and its peers read from a socket: the dial
//! request and reply, the overlay service hello, and the reload and Cloud
//! event requests. A request names a valid install id, and a frame that
//! parses writes a line that parses back to itself.
#![no_main]

use cmux_link::dial::{
    CloudEventRequest, DialReply, MAX_LINE_BYTES, ReloadRequest, ServiceHello, line, parse_line,
    parse_request,
};
use cmux_link::stamp::valid_id;
use libfuzzer_sys::fuzz_target;
use serde::Serialize;
use serde::de::DeserializeOwned;

fn round_trips<T: Serialize + DeserializeOwned + PartialEq + std::fmt::Debug>(text: &str) {
    let Some(frame) = parse_line::<T>(text) else { return };
    let written = line(&frame);
    // Defaults the input left out are written back (`"revision":null`), which
    // may take a line past the limit the reader enforces.
    if written.len() <= MAX_LINE_BYTES + 1 {
        assert_eq!(parse_line::<T>(&written), Some(frame));
    }
}

fuzz_target!(|data: &[u8]| {
    let Ok(text) = std::str::from_utf8(data) else { return };
    if let Ok(request) = parse_request(text) {
        assert!(valid_id(&request.host));
        assert_eq!(parse_request(&line(&request)), Ok(request));
    }
    round_trips::<DialReply>(text);
    round_trips::<ServiceHello>(text);
    round_trips::<ReloadRequest>(text);
    round_trips::<CloudEventRequest>(text);
});
