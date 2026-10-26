//! Hextile (RFC 6143 7.7.4): 16x16 tiles, each raw or a background plus
//! colored subrectangles.

use std::io::Read;

use crate::error::Result;
use crate::framebuffer::{Framebuffer, Rect};
use crate::pixel::PixelFormat;
use crate::wire::WireReader;

const RAW: u8 = 1;
const BACKGROUND: u8 = 2;
const FOREGROUND: u8 = 4;
const ANY_SUBRECTS: u8 = 8;
const SUBRECTS_COLORED: u8 = 16;

pub fn decode<R: Read>(
    reader: &mut WireReader<R>,
    fb: &mut Framebuffer,
    format: &PixelFormat,
    rect: &Rect,
) -> Result<()> {
    let bpp = format.bytes_per_pixel();
    let mut background = [0, 0, 0, 255];
    let mut foreground = [0, 0, 0, 255];
    for ty in (0..rect.height).step_by(16) {
        for tx in (0..rect.width).step_by(16) {
            let tile = Rect::new(
                rect.x + tx,
                rect.y + ty,
                (rect.width - tx).min(16),
                (rect.height - ty).min(16),
            );
            let flags = reader.u8()?;
            if flags & RAW != 0 {
                let bytes = reader.bytes(super::pixel_bytes(&tile, bpp))?;
                super::put_wire_pixels(fb, format, &tile, &bytes);
                continue;
            }
            if flags & BACKGROUND != 0 {
                background = format.rgba(&reader.bytes(bpp)?);
            }
            fb.fill(&tile, background);
            if flags & FOREGROUND != 0 {
                foreground = format.rgba(&reader.bytes(bpp)?);
            }
            if flags & ANY_SUBRECTS == 0 {
                continue;
            }
            let count = reader.u8()?;
            for _ in 0..count {
                let color = if flags & SUBRECTS_COLORED != 0 {
                    format.rgba(&reader.bytes(bpp)?)
                } else {
                    foreground
                };
                let xy = reader.u8()?;
                let wh = reader.u8()?;
                let sub = super::sub_rect(
                    &tile,
                    u16::from(xy >> 4),
                    u16::from(xy & 15),
                    u16::from(wh >> 4) + 1,
                    u16::from(wh & 15) + 1,
                )?;
                fb.fill(&sub, color);
            }
        }
    }
    Ok(())
}
