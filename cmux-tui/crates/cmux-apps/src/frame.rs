//! A version's first frame (RFD 0003, publish step 7): the PNG of its loopback target, fitted
//! to what the platform keeps and this machine's agent carries.
//!
//! The platform keeps at most [`FRAME_LIMIT`] decoded bytes (`PUT
//! /v1/cloud/apps/{slug}/versions/{n}/frame`, cmux-platform#1732). The frame goes there as one
//! `apps.call` line, whose JSON body this machine's agent caps at 64 KiB (cmux-host
//! `cloud::apps_call`), so the base64 PNG has to fit in that: [`FRAME_BUDGET`]. A frame over it is
//! re-encoded, then halved until it fits. It is never replaced by anything the app didn't draw.

use std::io::Cursor;

/// The platform's cap on a stored frame, in decoded bytes.
pub const FRAME_LIMIT: usize = 256 * 1024;
/// The decoded bytes one `apps.call` carries: base64 of it, in `{"png": ...}` and the call's
/// line, stays under the agent's 64 KiB body and line caps.
pub const FRAME_BUDGET: usize = 46 * 1024;
/// The page size the frame is rendered at, in CSS pixels at scale 1.
pub const FRAME_WIDTH: u32 = 1280;
pub const FRAME_HEIGHT: u32 = 800;
/// A frame halved below this width is too small to show; none is sent.
const MIN_WIDTH: u32 = 160;
/// A decoded frame larger than this is refused (the capture is 1280x800 RGBA, 4 MB).
const DECODE_LIMIT: usize = 64 * 1024 * 1024;

const SIGNATURE: [u8; 8] = [0x89, b'P', b'N', b'G', b'\r', b'\n', 0x1a, b'\n'];

/// Whether `bytes` starts with the PNG signature (the platform checks it too).
pub fn is_png(bytes: &[u8]) -> bool {
    bytes.starts_with(&SIGNATURE)
}

/// `png` as it is when it fits `budget`, else re-encoded, then halved (2x2 box) until it fits.
/// `Err` when it isn't a PNG, can't be decoded, or no size from its width down to 160 px fits.
pub fn fit(png: &[u8], budget: usize) -> Result<Vec<u8>, String> {
    if !is_png(png) {
        return Err("the capture is not a PNG".to_owned());
    }
    if png.len() <= budget {
        return Ok(png.to_vec());
    }
    let mut image = decode(png)?;
    loop {
        let encoded = image.encode()?;
        if encoded.len() <= budget {
            return Ok(encoded);
        }
        if image.width / 2 < MIN_WIDTH || image.height < 2 {
            return Err(format!(
                "no frame fits {budget} bytes: {}x{} is still {} bytes",
                image.width,
                image.height,
                encoded.len()
            ));
        }
        image = image.halved();
    }
}

/// An 8-bit RGBA image.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Rgba {
    pub width: u32,
    pub height: u32,
    pub pixels: Vec<u8>,
}

fn decode(png: &[u8]) -> Result<Rgba, String> {
    let mut decoder =
        png::Decoder::new_with_limits(Cursor::new(png), png::Limits { bytes: DECODE_LIMIT });
    decoder.set_transformations(png::Transformations::normalize_to_color8());
    let mut reader = decoder.read_info().map_err(|e| format!("the capture's PNG: {e}"))?;
    let mut buf = vec![0; reader.output_buffer_size()];
    let info = reader.next_frame(&mut buf).map_err(|e| format!("the capture's PNG: {e}"))?;
    let data = buf.get(..info.buffer_size()).unwrap_or_default();
    let pixels: Vec<u8> = match info.color_type {
        png::ColorType::Rgba => data.to_vec(),
        png::ColorType::Rgb => data.chunks_exact(3).flat_map(|p| [p[0], p[1], p[2], 255]).collect(),
        png::ColorType::GrayscaleAlpha => {
            data.chunks_exact(2).flat_map(|p| [p[0], p[0], p[0], p[1]]).collect()
        }
        png::ColorType::Grayscale => data.iter().flat_map(|&g| [g, g, g, 255]).collect(),
        png::ColorType::Indexed => return Err("the capture's PNG kept its palette".to_owned()),
    };
    Ok(Rgba { width: info.width, height: info.height, pixels })
}

impl Rgba {
    /// Half the width and height, each pixel the mean of its 2x2 block (an odd last row or
    /// column is dropped).
    pub fn halved(&self) -> Rgba {
        let (w, h) = (self.width / 2, self.height / 2);
        let stride = self.width as usize * 4;
        let mut pixels = Vec::with_capacity(w as usize * h as usize * 4);
        for y in 0..h as usize {
            for x in 0..w as usize {
                let at = |dy: usize, dx: usize, c: usize| {
                    let i = (2 * y + dy) * stride + (2 * x + dx) * 4 + c;
                    u32::from(self.pixels.get(i).copied().unwrap_or_default())
                };
                for c in 0..4 {
                    let sum = at(0, 0, c) + at(0, 1, c) + at(1, 0, c) + at(1, 1, c);
                    pixels.push(u8::try_from((sum + 2) / 4).unwrap_or(u8::MAX));
                }
            }
        }
        Rgba { width: w, height: h, pixels }
    }

    /// A PNG at the best compression; RGB when every pixel is opaque.
    pub fn encode(&self) -> Result<Vec<u8>, String> {
        let opaque = self.pixels.chunks_exact(4).all(|p| p[3] == 255);
        let (color, data) = if opaque {
            let rgb: Vec<u8> =
                self.pixels.chunks_exact(4).flat_map(|p| [p[0], p[1], p[2]]).collect();
            (png::ColorType::Rgb, rgb)
        } else {
            (png::ColorType::Rgba, self.pixels.clone())
        };
        let mut out = Vec::new();
        let mut encoder = png::Encoder::new(&mut out, self.width, self.height);
        encoder.set_color(color);
        encoder.set_depth(png::BitDepth::Eight);
        encoder.set_compression(png::Compression::Best);
        encoder.set_adaptive_filter(png::AdaptiveFilterType::Adaptive);
        let mut writer = encoder.write_header().map_err(|e| format!("encode the frame: {e}"))?;
        writer.write_image_data(&data).map_err(|e| format!("encode the frame: {e}"))?;
        writer.finish().map_err(|e| format!("encode the frame: {e}"))?;
        Ok(out)
    }
}
