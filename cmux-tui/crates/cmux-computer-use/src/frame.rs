//! What happens to pixels between the desktop and the agent, the same on
//! every platform:
//!
//! 1. Redact: denied and protected windows inside the frame are painted out
//!    (a display screenshot never leaks a password manager).
//! 2. Downscale so the long edge is at most `max_edge` (models read a
//!    ~1.2 MP image best; larger costs tokens and gains nothing).
//! 3. Change detection: a frame equal to the one this session last saw of
//!    the same target comes back as `unchanged` with no image.
//! 4. Encode: JPEG, or PNG when the agent asks for lossless pixels or when a
//!    small frame is smaller as PNG. `tests/frame_formats.rs` measures every
//!    choice here (bytes, encode time, SSIM and PSNR on text strokes).
//!
//! [`Geometry`] maps the agent's screenshot pixels back to desktop points.

use base64::Engine as _;

use crate::desktop::{Point, RawFrame, Rect};

pub const DEFAULT_MAX_EDGE: u32 = 1456;

/// JPEG quality for screenshots, picked by `tests/frame_formats.rs` and an
/// OCR study of model-sized screens (q92 reads no better than q85).
pub const JPEG_QUALITY: u8 = 85;
/// Frames up to this many pixels also try PNG and send the smaller.
const SMALL_FRAME_PIXELS: u64 = 256 * 256;

pub const MIME_JPEG: &str = "image/jpeg";
pub const MIME_PNG: &str = "image/png";

