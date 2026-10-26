//! Rectangle decoders. Every length and coordinate from the server is
//! checked before it is used; a bad one ends the session with
//! [`VncError::Protocol`].

mod hextile;
mod tight;
mod zrle;

use std::io::Read;

use flate2::{Decompress, FlushDecompress};

use crate::error::{Result, VncError};
use crate::framebuffer::{Framebuffer, Rect};
use crate::pixel::PixelFormat;
use crate::wire::WireReader;

/// Rectangle encodings and pseudo-encodings (RFC 6143 7.7 and 7.8).
pub mod encoding {
    pub const RAW: i32 = 0;
    pub const COPY_RECT: i32 = 1;
    pub const RRE: i32 = 2;
    pub const HEXTILE: i32 = 5;
    pub const ZLIB: i32 = 6;
    pub const TIGHT: i32 = 7;
    pub const ZRLE: i32 = 16;
    pub const DESKTOP_SIZE: i32 = -223;
    pub const LAST_RECT: i32 = -224;
    pub const CURSOR: i32 = -239;
    pub const DESKTOP_NAME: i32 = -307;
    pub const EXTENDED_DESKTOP_SIZE: i32 = -308;
    /// Tight/Zlib compression level 6 (-256 + level).
    pub const COMPRESS_LEVEL_6: i32 = -250;

    /// What this client advertises, most preferred first. ZRLE is the best
    /// lossless choice on every target server; Tight (no JPEG: no quality
    /// level is sent) for TightVNC; Hextile and RRE for old servers; CopyRect
    /// makes scrolling and window moves cheap; Raw always works.
    pub fn advertised(local_cursor: bool) -> Vec<i32> {
        let mut list = vec![
            COPY_RECT,
            ZRLE,
            TIGHT,
            ZLIB,
            HEXTILE,
            RRE,
            RAW,
            EXTENDED_DESKTOP_SIZE,
            DESKTOP_SIZE,
            LAST_RECT,
            DESKTOP_NAME,
            COMPRESS_LEVEL_6,
        ];
        if local_cursor {
            list.push(CURSOR);
        }
        list
    }
}

/// A cursor shape the server asked the client to draw (Cursor pseudo-encoding).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Cursor {
    pub hotspot_x: u16,
    pub hotspot_y: u16,
    pub width: u16,
    pub height: u16,
    /// RGBA, alpha 0 where the mask is clear.
    pub rgba: Vec<u8>,
}

/// The persistent zlib streams of one connection.
pub struct Decoders {
    zlib: Decompress,
    zrle: Decompress,
    tight: [Decompress; 4],
}

impl Default for Decoders {
    fn default() -> Self {
        Self {
            zlib: Decompress::new(true),
            zrle: Decompress::new(true),
            tight: std::array::from_fn(|_| Decompress::new(true)),
        }
    }
}

impl Decoders {
    /// Decodes one pixel-data rectangle into `fb`. `rect` is checked first.
    pub fn decode<R: Read>(
        &mut self,
        reader: &mut WireReader<R>,
        fb: &mut Framebuffer,
        format: &PixelFormat,
        encoding: i32,
        rect: &Rect,
    ) -> Result<()> {
        fb.check(rect)?;
        match encoding {
            encoding::RAW => raw(reader, fb, format, rect),
            encoding::COPY_RECT => {
                let (src_x, src_y) = (reader.u16()?, reader.u16()?);
                fb.check(&Rect::new(src_x, src_y, rect.width, rect.height))?;
                fb.copy(src_x, src_y, rect);
                Ok(())
            }
            encoding::RRE => rre(reader, fb, format, rect),
            encoding::HEXTILE => hextile::decode(reader, fb, format, rect),
            encoding::ZLIB => {
                let data = reader.compressed("Zlib")?;
                let expected = pixel_bytes(rect, format.bytes_per_pixel());
                let pixels = inflate(&mut self.zlib, &data, expected)?;
                if pixels.len() != expected {
                    return Err(VncError::protocol("Zlib rectangle size"));
                }
                put_wire_pixels(fb, format, rect, &pixels);
                Ok(())
            }
            encoding::ZRLE => {
                let data = reader.compressed("ZRLE")?;
                // Raw tiles plus one subencoding byte per 64x64 tile is the most a rectangle can need.
                let tiles = rect.width.div_ceil(64) as usize * rect.height.div_ceil(64) as usize;
                let limit = pixel_bytes(rect, format.cpixel_len()) + tiles * (1 + 127 * 4);
                let bytes = inflate(&mut self.zrle, &data, limit)?;
                zrle::decode(&bytes, fb, format, rect)
            }
            encoding::TIGHT => tight::decode(reader, &mut self.tight, fb, format, rect),
            other => Err(VncError::protocol(format!("encoding {other} was not requested"))),
        }
    }
}

pub(crate) fn pixel_bytes(rect: &Rect, bytes_per_pixel: usize) -> usize {
    usize::from(rect.width) * usize::from(rect.height) * bytes_per_pixel
}

/// Writes wire-format pixels (`rect.width * rect.height` of them) into `fb`.
pub(crate) fn put_wire_pixels(
    fb: &mut Framebuffer,
    format: &PixelFormat,
    rect: &Rect,
    bytes: &[u8],
) {
    let mut rgba = vec![0u8; pixel_bytes(rect, 4)];
    format.to_rgba_row(bytes, &mut rgba);
    fb.put(rect, &rgba);
}

