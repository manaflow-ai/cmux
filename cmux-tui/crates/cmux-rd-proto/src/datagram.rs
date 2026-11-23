use crate::error::{DecodeError, Reader};

/// Protocol version carried in the high nibble of the first header byte.
pub const VERSION: u8 = 1;

/// Size of [`DatagramHeader`] on the wire.
pub const HEADER_LEN: usize = 16;

/// Most shards (data plus parity) of a frame that carries parity: one FEC block.
pub const MAX_FEC_BLOCK: u32 = 255;

/// Most data shards of a frame without parity (about 4.6 MB at 1136-byte shards).
pub const MAX_FRAME_SHARDS: u32 = 4096;

/// The FEC blocks of a frame of `count` data shards and `fec_count` parity shards
/// (design D6: a frame larger than one block is split across blocks, each with its own
/// parity). One block while the frame fits [`MAX_FEC_BLOCK`] (every frame a viewer
/// without the `fec.blocks` cap is sent), else the fewest blocks whose largest one fits.
/// The blocks interleave: data shard `i` and parity shard `count + p` belong to block
/// `i % blocks` and `p % blocks`, so a burst of consecutive losses spreads over blocks.
/// Both ends derive the layout from the header alone; no field carries it.
pub fn fec_blocks(count: u16, fec_count: u16) -> usize {
    let (k, m) = (usize::from(count).max(1), usize::from(fec_count));
    if m == 0 {
        return 1;
    }
    let fits = |b: usize| k.div_ceil(b) + m.div_ceil(b) <= MAX_FEC_BLOCK as usize;
    (1..=k).find(|&b| fits(b)).unwrap_or(k)
}

/// The FEC block of shard `index` (data `0..count`, parity after) in [`fec_blocks`]' layout.
pub fn fec_block_of(index: u16, count: u16, blocks: usize) -> usize {
    let blocks = blocks.max(1);
    let (i, k) = (usize::from(index), usize::from(count));
    if i < k { i % blocks } else { (i - k) % blocks }
}

/// Header flag bits (low nibble of the first byte).
pub mod flags {
    /// The frame is an IDR: it references no earlier frame.
    pub const KEYFRAME: u8 = 0b0001;
    /// The frame re-encodes a static screen at higher quality.
    pub const REFINE: u8 = 0b0010;
    /// The frame recovers from a loss by referencing an acknowledged frame.
    pub const RECOVERY: u8 = 0b0100;
    /// The frame is a lossless tile top-off (rd change C3) on a tile stream:
    /// standalone (no reference chain); `ref_frame` names the video frame of
    /// the surface stream it applies on top of. Sent only with the `tile` cap.
    pub const TILE: u8 = 0b1000;
    /// Every defined flag.
    pub const ALL: u8 = KEYFRAME | REFINE | RECOVERY | TILE;
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
    /// A clock probe with the viewer's current estimate (viewer to host; cap `clock`).
    ClockPing = 9,
    /// The host's answer to a clock probe (host to viewer; cap `clock`).
    ClockPong = 10,
    /// One shard (data when `index < count`, parity otherwise) of an
    /// upstream media frame, viewer to host: microphone, camera or screen
    /// share (rd change C4; cap `up_media`).
    UpMedia = 11,
    /// One frame's host times for the stage ledger ([`crate::FrameTimes`]), sent after the
    /// frame's last shard; the header names its stream and frame (host to viewer; cap
    /// `ledger`).
    FrameTimes = 12,
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
            9 => Self::ClockPing,
            10 => Self::ClockPong,
            11 => Self::UpMedia,
            12 => Self::FrameTimes,
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

/// Maximum undrained local socket receipts per carrier. Overflow is counted;
/// it never backpressures media or creates a second media queue.
pub const MAX_DEPARTURE_RECEIPTS: usize = 8192;

/// Local observation of one datagram accepted by the transport socket.
/// This is not a wire format and does not claim physical NIC transmission.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DatagramDeparture {
    /// Parsed before link encryption; includes frame/shard and transport sequence.
    pub header: DatagramHeader,
    /// CLOCK_MONOTONIC microseconds, the host frame-ledger clock domain.
    pub departed_us: u64,
    /// Accepted socket payload bytes, including encryption/relay or stream framing,
    /// but excluding IP/UDP/TCP headers and any outer tunnel encapsulation.
    pub wire_bytes: usize,
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
        if matches!(kind, DatagramKind::Video | DatagramKind::Fec | DatagramKind::UpMedia) {
            let total = u32::from(header.count) + u32::from(header.fec_count);
            // A frame may span up to MAX_FRAME_SHARDS data shards. With parity it is one
            // FEC block (at most 255 shards) or, past that, several interleaved blocks
            // (`fec_blocks`) of at most 255 shards each, at most one parity per data shard.
            let fits = header.fec_count == 0 || total <= MAX_FEC_BLOCK || {
                let blocks = fec_blocks(header.count, header.fec_count);
                header.fec_count <= header.count
                    && usize::from(header.count).div_ceil(blocks)
                        + usize::from(header.fec_count).div_ceil(blocks)
                        <= MAX_FEC_BLOCK as usize
            };
            if header.count == 0
                || u32::from(header.index) >= total
                || u32::from(header.count) > MAX_FRAME_SHARDS
                || !fits
            {
                return Err(DecodeError::Invalid("shard index or count"));
            }
            // Upstream shards use one kind; the index tells data from parity.
            let parity = kind == DatagramKind::Fec;
            if kind != DatagramKind::UpMedia && parity != (header.index >= header.count) {
                return Err(DecodeError::Invalid("shard kind"));
            }
        }
        Ok((header, r.rest()))
    }
}
