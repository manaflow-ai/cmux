//! The host's pointer position (cap `cursor`): with it the host leaves the
//! pointer out of the picture and the viewer draws it, so a viewer in control
//! shows only its own pointer (no second, late one in the video) and a
//! view-only viewer draws the host's.

use crate::error::{DecodeError, Reader};

/// `DatagramKind::CursorPos` payload: `u32 seq`, `u32 x`, `u32 y` (stream
/// pixels), `u8 visible`. Latest wins: a viewer drops a seq older than the
/// newest it applied.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CursorPos {
    pub seq: u32,
    pub x: u32,
    pub y: u32,
    /// False while the pointer is off the streamed display.
    pub visible: bool,
}

impl CursorPos {
    pub const LEN: usize = 13;

    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(Self::LEN);
        out.extend_from_slice(&self.seq.to_le_bytes());
        out.extend_from_slice(&self.x.to_le_bytes());
        out.extend_from_slice(&self.y.to_le_bytes());
        out.push(u8::from(self.visible));
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, DecodeError> {
        let mut r = Reader::new(bytes);
        let seq = r.u32()?;
        let x = r.u32()?;
        let y = r.u32()?;
        let visible = r.u8()?;
        if !r.is_empty() || visible > 1 {
            return Err(DecodeError::Invalid("cursor pos"));
        }
        Ok(Self { seq, x, y, visible: visible == 1 })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips() {
        let c = CursorPos { seq: 7, x: 1919, y: 3, visible: true };
        let bytes = c.encode();
        assert_eq!(bytes.len(), CursorPos::LEN);
        assert_eq!(CursorPos::decode(&bytes), Ok(c));
    }

    #[test]
    fn refuses_trailing_bytes_and_bad_flag() {
        let mut bytes = CursorPos { seq: 1, x: 0, y: 0, visible: false }.encode();
        bytes.push(0);
        assert!(CursorPos::decode(&bytes).is_err());
        bytes.pop();
        bytes[12] = 2;
        assert!(CursorPos::decode(&bytes).is_err());
    }
}
