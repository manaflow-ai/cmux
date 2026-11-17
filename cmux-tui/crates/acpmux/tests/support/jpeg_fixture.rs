//! A baseline grey JPEG for tests: 8 px black and white squares, one per DCT block, so each
//! block is its DC term alone (`src/model_copies.rs` tests have the same writer).

#[allow(dead_code)]
pub fn checker_jpeg_of(w: u32, h: u32) -> Vec<u8> {
    let mut out = vec![0xff, 0xd8];
    let segment = |out: &mut Vec<u8>, marker: u8, body: &[u8]| {
        out.extend([0xff, marker]);
        out.extend(u16::try_from(body.len() + 2).unwrap().to_be_bytes());
        out.extend(body);
    };
    let mut dqt = vec![0u8];
    dqt.extend([1u8; 64]);
    segment(&mut out, 0xdb, &dqt);
    let (hb, wb) =
        (u16::try_from(h).unwrap().to_be_bytes(), u16::try_from(w).unwrap().to_be_bytes());
    segment(&mut out, 0xc0, &[8, hb[0], hb[1], wb[0], wb[1], 1, 1, 0x11, 0]);
    let mut dht = vec![0x00, 0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0];
    dht.extend(0..=11u8);
    segment(&mut out, 0xc4, &dht);
    segment(&mut out, 0xc4, &[0x10, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x00]);
    segment(&mut out, 0xda, &[1, 1, 0x00, 0, 63, 0]);
    // The standard luminance DC codes by size category: (code, length).
    const DC: [(u16, u8); 12] = [
        (0b00, 2),
        (0b010, 3),
        (0b011, 3),
        (0b100, 3),
        (0b101, 3),
        (0b110, 3),
        (0b1110, 4),
        (0b11110, 5),
        (0b111110, 6),
        (0b1111110, 7),
        (0b11111110, 8),
        (0b111111110, 9),
    ];
    let (mut acc, mut bits, mut data) = (0u32, 0u8, Vec::new());
    let mut put = |value: u32, len: u8, data: &mut Vec<u8>| {
        for i in (0..len).rev() {
            acc = (acc << 1) | ((value >> i) & 1);
            bits += 1;
            if bits == 8 {
                data.push(acc as u8);
                if acc as u8 == 0xff {
                    data.push(0);
                }
                (acc, bits) = (0, 0);
            }
        }
    };
    let mut previous = 0i32;
    for by in 0..h / 8 {
        for bx in 0..w / 8 {
            let dc = if (bx + by).is_multiple_of(2) { 8 * 127 } else { -8 * 128 };
            let diff = dc - previous;
            previous = dc;
            let size = (32 - diff.unsigned_abs().leading_zeros()) as u8;
            let (code, len) = DC[size as usize];
            put(u32::from(code), len, &mut data);
            let extra = if diff < 0 { (diff - 1) as u32 } else { diff as u32 };
            put(extra & ((1 << size) - 1), size, &mut data);
            // AC: end of block, the one code of length 1.
            put(0, 1, &mut data);
        }
    }
    put(0x7f, 7, &mut data);
    out.extend(data);
    out.extend([0xff, 0xd9]);
    out
}
