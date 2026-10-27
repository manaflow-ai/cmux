//! Lowercase hex of a public id's 16 bytes (moved out of resource.rs).

use std::fmt::Write as _;

pub(super) fn encode_hex(bytes: [u8; 16]) -> String {
    let mut output = String::with_capacity(32);
    for byte in bytes {
        // Writing into a String cannot fail.
        let _ = write!(output, "{byte:02x}");
    }
    output
}
