//! Base64 helpers: standard alphabet for keys (as WireGuard prints them),
//! URL-safe without padding for tickets.

use base64::Engine;
use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};

pub fn encode_key(key: &[u8]) -> String {
    STANDARD.encode(key)
}

/// A 32-byte key in standard base64, or `None`.
pub fn decode_key(text: &str) -> Option<[u8; 32]> {
    let bytes = STANDARD.decode(text.as_bytes()).ok()?;
    bytes.try_into().ok()
}

pub fn encode_url(bytes: &[u8]) -> String {
    URL_SAFE_NO_PAD.encode(bytes)
}

pub fn decode_url(text: &str) -> Option<Vec<u8>> {
    URL_SAFE_NO_PAD.decode(text.as_bytes()).ok()
}
