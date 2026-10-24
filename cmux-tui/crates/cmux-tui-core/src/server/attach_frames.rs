//! Client attach streams on a shared connection (`attach-streams-v1`) and
//! their binary frames (`attach-frames-v1`):
//! plans/cmux-next/app-daemon-connection-DESIGN.md section 3.
//!
//! A frame is a 16-byte little-endian header, then `len` payload bytes:
//! `0xFF | kind u8 | stream u16 | len u32 | offset u64`. `0xFF` never starts
//! a UTF-8 JSON line, so frames and JSON lines share one byte stream. Client
//! to daemon stays JSON lines.

use super::render_service::OutboundByteBudget;
use std::num::NonZeroU16;
use std::sync::Arc;

/// The first byte of every frame.
pub(crate) const FRAME_MAGIC: u8 = 0xFF;
/// Header bytes before a frame's payload.
pub(crate) const FRAME_HEADER_LEN: usize = 16;
/// The largest payload: the server's existing message budget
/// (`REMOTE_SESSION_MESSAGE_MAX_BYTES`).
pub(crate) const FRAME_MAX_PAYLOAD: usize = crate::REMOTE_SESSION_MESSAGE_MAX_BYTES;

/// Client capability and daemon capability of client-minted attach streams.
pub(crate) const ATTACH_STREAMS_CAPABILITY: &str = "attach-streams-v1";
/// Client capability and daemon capability of binary attach frames.
pub(crate) const ATTACH_FRAMES_CAPABILITY: &str = "attach-frames-v1";
/// Client capability and daemon capability of the shared-memory output ring
/// (surface/output_ring.rs): a local snapshot stream's bytes stay in the ring
/// the client maps; the stream carries RING_ADVANCE frames.
pub(crate) const TERMINAL_OUTPUT_RING_CAPABILITY: &str = "terminal-output-ring-v1";

/// What a frame's payload holds (design 3.2).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub(crate) enum FrameKind {
    /// Raw PTY bytes; offset of the first byte.
    Output = 1,
    /// In-band resize marker: JSON meta.
    Grid = 2,
    /// One JSON event object.
    Event = 3,
    /// A READY snapshot: `meta_len u32`, JSON meta, raw data.
    Snapshot = 4,
    /// A history or images chunk of the last READY, same shape.
    SnapshotMore = 5,
    /// A `vt-state` or `resized` replay: `meta_len u32`, JSON meta, replay
    /// bytes, then `pending_len` pending bytes.
    Replay = 6,
    /// A shared-memory output ring; its descriptor rides on this frame.
    Ring = 7,
    /// The ring's new published end; no payload.
    RingAdvance = 8,
}

impl FrameKind {
    pub(crate) fn from_byte(byte: u8) -> Option<Self> {
        Some(match byte {
            1 => Self::Output,
            2 => Self::Grid,
            3 => Self::Event,
            4 => Self::Snapshot,
            5 => Self::SnapshotMore,
            6 => Self::Replay,
            7 => Self::Ring,
            8 => Self::RingAdvance,
            _ => return None,
        })
    }
}

/// A client-minted stream id (1-65535), unique among a connection's open
/// streams.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub(crate) struct ClientStreamId(NonZeroU16);

impl ClientStreamId {
    pub(crate) fn new(raw: u16) -> Option<Self> {
        NonZeroU16::new(raw).map(Self)
    }

    pub(crate) fn get(self) -> u16 {
        self.0.get()
    }
}

impl<'de> serde::Deserialize<'de> for ClientStreamId {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let raw = u16::deserialize(deserializer)?;
        Self::new(raw).ok_or_else(|| serde::de::Error::custom("stream must be 1-65535"))
    }
}

impl serde::Serialize for ClientStreamId {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_u16(self.get())
    }
}

