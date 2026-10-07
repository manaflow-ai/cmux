//! The frontend install-key proof (identity.md section 3, P8 slice 3b-2).
//!
//! The Mac app keeps a 32-byte install key in its Keychain and hands it to
//! the daemon it starts over an inherited pipe (never argv or env). On every
//! connection the daemon sends a fresh nonce; the app answers with
//! `HMAC-SHA256(key, CONTEXT || 0 || install_id || 0 || nonce)`. This module
//! is the pure half: the message layout, the MAC, hex coding and the
//! constant-time check. It holds no key and does no I/O.

use hmac::{Hmac, Mac};
use sha2::Sha256;

/// Install key length in bytes.
pub const INSTALL_KEY_LEN: usize = 32;
/// Nonce length in bytes.
pub const NONCE_LEN: usize = 32;
/// Domain separation for the hello proof; a MAC made for another purpose
/// with the same key never verifies here.
pub const CONTEXT: &[u8] = b"cmux-frontend-hello-v1";
/// Longest install id the daemon accepts.
pub const MAX_INSTALL_ID_LEN: usize = 128;

/// HMAC-SHA256 of `message` under `key` (RFC 2104, RustCrypto `hmac`).
pub fn hmac_sha256(key: &[u8], message: &[u8]) -> [u8; 32] {
    // crash-allow: HMAC (RFC 2104) accepts a key of any length; new_from_slice never fails.
    let mut mac = <Hmac<Sha256> as Mac>::new_from_slice(key).expect("HMAC accepts any key length");
    mac.update(message);
    mac.finalize().into_bytes().into()
}

/// An install id is 1..=128 ASCII letters, digits, `-` or `_`, so it can
/// never smuggle a separator into the MAC input or a log line.
pub fn valid_install_id(install_id: &str) -> bool {
    !install_id.is_empty()
        && install_id.len() <= MAX_INSTALL_ID_LEN
        && install_id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_')
}

/// The bytes the proof covers.
fn proof_message(install_id: &str, nonce: &[u8; NONCE_LEN]) -> Vec<u8> {
    let mut message = Vec::with_capacity(CONTEXT.len() + install_id.len() + NONCE_LEN + 2);
    message.extend_from_slice(CONTEXT);
    message.push(0);
    message.extend_from_slice(install_id.as_bytes());
    message.push(0);
    message.extend_from_slice(nonce);
    message
}

/// The proof the app sends, as lowercase hex.
pub fn hello_proof(key: &[u8], install_id: &str, nonce: &[u8; NONCE_LEN]) -> String {
    hex(&hmac_sha256(key, &proof_message(install_id, nonce)))
}

/// Checks `proof` (hex) in constant time. A malformed proof, a wrong key, a
/// wrong install id or another nonce all return false.
pub fn verify_hello_proof(
    key: &[u8],
    install_id: &str,
    nonce: &[u8; NONCE_LEN],
    proof: &str,
) -> bool {
    if !valid_install_id(install_id) {
        return false;
    }
    let Some(provided) = unhex::<32>(proof) else { return false };
    // crash-allow: HMAC (RFC 2104) accepts a key of any length; new_from_slice never fails.
    let mut mac = <Hmac<Sha256> as Mac>::new_from_slice(key).expect("HMAC accepts any key length");
    mac.update(&proof_message(install_id, nonce));
    mac.verify_slice(&provided).is_ok()
}

/// Lowercase hex.
pub fn hex(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        out.push(DIGITS[usize::from(byte >> 4)] as char);
        out.push(DIGITS[usize::from(byte & 0x0f)] as char);
    }
    out
}

/// Exactly `N` bytes of lowercase or uppercase hex, else `None`.
pub fn unhex<const N: usize>(text: &str) -> Option<[u8; N]> {
    let bytes = text.as_bytes();
    if bytes.len() != N * 2 {
        return None;
    }
    let mut out = [0u8; N];
    for (slot, pair) in out.iter_mut().zip(bytes.chunks_exact(2)) {
        *slot = (nibble(pair[0])? << 4) | nibble(pair[1])?;
    }
    Some(out)
}

fn nibble(digit: u8) -> Option<u8> {
    match digit {
        b'0'..=b'9' => Some(digit - b'0'),
        b'a'..=b'f' => Some(digit - b'a' + 10),
        b'A'..=b'F' => Some(digit - b'A' + 10),
        _ => None,
    }
}

#[cfg(test)]
#[path = "frontend_proof_tests.rs"]
mod tests;
