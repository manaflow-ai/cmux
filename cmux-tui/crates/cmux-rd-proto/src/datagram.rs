use crate::error::{DecodeError, Reader};

/// Protocol version carried in the high nibble of the first header byte.
pub const VERSION: u8 = 1;

/// Size of [`DatagramHeader`] on the wire.
pub const HEADER_LEN: usize = 16;

/// Header flag bits (low nibble of the first byte).
pub mod flags {
    /// The frame is an IDR: it references no earlier frame.
    pub const KEYFRAME: u8 = 0b0001;
    /// The frame re-encodes a static screen at higher quality.
    pub const REFINE: u8 = 0b0010;
    /// The frame recovers from a loss by referencing an acknowledged frame.
    pub const RECOVERY: u8 = 0b0100;
    /// Every defined flag.
    pub const ALL: u8 = KEYFRAME | REFINE | RECOVERY;
}

/// What a datagram carries.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum DatagramKind {
    /// One data shard of a video frame.
    Video = 1,
    /// One parity shard of a video frame.
    Fec = 2,
    /// One audio packet.
    Audio = 3,
    /// Viewer input events (viewer to host).
    Input = 4,
    /// The newest input sequence number the host applied (host to viewer).
    InputAck = 5,
    /// Cursor position, latest wins (host to viewer).
    CursorPos = 6,
    /// Transport-wide feedback (viewer to host).
    Feedback = 7,
    /// Bandwidth probe padding (host to viewer).
    Probe = 8,
}

impl DatagramKind {
    /// Parses a kind byte.
    pub fn from_u8(value: u8) -> Result<Self, DecodeError> {
        Ok(match value {
            1 => Self::Video,
            2 => Self::Fec,
            3 => Self::Audio,
            4 => Self::Input,
            5 => Self::InputAck,
            6 => Self::CursorPos,
            7 => Self::Feedback,
            8 => Self::Probe,
            other => return Err(DecodeError::Kind(other)),
        })
    }
}

/// The 16-byte header of every `cmux.rd/1` datagram.
///
/// Layout: `u8 version<<4 | flags`, `u8 kind`, `u16 stream`, `u32 frame`,
/// `u16 index`, `u16 count`, `u16 fec_count`, `u16 transport_seq`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DatagramHeader {
    pub flags: u8,
    pub kind: DatagramKind,
    /// One stream per remote display.
    pub stream: u16,
    /// Frame number (video, fec, audio); 0 for other kinds.
    pub frame: u32,
    /// Shard index inside the frame: data shards `0..count`, parity shards
    /// `count..count + fec_count`.
    pub index: u16,
    /// Number of data shards of the frame.
    pub count: u16,
    /// Number of parity shards of the frame.
    pub fec_count: u16,
    /// Sender-wide sequence number for transport-wide feedback.
    pub transport_seq: u16,
}

impl DatagramHeader {
    /// Appends the header to `out`.
    pub fn encode_into(&self, out: &mut Vec<u8>) {
        out.push((VERSION << 4) | (self.flags & flags::ALL));
        out.push(self.kind as u8);
        out.extend_from_slice(&self.stream.to_le_bytes());
        out.extend_from_slice(&self.frame.to_le_bytes());
        out.extend_from_slice(&self.index.to_le_bytes());
        out.extend_from_slice(&self.count.to_le_bytes());
        out.extend_from_slice(&self.fec_count.to_le_bytes());
        out.extend_from_slice(&self.transport_seq.to_le_bytes());
    }

    /// Returns the header as a 16-byte array.
    pub fn encode(&self) -> [u8; HEADER_LEN] {
        let mut v = Vec::with_capacity(HEADER_LEN);
        self.encode_into(&mut v);
        let mut out = [0u8; HEADER_LEN];
        out.copy_from_slice(&v);
        out
    }

    /// Splits a datagram into its header and payload.
    pub fn decode(datagram: &[u8]) -> Result<(Self, &[u8]), DecodeError> {
        let mut r = Reader::new(datagram);
        let first = r.u8()?;
        let version = first >> 4;
        if version != VERSION {
            return Err(DecodeError::Version(version));
        }
        let header_flags = first & 0x0f;
        if header_flags & !flags::ALL != 0 {
            return Err(DecodeError::Invalid("flags"));
        }
        let kind = DatagramKind::from_u8(r.u8()?)?;
        let header = Self {
            flags: header_flags,
            kind,
            stream: r.u16()?,
            frame: r.u32()?,
            index: r.u16()?,
            count: r.u16()?,
            fec_count: r.u16()?,
            transport_seq: r.u16()?,
        };
        if matches!(kind, DatagramKind::Video | DatagramKind::Fec) {
            let total = u32::from(header.count) + u32::from(header.fec_count);
            if header.count == 0 || u32::from(header.index) >= total || total > 255 {
                return Err(DecodeError::Invalid("shard index or count"));
            }
            let parity = kind == DatagramKind::Fec;
            if parity != (header.index >= header.count) {
                return Err(DecodeError::Invalid("shard kind"));
            }
        }
        Ok((header, r.rest()))
    }
}
