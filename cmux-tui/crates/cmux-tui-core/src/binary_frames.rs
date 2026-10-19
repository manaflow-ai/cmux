//! Binary frames on the local socket (`terminal-binary-frames-v1`,
//! spec/transports.md "Binary frames").
//!
//! A connection whose client lists the capability in `set-client-info` keeps
//! speaking JSON lines, and the daemon may put a binary frame between two
//! lines wherever it would have sent the equivalent JSON event. The client
//! may send binary input frames the same way. A frame starts with byte
//! [`MARKER`] (NUL), which never starts a JSON line, so every message
//! boundary says which of the two follows and no switch point exists.
//!
//! ```text
//! offset  size  field
//! 0       1     MARKER (0x00)
//! 1       1     kind
//! 2       2     flags, u16 little endian (unknown bits are zero)
//! 4       4     payload length, u32 little endian
//! 8       n     payload
//! ```
//!
//! Kinds:
//!
//! - [`KIND_OUTPUT`] (daemon to client): `surface u64, generation u64,
//!   offset u64` (little endian), then the PTY bytes. It is the `output`
//!   event: with [`OUTPUT_FLAG_POSITION`] (snapshot attach) `generation` and
//!   `offset` are the event's fields; without it both are zero and absent.
//! - [`KIND_EVENT_DATA`] (daemon to client): `json_len u32`, the event's
//!   JSON object without its `data` field, then the bytes that field would
//!   carry base64-encoded. Snapshot READY, history and images chunks use it.
//! - [`KIND_INPUT`] (client to daemon): `id u64, surface u64`, then the
//!   bytes; [`INPUT_FLAG_PASTE`] marks a paste. It is the request
//!   `{"id":id,"cmd":"send","surface":surface,"bytes":..,"paste":..}` and
//!   gets that request's JSON reply.

use std::io::Read;

/// Negotiated in `identify` (daemon) and `set-client-info` (client).
pub const BINARY_FRAMES_CAPABILITY: &str = "terminal-binary-frames-v1";

pub const MARKER: u8 = 0x00;
pub const HEADER_BYTES: usize = 8;

pub const KIND_OUTPUT: u8 = 0x01;
pub const KIND_EVENT_DATA: u8 = 0x02;
pub const KIND_INPUT: u8 = 0x11;

/// `KIND_OUTPUT`: `generation` and `offset` are present (snapshot attach).
pub const OUTPUT_FLAG_POSITION: u16 = 0x0001;
/// `KIND_INPUT`: the bytes are a paste (`send` with `paste: true`).
pub const INPUT_FLAG_PASTE: u16 = 0x0001;

/// Largest payload of a daemon frame: the line limit of the CmuxNext reader
/// (a snapshot READY or history chunk; output frames stay under the 8 MiB
/// viewer backlog).
pub const MAX_DAEMON_FRAME_PAYLOAD_BYTES: usize = 64 << 20;

pub const OUTPUT_PREFIX_BYTES: usize = 24;
pub const INPUT_PREFIX_BYTES: usize = 16;

/// The 8-byte frame header.
pub fn header(kind: u8, flags: u16, payload_len: u32) -> [u8; HEADER_BYTES] {
    let mut header = [0; HEADER_BYTES];
    header[0] = MARKER;
    header[1] = kind;
    header[2..4].copy_from_slice(&flags.to_le_bytes());
    header[4..8].copy_from_slice(&payload_len.to_le_bytes());
    header
}

/// One frame as read off the stream.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Frame {
    pub kind: u8,
    pub flags: u16,
    pub payload: Vec<u8>,
}

/// Reads one frame whose first byte (the marker) has not been consumed yet.
/// A payload over `max_payload` bytes is `InvalidData` before any of it is
/// read.
pub fn read_frame(reader: &mut impl Read, max_payload: usize) -> std::io::Result<Frame> {
    let mut header = [0u8; HEADER_BYTES];
    reader.read_exact(&mut header)?;
    if header[0] != MARKER {
        return Err(invalid("binary frame without its marker"));
    }
    let flags = u16::from_le_bytes([header[2], header[3]]);
    let len = u32::from_le_bytes([header[4], header[5], header[6], header[7]]) as usize;
    if len > max_payload {
        return Err(invalid(format!(
            "binary frame of {len} bytes exceeds the {max_payload}-byte limit"
        )));
    }
    let mut payload = vec![0; len];
    reader.read_exact(&mut payload)?;
    Ok(Frame { kind: header[1], flags, payload })
}

/// An `output` frame's fields.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct OutputFrame<'a> {
    pub surface: u64,
    /// `(generation, offset)` on a snapshot attach.
    pub position: Option<(u64, u64)>,
    pub data: &'a [u8],
}

impl Frame {
    pub fn output(&self) -> std::io::Result<OutputFrame<'_>> {
        if self.kind != KIND_OUTPUT || self.payload.len() < OUTPUT_PREFIX_BYTES {
            return Err(invalid("malformed output frame"));
        }
        let word = |at: usize| u64::from_le_bytes(self.payload[at..at + 8].try_into().unwrap());
        Ok(OutputFrame {
            surface: word(0),
            position: (self.flags & OUTPUT_FLAG_POSITION != 0).then(|| (word(8), word(16))),
            data: &self.payload[OUTPUT_PREFIX_BYTES..],
        })
    }

    /// An event-with-data frame: its JSON object (without `data`) and the
    /// data bytes.
    pub fn event_data(&self) -> std::io::Result<(&[u8], &[u8])> {
        if self.kind != KIND_EVENT_DATA || self.payload.len() < 4 {
            return Err(invalid("malformed event frame"));
        }
        let json_len = u32::from_le_bytes(self.payload[0..4].try_into().unwrap()) as usize;
        let rest = &self.payload[4..];
        if json_len > rest.len() {
            return Err(invalid("malformed event frame"));
        }
        Ok(rest.split_at(json_len))
    }

    /// An input frame: `(id, surface, paste, bytes)`; the bytes move out of
    /// the frame (the prefix stays behind).
    pub fn take_input(&mut self) -> std::io::Result<(u64, u64, bool, Vec<u8>)> {
        if self.kind != KIND_INPUT || self.payload.len() < INPUT_PREFIX_BYTES {
            return Err(invalid("malformed input frame"));
        }
        let word = |at: usize| u64::from_le_bytes(self.payload[at..at + 8].try_into().unwrap());
        let (id, surface) = (word(0), word(8));
        let bytes = self.payload.split_off(INPUT_PREFIX_BYTES);
        Ok((id, surface, self.flags & INPUT_FLAG_PASTE != 0, bytes))
    }
}

/// The whole input frame for `send {id, surface, bytes, paste}`.
pub fn encode_input(id: u64, surface: u64, paste: bool, bytes: &[u8]) -> Vec<u8> {
    let len = INPUT_PREFIX_BYTES + bytes.len();
    let mut frame = Vec::with_capacity(HEADER_BYTES + len);
    frame.extend_from_slice(&header(
        KIND_INPUT,
        if paste { INPUT_FLAG_PASTE } else { 0 },
        u32::try_from(len).expect("input frame fits u32"),
    ));
    frame.extend_from_slice(&id.to_le_bytes());
    frame.extend_from_slice(&surface.to_le_bytes());
    frame.extend_from_slice(bytes);
    frame
}

fn invalid(message: impl Into<String>) -> std::io::Error {
    std::io::Error::new(std::io::ErrorKind::InvalidData, message.into())
}
