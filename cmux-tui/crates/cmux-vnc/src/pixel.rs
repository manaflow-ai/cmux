//! RFB pixel formats and their conversion to RGBA.

use crate::error::{Result, VncError};

/// A server pixel format (RFC 6143 7.4). Only true color is decoded; this
/// client always asks for [`PixelFormat::RGBX`] and every server it targets
/// (macOS Screen Sharing, TigerVNC, TightVNC, UltraVNC, RealVNC) honors it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PixelFormat {
    pub bits_per_pixel: u8,
    pub depth: u8,
    pub big_endian: bool,
    pub true_color: bool,
    pub red_max: u16,
    pub green_max: u16,
    pub blue_max: u16,
    pub red_shift: u8,
    pub green_shift: u8,
    pub blue_shift: u8,
}

impl PixelFormat {
    /// 32 bits per pixel, little endian, 8 bits per channel: the bytes in
    /// memory are R, G, B, unused, which is RGBA once the last byte is 255.
    pub const RGBX: Self = Self {
        bits_per_pixel: 32,
        depth: 24,
        big_endian: false,
        true_color: true,
        red_max: 255,
        green_max: 255,
        blue_max: 255,
        red_shift: 0,
        green_shift: 8,
        blue_shift: 16,
    };

    /// Parses the 16-byte wire form.
    pub fn parse(bytes: &[u8; 16]) -> Self {
        Self {
            bits_per_pixel: bytes[0],
            depth: bytes[1],
            big_endian: bytes[2] != 0,
            true_color: bytes[3] != 0,
            red_max: u16::from_be_bytes([bytes[4], bytes[5]]),
            green_max: u16::from_be_bytes([bytes[6], bytes[7]]),
            blue_max: u16::from_be_bytes([bytes[8], bytes[9]]),
            red_shift: bytes[10],
            green_shift: bytes[11],
            blue_shift: bytes[12],
        }
    }

    /// The 16-byte wire form.
    pub fn encode(&self) -> [u8; 16] {
        let [rh, rl] = self.red_max.to_be_bytes();
        let [gh, gl] = self.green_max.to_be_bytes();
        let [bh, bl] = self.blue_max.to_be_bytes();
        [
            self.bits_per_pixel,
            self.depth,
            u8::from(self.big_endian),
            u8::from(self.true_color),
            rh,
            rl,
            gh,
            gl,
            bh,
            bl,
            self.red_shift,
            self.green_shift,
            self.blue_shift,
            0,
            0,
            0,
        ]
    }

    /// Checks that pixels in this format can be decoded.
    pub fn validate(&self) -> Result<()> {
        if !matches!(self.bits_per_pixel, 8 | 16 | 32) {
            return Err(VncError::protocol(format!("{} bits per pixel", self.bits_per_pixel)));
        }
        if !self.true_color {
            return Err(VncError::protocol("color-map pixel formats are not supported"));
        }
        for (max, shift) in [
            (self.red_max, self.red_shift),
            (self.green_max, self.green_shift),
            (self.blue_max, self.blue_shift),
        ] {
            if max == 0 || u32::from(shift) >= u32::from(self.bits_per_pixel) {
                return Err(VncError::protocol("pixel format channel out of range"));
            }
        }
        Ok(())
    }

    pub fn bytes_per_pixel(&self) -> usize {
        usize::from(self.bits_per_pixel / 8)
    }

