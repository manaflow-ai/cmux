//! The remote cursor as metadata (cap `cursor`): the host leaves the cursor out of its
//! pictures and reports it instead, so the viewer shows one cursor that moves with no
//! round trip (the local pointer wears the remote shape) and draws the remote one only
//! where the two differ.
//!
//! Position and visibility ride `DatagramKind::CursorPos` datagrams, latest wins: the
//! header's `frame` field is a sender-wide sequence number and a viewer drops a datagram
//! older than the newest it applied. A shape is an image plus hotspot in stream pixels,
//! sent once per new shape on the reliable control stream (`Control::CursorShape`) and
//! named by [`shape_id`]; a position names the shape the cursor wears.

use crate::datagram::{DatagramHeader, DatagramKind};
use crate::error::{DecodeError, Reader};

/// Bits of a [`CursorPos`]'s flags byte.
pub mod cursor_flags {
    /// The cursor is shown (an app may hide it, for example while typing).
    pub const VISIBLE: u8 = 0b0001;
    /// Every defined flag.
    pub const ALL: u8 = VISIBLE;
}

/// Most pixels on either side of a cursor shape; a larger cursor is scaled down to fit.
pub const MAX_CURSOR_SIDE: u32 = 256;

/// Size of a [`CursorPos`] payload on the wire.
pub const CURSOR_POS_LEN: usize = 13;

/// `DatagramKind::CursorPos` payload: `u32 shape`, `i32 x`, `i32 y`, `u8 flags`. `x` and
/// `y` are the hotspot in stream pixels (outside the frame when the cursor is on another
/// display); `shape` is the [`shape_id`] of the shape it wears, 0 when unknown.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct CursorPos {
    pub shape: u32,
    pub x: i32,
    pub y: i32,
    pub visible: bool,
}

impl CursorPos {
    pub fn encode(&self) -> [u8; CURSOR_POS_LEN] {
        let flags = if self.visible { cursor_flags::VISIBLE } else { 0 };
        let bytes = self
            .shape
            .to_le_bytes()
            .into_iter()
            .chain(self.x.to_le_bytes())
            .chain(self.y.to_le_bytes())
            .chain([flags]);
        let mut out = [0u8; CURSOR_POS_LEN];
        for (slot, byte) in out.iter_mut().zip(bytes) {
            *slot = byte;
        }
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, DecodeError> {
        let mut r = Reader::new(bytes);
        let shape = r.u32()?;
        let x = r.i32()?;
        let y = r.i32()?;
        let flags = r.u8()?;
        if !r.is_empty() || flags & !cursor_flags::ALL != 0 {
            return Err(DecodeError::Invalid("cursor position"));
        }
        Ok(Self { shape, x, y, visible: flags & cursor_flags::VISIBLE != 0 })
    }

    /// The whole datagram (header and payload), sequence `seq`.
    pub fn datagram(&self, seq: u32) -> Vec<u8> {
        let header = DatagramHeader {
            flags: 0,
            kind: DatagramKind::CursorPos,
            stream: 0,
            frame: seq,
            index: 0,
            count: 0,
            fec_count: 0,
            transport_seq: 0,
        };
        let mut out = Vec::with_capacity(crate::HEADER_LEN + CURSOR_POS_LEN);
        header.encode_into(&mut out);
        out.extend_from_slice(&self.encode());
        out
    }

    /// Splits a `CursorPos` datagram into its sequence number and position.
    pub fn from_datagram(datagram: &[u8]) -> Result<(u32, Self), DecodeError> {
        let (header, payload) = DatagramHeader::decode(datagram)?;
        if header.kind != DatagramKind::CursorPos {
            return Err(DecodeError::Invalid("cursor position kind"));
        }
        Ok((header.frame, Self::decode(payload)?))
    }
}

/// Whether sequence `seq` is newer than `last` (wrapping, half the space ahead).
pub fn cursor_seq_newer(seq: u32, last: u32) -> bool {
    seq != last && seq.wrapping_sub(last) < 1 << 31
}

/// The id of a shape: FNV-1a over its size, hotspot and premultiplied RGBA pixels, never 0
/// (0 means unknown). The host keys its sent shapes by it, the viewer its cache.
pub fn shape_id(width: u32, height: u32, hot_x: u32, hot_y: u32, rgba: &[u8]) -> u32 {
    const OFFSET: u64 = 0xcbf2_9ce4_8422_2325;
    const PRIME: u64 = 0x0000_0100_0000_01b3;
    let mut hash = OFFSET;
    let mut eat = |bytes: &[u8]| {
        for &b in bytes {
            hash ^= u64::from(b);
            hash = hash.wrapping_mul(PRIME);
        }
    };
    for v in [width, height, hot_x, hot_y] {
        eat(&v.to_le_bytes());
    }
    eat(rgba);
    let folded = (hash ^ (hash >> 32)) as u32;
    if folded == 0 { 1 } else { folded }
}

const BASE64: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/// Standard base64 with padding: a shape's pixels in its control message.
pub fn base64_encode(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let byte = |i: usize| u32::from(chunk.get(i).copied().unwrap_or(0));
        let n = (byte(0) << 16) | (byte(1) << 8) | byte(2);
        for i in 0..4 {
            let digit = BASE64.get(((n >> (18 - 6 * i)) & 63) as usize).copied();
            match digit {
                Some(digit) if i <= chunk.len() => out.push(char::from(digit)),
                _ => out.push('='),
            }
        }
    }
    out
}