fn raw<R: Read>(
    reader: &mut WireReader<R>,
    fb: &mut Framebuffer,
    format: &PixelFormat,
    rect: &Rect,
) -> Result<()> {
    let bpp = format.bytes_per_pixel();
    let mut line = vec![0u8; usize::from(rect.width) * bpp];
    let mut rgba = vec![0u8; usize::from(rect.width) * 4];
    for row in 0..rect.height {
        reader.exact(&mut line)?;
        format.to_rgba_row(&line, &mut rgba);
        fb.put(&Rect::new(rect.x, rect.y + row, rect.width, 1), &rgba);
    }
    Ok(())
}

fn rre<R: Read>(
    reader: &mut WireReader<R>,
    fb: &mut Framebuffer,
    format: &PixelFormat,
    rect: &Rect,
) -> Result<()> {
    let count = reader.u32()?;
    let bpp = format.bytes_per_pixel();
    let background = format.rgba(&reader.bytes(bpp)?);
    fb.fill(rect, background);
    for _ in 0..count {
        let color = format.rgba(&reader.bytes(bpp)?);
        let (x, y, w, h) = (reader.u16()?, reader.u16()?, reader.u16()?, reader.u16()?);
        let sub = sub_rect(rect, x, y, w, h)?;
        fb.fill(&sub, color);
    }
    Ok(())
}

/// A subrectangle relative to `rect`, checked to lie inside it.
pub(crate) fn sub_rect(rect: &Rect, x: u16, y: u16, w: u16, h: u16) -> Result<Rect> {
    if u32::from(x) + u32::from(w) > u32::from(rect.width)
        || u32::from(y) + u32::from(h) > u32::from(rect.height)
    {
        return Err(VncError::protocol("subrectangle outside its rectangle"));
    }
    Ok(Rect::new(rect.x + x, rect.y + y, w, h))
}

/// Reads a Cursor pseudo-encoding rectangle (pixels then a 1-bit mask).
pub fn cursor<R: Read>(
    reader: &mut WireReader<R>,
    format: &PixelFormat,
    rect: &Rect,
) -> Result<Cursor> {
    if rect.width > 256 || rect.height > 256 {
        return Err(VncError::protocol("cursor larger than 256x256"));
    }
    let pixels = reader.bytes(pixel_bytes(rect, format.bytes_per_pixel()))?;
    let mask_stride = usize::from(rect.width).div_ceil(8);
    let mask = reader.bytes(mask_stride * usize::from(rect.height))?;
    let mut rgba = vec![0u8; pixel_bytes(rect, 4)];
    format.to_rgba_row(&pixels, &mut rgba);
    for y in 0..usize::from(rect.height) {
        for x in 0..usize::from(rect.width) {
            let visible = mask[y * mask_stride + x / 8] & (0x80 >> (x % 8)) != 0;
            rgba[(y * usize::from(rect.width) + x) * 4 + 3] = if visible { 255 } else { 0 };
        }
    }
    Ok(Cursor {
        hotspot_x: rect.x,
        hotspot_y: rect.y,
        width: rect.width,
        height: rect.height,
        rgba,
    })
}

/// Inflates `input` on a persistent stream, producing at most `limit` bytes.
/// The buffer keeps one spare byte past `limit`, so the stream can consume
/// the server's sync-flush marker after the last pixel.
pub(crate) fn inflate(stream: &mut Decompress, input: &[u8], limit: usize) -> Result<Vec<u8>> {
    let room = limit + 1;
    let mut out: Vec<u8> = Vec::with_capacity(room.min(input.len().saturating_mul(4).max(1024)));
    let start = stream.total_in();
    loop {
        if out.len() == out.capacity() {
            if out.len() >= room {
                return Err(VncError::protocol("compressed rectangle inflates past its size"));
            }
            out.reserve_exact((room - out.len()).min(out.len().max(4096)));
        }
        let consumed = (stream.total_in() - start) as usize;
        let (before_in, before_out) = (stream.total_in(), stream.total_out());
        stream
            .decompress_vec(&input[consumed..], &mut out, FlushDecompress::Sync)
            .map_err(|error| VncError::protocol(format!("zlib: {error}")))?;
        if out.len() > limit {
            return Err(VncError::protocol("compressed rectangle inflates past its size"));
        }
        let consumed = (stream.total_in() - start) as usize;
        if consumed >= input.len() && out.len() < out.capacity() {
            return Ok(out);
        }
        if stream.total_in() == before_in && stream.total_out() == before_out {
            if consumed >= input.len() {
                return Ok(out);
            }
            return Err(VncError::protocol("zlib stream stalled"));
        }
    }
}

/// Reads bytes from a decompressed buffer, failing past its end.
pub(crate) struct Cursor8<'a> {
    bytes: &'a [u8],
    at: usize,
}

impl<'a> Cursor8<'a> {
    pub fn new(bytes: &'a [u8]) -> Self {
        Self { bytes, at: 0 }
    }

    pub fn take(&mut self, len: usize) -> Result<&'a [u8]> {
        let end = self.at.checked_add(len).filter(|&end| end <= self.bytes.len());
        let end = end.ok_or_else(|| VncError::protocol("compressed data ends early"))?;
        let slice = &self.bytes[self.at..end];
        self.at = end;
        Ok(slice)
    }

    pub fn u8(&mut self) -> Result<u8> {
        Ok(self.take(1)?[0])
    }
}

#[cfg(test)]
mod tests;
