//! Frozen v1 wire format. See `PROTOCOL.md`; never change existing fields.

pub const MAGIC: [u8; 8] = *b"CMUXKEEP";
pub const VERSION: u16 = 1;
pub const FRAME_LEN: usize = 32;

pub const HELLO: u16 = 1;
pub const EXIT: u16 = 2;
pub const SIZE: u16 = 3;
pub const RESIZE: u16 = 16;
pub const TERMINATE: u16 = 17;

/// Terminal size in cells and, when known, pixels. Pixel sizes let
/// programs that draw images (Kitty graphics, sixel) size their output.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Size {
    pub cols: u16,
    pub rows: u16,
    pub width_px: u16,
    pub height_px: u16,
}

impl Size {
    pub fn new(cols: u16, rows: u16) -> Self {
        Self { cols, rows, width_px: 0, height_px: 0 }
    }

    pub fn cells(&self) -> u32 {
        u32::from(self.cols) | (u32::from(self.rows) << 16)
    }

    pub fn pixels(&self) -> u64 {
        u64::from(self.width_px) | (u64::from(self.height_px) << 16)
    }

    pub fn from_fields(cells: u32, pixels: u64) -> Self {
        Self {
            cols: cells as u16,
            rows: (cells >> 16) as u16,
            width_px: pixels as u16,
            height_px: (pixels >> 16) as u16,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Frame {
    pub version: u16,
    pub kind: u16,
    pub a: u32,
    pub b: u64,
    pub c: u64,
}

impl Frame {
    pub fn new(kind: u16, a: u32, b: u64, c: u64) -> Self {
        Self { version: VERSION, kind, a, b, c }
    }

    pub fn resize(size: Size) -> Self {
        Self::new(RESIZE, size.cells(), size.pixels(), 0)
    }

    pub fn size_report(size: Size, generation: u64) -> Self {
        Self::new(SIZE, size.cells(), size.pixels(), generation)
    }

    /// The size carried by a `RESIZE` or `SIZE` frame.
    pub fn size(&self) -> Size {
        Size::from_fields(self.a, self.b)
    }

    pub fn encode(&self) -> [u8; FRAME_LEN] {
        let mut out = [0u8; FRAME_LEN];
        out[0..8].copy_from_slice(&MAGIC);
        out[8..10].copy_from_slice(&self.version.to_le_bytes());
        out[10..12].copy_from_slice(&self.kind.to_le_bytes());
        out[12..16].copy_from_slice(&self.a.to_le_bytes());
        out[16..24].copy_from_slice(&self.b.to_le_bytes());
        out[24..32].copy_from_slice(&self.c.to_le_bytes());
        out
    }

    /// `None` for a bad magic or a version below 1; the receiver then
    /// closes the connection.
    pub fn decode(bytes: &[u8; FRAME_LEN]) -> Option<Self> {
        if bytes[0..8] != MAGIC {
            return None;
        }
        let version = u16::from_le_bytes([bytes[8], bytes[9]]);
        if version == 0 {
            return None;
        }
        Some(Self {
            version,
            kind: u16::from_le_bytes([bytes[10], bytes[11]]),
            a: u32::from_le_bytes(bytes[12..16].try_into().ok()?),
            b: u64::from_le_bytes(bytes[16..24].try_into().ok()?),
            c: u64::from_le_bytes(bytes[24..32].try_into().ok()?),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keeper_frame_layout_is_frozen() {
        let frame = Frame::new(HELLO, 0x0102_0304, 0x1112_1314_1516_1718, 7);
        let bytes = frame.encode();
        assert_eq!(&bytes[0..8], b"CMUXKEEP");
        assert_eq!(&bytes[8..12], &[1, 0, 1, 0]);
        assert_eq!(&bytes[12..16], &[4, 3, 2, 1]);
        assert_eq!(&bytes[16..24], &[0x18, 0x17, 0x16, 0x15, 0x14, 0x13, 0x12, 0x11]);
        assert_eq!(&bytes[24..32], &[7, 0, 0, 0, 0, 0, 0, 0]);
        assert_eq!(Frame::decode(&bytes), Some(frame));
    }

    #[test]
    fn keeper_frame_rejects_bad_magic_and_version_zero() {
        let mut bytes = Frame::new(EXIT, 1, 0, 0).encode();
        bytes[0] = b'X';
        assert_eq!(Frame::decode(&bytes), None);
        let mut bytes = Frame::new(EXIT, 1, 0, 0).encode();
        bytes[8] = 0;
        assert_eq!(Frame::decode(&bytes), None);
    }

    #[test]
    fn keeper_frame_accepts_future_versions() {
        let size = Size { cols: 120, rows: 40, width_px: 960, height_px: 640 };
        let mut frame = Frame::resize(size);
        frame.version = 9;
        let decoded = Frame::decode(&frame.encode()).unwrap();
        assert_eq!(decoded.version, 9);
        assert_eq!(decoded.size(), size);
    }
}
