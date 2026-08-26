use std::collections::HashMap;
use std::fmt;
use std::io;

use bytes::{BufMut, Bytes, BytesMut};
use cmux_remote_protocol::{Lane, MAX_FRAME_PAYLOAD, REMOTE_SESSION_MESSAGE_MAX_BYTES};
use tokio::io::{AsyncBufRead, AsyncBufReadExt, AsyncReadExt};

const MAGIC: [u8; 4] = *b"CMXL";
const HEADER_BYTES: usize = 4 + 8 + 4 + 4;
const CHUNK_BYTES: usize = MAX_FRAME_PAYLOAD - HEADER_BYTES;
// The local mux transport appends a newline after each serialized message.
pub(crate) const MAX_MUX_LINE_BYTES: usize = REMOTE_SESSION_MESSAGE_MAX_BYTES + 1;
const MAX_IN_FLIGHT_LINES: usize = 256;
const MAX_IN_FLIGHT_BYTES: usize = MAX_MUX_LINE_BYTES * 2;

pub(crate) async fn read_bounded_line<R>(reader: &mut R, line: &mut Vec<u8>) -> io::Result<usize>
where
    R: AsyncBufRead + Unpin,
{
    read_bounded_line_with_limit(reader, line, MAX_MUX_LINE_BYTES).await
}

async fn read_bounded_line_with_limit<R>(
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
    if line.len() > MAX_MUX_LINE_BYTES {
        return Err(MuxCodecError::LineTooLarge(line.len()));
    }
    let parts = line.len().max(1).div_ceil(CHUNK_BYTES);
    let parts = u32::try_from(parts).map_err(|_| MuxCodecError::LineTooLarge(line.len()))?;
    let mut encoded = Vec::with_capacity(parts as usize);
    if line.is_empty() {
        encoded.push(encode_part(message, 0, 1, &[]));
    } else {
        for (part, chunk) in line.chunks(CHUNK_BYTES).enumerate() {
            encoded.push(encode_part(message, part as u32, parts, chunk));
        }
    }
    Ok(encoded)
}

fn encode_part(message: u64, part: u32, parts: u32, payload: &[u8]) -> Bytes {
    let mut encoded = BytesMut::with_capacity(HEADER_BYTES + payload.len());
    encoded.extend_from_slice(&MAGIC);
    encoded.put_u64(message);
    encoded.put_u32(part);
    encoded.put_u32(parts);
    encoded.extend_from_slice(payload);
    encoded.freeze()
}

#[derive(Default)]
pub(crate) struct MuxLineAssembler<R = ()> {
    lines: HashMap<u64, PartialLine<R>>,
    bytes: usize,
}

struct PartialLine<R> {
    lane: Lane,
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

#[cfg(test)]
impl MuxLineAssembler<()> {
    pub(crate) fn push(
        &mut self,
        lane: Lane,
        packet: Bytes,
    ) -> Result<Option<(Lane, Bytes)>, MuxCodecError> {
        self.push_retaining(lane, packet, ()).map(|line| line.map(|line| (line.lane, line.payload)))
    }
}

impl<R> MuxLineAssembler<R> {
    pub(crate) fn push_retaining(
        &mut self,
        lane: Lane,
        packet: Bytes,
        retained: R,
    ) -> Result<Option<AssembledMuxLine<R>>, MuxCodecError> {
        if packet.len() < HEADER_BYTES || packet[..4] != MAGIC {
            return Err(MuxCodecError::InvalidPacket);
        }
        let message = u64::from_be_bytes(packet[4..12].try_into().unwrap());
        let part = u32::from_be_bytes(packet[12..16].try_into().unwrap());
        let parts = u32::from_be_bytes(packet[16..20].try_into().unwrap());
        if parts == 0 || part >= parts || parts as usize > MAX_MUX_LINE_BYTES.div_ceil(CHUNK_BYTES)
        {
            return Err(MuxCodecError::InvalidPacket);
        }
        if !self.lines.contains_key(&message) {
            if self.lines.len() >= MAX_IN_FLIGHT_LINES {
                return Err(MuxCodecError::TooManyLines);
            }
            self.lines.insert(
                message,
                PartialLine {
                    lane,
                    parts: vec![None; parts as usize],
                    retained: Vec::with_capacity(parts as usize),
                    received: 0,
                    bytes: 0,
                },
            );
        }
        let line = self.lines.get_mut(&message).expect("line was inserted");
        if line.lane != lane
            || line.parts.len() != parts as usize
            || line.parts[part as usize].is_some()
        {
            return Err(MuxCodecError::InvalidPacket);
        }
        let payload = packet.slice(HEADER_BYTES..);
        if line.bytes.saturating_add(payload.len()) > MAX_MUX_LINE_BYTES
            || self.bytes.saturating_add(payload.len()) > MAX_IN_FLIGHT_BYTES
        {
            return Err(MuxCodecError::LineTooLarge(line.bytes.saturating_add(payload.len())));
        }
        line.bytes += payload.len();
        line.received += 1;
        self.bytes += payload.len();
        line.parts[part as usize] = Some(payload);
        line.retained.push(retained);
        if line.received != line.parts.len() {
            return Ok(None);
        }
        let line = self.lines.remove(&message).expect("complete line exists");
        self.bytes = self.bytes.saturating_sub(line.bytes);
        let mut joined = BytesMut::with_capacity(line.bytes);
        for part in line.parts {
            joined.extend_from_slice(&part.expect("all parts received"));
        }
        Ok(Some(AssembledMuxLine {
            lane: line.lane,
            payload: joined.freeze(),
            _retained: line.retained,
        }))
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MuxCodecError {
    InvalidPacket,
    LineTooLarge(usize),
    TooManyLines,
}

impl fmt::Display for MuxCodecError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidPacket => formatter.write_str("invalid mux line packet"),
            Self::LineTooLarge(size) => write!(formatter, "mux line is too large: {size}"),
            Self::TooManyLines => formatter.write_str("too many incomplete mux lines"),
        }
    }
}

impl std::error::Error for MuxCodecError {}

#[cfg(test)]
mod tests {
    use tokio::io::{AsyncReadExt, BufReader};

    use super::*;

    #[tokio::test]
    async fn bounded_line_reader_stops_at_limit_plus_one_before_eof() {
        let input = b"abcdefghij\n";
        let mut reader = BufReader::new(input.as_slice());
        let mut line = Vec::new();

        let read = read_bounded_line_with_limit(&mut reader, &mut line, 4).await.unwrap();

        assert_eq!(read, 5);
        assert_eq!(line, b"abcde");
        assert_eq!(reader.read_u8().await.unwrap(), b'f');
    }

    #[test]
    fn interleaved_lanes_reassemble_without_byte_corruption() {
        let large = vec![b'x'; MAX_FRAME_PAYLOAD * 2];
        let bulk = encode_line(1, &large).unwrap();
        let input = encode_line(2, b"input\n").unwrap();
        let mut assembler = MuxLineAssembler::default();
        assert!(assembler.push(Lane::Bulk, bulk[0].clone()).unwrap().is_none());
        let (_, input) = assembler.push(Lane::Interactive, input[0].clone()).unwrap().unwrap();
        assert_eq!(input, b"input\n".as_slice());
        let mut complete = None;
        for part in bulk.into_iter().skip(1) {
            complete = assembler.push(Lane::Bulk, part).unwrap().or(complete);
        }
        assert_eq!(complete.unwrap().1, large);
    }
}
