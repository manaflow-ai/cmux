use std::collections::HashMap;
use std::fmt;
use std::io::{self, Read, Write};

use bytes::{BufMut, Bytes, BytesMut};
use cmux_remote_protocol::{
    Lane, MAX_FRAME_PAYLOAD, MUX_LINE_ZLIB_MIN_BYTES, REMOTE_CLIENT_MESSAGE_MAX_BYTES,
    REMOTE_SESSION_MESSAGE_MAX_BYTES,
};
use flate2::Compression;
use flate2::read::ZlibDecoder;
use flate2::write::ZlibEncoder;
use tokio::io::{AsyncBufRead, AsyncBufReadExt, AsyncReadExt};

const MAGIC: [u8; 4] = *b"CMXL";
// A line whose joined parts are one zlib stream of the JSONL bytes (trailing
// LF included). Sent only daemon-to-client, and only on a stream whose client
// asked for it and whose daemon confirmed it (`MUX_LINE_ZLIB_V1_FEATURE`): a
// chat's attach reply on a slow machine link is ~75 KB of JSON that crossed
// the link whole.
const ZLIB_MAGIC: [u8; 4] = *b"CMXZ";
/// Past this, the daemon compresses a line on a blocking thread.
pub(crate) const ZLIB_BLOCKING_LINE_BYTES: usize = 1 << 20;
const HEADER_BYTES: usize = 4 + 8 + 4 + 4;
const CHUNK_BYTES: usize = MAX_FRAME_PAYLOAD - HEADER_BYTES;
// The local mux transport appends a newline after each serialized message.
// Keep the delimiter outside each directional payload budget. The shorter
// alias is retained for upload callers and existing tests.
pub(crate) const MAX_MUX_UPLOAD_LINE_BYTES: usize = REMOTE_CLIENT_MESSAGE_MAX_BYTES + 1;
pub(crate) const MAX_MUX_DOWNLOAD_LINE_BYTES: usize = REMOTE_SESSION_MESSAGE_MAX_BYTES + 1;
pub(crate) const MAX_MUX_LINE_BYTES: usize = MAX_MUX_UPLOAD_LINE_BYTES;
const MAX_IN_FLIGHT_LINES: usize = 256;
const MAX_IN_FLIGHT_BYTES: usize = MAX_MUX_DOWNLOAD_LINE_BYTES * 2;
// Keep packet-declared part counts bounded even when callers configure an
// unusually large byte maximum. `Vec::with_capacity(parts)` allocates before
// any payload arrives, so the protocol needs an independent entry cap.
const MAX_PARTS_PER_LINE: usize = MAX_MUX_DOWNLOAD_LINE_BYTES.div_ceil(CHUNK_BYTES);

/// Return the serialized payload size for one JSONL message. A trailing LF is
/// framing and is not part of the directional payload budget. EOF-terminated
/// lines are valid on the relay path, so they must be measured as-is.
pub(crate) fn mux_line_payload_len(line: &[u8]) -> usize {
    line.strip_suffix(b"\n").map_or(line.len(), |payload| payload.len())
}

pub(crate) async fn read_bounded_line<R>(reader: &mut R, line: &mut Vec<u8>) -> io::Result<usize>
where
    R: AsyncBufRead + Unpin,
{
    read_bounded_line_with_limit(reader, line, MAX_MUX_UPLOAD_LINE_BYTES).await
}

pub(crate) async fn read_bounded_line_with_limit<R>(
    reader: &mut R,
    line: &mut Vec<u8>,
    maximum: usize,
) -> io::Result<usize>
where
    R: AsyncBufRead + Unpin,
{
    line.clear();
    let limit = u64::try_from(maximum).ok().and_then(|maximum| maximum.checked_add(1)).ok_or_else(
        || io::Error::new(io::ErrorKind::InvalidInput, "mux line limit is too large"),
    )?;
    reader.take(limit).read_until(b'\n', line).await
}

pub(crate) fn encode_line(message: u64, line: &[u8]) -> Result<Vec<Bytes>, MuxCodecError> {
    encode_line_with_limit(message, line, MAX_MUX_UPLOAD_LINE_BYTES)
}

pub(crate) fn encode_line_with_limit(
    message: u64,
    line: &[u8],
    maximum: usize,
) -> Result<Vec<Bytes>, MuxCodecError> {
    if mux_line_payload_len(line) > maximum.saturating_sub(1) {
        return Err(MuxCodecError::LineTooLarge(line.len()));
    }
    encode_parts(MAGIC, message, line)
}

