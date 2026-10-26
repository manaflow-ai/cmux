//! DES encryption of one block, only for the VNC password challenge
//! (security type 2). VNC auth is DES by definition; this is not used for
//! anything else.

const IP: [u8; 64] = [
    58, 50, 42, 34, 26, 18, 10, 2, 60, 52, 44, 36, 28, 20, 12, 4, 62, 54, 46, 38, 30, 22, 14, 6,
    64, 56, 48, 40, 32, 24, 16, 8, 57, 49, 41, 33, 25, 17, 9, 1, 59, 51, 43, 35, 27, 19, 11, 3, 61,
    53, 45, 37, 29, 21, 13, 5, 63, 55, 47, 39, 31, 23, 15, 7,
];
const FP: [u8; 64] = [
    40, 8, 48, 16, 56, 24, 64, 32, 39, 7, 47, 15, 55, 23, 63, 31, 38, 6, 46, 14, 54, 22, 62, 30,
    37, 5, 45, 13, 53, 21, 61, 29, 36, 4, 44, 12, 52, 20, 60, 28, 35, 3, 43, 11, 51, 19, 59, 27,
    34, 2, 42, 10, 50, 18, 58, 26, 33, 1, 41, 9, 49, 17, 57, 25,
];
const E: [u8; 48] = [
    32, 1, 2, 3, 4, 5, 4, 5, 6, 7, 8, 9, 8, 9, 10, 11, 12, 13, 12, 13, 14, 15, 16, 17, 16, 17, 18,
    19, 20, 21, 20, 21, 22, 23, 24, 25, 24, 25, 26, 27, 28, 29, 28, 29, 30, 31, 32, 1,
];
const P: [u8; 32] = [
    16, 7, 20, 21, 29, 12, 28, 17, 1, 15, 23, 26, 5, 18, 31, 10, 2, 8, 24, 14, 32, 27, 3, 9, 19,
    13, 30, 6, 22, 11, 4, 25,
];
const PC1: [u8; 56] = [
    57, 49, 41, 33, 25, 17, 9, 1, 58, 50, 42, 34, 26, 18, 10, 2, 59, 51, 43, 35, 27, 19, 11, 3, 60,
    52, 44, 36, 63, 55, 47, 39, 31, 23, 15, 7, 62, 54, 46, 38, 30, 22, 14, 6, 61, 53, 45, 37, 29,
    21, 13, 5, 28, 20, 12, 4,
];
const PC2: [u8; 48] = [
    14, 17, 11, 24, 1, 5, 3, 28, 15, 6, 21, 10, 23, 19, 12, 4, 26, 8, 16, 7, 27, 20, 13, 2, 41, 52,
    31, 37, 47, 55, 30, 40, 51, 45, 33, 48, 44, 49, 39, 56, 34, 53, 46, 42, 50, 36, 29, 32,
];
const SHIFTS: [u32; 16] = [1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1];
const S: [[u8; 64]; 8] = [
    [
        14, 4, 13, 1, 2, 15, 11, 8, 3, 10, 6, 12, 5, 9, 0, 7, 0, 15, 7, 4, 14, 2, 13, 1, 10, 6, 12,
        11, 9, 5, 3, 8, 4, 1, 14, 8, 13, 6, 2, 11, 15, 12, 9, 7, 3, 10, 5, 0, 15, 12, 8, 2, 4, 9,
        1, 7, 5, 11, 3, 14, 10, 0, 6, 13,
    ],
    [
        15, 1, 8, 14, 6, 11, 3, 4, 9, 7, 2, 13, 12, 0, 5, 10, 3, 13, 4, 7, 15, 2, 8, 14, 12, 0, 1,
        10, 6, 9, 11, 5, 0, 14, 7, 11, 10, 4, 13, 1, 5, 8, 12, 6, 9, 3, 2, 15, 13, 8, 10, 1, 3, 15,
        4, 2, 11, 6, 7, 12, 0, 5, 14, 9,
    ],
    [
        10, 0, 9, 14, 6, 3, 15, 5, 1, 13, 12, 7, 11, 4, 2, 8, 13, 7, 0, 9, 3, 4, 6, 10, 2, 8, 5,
        14, 12, 11, 15, 1, 13, 6, 4, 9, 8, 15, 3, 0, 11, 1, 2, 12, 5, 10, 14, 7, 1, 10, 13, 0, 6,
        9, 8, 7, 4, 15, 14, 3, 11, 5, 2, 12,
    ],
    [
        7, 13, 14, 3, 0, 6, 9, 10, 1, 2, 8, 5, 11, 12, 4, 15, 13, 8, 11, 5, 6, 15, 0, 3, 4, 7, 2,
        12, 1, 10, 14, 9, 10, 6, 9, 0, 12, 11, 7, 13, 15, 1, 3, 14, 5, 2, 8, 4, 3, 15, 0, 6, 10, 1,
        13, 8, 9, 4, 5, 11, 12, 7, 2, 14,
    ],
    [
        2, 12, 4, 1, 7, 10, 11, 6, 8, 5, 3, 15, 13, 0, 14, 9, 14, 11, 2, 12, 4, 7, 13, 1, 5, 0, 15,
        10, 3, 9, 8, 6, 4, 2, 1, 11, 10, 13, 7, 8, 15, 9, 12, 5, 6, 3, 0, 14, 11, 8, 12, 7, 1, 14,
        2, 13, 6, 15, 0, 9, 10, 4, 5, 3,
    ],
    [
        12, 1, 10, 15, 9, 2, 6, 8, 0, 13, 3, 4, 14, 7, 5, 11, 10, 15, 4, 2, 7, 12, 9, 5, 6, 1, 13,
        14, 0, 11, 3, 8, 9, 14, 15, 5, 2, 8, 12, 3, 7, 0, 4, 10, 1, 13, 11, 6, 4, 3, 2, 12, 9, 5,
        15, 10, 11, 14, 1, 7, 6, 0, 8, 13,
    ],
    [
        4, 11, 2, 14, 15, 0, 8, 13, 3, 12, 9, 7, 5, 10, 6, 1, 13, 0, 11, 7, 4, 9, 1, 10, 14, 3, 5,
        12, 2, 15, 8, 6, 1, 4, 11, 13, 12, 3, 7, 14, 10, 15, 6, 8, 0, 5, 9, 2, 6, 11, 13, 8, 1, 4,
        10, 7, 9, 5, 0, 15, 14, 2, 3, 12,
    ],
    [
        13, 2, 8, 4, 6, 15, 11, 1, 10, 9, 3, 14, 5, 0, 12, 7, 1, 15, 13, 8, 10, 3, 7, 4, 12, 5, 6,
        11, 0, 14, 9, 2, 7, 11, 4, 1, 9, 12, 14, 2, 0, 6, 10, 13, 15, 3, 5, 8, 2, 1, 14, 7, 4, 10,
        8, 13, 15, 12, 9, 0, 3, 5, 6, 11,
    ],
];

