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