/// Decodes standard base64 with padding; `None` for anything else.
pub fn base64_decode(text: &str) -> Option<Vec<u8>> {
    let bytes = text.as_bytes();
    if !bytes.len().is_multiple_of(4) {
        return None;
    }
    let value = |c: u8| BASE64.iter().position(|&b| b == c).map(|v| v as u32);
    let mut out = Vec::with_capacity(bytes.len() / 4 * 3);
    let quads = bytes.len() / 4;
    for (i, quad) in bytes.chunks(4).enumerate() {
        let last = i + 1 == quads;
        let pad = quad.iter().rev().take_while(|&&c| c == b'=').count();
        if pad > 2 || (pad > 0 && !last) {
            return None;
        }
        let mut n = 0u32;
        for &c in quad.iter().take(4 - pad) {
            n = (n << 6) | value(c)?;
        }
        n <<= 6 * pad as u32;
        let decoded = [(n >> 16) as u8, (n >> 8) as u8, n as u8];
        out.extend(decoded.iter().take(3 - pad));
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_position_round_trips_through_its_datagram() {
        let pos = CursorPos { shape: 0xdead_beef, x: -3, y: 1080, visible: true };
        let datagram = pos.datagram(41);
        assert_eq!(datagram.len(), crate::HEADER_LEN + CURSOR_POS_LEN);
        assert_eq!(datagram[1], DatagramKind::CursorPos as u8);
        assert_eq!(CursorPos::from_datagram(&datagram), Ok((41, pos)));
        let hidden = CursorPos { visible: false, ..pos };
        assert_eq!(CursorPos::decode(&hidden.encode()), Ok(hidden));
    }

    #[test]
    fn a_bad_position_is_refused() {
        let mut bytes = CursorPos { shape: 1, x: 0, y: 0, visible: true }.encode().to_vec();
        bytes[12] = 0b10;
        assert!(CursorPos::decode(&bytes).is_err(), "unknown flag");
        assert!(CursorPos::decode(&bytes[..12]).is_err(), "truncated");
        bytes[12] = 1;
        bytes.push(0);
        assert!(CursorPos::decode(&bytes).is_err(), "trailing byte");
    }

    #[test]
    fn newer_wraps_and_ignores_repeats() {
        assert!(cursor_seq_newer(2, 1));
        assert!(!cursor_seq_newer(1, 2));
        assert!(!cursor_seq_newer(5, 5));
        assert!(cursor_seq_newer(0, u32::MAX));
        assert!(!cursor_seq_newer(u32::MAX, 0));
    }

    #[test]
    fn shape_ids_follow_pixels_and_hotspot_and_are_never_zero() {
        let pixels = [0u8, 0, 0, 255, 255, 255, 255, 255];
        let a = shape_id(2, 1, 0, 0, &pixels);
        assert_eq!(a, shape_id(2, 1, 0, 0, &pixels));
        assert_ne!(a, shape_id(2, 1, 1, 0, &pixels));
        assert_ne!(a, shape_id(1, 2, 0, 0, &pixels));
        assert_ne!(a, shape_id(2, 1, 0, 0, &[0u8, 0, 0, 255, 255, 255, 255, 254]));
        assert_ne!(a, 0);
    }

    #[test]
    fn base64_matches_the_standard_alphabet() {
        for (plain, coded) in [
            (&b""[..], ""),
            (b"f", "Zg=="),
            (b"fo", "Zm8="),
            (b"foo", "Zm9v"),
            (b"foob", "Zm9vYg=="),
            (b"\xff\xfe\x00", "//4A"),
        ] {
            assert_eq!(base64_encode(plain), coded);
            assert_eq!(base64_decode(coded).as_deref(), Some(plain));
        }
        assert_eq!(base64_decode("Zg="), None);
        assert_eq!(base64_decode("Zg==Zg=="), None);
        assert_eq!(base64_decode("Z!=="), None);
    }
}