/// How one attach stream is written on its connection.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub(crate) struct StreamFraming {
    /// The client's id for the stream; `None` for a legacy attach (one per
    /// connection, untagged events).
    pub(crate) id: Option<ClientStreamId>,
    /// Write the stream's events as binary frames (needs `id`).
    pub(crate) frames: bool,
}

impl StreamFraming {
    pub(crate) const LEGACY: Self = Self { id: None, frames: false };

    /// The framing of a stream the client names `id` on a connection with
    /// `frames` negotiated. Frames without an id are impossible: a frame
    /// header always names its stream.
    pub(crate) fn client(id: ClientStreamId, frames: bool) -> Self {
        Self { id: Some(id), frames }
    }

    /// The stream id frames carry; `Some` exactly when frames are written.
    pub(crate) fn frame_stream(self) -> Option<ClientStreamId> {
        if self.frames { self.id } else { None }
    }
}

/// A frame's header fields.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct FrameHeader {
    pub(crate) kind: FrameKind,
    pub(crate) stream: ClientStreamId,
    pub(crate) len: u32,
    pub(crate) offset: u64,
}

/// Why a header did not decode.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum FrameHeaderError {
    Magic,
    Kind(u8),
    Stream,
    TooLarge(u32),
}

impl FrameHeader {
    pub(crate) fn encode(self) -> [u8; FRAME_HEADER_LEN] {
        let mut header = [0_u8; FRAME_HEADER_LEN];
        header[0] = FRAME_MAGIC;
        header[1] = self.kind as u8;
        header[2..4].copy_from_slice(&self.stream.get().to_le_bytes());
        header[4..8].copy_from_slice(&self.len.to_le_bytes());
        header[8..16].copy_from_slice(&self.offset.to_le_bytes());
        header
    }

    pub(crate) fn decode(bytes: &[u8; FRAME_HEADER_LEN]) -> Result<Self, FrameHeaderError> {
        if bytes[0] != FRAME_MAGIC {
            return Err(FrameHeaderError::Magic);
        }
        let kind = FrameKind::from_byte(bytes[1]).ok_or(FrameHeaderError::Kind(bytes[1]))?;
        let stream = ClientStreamId::new(u16::from_le_bytes([bytes[2], bytes[3]]))
            .ok_or(FrameHeaderError::Stream)?;
        let len = u32::from_le_bytes([bytes[4], bytes[5], bytes[6], bytes[7]]);
        if len as usize > FRAME_MAX_PAYLOAD {
            return Err(FrameHeaderError::TooLarge(len));
        }
        let mut offset = [0_u8; 8];
        offset.copy_from_slice(&bytes[8..16]);
        Ok(Self { kind, stream, len, offset: u64::from_le_bytes(offset) })
    }
}

/// One encoded frame, charged to the connection's outbound byte budget until
/// it is written.
pub(crate) struct BudgetedFrame {
    bytes: Vec<u8>,
    retained_bytes: usize,
    budget: Arc<OutboundByteBudget>,
    /// Passed with the frame's first byte (`SCM_RIGHTS`): a RING frame's
    /// read-only ring descriptor. Closed once the frame is written or dropped.
    #[cfg(unix)]
    descriptor: Option<std::os::fd::OwnedFd>,
}

impl BudgetedFrame {
    pub(crate) fn as_bytes(&self) -> &[u8] {
        &self.bytes
    }

    #[cfg(unix)]
    pub(crate) fn descriptor(&self) -> Option<std::os::fd::RawFd> {
        use std::os::fd::AsRawFd as _;
        self.descriptor.as_ref().map(|descriptor| descriptor.as_raw_fd())
    }

    pub(crate) fn len(&self) -> usize {
        self.bytes.len()
    }
}

impl Drop for BudgetedFrame {
    fn drop(&mut self) {
        self.budget.release(self.retained_bytes);
    }
}

fn would_block(message: &'static str) -> std::io::Error {
    std::io::Error::new(std::io::ErrorKind::WouldBlock, message)
}

