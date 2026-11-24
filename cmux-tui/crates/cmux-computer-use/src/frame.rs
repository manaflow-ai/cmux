//! What happens to pixels between the desktop and the agent, the same on
//! every platform:
//!
//! 1. Redact: denied and protected windows inside the frame are painted out
//!    (a display screenshot never leaks a password manager).
//! 2. Downscale so the long edge is at most `max_edge` (models read a
//!    ~1.2 MP image best; larger costs tokens and gains nothing).
//! 3. Change detection: a frame equal to the one this session last saw of
//!    the same target comes back as `unchanged` with no image.
//! 4. PNG encode.
//!
//! [`Geometry`] maps the agent's screenshot pixels back to desktop points.

use base64::Engine as _;

use crate::desktop::{Point, RawFrame, Rect};

pub const DEFAULT_MAX_EDGE: u32 = 1456;

/// How a screenshot the agent saw maps to the desktop.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Geometry {
    /// The screenshot's size, as the agent sees it.
    pub width: u32,
    pub height: u32,
    /// Desktop points per screenshot pixel.
    pub points_per_pixel: f64,
    /// The screenshot's top-left, in global desktop points.
    pub origin: Point,
}

impl Geometry {
    /// A screenshot pixel to a global desktop point.
    pub fn to_global(&self, x: f64, y: f64) -> Point {
        Point {
            x: self.origin.x + x * self.points_per_pixel,
            y: self.origin.y + y * self.points_per_pixel,
        }
    }
    /// A global rect to screenshot pixels.
    pub fn to_pixels(&self, r: &Rect) -> Rect {
        let k = 1.0 / self.points_per_pixel;
        Rect {
            x: ((r.x - self.origin.x) * k).round(),
            y: ((r.y - self.origin.y) * k).round(),
            width: (r.width * k).round(),
            height: (r.height * k).round(),
        }
    }
}

pub struct Encoded {
    pub png_base64: Option<String>,
    pub geometry: Geometry,
    /// FNV-1a of the downscaled pixels.
    pub digest: u64,
    pub unchanged: bool,
    pub redacted: usize,
}

/// Paints `rects` (global points) black inside `frame`.
pub fn redact(frame: &mut RawFrame, rects: &[Rect]) -> usize {
    let mut count = 0;
    for r in rects {
        let x0 = ((r.x - frame.origin.x) * frame.scale).floor().max(0.0) as i64;
        let y0 = ((r.y - frame.origin.y) * frame.scale).floor().max(0.0) as i64;
        let x1 = (((r.x + r.width) - frame.origin.x) * frame.scale).ceil() as i64;
        let y1 = (((r.y + r.height) - frame.origin.y) * frame.scale).ceil() as i64;
        let x1 = x1.min(frame.width as i64);
        let y1 = y1.min(frame.height as i64);
        if x0 >= x1 || y0 >= y1 {
            continue;
        }
        count += 1;
        for y in y0..y1 {
            let row = (y as usize) * frame.width as usize * 4;
            for x in x0..x1 {
                let i = row + x as usize * 4;
                // A frame shorter than its size says keeps what it has.
                if let Some(px) = frame.rgba.get_mut(i..i.saturating_add(4)) {
                    for (dst, value) in px.iter_mut().zip([24, 24, 28, 255]) {
                        *dst = value;
                    }
                }
            }
        }
    }
    count
}

/// Area-average downscale so the long edge is at most `max_edge`.
pub fn downscale(frame: &RawFrame, max_edge: u32) -> (u32, u32, Vec<u8>) {
    let (w, h) = (frame.width.max(1), frame.height.max(1));
    let long = w.max(h);
    if long <= max_edge {
        return (w, h, frame.rgba.clone());
    }
    let k = max_edge as f64 / long as f64;
    let nw = ((w as f64 * k).round() as u32).max(1);
    let nh = ((h as f64 * k).round() as u32).max(1);
    let mut out = vec![0u8; (nw * nh * 4) as usize];
    for ny in 0..nh {
        let sy0 = (ny as u64 * h as u64 / nh as u64) as u32;
        let sy1 = (((ny + 1) as u64 * h as u64).div_ceil(nh as u64) as u32).min(h).max(sy0 + 1);
        for nx in 0..nw {
            let sx0 = (nx as u64 * w as u64 / nw as u64) as u32;
            let sx1 = (((nx + 1) as u64 * w as u64).div_ceil(nw as u64) as u32).min(w).max(sx0 + 1);
            let mut acc = [0u64; 4];
            let mut n = 0u64;
            for sy in sy0..sy1 {
                let row = (sy * w) as usize * 4;
                for sx in sx0..sx1 {
                    let i = row + sx as usize * 4;
                    // A frame shorter than its size says averages what it has.
                    let Some(px) = frame.rgba.get(i..i.saturating_add(4)) else {
                        continue;
                    };
                    for (slot, byte) in acc.iter_mut().zip(px) {
                        *slot += *byte as u64;
                    }
                    n += 1;
                }
            }
            let o = ((ny * nw + nx) * 4) as usize;
            if let Some(px) = out.get_mut(o..o.saturating_add(4)) {
                for (dst, sum) in px.iter_mut().zip(acc) {
                    *dst = (sum / n.max(1)) as u8;
                }
            }
        }
    }
    (nw, nh, out)
}

fn fnv(bytes: &[u8]) -> u64 {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for b in bytes {
        hash ^= *b as u64;
        hash = hash.wrapping_mul(0x0100_0000_01b3);
    }
    hash
}

pub fn encode_png(width: u32, height: u32, rgba: &[u8]) -> Result<Vec<u8>, String> {
    let mut out = Vec::new();
    {
        let mut encoder = png::Encoder::new(&mut out, width, height);
        encoder.set_color(png::ColorType::Rgba);
        encoder.set_depth(png::BitDepth::Eight);
        encoder.set_compression(png::Compression::Fast);
        let mut writer = encoder.write_header().map_err(|e| e.to_string())?;
        writer.write_image_data(rgba).map_err(|e| e.to_string())?;
    }
    Ok(out)
}

/// Runs the pipeline. `previous`: the digest this session last saw of the
/// same target; `force` sends the image even when unchanged.
pub fn process(
    mut frame: RawFrame,
    redact_rects: &[Rect],
    max_edge: u32,
    previous: Option<u64>,
    force: bool,
) -> Result<Encoded, String> {
    if frame.rgba.len() != (frame.width as usize) * (frame.height as usize) * 4 {
        return Err(format!(
            "the desktop returned {} bytes for a {}x{} frame",
            frame.rgba.len(),
            frame.width,
            frame.height
        ));
    }
    let redacted = redact(&mut frame, redact_rects);
    let (w, h, pixels) = downscale(&frame, max_edge);
    let digest = fnv(&pixels);
    let points_per_pixel = (frame.width as f64 / w as f64) / frame.scale.max(0.01);
    let geometry = Geometry { width: w, height: h, points_per_pixel, origin: frame.origin };
    let unchanged = previous == Some(digest);
    let png_base64 = if unchanged && !force {
        None
    } else {
        Some(base64::engine::general_purpose::STANDARD.encode(encode_png(w, h, &pixels)?))
    };
    Ok(Encoded { png_base64, geometry, digest, unchanged, redacted })
}

#[cfg(test)]
#[path = "frame_tests.rs"]
mod tests;