/// The packets of one daemon-to-client line: one zlib stream tagged `CMXZ`
/// when `zlib` (the stream negotiated it), the line is
/// [`MUX_LINE_ZLIB_MIN_BYTES`] or more and compressing shrinks it; otherwise
/// the plain `CMXL` packets of [`encode_line_with_limit`]. `maximum` bounds the
/// plain line either way, so a reader inflates to no more than before.
pub(crate) fn encode_line_for_client(
    message: u64,
    line: &[u8],
    maximum: usize,
    zlib: bool,
) -> Result<Vec<Bytes>, MuxCodecError> {
    if !zlib || line.len() < MUX_LINE_ZLIB_MIN_BYTES {
        return encode_line_with_limit(message, line, maximum);
    }
    if mux_line_payload_len(line) > maximum.saturating_sub(1) {
        return Err(MuxCodecError::LineTooLarge(line.len()));
    }
    let compressed = deflate(line);
    if compressed.len() >= line.len() {
        return encode_line_with_limit(message, line, maximum);
    }
    encode_parts(ZLIB_MAGIC, message, &compressed)
}

/// `line` as one zlib stream at the fastest level (acpmux's peer links use the
/// same, `acpmux/src/frame_compress.rs`).
fn deflate(line: &[u8]) -> Vec<u8> {
    let mut encoder = ZlibEncoder::new(Vec::with_capacity(line.len() / 4), Compression::new(1));
    // Writing to a Vec cannot fail.
    let _ = encoder.write_all(line);
    encoder.finish().unwrap_or_default()
}

/// The line held by a `CMXZ` stream, refused past `limit` bytes inflated (a
/// few KB must not inflate to gigabytes) or when it is not zlib.
fn inflate(compressed: &[u8], limit: usize) -> Result<Vec<u8>, MuxCodecError> {
    let mut line = Vec::new();
    ZlibDecoder::new(compressed)
        .take(u64::try_from(limit).unwrap_or(u64::MAX).saturating_add(1))
        .read_to_end(&mut line)
        .map_err(|_| MuxCodecError::InvalidCompressedLine)?;
    if line.len() > limit {
        return Err(MuxCodecError::LineTooLarge(line.len()));
    }
    Ok(line)
}

fn encode_parts(magic: [u8; 4], message: u64, payload: &[u8]) -> Result<Vec<Bytes>, MuxCodecError> {
    let parts = payload.len().max(1).div_ceil(CHUNK_BYTES);
    let parts = u32::try_from(parts).map_err(|_| MuxCodecError::LineTooLarge(payload.len()))?;
    if payload.is_empty() {
        return Ok(vec![encode_part(magic, message, 0, 1, &[])]);
    }
    Ok(payload
        .chunks(CHUNK_BYTES)
        .enumerate()
        .map(|(part, chunk)| encode_part(magic, message, part as u32, parts, chunk))
        .collect())
}

fn encode_part(magic: [u8; 4], message: u64, part: u32, parts: u32, payload: &[u8]) -> Bytes {
    let mut encoded = BytesMut::with_capacity(HEADER_BYTES + payload.len());
    encoded.extend_from_slice(&magic);
    encoded.put_u64(message);
    encoded.put_u32(part);
    encoded.put_u32(parts);
    encoded.extend_from_slice(payload);
    encoded.freeze()
}

pub(crate) struct MuxLineAssembler<R = ()> {
    lines: HashMap<u64, PartialLine<R>>,
    bytes: usize,
    maximum: usize,
    zlib: bool,
}

impl<R> Default for MuxLineAssembler<R> {
    fn default() -> Self {
        Self::with_maximum(MAX_MUX_DOWNLOAD_LINE_BYTES)
    }
}

impl<R> MuxLineAssembler<R> {
    pub(crate) fn with_maximum(maximum: usize) -> Self {
        Self { lines: HashMap::new(), bytes: 0, maximum, zlib: false }
    }

    /// Read `CMXZ` lines too: only on a stream whose daemon confirmed
    /// `MUX_LINE_ZLIB_V1_FEATURE`. Without it a `CMXZ` packet is refused.
    pub(crate) fn accepting_zlib(mut self, zlib: bool) -> Self {
        self.zlib = zlib;
        self
    }
}

struct PartialLine<R> {
    lane: Lane,
    compressed: bool,
    parts: Vec<Option<Bytes>>,
    retained: Vec<R>,
    received: usize,
    bytes: usize,
}

pub(crate) struct AssembledMuxLine<R> {
    lane: Lane,
    payload: Bytes,
    _retained: Vec<R>,
}

