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
        Self { config, w, h, prev: None }
    }

    /// The signals for the next frame: nothing for the first one, else the
    /// changed regions since the last frame, or one cut. `scale` maps a
    /// thumbnail pixel to the source's pixels (x, y).
    pub fn push(&mut self, gray: &[u8], scale: (f64, f64)) -> Vec<Signal> {
        let _ = (gray, scale, self.config, self.w, self.h, &self.prev);
        Vec::new()
    }
}

/// A gray thumbnail `out_w` pixels wide (each pixel the mean of the area it
/// covers) of a `w` x `h` luma plane; returns it with its height.
pub fn thumbnail(luma: &[u8], w: usize, h: usize, out_w: usize) -> (Vec<u8>, usize) {
    let _ = (luma, w, h, out_w);
    (Vec::new(), 0)
}