/// An encoded screenshot, as the agent receives it.
#[derive(Clone, Debug, PartialEq)]
pub struct Image {
    /// [`MIME_JPEG`] or [`MIME_PNG`].
    pub mime: String,
    pub base64: String,
}

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
    pub image: Option<Image>,
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
                frame.rgba[i] = 24;
                frame.rgba[i + 1] = 24;
                frame.rgba[i + 2] = 28;
                frame.rgba[i + 3] = 255;
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
                    for (slot, byte) in acc.iter_mut().zip(&frame.rgba[i..i + 4]) {
                        *slot += *byte as u64;
                    }
                    n += 1;
                }
            }
            let o = ((ny * nw + nx) * 4) as usize;
            for (dst, sum) in out[o..o + 4].iter_mut().zip(acc) {
                *dst = (sum / n.max(1)) as u8;
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

pub fn encode_jpeg(width: u32, height: u32, rgba: &[u8], quality: u8) -> Result<Vec<u8>, String> {
    let (w, h) = (u16::try_from(width), u16::try_from(height));
    let (Ok(w), Ok(h)) = (w, h) else {
        return Err(format!("a {width}x{height} frame is too large for JPEG"));
    };
    let mut out = Vec::new();
    let mut encoder = jpeg_encoder::Encoder::new(&mut out, quality);
    // Full-resolution chroma: 4:2:0 smears colored text (OCR error rate 3.2 % vs 1.4 %).
    encoder.set_sampling_factor(jpeg_encoder::SamplingFactor::R_4_4_4);
    encoder.encode(rgba, w, h, jpeg_encoder::ColorType::Rgba).map_err(|e| e.to_string())?;
    Ok(out)
}

/// The bytes the agent receives and their MIME type: JPEG at
/// [`JPEG_QUALITY`], except that a small frame goes out as PNG when that is
/// smaller, and `lossless` always gets PNG.
pub fn encode(
    width: u32,
    height: u32,
    rgba: &[u8],
    lossless: bool,
) -> Result<(&'static str, Vec<u8>), String> {
    if lossless {
        return Ok((MIME_PNG, encode_png(width, height, rgba)?));
    }
    let jpeg = encode_jpeg(width, height, rgba, JPEG_QUALITY)?;
    if (width as u64) * (height as u64) <= SMALL_FRAME_PIXELS {
        let png = encode_png(width, height, rgba)?;
        if png.len() <= jpeg.len() {
            return Ok((MIME_PNG, png));
        }
    }
    Ok((MIME_JPEG, jpeg))
}

/// Runs the pipeline. `previous`: the digest this session last saw of the
/// same target; `force` sends the image even when unchanged; `lossless`
/// sends PNG.
pub fn process(
    mut frame: RawFrame,
    redact_rects: &[Rect],
    max_edge: u32,
    previous: Option<u64>,
    force: bool,
    lossless: bool,
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
    let image = if unchanged && !force {
        None
    } else {
        let (mime, bytes) = encode(w, h, &pixels, lossless)?;
        let base64 = base64::engine::general_purpose::STANDARD.encode(bytes);
        Some(Image { mime: mime.to_string(), base64 })
    };
    Ok(Encoded { image, geometry, digest, unchanged, redacted })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn frame(w: u32, h: u32, scale: f64) -> RawFrame {
        RawFrame {
            width: w,
            height: h,
            rgba: vec![255; (w * h * 4) as usize],
            scale,
            origin: Point { x: 100.0, y: 50.0 },
        }
    }

    #[test]
    fn downscales_and_maps_back_to_points() {
        let f = frame(2912, 1820, 2.0); // a 1456x910 pt display at 2x
        let e = process(f, &[], DEFAULT_MAX_EDGE, None, false, false).unwrap();
        assert_eq!((e.geometry.width, e.geometry.height), (1456, 910));
        assert!((e.geometry.points_per_pixel - 1.0).abs() < 1e-9);
        assert_eq!(e.geometry.to_global(10.0, 20.0), Point { x: 110.0, y: 70.0 });
        assert_eq!(e.image.unwrap().mime, MIME_JPEG);
    }

    #[test]
    fn unchanged_frames_send_no_image() {
        let a = process(frame(40, 30, 1.0), &[], 100, None, false, false).unwrap();
        let b = process(frame(40, 30, 1.0), &[], 100, Some(a.digest), false, false).unwrap();
        assert!(b.unchanged && b.image.is_none());
        let c = process(frame(40, 30, 1.0), &[], 100, Some(a.digest), true, false).unwrap();
        assert!(c.image.is_some());
    }

    #[test]
    fn redaction_paints_the_denied_window_out() {
        let mut f = frame(20, 20, 2.0); // 10x10 pt at (100, 50)
        let n = redact(&mut f, &[Rect { x: 100.0, y: 50.0, width: 5.0, height: 5.0 }]);
        assert_eq!(n, 1);
        assert_eq!(f.rgba[0], 24); // top-left pixel redacted
        let last = f.rgba.len() - 4;
        assert_eq!(f.rgba[last], 255); // bottom-right untouched
        // Outside the frame: nothing.
        assert_eq!(redact(&mut f, &[Rect { x: 0.0, y: 0.0, width: 10.0, height: 10.0 }]), 0);
    }

    #[test]
    fn rejects_short_buffers() {
        let mut f = frame(4, 4, 1.0);
        f.rgba.truncate(10);
        assert!(process(f, &[], 100, None, false, false).is_err());
    }

    #[test]
    fn screens_go_out_as_jpeg_and_lossless_or_tiny_flat_frames_as_png() {
        let f = frame(800, 600, 1.0);
        let jpeg = process(f, &[], DEFAULT_MAX_EDGE, None, false, false).unwrap().image.unwrap();
        assert_eq!(jpeg.mime, MIME_JPEG);
        let bytes = base64::engine::general_purpose::STANDARD.decode(&jpeg.base64).unwrap();
        assert_eq!(&bytes[..2], &[0xff, 0xd8]);
        let png = process(frame(800, 600, 1.0), &[], DEFAULT_MAX_EDGE, None, false, true);
        assert_eq!(png.unwrap().image.unwrap().mime, MIME_PNG);
        // A flat 40x30 frame is a few dozen bytes as PNG, smaller than any JPEG.
        let tiny = process(frame(40, 30, 1.0), &[], 100, None, false, false).unwrap();
        assert_eq!(tiny.image.unwrap().mime, MIME_PNG);
    }
}
