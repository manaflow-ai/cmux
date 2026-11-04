//! Device-signed requests (PROTOCOL.md, "Identity"): `X-Device-Id`,
//! `X-Device-Ts` and `X-Device-Sig`, the signature over
//! `"<METHOD>\n<path+query>\n<ts>\n<hex sha256 of body or empty>"`, and
//! ECDSA P-256 helpers shared by request and decision signatures.

use ring::signature::{ECDSA_P256_SHA256_FIXED, UnparsedPublicKey};
use sha2::{Digest, Sha256};

pub const ID_HEADER: &str = "X-Device-Id";
pub const TIMESTAMP_HEADER: &str = "X-Device-Ts";
pub const SIGNATURE_HEADER: &str = "X-Device-Sig";

/// The P-256 group order n, big-endian.
const ORDER: [u8; 32] = [
    0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xbc, 0xe6, 0xfa, 0xad, 0xa7, 0x17, 0x9e, 0x84, 0xf3, 0xb9, 0xca, 0xc2, 0xfc, 0x63, 0x25, 0x51,
];

/// n / 2 (floor), big-endian: an `s` above it is high.
const HALF_ORDER: [u8; 32] = [
    0x7f, 0xff, 0xff, 0xff, 0x80, 0x00, 0x00, 0x00, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xde, 0x73, 0x7d, 0x56, 0xd3, 0x8b, 0xcf, 0x42, 0x79, 0xdc, 0xe5, 0x61, 0x7e, 0x31, 0x92, 0xa8,
];

/// Lowercase hex SHA-256 of `body`, or the empty string for no body or an
/// empty one.
pub fn body_sha256_hex(body: Option<&[u8]>) -> String {
    match body {
        Some(bytes) if !bytes.is_empty() => hex::encode(Sha256::digest(bytes)),
        _ => String::new(),
    }
}

/// The string a device signs for one request.
pub fn canonical_request(
    method: &str,
    path_and_query: &str,
    timestamp: i64,
    body: Option<&[u8]>,
) -> String {
    format!(
        "{}\n{}\n{}\n{}",
        method.to_ascii_uppercase(),
        path_and_query,
        timestamp,
        body_sha256_hex(body)
    )
}

/// A URL's percent-encoded path (`/` when empty) and `?query` when it has one:
/// the request target as sent.
pub fn path_and_query(url: &url::Url) -> String {
    let path = if url.path().is_empty() { "/" } else { url.path() };
    match url.query() {
        Some(query) => format!("{path}?{query}"),
        None => path.to_owned(),
    }
}

/// The signature with `s` replaced by `n - s` when `s > n/2`. `None` when the
/// signature is not 64 bytes or `s` is zero or not below `n`.
pub fn low_s(signature: &[u8]) -> Option<[u8; 64]> {
    let raw: [u8; 64] = signature.try_into().ok()?;
    let (r, s) = raw.split_at_checked(32)?;
    let s: [u8; 32] = s.try_into().ok()?;
    if s.iter().all(|byte| *byte == 0) || s >= ORDER {
        return None;
    }
    if s <= HALF_ORDER {
        return Some(raw);
    }
    let mut out = [0u8; 64];
    let (out_r, out_s) = out.split_at_mut_checked(32)?;
    out_r.copy_from_slice(r);
    out_s.copy_from_slice(&sub_be(&ORDER, &s));
    Some(out)
}

/// `a - b` for big-endian 256-bit numbers with `a >= b` (wrapping per byte,
/// carrying the borrow).
fn sub_be(a: &[u8; 32], b: &[u8; 32]) -> [u8; 32] {
    let mut out = [0u8; 32];
    let mut borrow = false;
    for ((digit, x), y) in out.iter_mut().zip(a).zip(b).rev() {
        let (less, borrowed) = x.overflowing_sub(*y);
        let (less, borrowed_again) = less.overflowing_sub(u8::from(borrow));
        *digit = less;
        borrow = borrowed || borrowed_again;
    }
    out
}

/// Verifies an ECDSA-P256-SHA256 raw r||s signature of `message` with an X9.63
/// uncompressed public key. High-S signatures verify: `s` is normalized first.
pub fn verify(public_key_x963: &[u8], message: &[u8], signature: &[u8]) -> bool {
    if public_key_x963.len() != 65 || public_key_x963.first() != Some(&0x04) {
        return false;
    }
    let Some(normalized) = low_s(signature) else {
        return false;
    };
    UnparsedPublicKey::new(&ECDSA_P256_SHA256_FIXED, public_key_x963)
        .verify(message, &normalized)
        .is_ok()
}

/// [`verify`] with the key and signature in base64, as the hub sends them.
pub fn verify_base64(public_key_b64: &str, message: &[u8], signature_b64: &str) -> bool {
    use base64::Engine as _;
    let engine = base64::engine::general_purpose::STANDARD;
    match (engine.decode(public_key_b64), engine.decode(signature_b64)) {
        (Ok(key), Ok(sig)) => verify(&key, message, &sig),
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn half_order_is_order_shifted_right() {
        let mut shifted = [0u8; 32];
        let mut carry = 0u8;
        for (index, byte) in ORDER.iter().enumerate() {
            shifted[index] = (byte >> 1) | (carry << 7);
            carry = byte & 1;
        }
        assert_eq!(shifted, HALF_ORDER);
    }

    #[test]
    fn a_high_s_becomes_n_minus_s() {
        // s = n - 1 is high; its low form is 1.
        let mut high = [7u8; 64];
        let mut s = ORDER;
        s[31] -= 1;
        high[32..].copy_from_slice(&s);
        let low = low_s(&high).unwrap();
        assert_eq!(&low[..32], &[7u8; 32]);
        let mut one = [0u8; 32];
        one[31] = 1;
        assert_eq!(&low[32..], &one);
        // s = n/2 is already low and stays.
        let mut half = [9u8; 64];
        half[32..].copy_from_slice(&HALF_ORDER);
        assert_eq!(low_s(&half), Some(half));
        // A borrow across bytes: n - (n/2 + 1).
        let mut above = HALF_ORDER;
        above[31] += 1;
        let mut sig = [0u8; 64];
        sig[32..].copy_from_slice(&above);
        sig[0] = 1;
        let lowered = low_s(&sig).unwrap();
        assert_eq!(&lowered[32..], &HALF_ORDER, "n - (floor(n/2) + 1) = floor(n/2) for odd n");
    }

    #[test]
    fn low_s_refuses_zero_and_out_of_range() {
        assert!(low_s(&[0u8; 64]).is_none());
        let mut sig = [1u8; 64];
        sig[32..].copy_from_slice(&ORDER);
        assert!(low_s(&sig).is_none());
        assert!(low_s(&[1u8; 63]).is_none());
    }

    #[test]
    fn path_and_query_keeps_the_query() {
        let url = url::Url::parse("https://hub.example/v1/sessions/a%20b/ws?ticket=x.y").unwrap();
        assert_eq!(path_and_query(&url), "/v1/sessions/a%20b/ws?ticket=x.y");
    }
}
