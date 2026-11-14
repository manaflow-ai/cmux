use super::*;

fn wg(kind: u8, len: usize) -> Vec<u8> {
    let mut bytes = vec![0xA5; len];
    bytes[0] = kind;
    bytes[1..4].copy_from_slice(&[0, 0, 0]);
    bytes
}

#[test]
fn wireguard_messages_classify_by_type_and_size() {
    assert_eq!(classify(&wg(1, 148)), DatagramClass::WireGuardInitiation);
    assert_eq!(classify(&wg(2, 92)), DatagramClass::WireGuardResponse);
    assert_eq!(classify(&wg(3, 64)), DatagramClass::WireGuardCookieReply);
    assert_eq!(classify(&wg(4, 32)), DatagramClass::WireGuardData);
    assert_eq!(classify(&wg(4, 32 + 1424)), DatagramClass::WireGuardData);
}
