//! A real PNG of a given length for tests that send a picture. acpmux reads every inline PNG for
//! its metadata and refuses one it cannot read (`src/image_privacy.rs`), so a test picture is a
//! whole PNG, not a signature padded with filler. Its own copy for unit tests is
//! `image_privacy::fixture_png`.

/// A valid grey PNG one pixel high, `n` bytes long (at least 72), its pixels `seed`: IHDR, one
/// IDAT of stored deflate blocks, IEND. Nothing in it is metadata, so acpmux sends it as it is.
#[allow(dead_code)]
pub fn png_of_len(n: usize, seed: u8) -> Vec<u8> {
    // Signature 8, IHDR 25, IDAT head and CRC 12, zlib head 2 and Adler-32 4, IEND 12.
    const FIXED: usize = 8 + 25 + 12 + 6 + 12;
    let total = |raw: usize| FIXED + raw + 5 * raw.div_ceil(65_535).max(1);
    let mut raw = n.saturating_sub(FIXED + 5).max(2);
    while raw > 2 && total(raw) > n {
        raw -= 1;
    }
    // One row: its filter byte (0) and `raw - 1` pixels.
    let mut row = vec![seed; raw];
    row[0] = 0;
    let mut z = vec![0x78, 0x01];
    let blocks: Vec<&[u8]> = row.chunks(65_535).collect();
    for (i, block) in blocks.iter().enumerate() {
        z.push(u8::from(i + 1 == blocks.len()));
        let len = u16::try_from(block.len()).unwrap();
        z.extend(len.to_le_bytes());
        z.extend((!len).to_le_bytes());
        z.extend(*block);
    }
    let (mut a, mut b) = (1u32, 0u32);
    for byte in &row {
        a = (a + u32::from(*byte)) % 65_521;
        b = (b + a) % 65_521;
    }
    z.extend(((b << 16) | a).to_be_bytes());
    let mut ihdr = u32::try_from(raw - 1).unwrap().to_be_bytes().to_vec();
    ihdr.extend(1u32.to_be_bytes());
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
