//! Durable Object relay frame (`RelayFrame::decode`, `split_datagrams`): a
//! frame that decodes re-encodes to the same bytes, and a datagram batch
//! splits into non-empty records that rebuild the same frame.
#![no_main]

use cmux_transport::relay_frame::{RELAY_FRAME_HEADER_LEN, RELAY_FRAME_MAX_PAYLOAD};
use cmux_transport::{FrameKind, RelayFrame};
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let Ok(frame) = RelayFrame::decode(data) else { return };
    assert!(frame.payload.len() <= RELAY_FRAME_MAX_PAYLOAD);
    assert_eq!(frame.payload.as_slice(), &data[RELAY_FRAME_HEADER_LEN..]);
    assert_eq!(frame.encode().as_deref(), Ok(data));
    if frame.kind == FrameKind::Datagrams {
        let records = frame.split_datagrams().expect("a decoded batch splits");
        assert!(!records.is_empty() && records.iter().all(|record| !record.is_empty()));
        assert_eq!(RelayFrame::datagrams(frame.peer, &records), Ok(frame.clone()));
    }
});
