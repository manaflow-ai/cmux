//! `cmux.rd/1` datagram header (`DatagramHeader::decode`): a header that
//! decodes re-encodes to the first 16 bytes, keeps its shard index inside
//! its frame, and the payload is the rest of the datagram.
#![no_main]

use cmux_rd_proto::{DatagramHeader, DatagramKind, HEADER_LEN, MAX_FEC_BLOCK, MAX_FRAME_SHARDS};
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let Ok((header, payload)) = DatagramHeader::decode(data) else { return };
    assert_eq!(payload, &data[HEADER_LEN..]);
    assert_eq!(header.encode().as_slice(), &data[..HEADER_LEN]);
    if matches!(header.kind, DatagramKind::Video | DatagramKind::Fec | DatagramKind::UpMedia) {
        let total = u32::from(header.count) + u32::from(header.fec_count);
        let limit = if header.fec_count == 0 { MAX_FRAME_SHARDS } else { MAX_FEC_BLOCK };
        assert!(header.count > 0 && u32::from(header.index) < total && total <= limit);
    }
});
