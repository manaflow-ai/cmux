//! The glass-to-glass marker: 20 cells of 32x32 px in one row at (0,0).
//! Cells 0..15 carry bit i of (counter mod 65536), LSB first; cells 16..19 are guard 1,0,1,0.

pub const CELLS: usize = 20;
pub const CELL: u32 = 32;
const GUARD: [bool; 4] = [true, false, true, false];

/// Cell values (true = white) for a counter.
pub fn cells(counter: u32) -> [bool; CELLS] {
    let mut out = [false; CELLS];
    let v = counter & 0xffff;
    for (i, c) in out.iter_mut().enumerate().take(16) {
        *c = (v >> i) & 1 == 1;
    }
    for (c, guard) in out.iter_mut().skip(16).zip(GUARD) {
        *c = guard;
    }
    out
}

/// Reads the marker from a luma plane. `video_range` selects the threshold (125 vs 128).
/// Only the bench viewer (and the tests) decode markers.
#[cfg(feature = "bench")]
pub fn decode_luma(y: &[u8], stride: usize, video_range: bool) -> Option<u16> {
    let threshold = if video_range { 125 } else { 128 };
    let center = (CELL / 2) as usize;
    let mut bits = [false; CELLS];
    for (i, b) in bits.iter_mut().enumerate() {
        let idx = center * stride + center + CELL as usize * i;
        *b = *y.get(idx)? > threshold;
    }
    if bits.last_chunk::<4>() != Some(&GUARD) {
        return None;
    }
    Some(bits.iter().take(16).enumerate().fold(0u16, |acc, (i, &b)| acc | (u16::from(b) << i)))
}

/// Paints the marker into a 32-bit BGRX image buffer (used by the motion workload). A row
/// narrower than the marker shows the cells that fit; a zero stride has no rows to paint.
pub fn paint_bgrx(buf: &mut [u8], stride: usize, counter: u32) {
    if stride == 0 {
        return;
    }
    let cells = cells(counter);
    for row in buf.chunks_exact_mut(stride).take(CELL as usize) {
        for (span, &white) in row.chunks_mut(CELL as usize * 4).zip(&cells) {
            span.fill(if white { 255 } else { 0 });
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cells_end_with_the_guard() {
        let cells = cells(0b1011);
        assert_eq!(cells[..4], [true, true, false, true]);
        assert!(cells[4..16].iter().all(|c| !c));
        assert_eq!(cells[16..], GUARD);
    }

    #[cfg(feature = "bench")]
    #[test]
    fn a_painted_marker_decodes_to_its_counter() {
        let (width, height) = (CELLS * CELL as usize, CELL as usize + 4);
        let stride = width * 4;
        let mut bgrx = vec![0u8; stride * height];
        paint_bgrx(&mut bgrx, stride, 0x1_2345);
        // The blue byte of each pixel as a luma plane.
        let luma: Vec<u8> = bgrx.chunks_exact(4).map(|px| px[0]).collect();
        assert_eq!(decode_luma(&luma, width, false), Some(0x2345));
        // A plane too small for the marker has none.
        assert_eq!(decode_luma(&luma[..width], width, false), None);
    }

    #[test]
    fn painting_never_leaves_the_buffer() {
        // A row narrower than the marker, a partial last row, and a zero stride.
        let mut narrow = vec![7u8; 100 * 3 + 50];
        paint_bgrx(&mut narrow, 100, 0xffff);
        assert!(narrow[..32 * 3].iter().all(|&b| b == 255));
        assert!(narrow[300..].iter().all(|&b| b == 7));
        paint_bgrx(&mut narrow, 0, 1);
        paint_bgrx(&mut [], 64, 1);
    }
}
