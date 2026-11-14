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
    for (region, text) in block.chunks_exact_mut(64).zip([username, password]) {
        for (slot, byte) in region.iter_mut().zip(text.bytes().take(63).chain(std::iter::once(0))) {
            *slot = byte;
        }
    }
    block
}

fn left_pad(value: &BigUint, length: usize) -> Vec<u8> {
    let bytes = value.to_bytes_be();
    let mut out = vec![0; length.saturating_sub(bytes.len())];
    out.extend(bytes.iter().skip(bytes.len().saturating_sub(length)).copied());
    out
}

#[cfg(test)]
mod tests;
