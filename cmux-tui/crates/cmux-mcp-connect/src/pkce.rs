//! PKCE S256 (RFC 7636) and the `state` check (threat model T12). The caller
//! brings the random bytes, so this stays pure and testable.

use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use sha2::{Digest, Sha256};

/// A code verifier from 32 random bytes: 43 base64url characters.
pub fn verifier(random: &[u8; 32]) -> String {
    URL_SAFE_NO_PAD.encode(random)
}

/// The S256 challenge of a verifier.
pub fn challenge_s256(verifier: &str) -> String {
    URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()))
}

/// A `state` from 32 random bytes.
pub fn state(random: &[u8; 32]) -> String {
    URL_SAFE_NO_PAD.encode(random)
}

/// Compares two `state` values in constant time for their length.
pub fn state_matches(expected: &str, got: &str) -> bool {
    let (a, b) = (expected.as_bytes(), got.as_bytes());
    if a.len() != b.len() || a.is_empty() {
        return false;
    }
    a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}
