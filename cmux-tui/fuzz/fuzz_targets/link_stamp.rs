//! The link peer stamp (`stamp::parse`), the first line of every stream the
//! link hands the daemon's remote entry. A stamp that parses names only
//! valid identifiers, and its encoding parses back to the same stamp.
#![no_main]

use cmux_link::stamp::{encode, parse};
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let Ok(text) = std::str::from_utf8(data) else { return };
    let Ok(stamp) = parse(text) else { return };
    assert!(stamp.peer.is_valid());
    let written = encode(&stamp.peer, stamp.check).expect("a parsed stamp encodes");
    assert_eq!(parse(&written), Ok(stamp));
});