    /// The pixel value of `bytes` (exactly [`Self::bytes_per_pixel`] long).
    fn value(&self, bytes: &[u8]) -> u32 {
        match (bytes.len(), self.big_endian) {
            (1, _) => u32::from(bytes[0]),
            (2, false) => u32::from(u16::from_le_bytes([bytes[0], bytes[1]])),
            (2, true) => u32::from(u16::from_be_bytes([bytes[0], bytes[1]])),
            (_, false) => u32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]),
            (_, true) => u32::from_be_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]),
        }
    }

    /// RGBA of a pixel value.
    pub fn rgba_of_value(&self, value: u32) -> [u8; 4] {
        [
            scale((value >> self.red_shift) & u32::from(self.red_max), self.red_max),
            scale((value >> self.green_shift) & u32::from(self.green_max), self.green_max),
            scale((value >> self.blue_shift) & u32::from(self.blue_max), self.blue_max),
            255,
        ]
    }

    /// RGBA of one pixel in wire bytes.
    pub fn rgba(&self, bytes: &[u8]) -> [u8; 4] {
        if *self == Self::RGBX {
            return [bytes[0], bytes[1], bytes[2], 255];
        }
        self.rgba_of_value(self.value(bytes))
    }

    /// Converts a run of wire pixels to RGBA into `out` (4 bytes per pixel).
    pub fn to_rgba_row(&self, bytes: &[u8], out: &mut [u8]) {
        let bpp = self.bytes_per_pixel();
        for (pixel, rgba) in bytes.chunks_exact(bpp).zip(out.chunks_exact_mut(4)) {
            rgba.copy_from_slice(&self.rgba(pixel));
        }
    }

    /// Length of a ZRLE CPIXEL: 3 when a 32-bit true-color pixel's channels
    /// fit in its low or high three bytes, else the full pixel.
    pub fn cpixel_len(&self) -> usize {
        if self.bits_per_pixel == 32 && self.depth <= 24 && (self.fits_low() || self.fits_high()) {
            3
        } else {
            self.bytes_per_pixel()
        }
    }

    fn channel_mask(&self) -> u32 {
        (u32::from(self.red_max) << self.red_shift)
            | (u32::from(self.green_max) << self.green_shift)
            | (u32::from(self.blue_max) << self.blue_shift)
    }

    fn fits_low(&self) -> bool {
        self.channel_mask() & 0xFF00_0000 == 0
    }

    fn fits_high(&self) -> bool {
        self.channel_mask() & 0x0000_00FF == 0
    }

    /// RGBA of a CPIXEL (RFC 6143 7.7.6): the three least significant bytes
    /// when the channels fit there, else the three most significant, in the
    /// pixel's byte order.
    pub fn cpixel_rgba(&self, bytes: &[u8]) -> [u8; 4] {
        if bytes.len() != 3 {
            return self.rgba(bytes);
        }
        let (b0, b1, b2) = (u32::from(bytes[0]), u32::from(bytes[1]), u32::from(bytes[2]));
        let value = match (self.fits_low(), self.big_endian) {
            (true, false) => b0 | b1 << 8 | b2 << 16,
            (true, true) => b0 << 16 | b1 << 8 | b2,
            (false, false) => b0 << 8 | b1 << 16 | b2 << 24,
            (false, true) => b0 << 24 | b1 << 16 | b2 << 8,
        };
        self.rgba_of_value(value)
    }

    /// True when Tight sends 3-byte TPIXELs in R, G, B order.
    pub fn tight_rgb(&self) -> bool {
        self.bits_per_pixel == 32
            && self.depth == 24
            && self.red_max == 255
            && self.green_max == 255
            && self.blue_max == 255
    }

    /// Length of a Tight TPIXEL.
    pub fn tpixel_len(&self) -> usize {
        if self.tight_rgb() { 3 } else { self.bytes_per_pixel() }
    }

    /// RGBA of a Tight TPIXEL.
    pub fn tpixel_rgba(&self, bytes: &[u8]) -> [u8; 4] {
        if bytes.len() == 3 { [bytes[0], bytes[1], bytes[2], 255] } else { self.rgba(bytes) }
    }
}

/// Scales a channel value of `0..=max` to `0..=255`.
fn scale(value: u32, max: u16) -> u8 {
    if max == 255 {
        return value as u8;
    }
    ((value * 255 + u32::from(max) / 2) / u32::from(max)) as u8
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rgbx_round_trips_its_wire_form() {
        assert_eq!(PixelFormat::parse(&PixelFormat::RGBX.encode()), PixelFormat::RGBX);
        assert_eq!(PixelFormat::RGBX.rgba(&[1, 2, 3, 99]), [1, 2, 3, 255]);
        assert_eq!(PixelFormat::RGBX.cpixel_len(), 3);
        assert_eq!(PixelFormat::RGBX.cpixel_rgba(&[1, 2, 3]), [1, 2, 3, 255]);
    }

    #[test]
    fn big_endian_bgr_and_rgb565_decode() {
        // macOS's native format: 32 bpp big endian, red in bits 16..24.
        let mut format = PixelFormat::RGBX;
        format.big_endian = true;
        format.red_shift = 16;
        format.blue_shift = 0;
        assert_eq!(format.rgba(&[0, 0x10, 0x20, 0x30]), [0x10, 0x20, 0x30, 255]);
        assert_eq!(format.cpixel_rgba(&[0x10, 0x20, 0x30]), [0x10, 0x20, 0x30, 255]);
        let rgb565 = PixelFormat {
            bits_per_pixel: 16,
            depth: 16,
            big_endian: false,
            true_color: true,
            red_max: 31,
            green_max: 63,
            blue_max: 31,
            red_shift: 11,
            green_shift: 5,
            blue_shift: 0,
        };
        assert_eq!(rgb565.rgba(&0xF800u16.to_le_bytes()), [255, 0, 0, 255]);
        assert_eq!(rgb565.rgba(&0x07E0u16.to_le_bytes()), [0, 255, 0, 255]);
        assert_eq!(rgb565.cpixel_len(), 2);
    }

    #[test]
    fn high_byte_cpixels_read_the_top_three_bytes() {
        let mut format = PixelFormat::RGBX;
        format.red_shift = 8;
        format.green_shift = 16;
        format.blue_shift = 24;
        assert_eq!(format.cpixel_len(), 3);
        assert_eq!(format.cpixel_rgba(&[7, 8, 9]), [7, 8, 9, 255]);
    }

    #[test]
    fn invalid_formats_are_refused() {
        let mut format = PixelFormat::RGBX;
        format.true_color = false;
        assert!(format.validate().is_err());
        let mut format = PixelFormat::RGBX;
        format.bits_per_pixel = 24;
        assert!(format.validate().is_err());
        let mut format = PixelFormat::RGBX;
        format.red_shift = 40;
        assert!(format.validate().is_err());
    }
}
