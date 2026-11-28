use super::*;

#[test]
fn canonical_terminal_hex_requires_lowercase_uuid_v4() {
    let canonical = "00000000000040008000000000000001";
    assert_eq!(TerminalId::from_hex(canonical).unwrap().to_hex(), canonical);
    assert!(TerminalId::from_hex("00000000000030008000000000000001").is_none());
    assert!(TerminalId::from_hex("00000000000040007000000000000001").is_none());
    assert!(TerminalId::from_hex("0000000000004000800000000000000A").is_none());
    assert!(TerminalId::from_hex("short").is_none());
}
