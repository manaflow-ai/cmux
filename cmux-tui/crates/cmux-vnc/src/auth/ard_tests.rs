use super::*;
use aes::cipher::BlockDecrypt;

#[test]
fn apple_dh_derives_a_key_the_server_can_decrypt() {
    // A toy group: p = 0xFFFB (prime), g = 2. The server's secret is 7.
    let prime = [0xFF, 0xFB];
    let server_secret = BigUint::from(7u8);
    let modulus = BigUint::from_bytes_be(&prime);
    let server_public = left_pad(&BigUint::from(2u8).modpow(&server_secret, &modulus), 2);
    let padding = [0xAA; 128];
    let reply =
        response(2, &prime, &server_public, "leo", "hunter2", &[0x01, 0x23], padding).unwrap();
    assert_eq!(reply.client_public_key.len(), 2);

    // The server side: shared = client_public ^ server_secret.
    let shared = BigUint::from_bytes_be(&reply.client_public_key).modpow(&server_secret, &modulus);
    let key = md5::digest(&left_pad(&shared, 2));
    let cipher = Aes128::new(&key.into());
    let mut block = reply.encrypted_credentials;
    for chunk in block.chunks_exact_mut(16) {
        cipher.decrypt_block(chunk.into());
    }
    assert_eq!(block, credentials("leo", "hunter2", padding));
    assert_eq!(&block[..4], b"leo\0");
    assert_eq!(&block[64..72], b"hunter2\0");
    assert_eq!(block[4], 0xAA, "padding stays after the terminator");
}

#[test]
fn long_credentials_are_cut_to_63_bytes() {
    let long = "x".repeat(100);
    let block = credentials(&long, &long, [1; 128]);
    assert_eq!(block[62], b'x');
    assert_eq!(block[63], 0);
    assert_eq!(block[127], 0);
}

#[test]
fn mismatched_key_lengths_are_refused() {
    assert!(response(2, &[0xFF, 0xFB], &[1], "a", "b", &[1], [0; 128]).is_none());
    assert!(response(2, &[], &[], "a", "b", &[1], [0; 128]).is_none());
}
