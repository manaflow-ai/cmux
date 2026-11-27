//! PNG in and out, normalized to 8-bit RGBA, and the pixel content hash.

use sha2::{Digest, Sha256};
use std::fmt;

/// An 8-bit RGBA image, rows top to bottom, no padding.
#[derive(Clone, PartialEq, Eq)]
pub struct Rgba {
    pub width: u32,
    pub height: u32,
    pub data: Vec<u8>,
}

impl fmt::Debug for Rgba {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Rgba({}x{})", self.width, self.height)
    }
}

#[derive(Debug)]
pub struct ImageError(pub String);

impl fmt::Display for ImageError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for ImageError {}

impl Rgba {
    pub fn new(width: u32, height: u32, fill: [u8; 4]) -> Self {
        let mut data = Vec::with_capacity(width as usize * height as usize * 4);
        for _ in 0..(width as usize * height as usize) {
            data.extend_from_slice(&fill);
        }
        Rgba { width, height, data }
    }

    #[inline]
    pub fn pixel(&self, x: u32, y: u32) -> [u8; 4] {
        let i = y as usize * self.width as usize + x as usize;
        self.data.as_chunks::<4>().0.get(i).copied().unwrap_or([0; 4])
    }

    #[inline]
    pub fn set(&mut self, x: u32, y: u32, p: [u8; 4]) {
        let i = y as usize * self.width as usize + x as usize;
        if let Some(px) = self.data.as_chunks_mut::<4>().0.get_mut(i) {
            *px = p;
        }
    }

    /// The content address: SHA-256 of the decoded pixels and size, so two encodings of the same pixels
    /// (RGB or RGBA, any compression, any metadata chunks) share one golden.
    pub fn content_hash(&self) -> String {
        let mut h = Sha256::new();
        h.update(b"cmux-shotdiff/rgba8/v1\n");
        h.update(self.width.to_le_bytes());
        h.update(self.height.to_le_bytes());
        h.update(&self.data);
        hex(&h.finalize())
    }
}

fn hex(bytes: &[u8]) -> String {
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        for nibble in [b >> 4, b & 15] {
            s.push(char::from_digit(u32::from(nibble), 16).unwrap_or('0'));
        }
    }
    s
}

/// Decodes any PNG (gray, gray+alpha, RGB, RGBA, palette, 16-bit) to 8-bit RGBA.
pub fn decode_png(bytes: &[u8]) -> Result<Rgba, ImageError> {
    let mut decoder = png::Decoder::new(std::io::Cursor::new(bytes));
    decoder.set_transformations(png::Transformations::EXPAND | png::Transformations::STRIP_16);
    let mut reader = decoder.read_info().map_err(|e| ImageError(format!("png: {e}")))?;
    let mut buf = vec![0u8; reader.output_buffer_size()];
    let info = reader.next_frame(&mut buf).map_err(|e| ImageError(format!("png: {e}")))?;
    buf.truncate(info.buffer_size());
    let (w, h) = (info.width, info.height);
    let n = w as usize * h as usize;
    let data = match info.color_type {
        png::ColorType::Rgba => buf,
        png::ColorType::Rgb => {
            let mut out = Vec::with_capacity(n * 4);
            for &[r, g, b] in buf.as_chunks::<3>().0 {
                out.extend_from_slice(&[r, g, b, 255]);
            }
            out
        }
        png::ColorType::Grayscale => {
            let mut out = Vec::with_capacity(n * 4);
            for &g in &buf {
                out.extend_from_slice(&[g, g, g, 255]);
            }
            out
        }
        png::ColorType::GrayscaleAlpha => {
            let mut out = Vec::with_capacity(n * 4);
            for &[g, a] in buf.as_chunks::<2>().0 {
                out.extend_from_slice(&[g, g, g, a]);
            }
            out
        }
        png::ColorType::Indexed => return Err(ImageError("png: palette left unexpanded".into())),
    };
    if data.len() != n * 4 {
        return Err(ImageError(format!("png: {} bytes for {w}x{h}", data.len())));
    }
    Ok(Rgba { width: w, height: h, data })
}

/// Encodes RGBA as PNG with fixed settings, so the same pixels always give the same bytes.
pub fn encode_png(img: &Rgba) -> Result<Vec<u8>, ImageError> {
    let mut out = Vec::new();
    {
        let mut enc = png::Encoder::new(&mut out, img.width, img.height);
        enc.set_color(png::ColorType::Rgba);
        enc.set_depth(png::BitDepth::Eight);
        enc.set_compression(png::Compression::Default);
        enc.set_filter(png::FilterType::Paeth);
        enc.set_adaptive_filter(png::AdaptiveFilterType::NonAdaptive);
        let mut writer = enc.write_header().map_err(|e| ImageError(format!("png: {e}")))?;
        writer.write_image_data(&img.data).map_err(|e| ImageError(format!("png: {e}")))?;
        writer.finish().map_err(|e| ImageError(format!("png: {e}")))?;
    }
    Ok(out)
}
