//! Crockford base32 (https://www.crockford.com/base32.html), no check symbol.

/// The 32 symbols: digits, then letters without I, L, O and U.
pub const ALPHABET: &[u8; 32] = b"0123456789ABCDEFGHJKMNPQRSTVWXYZ";

/// Value of an uppercase symbol, with the decode aliases `O` = 0 and
/// `I`, `L` = 1. Lowercase input must be uppercased by the caller.
pub fn decode_symbol(c: char) -> Option<u8> {
    match c {
        'O' => Some(0),
        'I' | 'L' => Some(1),
        'U' => None,
        _ => ALPHABET.iter().position(|s| *s as char == c).map(|p| p as u8),
    }
}

/// The first `symbols` symbols of `bytes`, 5 bits each, most significant
/// bit first. Panics when `bytes` holds fewer than `5 * symbols` bits.
pub fn encode_bits(bytes: &[u8], symbols: usize) -> String {
    assert!(bytes.len() * 8 >= symbols * 5, "not enough input bits");
    (0..symbols)
        .map(|i| {
            let bit = i * 5;
            let (byte, shift) = (bit / 8, bit % 8);
            let hi = u16::from(bytes[byte]) << 8;
            let lo = bytes.get(byte + 1).copied().map_or(0, u16::from);
            let value = ((hi | lo) >> (11 - shift)) & 0x1f;
            ALPHABET[value as usize] as char
        })
        .collect()
}
