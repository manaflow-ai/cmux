//! A real PNG of about a given length for tests that send a picture. acpmux reads every inline
//! PNG for its metadata and refuses one it cannot read (`src/image_privacy.rs`), so a test
//! picture is a whole PNG, not a signature padded with filler.

/// A valid grey PNG of at least `n` bytes (and at most a row more), its pixels `seed`: IHDR, one
/// IDAT of stored deflate blocks, IEND. Nothing in it is metadata, so acpmux keeps it as it is,
/// and it is at most 1024 px wide, so a small one is within every model's edge.
#[allow(dead_code)]
pub fn png_of_len(n: usize, seed: u8) -> Vec<u8> {
    // Signature 8, IHDR 25, IDAT head and CRC 12, zlib head 2 and Adler-32 4, IEND 12, and 5 per
    // stored block.
    const FIXED: usize = 8 + 25 + 12 + 6 + 12;
    let wanted = n.saturating_sub(FIXED + 5 * n.div_ceil(65_535)).max(2);
    let w = (wanted - 1).clamp(1, 1024);
    let h = wanted.div_ceil(w + 1);
    // Each row: its filter byte (0) and `w` pixels.
    let mut raw = Vec::with_capacity(h * (w + 1));
    for _ in 0..h {
        raw.push(0);
        raw.extend(std::iter::repeat_n(seed, w));
    }
    let mut z = vec![0x78, 0x01];
    let blocks: Vec<&[u8]> = raw.chunks(65_535).collect();
    for (i, block) in blocks.iter().enumerate() {
        z.push(u8::from(i + 1 == blocks.len()));
        let len = u16::try_from(block.len()).unwrap();
        z.extend(len.to_le_bytes());
        z.extend((!len).to_le_bytes());
        z.extend(*block);
    }
    let (mut a, mut b) = (1u32, 0u32);
    for byte in &raw {
        a = (a + u32::from(*byte)) % 65_521;
        b = (b + a) % 65_521;
    }
    z.extend(((b << 16) | a).to_be_bytes());
    let mut ihdr = u32::try_from(w).unwrap().to_be_bytes().to_vec();
    ihdr.extend(u32::try_from(h).unwrap().to_be_bytes());
    ihdr.extend([8, 0, 0, 0, 0]);
    let mut out = b"\x89PNG\r\n\x1a\n".to_vec();
    for (kind, data) in [(b"IHDR", &ihdr[..]), (b"IDAT", &z[..]), (b"IEND", &[][..])] {
        out.extend(u32::try_from(data.len()).unwrap().to_be_bytes());
        let start = out.len();
        out.extend(kind);
        out.extend(data);
        let crc = crc(&out[start..]);
        out.extend(crc.to_be_bytes());
    }
    out
}

fn crc(bytes: &[u8]) -> u32 {
    let mut crc = !0u32;
    for byte in bytes {
        crc ^= u32::from(*byte);
        for _ in 0..8 {
            crc = if crc & 1 == 1 { (crc >> 1) ^ 0xedb8_8320 } else { crc >> 1 };
        }
    }
    !crc
}
