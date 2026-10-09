//! One UDP socket carries WireGuard and STUN. This tells them apart.
//!
//! WireGuard messages start with a little-endian u32 type of 1 to 4, so the
//! first byte is the type and the next three are zero. Handshake messages
//! have fixed sizes; a data message is a 16-byte header plus a ciphertext of
//! at least the 16-byte tag. Implementations differ on padding (boringtun
//! does not pad; others pad to 16 bytes but only up to the MTU), so the
//! data length is not checked against a multiple of 16. STUN messages start
//! with two zero bits, carry the magic cookie 0x2112A442 at offset 4 and a
//! body length that is a multiple of 4 and matches the datagram. The two
//! cannot collide: bytes 2..4 of every WireGuard message are zero, so a
//! WireGuard message read as STUN declares an empty body and would have to
//! be 20 bytes long, and the smallest WireGuard message is 32 bytes.

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
        (4, len) if len >= WG_DATA_MIN_LEN => DatagramClass::WireGuardData,
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
