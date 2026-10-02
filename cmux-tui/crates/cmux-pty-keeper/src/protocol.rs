//! Frozen v1 wire format. See `PROTOCOL.md`; never change existing fields.

pub const MAGIC: [u8; 8] = *b"CMUXKEEP";
pub const VERSION: u16 = 1;
pub const FRAME_LEN: usize = 32;

pub const HELLO: u16 = 1;
pub const EXIT: u16 = 2;
pub const RESIZE: u16 = 16;
pub const TERMINATE: u16 = 17;

/// Most Unix clients a keeper serves at once.
pub const MAX_CLIENTS: usize = 16;

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

    pub fn resize(cols: u16, rows: u16) -> Self {
        Self::new(RESIZE, u32::from(cols) | (u32::from(rows) << 16), 0, 0)
    }

    /// `(cols, rows)` of a `RESIZE` frame.
    pub fn size(&self) -> (u16, u16) {
        ((self.a & 0xffff) as u16, (self.a >> 16) as u16)
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
        let mut frame = Frame::resize(120, 40);
        frame.version = 9;
        let decoded = Frame::decode(&frame.encode()).unwrap();
        assert_eq!(decoded.version, 9);
        assert_eq!(decoded.size(), (120, 40));
    }
}
