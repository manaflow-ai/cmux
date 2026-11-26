//! `GlyphMask.swift`: the stem-weight cache key and value, the image's pixel size, where the
//! glyph image sits in its fill, the ink's clamped components and the reference drawings'
//! constants. The Core Graphics drawing and coverage measurement stay in Swift.

use serde::{Deserialize, Serialize};

/// The weight cache's size at which it empties before the next insert (`cache.count >= 512`).
pub const WEIGHT_CACHE_LIMIT: usize = 512;

/// The reference string `measure` draws to find an ink's stem step.
pub const MEASURE_STRING: &str = "Hlm";
/// `measure`'s bitmap width in pixels.
pub const MEASURE_WIDTH: usize = 96;
/// `measure`'s bitmap height in pixels.
pub const MEASURE_HEIGHT: usize = 40;
/// The scale `measure` and `warmStems` draw at.
pub const REFERENCE_SCALE: f64 = 2.0;
/// The text position (points) `measure` and `warmStems` draw their line at.
pub const REFERENCE_TEXT_POSITION: (f64, f64) = (2.0, 5.0);
/// The string `warmStems` draws in each face.
pub const WARM_STRING: &str = "Hlm1";
/// `warmStems`' bitmap width in pixels.
pub const WARM_WIDTH: usize = 64;
/// `warmStems`' bitmap height in pixels.
pub const WARM_HEIGHT: usize = 32;
/// The weights `warmStems` warms, each in the system and the monospaced-digit system face.
pub const WARM_WEIGHTS: [&str; 3] = ["regular", "medium", "semibold"];

/// `components(of:)` after the sRGB conversion: the first three parts clamped to 0...1; a missing
/// ink (or one with fewer than three parts) is black.
pub fn components(ink: Option<&[f64]>) -> [f64; 3] {
    match ink {
        Some(parts) if parts.len() >= 3 => {
            [parts[0], parts[1], parts[2]].map(|c| c.clamp(0.0, 1.0))
        }
        _ => [0.0, 0.0, 0.0],
    }
}

/// The weight cache key of `weight(of:smoothing:)`: the smoothing bit, then each component's
/// 8-bit value, shifted in.
pub fn weight_key(rgb: [f64; 3], smooths_stems: bool) -> u32 {
    rgb.iter().fold(u32::from(smooths_stems), |key, c| (key << 8) | (c * 255.0).round() as u32)
}

/// The weight `weight(of:smoothing:)` returns for a measured coverage: twice the coverage plus
/// the smoothing bit (so the two smoothings never share a weight).
pub fn weight(measured: i64, smooths_stems: bool) -> i64 {
    measured * 2 + i64::from(smooths_stems)
}

/// The weight cache empties before an insert at this size.
pub fn weight_cache_evicts(count: usize) -> bool {
    count >= WEIGHT_CACHE_LIMIT
}

/// `max(scale, 1)`: every image and placement scale.
pub fn image_scale(scale: f64) -> f64 {
    scale.max(1.0)
}

/// `pixels(_:scale:)`: the size in whole pixels, rounded up (the scale already at least 1).
pub fn pixels(width: f64, height: f64, scale: f64) -> (i64, i64) {
    ((width * scale).ceil() as i64, (height * scale).ceil() as i64)
}

/// The image's pixel size for `size` at `scale` (`image(size:scale:...)`); None where it draws
/// nothing (a side of 0 pixels).
pub fn image_pixels(width: f64, height: f64, scale: f64) -> Option<(i64, i64)> {
    let (w, h) = pixels(width, height, image_scale(scale));
    (w > 0 && h > 0).then_some((w, h))
}

/// `rendersTopDown`: the geometry-flipped flags of a layer and its ancestors combine (each flips).
pub fn renders_top_down(flipped_chain: &[bool]) -> bool {
    flipped_chain.iter().filter(|f| **f).count() % 2 == 1
}

/// Where `place(_:in:scale:)` puts the glyph image in its fill.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Placement {
    /// The frame's origin x (always 0).
    pub x: f64,
    /// The frame's origin y: 0 top-down, else the fill's height less the image's.
    pub y: f64,
    /// The image's width in points (whole pixels over the scale).
    pub width: f64,
    /// The image's height in points.
    pub height: f64,
    /// The image's `contentsScale`.
    pub contents_scale: f64,
}

/// `place(_:in:scale:)` for a fill `width` by `height`.
pub fn place(width: f64, height: f64, scale: f64, top_down: bool) -> Placement {
    let scale = image_scale(scale);
    let (w, h) = pixels(width, height, scale);
    let size_w = w as f64 / scale;
    let size_h = h as f64 / scale;
    let y = if top_down { 0.0 } else { height - size_h };
    Placement { x: 0.0, y, width: size_w, height: size_h, contents_scale: scale }
}
