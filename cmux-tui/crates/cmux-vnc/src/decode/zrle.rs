//! ZRLE (RFC 6143 7.7.6): 64x64 tiles of CPIXELs, raw, solid, packed
//! palette, plain RLE or palette RLE, inside one zlib stream.

use super::Cursor8;
use crate::error::{Result, VncError};
use crate::framebuffer::{Framebuffer, Rect};
use crate::pixel::PixelFormat;

pub fn decode(bytes: &[u8], fb: &mut Framebuffer, format: &PixelFormat, rect: &Rect) -> Result<()> {
    let mut data = Cursor8::new(bytes);
    let cpixel = format.cpixel_len();
    let mut tile_rgba = Vec::with_capacity(64 * 64 * 4);
    for ty in (0..rect.height).step_by(64) {
        for tx in (0..rect.width).step_by(64) {
            let tile = Rect::new(
                rect.x + tx,
                rect.y + ty,
                (rect.width - tx).min(64),
                (rect.height - ty).min(64),
            );
            let pixels = usize::from(tile.width) * usize::from(tile.height);
            tile_rgba.clear();
            let sub = data.u8()?;
            match sub {
                0 => {
                    for pixel in data.take(pixels * cpixel)?.chunks_exact(cpixel) {
                        tile_rgba.extend_from_slice(&format.cpixel_rgba(pixel));
                    }
                }
                1 => {
                    fb.fill(&tile, format.cpixel_rgba(data.take(cpixel)?))?;
                    continue;
                }
                2..=16 => {
                    let palette = read_palette(&mut data, format, usize::from(sub))?;
                    let bits = match sub {
                        2 => 1,
                        3 | 4 => 2,
                        _ => 4,
                    };
                    let stride = (usize::from(tile.width) * bits).div_ceil(8);
                    let packed = data.take(stride * usize::from(tile.height))?;
                    for row in packed.chunks_exact(stride) {
                        for x in 0..usize::from(tile.width) {
                            let bit = x * bits;
                            let byte = row
                                .get(bit / 8)
                                .ok_or_else(|| VncError::protocol("ZRLE packed palette bounds"))?;
                            let index = (byte >> (8 - bits - bit % 8)) & ((1 << bits) - 1);
                            let color = palette
                                .get(usize::from(index))
                                .ok_or_else(|| VncError::protocol("ZRLE palette index"))?;
                            tile_rgba.extend_from_slice(color);
                        }
                    }
                }
                128 => {
                    while tile_rgba.len() < pixels * 4 {
                        let color = format.cpixel_rgba(data.take(cpixel)?);
                        run(&mut data, &mut tile_rgba, color, pixels)?;
                    }
                }
                130..=255 => {
                    let palette = read_palette(&mut data, format, usize::from(sub - 128))?;
                    while tile_rgba.len() < pixels * 4 {
                        let index = data.u8()?;
                        let color = *palette
                            .get(usize::from(index & 127))
                            .ok_or_else(|| VncError::protocol("ZRLE palette index"))?;
                        if index & 128 == 0 {
                            tile_rgba.extend_from_slice(&color);
                        } else {
                            run(&mut data, &mut tile_rgba, color, pixels)?;
                        }
                    }
                }
                other => return Err(VncError::protocol(format!("ZRLE subencoding {other}"))),
            }
            if tile_rgba.len() != pixels * 4 {
                return Err(VncError::protocol("ZRLE run past its tile"));
            }
            fb.put(&tile, &tile_rgba)?;
        }
    }
    Ok(())
}

fn read_palette(data: &mut Cursor8<'_>, format: &PixelFormat, size: usize) -> Result<Vec<[u8; 4]>> {
    let cpixel = format.cpixel_len();
    Ok(data.take(size * cpixel)?.chunks_exact(cpixel).map(|p| format.cpixel_rgba(p)).collect())
}

/// A run length (sum of bytes until one below 255, plus 1) of `color`.
fn run(data: &mut Cursor8<'_>, out: &mut Vec<u8>, color: [u8; 4], pixels: usize) -> Result<()> {
    let mut length = 1usize;
    loop {
        let byte = data.u8()?;
        length += usize::from(byte);
        if byte != 255 {
            break;
        }
        if length > pixels {
            return Err(VncError::protocol("ZRLE run past its tile"));
        }
    }
    if out.len() / 4 + length > pixels {
        return Err(VncError::protocol("ZRLE run past its tile"));
    }
    for _ in 0..length {
        out.extend_from_slice(&color);
    }
    Ok(())
}
