//! The glass-to-glass marker: 20 cells of 32x32 px in one row at (0,0).
//! Cells 0..15 carry bit i of (counter mod 65536), LSB first; cells 16..19 are guard 1,0,1,0.

pub const CELLS: usize = 20;
pub const CELL: u32 = 32;
const GUARD: [bool; 4] = [true, false, true, false];

/// Cell values (true = white) for a counter.
// The Linux test app paints the marker; on macOS the marker is its own app (scripts/mac-marker).
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
pub fn cells(counter: u32) -> [bool; CELLS] {
    let mut out = [false; CELLS];
    let v = counter & 0xffff;
    for (i, c) in out.iter_mut().enumerate().take(16) {
        *c = (v >> i) & 1 == 1;
    }
    out[16..].copy_from_slice(&GUARD);
    out
}

/// Reads the marker whose top-left is at `origin` (pixels) from a luma plane. `video_range`
/// selects the threshold (125 vs 128). Only the bench viewer (and the tests) decode markers.
#[cfg(feature = "bench")]
pub fn decode_luma_at(
    y: &[u8],
    stride: usize,
    video_range: bool,
    origin: (usize, usize),
) -> Option<u16> {
    decode_with(video_range, origin, |px, py| y.get(py * stride + px).copied())
}

/// Reads the marker through `luma_at(x, y)`, the luma at a stream pixel (a viewer that scales
/// a smaller picture up to the stream reads it scaled, src/scaled.rs).
#[cfg(feature = "bench")]
pub fn decode_with(
    video_range: bool,
    origin: (usize, usize),
    luma_at: impl Fn(usize, usize) -> Option<u8>,
) -> Option<u16> {
    let threshold = if video_range { 125 } else { 128 };
    let center = (CELL / 2) as usize;
    let mut bits = [false; CELLS];
    for (i, b) in bits.iter_mut().enumerate() {
        *b = luma_at(origin.0 + center + CELL as usize * i, origin.1 + center)? > threshold;
    }
    if bits[16..] != GUARD {
        return None;
    }
    Some(bits[..16].iter().enumerate().fold(0u16, |acc, (i, &b)| acc | (u16::from(b) << i)))
}

/// Paints the marker into a 32-bit BGRX image buffer (used by the motion workload).
// The Linux test app paints the marker; on macOS the marker is its own app (scripts/mac-marker).
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
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

/// The 1024x1024 noise texture of the `motion` workload (fixed seed, so every run codes the
/// same pictures).
pub fn motion_noise() -> Vec<u8> {
    let mut rng = crate::clock::Rng::new(0x0dd_ba11);
    (0..1024 * 1024).map(|_| (rng.next_u64() >> 56) as u8).collect()
}

/// Frame `t` of the `motion` workload into a `w`x`h` BGRX buffer: a full-screen moving
/// gradient plus a moving noise texture, with the marker for `counter` painted in. The test
/// app (`testapp --workload motion`) and `encode-selftest --workload motion` draw the same
/// pictures.
pub fn paint_motion_bgrx(buf: &mut [u8], w: usize, h: usize, noise: &[u8], t: usize, counter: u32) {
    let (dx, dy) = (t * 7, t * 3);
    let stride = w * 4;
    let col: Vec<u8> = (0..w).map(|x| (x * 255 / w) as u8).collect();
    for y in 0..h {
        let ny = ((y + dy) & 1023) * 1024;
        let gy = ((y * 255 / h) + t * 3) as u8;
        let row = &mut buf[y * stride..(y + 1) * stride];
        for (x, px) in row.chunks_exact_mut(4).enumerate() {
            let n = noise[ny + ((x + dx) & 1023)] >> 2;
            let r = col[x].wrapping_add((t * 2) as u8);
            let b = col[x].wrapping_add(gy).wrapping_sub(t as u8);
            px[0] = b.wrapping_add(n);
            px[1] = gy.wrapping_add(n);
            px[2] = r.wrapping_add(n);
            px[3] = 0;
        }
    }
    paint_bgrx(buf, stride, counter);
}
