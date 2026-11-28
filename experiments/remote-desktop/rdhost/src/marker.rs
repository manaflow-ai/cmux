//! The glass-to-glass marker: 20 cells of 32x32 px in one row at (0,0).
//! Cells 0..15 carry bit i of (counter mod 65536), LSB first; cells 16..19 are guard 1,0,1,0.

pub const CELLS: usize = 20;
pub const CELL: u32 = 32;
pub const WIDTH: u32 = CELL * CELLS as u32;
const GUARD: [bool; 4] = [true, false, true, false];

/// Cell values (true = white) for a counter.
pub fn cells(counter: u32) -> [bool; CELLS] {
    let mut out = [false; CELLS];
    let v = counter & 0xffff;
    for (i, c) in out.iter_mut().enumerate().take(16) {
        *c = (v >> i) & 1 == 1;
    }
    out[16..].copy_from_slice(&GUARD);
    out
}

/// Reads the marker from a luma plane. `video_range` selects the threshold (125 vs 128).
pub fn decode_luma(y: &[u8], stride: usize, video_range: bool) -> Option<u16> {
    let threshold = if video_range { 125 } else { 128 };
    let center = (CELL / 2) as usize;
    let mut bits = [false; CELLS];
    for (i, b) in bits.iter_mut().enumerate() {
        let idx = center * stride + center + CELL as usize * i;
        *b = *y.get(idx)? > threshold;
    }
    if bits[16..] != GUARD {
        return None;
    }
    Some(bits[..16].iter().enumerate().fold(0u16, |acc, (i, &b)| acc | (u16::from(b) << i)))
}

/// Paints the marker into a 32-bit BGRX image buffer (used by the motion workload).
pub fn paint_bgrx(buf: &mut [u8], stride: usize, counter: u32) {
    let rows = (CELL as usize).min(buf.len() / stride);
    for (i, white) in cells(counter).iter().enumerate() {
        let v = if *white { 255 } else { 0 };
        let x0 = i * CELL as usize * 4;
        let x1 = (x0 + CELL as usize * 4).min(stride);
        for row in 0..rows {
            buf[row * stride + x0..row * stride + x1].fill(v);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip_through_luma() {
        let w = WIDTH as usize;
        for counter in [0u32, 1, 2, 255, 4097, 65535, 65536 + 7] {
            let mut y = vec![0u8; w * CELL as usize];
            for (i, white) in cells(counter).iter().enumerate() {
                for row in 0..CELL as usize {
                    let s = row * w + i * CELL as usize;
                    y[s..s + CELL as usize].fill(if *white { 235 } else { 16 });
                }
            }
            assert_eq!(decode_luma(&y, w, true), Some((counter & 0xffff) as u16));
        }
    }

    #[test]
    fn rejects_bad_guard() {
        let w = WIDTH as usize;
        let y = vec![200u8; w * CELL as usize];
        assert_eq!(decode_luma(&y, w, true), None);
    }
}
