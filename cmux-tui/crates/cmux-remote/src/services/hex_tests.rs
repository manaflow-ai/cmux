//! A renderer grant's token is exactly 64 hex digits; anything else is a
//! typed error, never a panic.

use super::*;

#[test]
fn a_token_decodes_in_either_case() {
    let token = "00ff10Ab".repeat(8);
    let decoded = decode_hex_32(&token).unwrap();
    assert_eq!(decoded[..4], [0x00, 0xff, 0x10, 0xab]);
    assert_eq!(decoded[28..], [0x00, 0xff, 0x10, 0xab]);
}

#[test]
fn malformed_tokens_are_errors() {
    for token in [
        String::new(),
        "0".repeat(63),
        "0".repeat(65),
        "0".repeat(66),
        format!("{}g", "0".repeat(63)),
        format!("{}é", "0".repeat(62)),
    ] {
        assert!(
            matches!(decode_hex_32(&token), Err(ServicesError::Remote(_))),
            "{token:?} decoded"
        );
    }
}
