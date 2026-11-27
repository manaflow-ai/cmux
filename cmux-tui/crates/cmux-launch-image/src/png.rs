//! The pixel size of a PNG from its first 24 bytes (signature and IHDR), without decoding it.

/// The bytes [`png_pixel_size`] reads: the 8-byte signature, the IHDR chunk's length and type, and
/// its width and height.
pub(crate) const HEADER_BYTES: usize = 24;

const SIGNATURE: [u8; 8] = [0x89, b'P', b'N', b'G', b'\r', b'\n', 0x1a, b'\n'];
/// The PNG spec's largest width or height (2^31 - 1).
const MAX_SIDE: u32 = 0x7fff_ffff;

/// The width and height a PNG's IHDR names, or `None` when `bytes` does not start with a PNG
/// signature and an IHDR of 13 bytes, or a side is 0 or over 2^31 - 1.
pub fn png_pixel_size(bytes: &[u8]) -> Option<(u32, u32)> {
    let header: &[u8; HEADER_BYTES] = bytes.get(..HEADER_BYTES)?.try_into().ok()?;
    let [
        s0,
        s1,
        s2,
        s3,
        s4,
        s5,
        s6,
        s7,
        l0,
        l1,
        l2,
        l3,
        t0,
        t1,
        t2,
        t3,
        w0,
        w1,
        w2,
        w3,
        h0,
        h1,
        h2,
        h3,
    ] = *header;
    if [s0, s1, s2, s3, s4, s5, s6, s7] != SIGNATURE
        || [l0, l1, l2, l3] != 13_u32.to_be_bytes()
        || [t0, t1, t2, t3] != *b"IHDR"
    {
        return None;
    }
    let width = u32::from_be_bytes([w0, w1, w2, w3]);
    let height = u32::from_be_bytes([h0, h1, h2, h3]);
    ((1..=MAX_SIDE).contains(&width) && (1..=MAX_SIDE).contains(&height)).then_some((width, height))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn header(width: u32, height: u32) -> Vec<u8> {
        let mut bytes = SIGNATURE.to_vec();
        bytes.extend_from_slice(&13_u32.to_be_bytes());
        bytes.extend_from_slice(b"IHDR");
        bytes.extend_from_slice(&width.to_be_bytes());
        bytes.extend_from_slice(&height.to_be_bytes());
        bytes
    }

    #[test]
    fn reads_the_size() {
        assert_eq!(png_pixel_size(&header(2880, 1800)), Some((2880, 1800)));
    }

    #[test]
    fn refuses_what_is_not_a_png_with_a_size() {
        assert_eq!(png_pixel_size(&header(0, 10)), None);
        assert_eq!(png_pixel_size(&header(10, 0x8000_0000)), None);
        assert_eq!(png_pixel_size(&header(10, 10)[..23]), None);
        assert_eq!(png_pixel_size(b"GIF89a................................"), None);
        let mut wrong_chunk = header(10, 10);
        wrong_chunk[12..16].copy_from_slice(b"IDAT");
        assert_eq!(png_pixel_size(&wrong_chunk), None);
    }
}
