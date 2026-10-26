//! Apple Diffie-Hellman authentication (security type 30), what macOS
//! Screen Sharing offers for a macOS user account. The client finishes the
//! DH exchange, keys AES-128-ECB with MD5(shared secret), and sends the
//! encrypted 128-byte credential block (user name and password, each
//! NUL-terminated in 64 bytes of random padding) followed by its public key.

use aes::Aes128;
use aes::cipher::{BlockEncrypt, KeyInit};
use num_bigint::BigUint;

use super::md5;

/// Largest DH key the server may ask for (macOS uses 128 bytes).
pub const MAX_KEY_BYTES: usize = 1024;

/// What the client sends back: the encrypted credentials, then its public key.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Response {
    pub encrypted_credentials: [u8; 128],
    pub client_public_key: Vec<u8>,
}

/// Computes the response. `private_key` (the prime's length) and `padding`
/// (128 bytes) are random in a session and fixed in tests.
pub fn response(
    generator: u16,
    prime: &[u8],
    server_public_key: &[u8],
    username: &str,
    password: &str,
    private_key: &[u8],
    padding: [u8; 128],
) -> Option<Response> {
    let length = prime.len();
    if length == 0 || server_public_key.len() != length {
        return None;
    }
    let modulus = BigUint::from_bytes_be(prime);
    if modulus <= BigUint::from(1u8) {
        return None;
    }
    let secret = BigUint::from_bytes_be(private_key);
    let client_public = BigUint::from(generator).modpow(&secret, &modulus);
    let shared = BigUint::from_bytes_be(server_public_key).modpow(&secret, &modulus);
    let key = md5::digest(&left_pad(&shared, length));
    let mut block = credentials(username, password, padding);
    let cipher = Aes128::new(&key.into());
    for chunk in block.chunks_exact_mut(16) {
        cipher.encrypt_block(chunk.into());
    }
    Some(Response {
        encrypted_credentials: block,
        client_public_key: left_pad(&client_public, length),
    })
}

/// The 128-byte block: user name at 0 and password at 64, each at most 63
/// bytes and NUL-terminated, over random padding.
pub fn credentials(username: &str, password: &str, padding: [u8; 128]) -> [u8; 128] {
    let mut block = padding;
    for (offset, text) in [(0, username), (64, password)] {
        let bytes = &text.as_bytes()[..text.len().min(63)];
        block[offset..offset + bytes.len()].copy_from_slice(bytes);
        block[offset + bytes.len()] = 0;
    }
    block
}

fn left_pad(value: &BigUint, length: usize) -> Vec<u8> {
    let bytes = value.to_bytes_be();
    let mut out = vec![0; length.saturating_sub(bytes.len())];
    out.extend_from_slice(&bytes[bytes.len().saturating_sub(length)..]);
    out
}

#[cfg(test)]
mod tests {
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
        let shared =
            BigUint::from_bytes_be(&reply.client_public_key).modpow(&server_secret, &modulus);
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
}
