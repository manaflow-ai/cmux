//! Tight (lossless parts): fill, and basic compression with the copy,
//! palette and gradient filters over four zlib streams. JPEG is never
//! requested (no quality pseudo-encoding is sent), so a JPEG rectangle is a
//! protocol error.

use std::io::Read;

use flate2::Decompress;

use super::inflate;
use crate::error::{Result, VncError};
use crate::framebuffer::{Framebuffer, Rect};
use crate::pixel::PixelFormat;
use crate::wire::{MAX_COMPRESSED_BYTES, WireReader};

const FILL: u8 = 0x08;
const JPEG: u8 = 0x09;
const EXPLICIT_FILTER: u8 = 0x04;
const FILTER_COPY: u8 = 0;
const FILTER_PALETTE: u8 = 1;
const FILTER_GRADIENT: u8 = 2;
/// Data shorter than this is sent uncompressed.
const MIN_TO_COMPRESS: usize = 12;

pub fn decode<R: Read>(
    reader: &mut WireReader<R>,
    streams: &mut [Decompress; 4],
    fb: &mut Framebuffer,
    format: &PixelFormat,
    rect: &Rect,
) -> Result<()> {
    let control = reader.u8()?;
    for (index, stream) in streams.iter_mut().enumerate() {
        if control & (1 << index) != 0 {
            *stream = Decompress::new(true);
        }
    }
    let kind = control >> 4;
    let tpixel = format.tpixel_len();
    if kind == FILL {
        return fb.fill(rect, format.tpixel_rgba(&reader.bytes(tpixel)?));
    }
    if kind == JPEG {
        return Err(VncError::protocol("Tight JPEG was not requested"));
    }
    if kind > JPEG {
        return Err(VncError::protocol(format!("Tight compression {kind}")));
    }
    let stream = streams
        .get_mut(usize::from(kind & 3))
        .ok_or_else(|| VncError::protocol("Tight stream index"))?;
    let filter = if kind & EXPLICIT_FILTER != 0 { reader.u8()? } else { FILTER_COPY };
    let (width, height) = (usize::from(rect.width), usize::from(rect.height));
    let mut rgba = Vec::with_capacity(width * height * 4);
    match filter {
        FILTER_COPY => {
            let data = read_data(reader, stream, width * height * tpixel)?;
            for pixel in data.chunks_exact(tpixel) {
                rgba.extend_from_slice(&format.tpixel_rgba(pixel));
            }
        }
        FILTER_PALETTE => {
            let size = usize::from(reader.u8()?) + 1;
            let palette: Vec<[u8; 4]> = reader
                .bytes(size * tpixel)?
                .chunks_exact(tpixel)
                .map(|p| format.tpixel_rgba(p))
                .collect();
            if size == 2 {
                let stride = width.div_ceil(8);
                let data = read_data(reader, stream, stride * height)?;
                for row in data.chunks_exact(stride) {
                    for x in 0..width {
                        let byte = row
                            .get(x / 8)
                            .ok_or_else(|| VncError::protocol("Tight packed palette bounds"))?;
                        let index = (byte >> (7 - x % 8)) & 1;
                        let color = palette
                            .get(usize::from(index))
                            .ok_or_else(|| VncError::protocol("Tight palette index"))?;
                        rgba.extend_from_slice(color);
                    }
                }
            } else {
                let data = read_data(reader, stream, width * height)?;
                for &index in &data {
                    let color = palette
                        .get(usize::from(index))
                        .ok_or_else(|| VncError::protocol("Tight palette index"))?;
                    rgba.extend_from_slice(color);
                }
            }
        }
        FILTER_GRADIENT => {
            let data = read_data(reader, stream, width * height * tpixel)?;
            gradient(&data, format, width, &mut rgba);
        }
        other => return Err(VncError::protocol(format!("Tight filter {other}"))),
    }
    fb.put(rect, &rgba)
}

/// Reads `len` bytes of filtered data: raw when short, else a compact
/// length and zlib data on `stream`.
fn read_data<R: Read>(
    reader: &mut WireReader<R>,
    stream: &mut Decompress,
    len: usize,
) -> Result<Vec<u8>> {
    if len < MIN_TO_COMPRESS {
        return reader.bytes(len);
    }
    let mut compressed = 0usize;
    for shift in [0, 7, 14] {
        let byte = reader.u8()?;
        let bits = if shift == 14 { usize::from(byte) } else { usize::from(byte & 0x7F) };
        compressed |= bits << shift;
        if byte & 0x80 == 0 || shift == 14 {
            break;
        }
    }
    if compressed > MAX_COMPRESSED_BYTES {
        return Err(VncError::protocol("Tight payload too large"));
    }
    let input = reader.bytes(compressed)?;
    let data = inflate(stream, &input, len)?;
    if data.len() != len {
        return Err(VncError::protocol("Tight rectangle size"));
    }
    Ok(data)
}

/// The gradient filter: each channel is the sent value plus the prediction
/// left + above - above-left, clamped to the channel's range.
fn gradient(data: &[u8], format: &PixelFormat, width: usize, out: &mut Vec<u8>) {
    let tpixel = format.tpixel_len();
    let maxes = if tpixel == 3 {
        [255u32; 3]
    } else {
        [u32::from(format.red_max), u32::from(format.green_max), u32::from(format.blue_max)]
    };
    let shifts = [format.red_shift, format.green_shift, format.blue_shift];
    let components = |pixel: &[u8]| -> [u32; 3] {
        if tpixel == 3 {
            let mut channels = [0; 3];
            for (channel, byte) in channels.iter_mut().zip(pixel) {
                *channel = u32::from(*byte);
            }
            channels
        } else {
            let value = wire_value(format, pixel);
            let [r, g, b] = shifts;
            let [rm, gm, bm] = maxes;
            [(value >> r) & rm, (value >> g) & gm, (value >> b) & bm]
        }
    };
    let mut above = vec![[0u32; 3]; width];
    let mut row = vec![[0u32; 3]; width];
    for line in data.chunks_exact(width * tpixel) {
        let mut left = [0u32; 3];
        let mut up_left = [0u32; 3];
        for ((pixel, up), current) in line.chunks_exact(tpixel).zip(&above).zip(&mut row) {
            let sent = components(pixel);
            for (((((channel, sent), left), up), up_left), max) in
                current.iter_mut().zip(sent).zip(left).zip(*up).zip(up_left).zip(maxes)
            {
                let predicted = (i64::from(left) + i64::from(up) - i64::from(up_left))
                    .clamp(0, i64::from(max)) as u32;
                *channel = (sent + predicted) & max;
            }
            left = *current;
            up_left = *up;
            let [r, g, b] = *current;
            if tpixel == 3 {
                out.extend_from_slice(&[r as u8, g as u8, b as u8, 255]);
            } else {
                let [rs, gs, bs] = shifts;
                let packed = (r << rs) | (g << gs) | (b << bs);
                out.extend_from_slice(&format.rgba_of_value(packed));
            }
        }
        std::mem::swap(&mut above, &mut row);
    }
}

fn wire_value(format: &PixelFormat, bytes: &[u8]) -> u32 {
    let mut value = 0u32;
    if format.big_endian {
        for &byte in bytes {
            value = (value << 8) | u32::from(byte);
        }
    } else {
        for &byte in bytes.iter().rev() {
            value = (value << 8) | u32::from(byte);
        }
    }
    value
}
