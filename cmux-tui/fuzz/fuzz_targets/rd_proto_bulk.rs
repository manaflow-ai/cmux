//! `cmux.rd/1` bulk chunk (`BulkFrame::decode`): a decoded chunk encodes back
//! to the same bytes and stays within `MAX_BULK_CHUNK`.
#![no_main]

use cmux_rd_proto::{BULK_PREFIX_LEN, BulkFrame, MAX_BULK_CHUNK};
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let Ok(frame) = BulkFrame::decode(data) else { return };
    assert!(frame.bytes.len() <= MAX_BULK_CHUNK);
    assert_eq!(frame.bytes.len() + BULK_PREFIX_LEN, data.len());
    assert_eq!(frame.encode(), data);
});