/// Selects bits of `input` (an `in_bits`-wide value, bit 1 the most
/// significant) in the order `table` names them.
fn permute(input: u64, in_bits: u32, table: &[u8]) -> u64 {
    table
        .iter()
        .fold(0, |out, &position| (out << 1) | ((input >> (in_bits - u32::from(position))) & 1))
}

fn subkeys(key: [u8; 8]) -> [u64; 16] {
    let permuted = permute(u64::from_be_bytes(key), 64, &PC1);
    let (mut c, mut d) = ((permuted >> 28) & 0x0FFF_FFFF, permuted & 0x0FFF_FFFF);
    let mut keys = [0; 16];
    for (round, shift) in SHIFTS.iter().enumerate() {
        c = ((c << shift) | (c >> (28 - shift))) & 0x0FFF_FFFF;
        d = ((d << shift) | (d >> (28 - shift))) & 0x0FFF_FFFF;
        keys[round] = permute((c << 28) | d, 56, &PC2);
    }
    keys
}

fn feistel(right: u32, key: u64) -> u32 {
    let mixed = permute(u64::from(right), 32, &E) ^ key;
    let mut out = 0u32;
    for (index, sbox) in S.iter().enumerate() {
        let six = ((mixed >> (42 - 6 * index)) & 0x3F) as usize;
        let row = ((six & 0x20) >> 4) | (six & 1);
        let column = (six >> 1) & 0xF;
        out = (out << 4) | u32::from(sbox[row * 16 + column]);
    }
    permute(u64::from(out), 32, &P) as u32
}

/// Encrypts one 8-byte block with an 8-byte key (DES, ECB).
pub fn encrypt_block(key: [u8; 8], block: [u8; 8]) -> [u8; 8] {
    let keys = subkeys(key);
    let permuted = permute(u64::from_be_bytes(block), 64, &IP);
    let (mut left, mut right) = ((permuted >> 32) as u32, permuted as u32);
    for key in keys {
        (left, right) = (right, left ^ feistel(right, key));
    }
    permute((u64::from(right) << 32) | u64::from(left), 64, &FP).to_be_bytes()
}

/// The VNC password response: the challenge's two blocks encrypted with the
/// password's first 8 bytes, each byte's bits reversed (RFC 6143 7.2.2).
pub fn vnc_response(password: &[u8], challenge: [u8; 16]) -> [u8; 16] {
    let mut key = [0u8; 8];
    for (slot, byte) in key.iter_mut().zip(password) {
        *slot = byte.reverse_bits();
    }
    let mut out = [0u8; 16];
    for half in 0..2 {
        let mut block = [0u8; 8];
        block.copy_from_slice(&challenge[half * 8..half * 8 + 8]);
        out[half * 8..half * 8 + 8].copy_from_slice(&encrypt_block(key, block));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn des_matches_the_textbook_vector() {
        let key = 0x1334_5779_9BBC_DFF1u64.to_be_bytes();
        let plain = 0x0123_4567_89AB_CDEFu64.to_be_bytes();
        assert_eq!(encrypt_block(key, plain), 0x85E8_1354_0F0A_B405u64.to_be_bytes());
    }

    #[test]
    fn des_matches_the_nist_zero_key_vector() {
        // FIPS 81 / NBS: key 0101010101010101, plaintext 95F8A5E5DD31D900 -> 8000000000000000.
        let key = 0x0101_0101_0101_0101u64.to_be_bytes();
        let plain = 0x95F8_A5E5_DD31_D900u64.to_be_bytes();
        assert_eq!(encrypt_block(key, plain), 0x8000_0000_0000_0000u64.to_be_bytes());
    }

    #[test]
    fn vnc_response_uses_bit_reversed_key_and_both_blocks() {
        let challenge: [u8; 16] = core::array::from_fn(|i| i as u8);
        let response = vnc_response(b"password-longer-than-8", challenge);
        let mut key = [0u8; 8];
        for (slot, byte) in key.iter_mut().zip(b"password") {
            *slot = byte.reverse_bits();
        }
        let first: [u8; 8] = challenge[..8].try_into().unwrap();
        let second: [u8; 8] = challenge[8..].try_into().unwrap();
        assert_eq!(&response[..8], &encrypt_block(key, first));
        assert_eq!(&response[8..], &encrypt_block(key, second));
        // Only the first 8 bytes of the password count.
        assert_eq!(response, vnc_response(b"password", challenge));
    }
}