/// Builds one frame from payload parts (written in order, no intermediate
/// copy), charged to `budget`.
pub(crate) fn encode_frame(
    budget: &Arc<OutboundByteBudget>,
    kind: FrameKind,
    stream: ClientStreamId,
    offset: u64,
    parts: &[&[u8]],
) -> std::io::Result<Arc<BudgetedFrame>> {
    let len = parts.iter().try_fold(0_usize, |total, part| total.checked_add(part.len()));
    let len = len.filter(|len| *len <= FRAME_MAX_PAYLOAD).ok_or_else(|| {
        std::io::Error::new(std::io::ErrorKind::InvalidData, "frame payload exceeds the limit")
    })?;
    let total = FRAME_HEADER_LEN + len;
    if !budget.try_retain(total) {
        return Err(would_block("global outbound byte budget overflowed"));
    }
    let mut bytes = Vec::new();
    if bytes.try_reserve_exact(total).is_err() {
        budget.release(total);
        return Err(would_block("could not allocate a frame"));
    }
    let header = FrameHeader { kind, stream, len: len as u32, offset };
    bytes.extend_from_slice(&header.encode());
    for part in parts {
        bytes.extend_from_slice(part);
    }
    Ok(Arc::new(BudgetedFrame {
        bytes,
        retained_bytes: total,
        budget: budget.clone(),
        #[cfg(unix)]
        descriptor: None,
    }))
}

/// A frame that passes `descriptor` with its first byte (a RING frame).
#[cfg(unix)]
pub(crate) fn encode_frame_passing(
    budget: &Arc<OutboundByteBudget>,
    kind: FrameKind,
    stream: ClientStreamId,
    offset: u64,
    parts: &[&[u8]],
    descriptor: std::os::fd::OwnedFd,
) -> std::io::Result<Arc<BudgetedFrame>> {
    let frame = encode_frame(budget, kind, stream, offset, parts)?;
    let mut frame =
        Arc::try_unwrap(frame).map_err(|_| std::io::Error::other("a new frame has one owner"))?;
    frame.descriptor = Some(descriptor);
    Ok(Arc::new(frame))
}

/// A frame whose payload is `meta_len u32 | meta | data parts`.
pub(crate) fn encode_meta_frame(
    budget: &Arc<OutboundByteBudget>,
    kind: FrameKind,
    stream: ClientStreamId,
    offset: u64,
    meta: &serde_json::Value,
    data: &[&[u8]],
) -> std::io::Result<Arc<BudgetedFrame>> {
    let meta = serde_json::to_vec(meta).map_err(std::io::Error::other)?;
    let meta_len = u32::try_from(meta.len())
        .map_err(|_| std::io::Error::new(std::io::ErrorKind::InvalidData, "frame meta too large"))?
        .to_le_bytes();
    let mut parts: Vec<&[u8]> = Vec::with_capacity(2 + data.len());
    parts.push(&meta_len);
    parts.push(&meta);
    parts.extend_from_slice(data);
    encode_frame(budget, kind, stream, offset, &parts)
}

/// `json` (one serialized JSON object) with `"stream":id` as its first
/// member: the JSON shape of a client stream's event.
pub(crate) fn tag_json_object(json: &str, stream: ClientStreamId) -> Option<String> {
    let rest = json.strip_prefix('{')?;
    let empty = rest.trim_start().starts_with('}');
    let mut tagged = String::with_capacity(json.len() + 16);
    tagged.push_str("{\"stream\":");
    tagged.push_str(&stream.get().to_string());
    if !empty {
        tagged.push(',');
    }
    tagged.push_str(rest);
    Some(tagged)
}

/// The largest OUTPUT payload: a stream's output is cut into frames of at
/// most this size, so what queues ahead of another stream's frame stays
/// bounded (design 3.2). Its value is measured in the slice-1 fleet run.
pub(crate) const OUTPUT_FRAME_MAX: usize = 64 * 1024;

#[cfg(test)]
#[path = "attach_frames_tests.rs"]
mod tests;
