//! Base64 (RFC 4648) for the device hub's keys and signatures, and base64url for its JWS
//! tickets. Small enough to keep the lockfile free of another crate.

const STD: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/// Standard base64 with padding.
#[allow(
    clippy::indexing_slicing,
    reason = "chunks(3) yields no empty chunk and every table index is masked to 0..64"
)]
pub fn encode(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let n = (u32::from(chunk[0]) << 16)
            | (u32::from(*chunk.get(1).unwrap_or(&0)) << 8)
            | u32::from(*chunk.get(2).unwrap_or(&0));
        out.push(STD[(n >> 18) as usize & 63] as char);
        out.push(STD[(n >> 12) as usize & 63] as char);
        out.push(if chunk.len() > 1 { STD[(n >> 6) as usize & 63] as char } else { '=' });
        out.push(if chunk.len() > 2 { STD[n as usize & 63] as char } else { '=' });
    }
    out
}

/// Decodes standard or URL-safe base64, padded or not. None on any other character.
pub fn decode(text: &str) -> Option<Vec<u8>> {
    let mut out = Vec::with_capacity(text.len() * 3 / 4);
    let mut acc = 0u32;
    let mut bits = 0;
    for c in text.trim().bytes() {
        let v = match c {
            b'A'..=b'Z' => c - b'A',
            b'a'..=b'z' => c - b'a' + 26,
            b'0'..=b'9' => c - b'0' + 52,
            b'+' | b'-' => 62,
            b'/' | b'_' => 63,
            b'=' => break,
            _ => return None,
        };
        acc = (acc << 6) | u32::from(v);
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((acc >> bits) as u8);
            acc &= (1 << bits) - 1;
        }
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_and_reads_url_safe() {
        for case in [&b""[..], b"f", b"fo", b"foo", b"foob", b"fooba", b"foobar"] {
            assert_eq!(decode(&encode(case)).as_deref(), Some(case));
        }
        assert_eq!(encode(b"foobar"), "Zm9vYmFy");
        assert_eq!(encode(b"fo"), "Zm8=");
        assert_eq!(decode("-_8").unwrap(), decode("+/8=").unwrap());
        assert!(decode("a b").is_none());
    }
}
