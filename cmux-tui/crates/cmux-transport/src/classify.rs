//! One UDP socket carries WireGuard and STUN. This tells them apart.
//!
//! WireGuard messages start with a little-endian u32 type of 1 to 4, so the
//! first byte is the type and the next three are zero, and each type has a
//! fixed size (data messages: a 16-byte header plus a ciphertext that is a
//! multiple of 16 bytes and at least the 16-byte tag). STUN messages start
//! with two zero bits, carry the magic cookie 0x2112A442 at offset 4 and a
//! body length that is a multiple of 4 and matches the datagram. No valid
//! WireGuard message has the STUN cookie in that place with a matching
//! length, because bytes 4..8 of a WireGuard message are the sender or
//! receiver index chosen at random; the length checks make a collision need
//! both a cookie match and an exact size, which the caller treats as STUN
//! only when it has a transaction outstanding.

/// What a received datagram is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DatagramClass {
    WireGuardInitiation,
    WireGuardResponse,
    WireGuardCookieReply,
    WireGuardData,
    Stun,
    Unknown,
}

pub const WG_INITIATION_LEN: usize = 148;
pub const WG_RESPONSE_LEN: usize = 92;
pub const WG_COOKIE_REPLY_LEN: usize = 64;
/// Header (type, receiver index, counter) plus the AEAD tag of an empty
/// (keepalive) payload.
pub const WG_DATA_MIN_LEN: usize = 32;
pub const STUN_HEADER_LEN: usize = 20;
pub const STUN_MAGIC_COOKIE: u32 = 0x2112_A442;

pub fn classify(datagram: &[u8]) -> DatagramClass {
    if is_stun(datagram) {
        return DatagramClass::Stun;
    }
    if datagram.len() < 4 || datagram[1..4] != [0, 0, 0] {
        return DatagramClass::Unknown;
    }
    match (datagram[0], datagram.len()) {
        (1, WG_INITIATION_LEN) => DatagramClass::WireGuardInitiation,
        (2, WG_RESPONSE_LEN) => DatagramClass::WireGuardResponse,
        (3, WG_COOKIE_REPLY_LEN) => DatagramClass::WireGuardCookieReply,
        (4, len) if len >= WG_DATA_MIN_LEN && (len - 16) % 16 == 0 => DatagramClass::WireGuardData,
        _ => DatagramClass::Unknown,
    }
}

fn is_stun(datagram: &[u8]) -> bool {
    if datagram.len() < STUN_HEADER_LEN || datagram[0] & 0xC0 != 0 {
        return false;
    }
    let cookie = u32::from_be_bytes([datagram[4], datagram[5], datagram[6], datagram[7]]);
    let body_len = usize::from(u16::from_be_bytes([datagram[2], datagram[3]]));
    cookie == STUN_MAGIC_COOKIE && body_len % 4 == 0 && STUN_HEADER_LEN + body_len == datagram.len()
}

#[cfg(test)]
mod tests {
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

    #[test]
    fn wrong_sizes_and_reserved_bytes_are_unknown() {
        assert_eq!(classify(&wg(1, 147)), DatagramClass::Unknown);
        assert_eq!(classify(&wg(4, 33)), DatagramClass::Unknown);
        assert_eq!(classify(&wg(5, 148)), DatagramClass::Unknown);
        let mut reserved = wg(1, 148);
        reserved[2] = 1;
        assert_eq!(classify(&reserved), DatagramClass::Unknown);
        assert_eq!(classify(&[]), DatagramClass::Unknown);
    }

    #[test]
    fn stun_needs_cookie_and_exact_length() {
        let request = crate::stun::binding_request([7; 12]);
        assert_eq!(classify(&request), DatagramClass::Stun);
        let mut long = request.clone();
        long.push(0);
        assert_ne!(classify(&long), DatagramClass::Stun);
        let mut no_cookie = request;
        no_cookie[4] = 0;
        assert_ne!(classify(&no_cookie), DatagramClass::Stun);
    }
}
