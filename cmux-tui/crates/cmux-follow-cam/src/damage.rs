//! Damage from a video's frames: where the pixels changed between two
//! frames, as [`Signal::Damage`] rects, and a [`Signal::Cut`] when most of
//! the frame changed (a scene change), so a recording with no signal trace
//! still gets a camera.
//!
//! Works on small grayscale frames (about 320 pixels wide is plenty, see
//! [`thumbnail`]); the rects come back in the source's pixels.

use crate::Signal;

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct DamageConfig {
    /// The side of a block, in thumbnail pixels: the damage's grain.
    pub block: usize,
    /// A pixel whose gray level moved by more than this changed (video
    /// compression noise moves a few levels).
    pub pixel_threshold: u8,
    /// A block with at least this many changed pixels changed.
    pub block_pixels: usize,
    /// When more than this share of the blocks changed, the frame is a cut.
    pub cut_share: f64,
}

impl Default for DamageConfig {
    fn default() -> Self {
        Self { block: 8, pixel_threshold: 24, block_pixels: 2, cut_share: 0.5 }
    }
}

/// Compares each frame with the one before it.
#[derive(Debug, Clone)]
pub struct FrameDiff {
    config: DamageConfig,
    w: usize,
    h: usize,
    prev: Option<Vec<u8>>,
}

impl FrameDiff {
    /// Frames of `w` x `h` gray pixels, row by row.
    pub fn new(config: DamageConfig, w: usize, h: usize) -> Self {
        let config = DamageConfig { block: config.block.max(1), ..config };
        Self { config, w, h, prev: None }
    }

    /// The signals for the next frame: nothing for the first one, else the
    /// changed regions since the last frame (one rect per group of touching
    /// changed blocks), or one cut. `scale` maps a thumbnail pixel to the
    /// source's pixels (x, y). A frame of the wrong size says nothing and
    /// starts the comparison over.
    pub fn push(&mut self, gray: &[u8], scale: (f64, f64)) -> Vec<Signal> {
        if gray.len() != self.w * self.h {
            self.prev = None;
            return Vec::new();
        }
        let Some(prev) = self.prev.as_mut() else {
            self.prev = Some(gray.to_vec());
            return Vec::new();
        };
        let block = self.config.block;
        let (bw, bh) = (self.w.div_ceil(block), self.h.div_ceil(block));
        let mut counts = vec![0usize; bw * bh];
        for y in 0..self.h {
            let row = y * self.w;
            let brow = (y / block) * bw;
            for x in 0..self.w {
                if gray[row + x].abs_diff(prev[row + x]) > self.config.pixel_threshold {
                    counts[brow + x / block] += 1;
                }
            }
        }
        prev.copy_from_slice(gray);
        let mut changed: Vec<bool> =
            counts.iter().map(|&n| n >= self.config.block_pixels.max(1)).collect();
        let total = changed.iter().filter(|&&c| c).count();
        if total == 0 {
            return Vec::new();
        }
        if total as f64 > self.config.cut_share * (bw * bh) as f64 {
            return vec![Signal::Cut];
        }
        // One rect per 8-connected group of changed blocks.
        let mut signals = Vec::new();
        let mut stack = Vec::new();
        for start in 0..changed.len() {
            if !changed[start] {
                continue;
            }
            changed[start] = false;
            stack.push(start);
            let (mut x0, mut y0, mut x1, mut y1) = (usize::MAX, usize::MAX, 0, 0);
            while let Some(i) = stack.pop() {
                let (bx, by) = (i % bw, i / bw);
                (x0, y0, x1, y1) = (x0.min(bx), y0.min(by), x1.max(bx), y1.max(by));
                for ny in by.saturating_sub(1)..=(by + 1).min(bh - 1) {
                    for nx in bx.saturating_sub(1)..=(bx + 1).min(bw - 1) {
                        let n = ny * bw + nx;
                        if changed[n] {
                            changed[n] = false;
                            stack.push(n);
                        }
                    }
                }
            }
            let (px0, py0) = (x0 * block, y0 * block);
            let (px1, py1) = (((x1 + 1) * block).min(self.w), ((y1 + 1) * block).min(self.h));
            signals.push(Signal::Damage {
                x: px0 as f64 * scale.0,
                y: py0 as f64 * scale.1,
                w: (px1 - px0) as f64 * scale.0,
                h: (py1 - py0) as f64 * scale.1,
            });
        }
        signals
    }
}

/// The size [`thumbnail`] makes of a `w` x `h` plane for `out_w`.
pub fn thumbnail_size(w: usize, h: usize, out_w: usize) -> (usize, usize) {
    let out_w = out_w.clamp(1, w.max(1));
    (out_w, ((h * out_w + w / 2) / w.max(1)).clamp(1, h.max(1)))
}

/// A gray thumbnail `out_w` pixels wide (each pixel the mean of the area it
/// covers) of a `w` x `h` luma plane; returns it with its height.
pub fn thumbnail(luma: &[u8], w: usize, h: usize, out_w: usize) -> (Vec<u8>, usize) {
    if w == 0 || h == 0 || luma.len() < w * h {
        return (Vec::new(), 0);
    }
    let (out_w, out_h) = thumbnail_size(w, h, out_w);
    let span = |i: usize, n: usize, out: usize| {
        let a = i * n / out;
        let b = ((i + 1) * n / out).max(a + 1).min(n);
        (a, b)
    };
    let columns: Vec<(usize, usize)> = (0..out_w).map(|i| span(i, w, out_w)).collect();
    let mut out = Vec::with_capacity(out_w * out_h);
    for oy in 0..out_h {
        let (ya, yb) = span(oy, h, out_h);
        for &(xa, xb) in &columns {
            let mut sum = 0u64;
            for y in ya..yb {
                sum += luma[y * w + xa..y * w + xb].iter().map(|&v| u64::from(v)).sum::<u64>();
            }
            let n = ((yb - ya) * (xb - xa)) as u64;
            out.push(((sum + n / 2) / n) as u8);
        }
    }
    (out, out_h)
}