impl<R> AssembledMuxLine<R> {
    pub(crate) fn lane(&self) -> Lane {
        self.lane
    }

    pub(crate) fn payload(&self) -> &Bytes {
        &self.payload
    }
}

/// Magic, message id, part index and part count of a line packet; `None`
/// when the packet is shorter than the header.
fn parse_header(packet: &[u8]) -> Option<([u8; 4], u64, u32, u32)> {
    let (magic, rest) = packet.split_first_chunk::<4>()?;
    let (message, rest) = rest.split_first_chunk::<8>()?;
    let (part, rest) = rest.split_first_chunk::<4>()?;
    let (parts, _) = rest.split_first_chunk::<4>()?;
    Some((
        *magic,
        u64::from_be_bytes(*message),
        u32::from_be_bytes(*part),
        u32::from_be_bytes(*parts),
    ))
}

impl<R> MuxLineAssembler<R> {
    pub(crate) fn push_retaining(
        &mut self,
        lane: Lane,
        packet: Bytes,
        retained: R,
    ) -> Result<Option<AssembledMuxLine<R>>, MuxCodecError> {
        let Some((magic, message, part, parts)) = parse_header(&packet) else {
            return Err(MuxCodecError::InvalidPacket);
        };
        let compressed = match magic {
            MAGIC => false,
            ZLIB_MAGIC if self.zlib => true,
            _ => return Err(MuxCodecError::InvalidPacket),
        };
        if parts == 0
            || part >= parts
            || parts as usize > self.maximum.div_ceil(CHUNK_BYTES)
            || parts as usize > MAX_PARTS_PER_LINE
        {
            return Err(MuxCodecError::InvalidPacket);
        }
        if !self.lines.contains_key(&message) && self.lines.len() >= MAX_IN_FLIGHT_LINES {
            return Err(MuxCodecError::TooManyLines);
        }
        let line = self.lines.entry(message).or_insert_with(|| PartialLine {
            lane,
            compressed,
            parts: vec![None; parts as usize],
            retained: Vec::with_capacity(parts as usize),
            received: 0,
            bytes: 0,
        });
        if line.lane != lane || line.compressed != compressed || line.parts.len() != parts as usize
        {
            return Err(MuxCodecError::InvalidPacket);
        }
        let Some(slot) = line.parts.get_mut(part as usize).filter(|slot| slot.is_none()) else {
            return Err(MuxCodecError::InvalidPacket);
        };
        let payload = packet.slice(HEADER_BYTES..);
        if line.bytes.saturating_add(payload.len()) > self.maximum
            || self.bytes.saturating_add(payload.len()) > MAX_IN_FLIGHT_BYTES
        {
            return Err(MuxCodecError::LineTooLarge(line.bytes.saturating_add(payload.len())));
        }
        let payload_len = payload.len();
        *slot = Some(payload);
        line.bytes += payload_len;
        line.received += 1;
        self.bytes += payload_len;
        line.retained.push(retained);
        if line.received != line.parts.len() {
            return Ok(None);
        }
        let Some(line) = self.lines.remove(&message) else {
            return Err(MuxCodecError::InvalidPacket);
        };
        self.bytes = self.bytes.saturating_sub(line.bytes);
        let mut joined = BytesMut::with_capacity(line.bytes);
        // `received == parts.len()` and every slot is filled once, so no part
        // is missing here.
        for part in line.parts.into_iter().flatten() {
            joined.extend_from_slice(&part);
        }
        let payload = if line.compressed {
            Bytes::from(inflate(&joined, self.maximum)?)
        } else {
            joined.freeze()
        };
        if mux_line_payload_len(&payload) > self.maximum.saturating_sub(1) {
            return Err(MuxCodecError::LineTooLarge(payload.len()));
        }
        Ok(Some(AssembledMuxLine { lane: line.lane, payload, _retained: line.retained }))
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MuxCodecError {
    InvalidPacket,
    LineTooLarge(usize),
    TooManyLines,
    InvalidCompressedLine,
}

impl fmt::Display for MuxCodecError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidPacket => formatter.write_str("invalid mux line packet"),
            Self::LineTooLarge(size) => write!(formatter, "mux line is too large: {size}"),
            Self::TooManyLines => formatter.write_str("too many incomplete mux lines"),
            Self::InvalidCompressedLine => {
                formatter.write_str("a compressed mux line did not inflate")
            }
        }
    }
}

impl std::error::Error for MuxCodecError {}

#[cfg(test)]
#[path = "mux_codec_tests.rs"]
pub(crate) mod tests;
