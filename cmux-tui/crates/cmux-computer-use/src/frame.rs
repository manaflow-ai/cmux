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

/// One window to paint out: its frame, and the frames (global points) of the
/// allowed windows in front of it, whose pixels are left as they are.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Redaction {
    pub rect: Rect,
    pub occluders: Vec<Rect>,
}

/// How far a covering window's frame is shrunk before it counts as covering:
/// rounded corners and shadows can show what is behind them.
pub const OCCLUDER_INSET: f64 = 12.0;

/// Paints `rects` (global points) black inside `frame`.
pub fn redact(frame: &mut RawFrame, rects: &[Rect]) -> usize {
    let items: Vec<Redaction> =
        rects.iter().map(|r| Redaction { rect: *r, occluders: vec![] }).collect();
    redact_visible(frame, &items)
}

/// Paints each window's visible part black: its frame minus its occluders
/// (each shrunk by [`OCCLUDER_INSET`]). Returns how many windows had any pixel painted.
pub fn redact_visible(frame: &mut RawFrame, items: &[Redaction]) -> usize {
    let mut count = 0;
    for item in items {
        let r = item.rect;
        let x0 = ((r.x - frame.origin.x) * frame.scale).floor().max(0.0) as i64;
        let y0 = ((r.y - frame.origin.y) * frame.scale).floor().max(0.0) as i64;
        let x1 = (((r.x + r.width) - frame.origin.x) * frame.scale).ceil() as i64;
        let y1 = (((r.y + r.height) - frame.origin.y) * frame.scale).ceil() as i64;
        let x1 = x1.min(frame.width as i64);
        let y1 = y1.min(frame.height as i64);
        if x0 >= x1 || y0 >= y1 {
            continue;
        }
        // The occluders in frame pixels, shrunk; empty ones dropped.
        let covers: Vec<(f64, f64, f64, f64)> = item
            .occluders
            .iter()
            .map(|o| {
                (
                    (o.x + OCCLUDER_INSET - frame.origin.x) * frame.scale,
                    (o.y + OCCLUDER_INSET - frame.origin.y) * frame.scale,
                    (o.x + o.width - OCCLUDER_INSET - frame.origin.x) * frame.scale,
                    (o.y + o.height - OCCLUDER_INSET - frame.origin.y) * frame.scale,
                )
            })
            .filter(|(a, b, c, d)| a < c && b < d)
            .collect();
        let mut painted = false;
        for y in y0..y1 {
            let py = y as f64 + 0.5;
            let row = (y as usize) * frame.width as usize * 4;
            for x in x0..x1 {
                let px = x as f64 + 0.5;
                if covers.iter().any(|(a, b, c, d)| px >= *a && px < *c && py >= *b && py < *d) {
                    continue;
                }
                let i = row + x as usize * 4;
                frame.rgba[i] = 24;
                frame.rgba[i + 1] = 24;
                frame.rgba[i + 2] = 28;
                frame.rgba[i + 3] = 255;
                painted = true;
            }
        }
        if painted {
            count += 1;
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

/// Runs the pipeline. `previous`: the digest this session last saw of the
/// same target; `force` sends the image even when unchanged.
pub fn process(
    mut frame: RawFrame,
    redactions: &[Redaction],
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
    let redacted = redact_visible(&mut frame, redactions);
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
        let e = process(f, &[], DEFAULT_MAX_EDGE, None, false).unwrap();
        assert_eq!((e.geometry.width, e.geometry.height), (1456, 910));
        assert!((e.geometry.points_per_pixel - 1.0).abs() < 1e-9);
        assert_eq!(e.geometry.to_global(10.0, 20.0), Point { x: 110.0, y: 70.0 });
        assert!(e.png_base64.is_some());
    }

    #[test]
    fn unchanged_frames_send_no_image() {
        let a = process(frame(40, 30, 1.0), &[], 100, None, false).unwrap();
        let b = process(frame(40, 30, 1.0), &[], 100, Some(a.digest), false).unwrap();
        assert!(b.unchanged && b.png_base64.is_none());
        let c = process(frame(40, 30, 1.0), &[], 100, Some(a.digest), true).unwrap();
        assert!(c.png_base64.is_some());
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
    fn an_allowed_window_in_front_keeps_its_pixels() {
        // A 100x100 pt frame at 1x; a denied window fills it; an allowed window
        // covers its middle. Only the uncovered parts (and the inset) are painted.
        let mut f = RawFrame {
            width: 100,
            height: 100,
            rgba: vec![255; 100 * 100 * 4],
            scale: 1.0,
            origin: Point { x: 0.0, y: 0.0 },
        };
        let item = Redaction {
            rect: Rect { x: 0.0, y: 0.0, width: 100.0, height: 100.0 },
            occluders: vec![Rect { x: 20.0, y: 20.0, width: 60.0, height: 60.0 }],
        };
        assert_eq!(redact_visible(&mut f, &[item]), 1);
        let at = |x: usize, y: usize| f.rgba[(y * 100 + x) * 4];
        assert_eq!(at(5, 5), 24, "outside the cover: painted");
        assert_eq!(at(50, 50), 255, "under the cover: left as it is");
        assert_eq!(at(25, 25), 24, "within the inset: painted (corners, shadows)");
        // Fully covered: nothing painted, not counted.
        let mut g = RawFrame { rgba: vec![255; 100 * 100 * 4], ..f.clone() };
        let hidden = Redaction {
            rect: Rect { x: 40.0, y: 40.0, width: 10.0, height: 10.0 },
            occluders: vec![Rect { x: 0.0, y: 0.0, width: 100.0, height: 100.0 }],
        };
        assert_eq!(redact_visible(&mut g, &[hidden]), 0);
    }

    #[test]
    fn rejects_short_buffers() {
        let mut f = frame(4, 4, 1.0);
        f.rgba.truncate(10);
        assert!(process(f, &[], 100, None, false).is_err());
    }
}
