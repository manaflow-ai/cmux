//! Standard base64 (RFC 4648 section 4, padded) decoding for the KRL and
//! certificate blobs. The crate has no base64 dependency, and this is the
//! only decoder it needs.

fn value(c: u8) -> Option<u32> {
    match c {
        b'A'..=b'Z' => Some(u32::from(c - b'A')),
        b'a'..=b'z' => Some(u32::from(c - b'a') + 26),
        b'0'..=b'9' => Some(u32::from(c - b'0') + 52),
        b'+' => Some(62),
        b'/' => Some(63),
        _ => None,
    }
}

/// Decodes padded standard base64; `None` on any other input.
pub fn decode(text: &str) -> Option<Vec<u8>> {
    let bytes = text.as_bytes();
    if !bytes.len().is_multiple_of(4) {
        return None;
    }
    let mut out = Vec::with_capacity(bytes.len() / 4 * 3);
    let chunks = bytes.len() / 4;
    for (index, chunk) in bytes.chunks(4).enumerate() {
        let last = index + 1 == chunks;
        let pad = chunk.iter().rev().take_while(|&&c| c == b'=').count();
        if pad > 2 || (pad > 0 && !last) {
            return None;
        }
        let mut acc = 0u32;
        for &c in &chunk[..4 - pad] {
            acc = (acc << 6) | value(c)?;
        }
        acc <<= 6 * pad as u32;
        let three = [(acc >> 16) as u8, (acc >> 8) as u8, acc as u8];
        // Non-zero bits under the padding are not canonical.
        if (pad == 1 && three[2] != 0) || (pad == 2 && (three[1] != 0 || three[2] != 0)) {
            return None;
        }
        out.extend_from_slice(&three[..3 - pad]);
    }
    Some(out)
}
