use std::collections::HashMap;
use std::fmt;
use std::io;

use bytes::{BufMut, Bytes, BytesMut};
use cmux_ipc::{BadMessage, FrameHeader, FrameKind};
use cmux_remote_protocol::{
    Lane, MAX_FRAME_PAYLOAD, REMOTE_CLIENT_MESSAGE_MAX_BYTES, REMOTE_SESSION_MESSAGE_MAX_BYTES,
};
use tokio::io::{AsyncBufRead, AsyncBufReadExt, AsyncReadExt};

const MAGIC: [u8; 4] = *b"CMXL";
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

/// One message cut from a local mux socket by [`read_bounded_message`]; its
/// bytes are in the caller's buffer, verbatim.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum MuxMessage {
    /// A JSON line, with its `\n` when it had one.
    Line,
    /// A cmux-ipc frame (`bridge-frames-v1`): its 16-byte header, then the
    /// payload the header declares. The bridge never reads the payload.
    Frame(FrameHeader),
}

/// Whether `message` is a frame: 0xFF never starts a UTF-8 JSON line.
fn is_frame(message: &[u8]) -> bool {
    message.first() == Some(&cmux_ipc::MAGIC)
}

/// The largest frame payload that fits a `maximum`-byte message budget
/// (the same budget, delimiter included, as a line in that direction).
fn frame_payload_limit(maximum: usize) -> u32 {
    let payload = maximum.saturating_sub(1).saturating_sub(cmux_ipc::HEADER_LEN);
    u32::try_from(payload).unwrap_or(u32::MAX).min(cmux_ipc::MAX_FRAME_PAYLOAD)
}

/// Cuts the next message at a message boundary: a frame when the first byte
/// is 0xFF, else a JSON line as [`read_bounded_line_with_limit`] does.
/// `Ok(None)` is a clean end of stream. A frame is cut from its header alone,
/// as cmux-ipc's `FrameReader` does: the header is validated before a payload
/// byte is read, and the payload is copied through unparsed. Without
/// `frames` (the far end did not advertise `bridge-frames-v1`) a frame is
/// `frames_not_negotiated`.
pub(crate) async fn read_bounded_message<R>(
    reader: &mut R,
    message: &mut Vec<u8>,
    maximum: usize,
    frames: bool,
) -> Result<Option<MuxMessage>, MuxReadError>
where
    R: AsyncBufRead + Unpin,
{
    message.clear();
    let Some(&first) = reader.fill_buf().await?.first() else {
        return Ok(None);
    };
    if first != cmux_ipc::MAGIC {
        read_bounded_line_with_limit(reader, message, maximum).await?;
        return Ok(Some(MuxMessage::Line));
    }
    if !frames {
        return Err(MuxCodecError::Frame(BadMessage::FramesNotNegotiated).into());
    }
    let need = cmux_ipc::HEADER_LEN;
    read_up_to(reader, message, need).await?;
    let Ok(header) = <[u8; cmux_ipc::HEADER_LEN]>::try_from(message.as_slice()) else {
        return Err(
            MuxCodecError::Frame(BadMessage::Truncated { have: message.len(), need }).into()
        );
    };
    let header =
        FrameHeader::decode(header, frame_payload_limit(maximum)).map_err(MuxCodecError::Frame)?;
    let need = header.frame_len();
    message.reserve_exact(need.saturating_sub(cmux_ipc::HEADER_LEN));
    read_up_to(reader, message, need).await?;
    if message.len() != need {
        return Err(
            MuxCodecError::Frame(BadMessage::Truncated { have: message.len(), need }).into()
        );
    }
    Ok(Some(MuxMessage::Frame(header)))
}

/// Checks a reassembled message that starts with 0xFF before it reaches the
/// local socket: one valid header within the `maximum` budget and exactly the
/// payload it declares, so a peer cannot smuggle a second message behind it.
fn check_bridged_frame(message: &[u8], maximum: usize) -> Result<FrameHeader, MuxCodecError> {
    let Some((header, _)) = message.split_first_chunk::<{ cmux_ipc::HEADER_LEN }>() else {
        let need = cmux_ipc::HEADER_LEN;
        return Err(MuxCodecError::Frame(BadMessage::Truncated { have: message.len(), need }));
    };
    let header =
        FrameHeader::decode(*header, frame_payload_limit(maximum)).map_err(MuxCodecError::Frame)?;
    let need = header.frame_len();
    if message.len() < need {
        return Err(MuxCodecError::Frame(BadMessage::Truncated { have: message.len(), need }));
    }
    if message.len() > need {
        return Err(MuxCodecError::InvalidPacket);
    }
    Ok(header)
}

/// Appends bytes until `message` holds `total` of them or the stream ends.
async fn read_up_to<R>(reader: &mut R, message: &mut Vec<u8>, total: usize) -> io::Result<()>
where
    R: AsyncBufRead + Unpin,
{
    let missing = u64::try_from(total.saturating_sub(message.len())).unwrap_or(u64::MAX);
    (&mut *reader).take(missing).read_to_end(message).await?;
    Ok(())
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

pub(crate) struct MuxLineAssembler<R = ()> {
    lines: HashMap<u64, PartialLine<R>>,
    bytes: usize,
    maximum: usize,
}

impl<R> Default for MuxLineAssembler<R> {
    fn default() -> Self {
        Self::with_maximum(MAX_MUX_DOWNLOAD_LINE_BYTES)
    }
}

impl<R> MuxLineAssembler<R> {
    pub(crate) fn with_maximum(maximum: usize) -> Self {
        Self { lines: HashMap::new(), bytes: 0, maximum }
    }
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
    frame: Option<FrameHeader>,
    _retained: Vec<R>,
}

impl<R> AssembledMuxLine<R> {
    pub(crate) fn lane(&self) -> Lane {
        self.lane
    }

    /// The header of a reassembled frame; `None` for a JSON line. The
    /// receiving end admits it with [`crate::mux_lanes::admit_bridged_frame`]
    /// before it writes a byte of it.
    pub(crate) fn frame_header(&self) -> Option<&FrameHeader> {
        self.frame.as_ref()
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
        if magic != MAGIC {
            return Err(MuxCodecError::InvalidPacket);
        }
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
            parts: vec![None; parts as usize],
            retained: Vec::with_capacity(parts as usize),
            received: 0,
            bytes: 0,
        });
        if line.lane != lane || line.parts.len() != parts as usize {
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
        let payload = joined.freeze();
        let frame = if is_frame(&payload) {
            Some(check_bridged_frame(&payload, self.maximum)?)
        } else if mux_line_payload_len(&payload) > self.maximum.saturating_sub(1) {
            return Err(MuxCodecError::LineTooLarge(payload.len()));
        } else {
            None
        };
        Ok(Some(AssembledMuxLine { lane: line.lane, payload, frame, _retained: line.retained }))
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MuxCodecError {
    InvalidPacket,
    LineTooLarge(usize),
    TooManyLines,
    /// A frame the cmux-ipc rules refuse (bad header, oversize, truncated,
    /// or a frame on a bridge without `bridge-frames-v1`).
    Frame(BadMessage),
    /// A frame that cannot cross a byte bridge: it carries a descriptor or
    /// names the local shared-memory ring.
    FrameNotBridged(FrameKind),
    /// A frame that arrived on a lane its sender never puts it on, so it
    /// could have passed items of its own sequence.
    FrameOffLane {
        kind: FrameKind,
        stream: u16,
        lane: Lane,
    },
}

impl fmt::Display for MuxCodecError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidPacket => formatter.write_str("invalid mux line packet"),
            Self::LineTooLarge(size) => write!(formatter, "mux line is too large: {size}"),
            Self::TooManyLines => formatter.write_str("too many incomplete mux lines"),
            Self::Frame(error) => write!(formatter, "bad mux frame ({}): {error}", error.reason()),
            Self::FrameNotBridged(kind) => {
                write!(formatter, "a {} frame cannot cross the mux bridge", kind.name())
            }
            Self::FrameOffLane { kind, stream, lane } => write!(
                formatter,
                "a {} frame of stream {stream} arrived on the {lane:?} mux lane",
                kind.name()
            ),
        }
    }
}

impl std::error::Error for MuxCodecError {}

/// Why [`read_bounded_message`] stopped.
#[derive(Debug)]
pub(crate) enum MuxReadError {
    Io(io::Error),
    Codec(MuxCodecError),
}

impl From<io::Error> for MuxReadError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

impl From<MuxCodecError> for MuxReadError {
    fn from(error: MuxCodecError) -> Self {
        Self::Codec(error)
    }
}

#[cfg(test)]
mod tests {
    use std::collections::{BTreeMap, VecDeque};

    use cmux_ipc::{Aux, CallAux, CallFlags, Frame, FrameReader, Message, PriorityHint};

    use super::*;
    use crate::mux_lanes::{FrameDirection, MuxLaneTracker, classify_client_line, classify_frame};

    const STREAMS: [u16; 3] = [1, 2, 3];

    fn encode(frame: &Frame) -> Vec<u8> {
        let mut out = BytesMut::new();
        frame.encode_into(&mut out);
        out.to_vec()
    }

    fn data(kind: FrameKind, stream: u16, offset: u64, payload: Vec<u8>) -> Frame {
        Frame::new(kind, stream, Aux::Offset(offset), Bytes::from(payload)).unwrap()
    }

    /// Each stream's frames, in order.
    type FramesByStream = BTreeMap<u16, Vec<Frame>>;

    /// Interleaved OUTPUT and EVENT frames of three streams (some longer than
    /// one CMXL part), stream-0 REPLY frames and JSON lines, as the remote
    /// daemon writes them, with each stream's frames in order.
    fn daemon_wire() -> (Vec<u8>, FramesByStream, Vec<Vec<u8>>) {
        let mut wire = Vec::new();
        let mut per_stream = BTreeMap::<u16, Vec<Frame>>::new();
        let mut lines = Vec::new();
        let mut offsets = [0_u64; 3];
        for round in 0..40_usize {
            for (index, stream) in STREAMS.into_iter().enumerate() {
                let len = match (round + index) % 7 {
                    0 => 0,
                    3 => CHUNK_BYTES * 2 + 17,
                    _ => 1 + (round * 131 + index * 977) % 4096,
                };
                let payload =
                    (0..len).map(|byte| (byte as u8) ^ (round as u8) ^ stream as u8).collect();
                let output = data(FrameKind::Output, stream, offsets[index], payload);
                offsets[index] += len as u64;
                wire.extend_from_slice(&encode(&output));
                per_stream.entry(stream).or_default().push(output);
                if round % 3 == index {
                    let title = format!("title {round}").into_bytes();
                    let event = data(FrameKind::Event, stream, offsets[index], title);
                    wire.extend_from_slice(&encode(&event));
                    per_stream.entry(stream).or_default().push(event);
                }
            }
            if round % 5 == 0 {
                let line = format!("{{\"event\":\"output\",\"surface\":9,\"seq\":{round}}}\n");
                wire.extend_from_slice(line.as_bytes());
                lines.push(line.into_bytes());
                let call = CallAux {
                    request_id: round as u32,
                    method_id: 0x0101,
                    priority: PriorityHint::Control,
                    flags: CallFlags::empty(),
                };
                let body = Bytes::from(format!("{{\"round\":{round}}}"));
                let reply = Frame::new(FrameKind::Reply, 0, Aux::Call(call), body).unwrap();
                wire.extend_from_slice(&encode(&reply));
                per_stream.entry(0).or_default().push(reply);
            }
        }
        (wire, per_stream, lines)
    }

    /// What the sending end of the bridge does: cut each message and encode
    /// it as CMXL packets on its lane.
    async fn cut_into_lanes(mut wire: &[u8], direction: FrameDirection) -> [VecDeque<Bytes>; 4] {
        let tracker = MuxLaneTracker::default();
        let mut lanes: [VecDeque<Bytes>; 4] = Default::default();
        let mut bytes = Vec::new();
        let mut message = 1_u64;
        let maximum = MAX_MUX_DOWNLOAD_LINE_BYTES;
        while let Some(kind) =
            read_bounded_message(&mut wire, &mut bytes, maximum, true).await.unwrap()
        {
            let lane = match (kind, direction) {
                (MuxMessage::Frame(header), _) => classify_frame(&header, direction).unwrap(),
                (MuxMessage::Line, FrameDirection::ToClient) => {
                    tracker.classify_server_line(&bytes).unwrap()
                }
                (MuxMessage::Line, FrameDirection::ToDaemon) => classify_client_line(&bytes),
            };
            for packet in encode_line_with_limit(message, &bytes, maximum).unwrap() {
                lanes[lane as usize].push_back(packet);
            }
            message += 1;
        }
        lanes
    }

    /// The messages of a delivered byte stream, in delivery order: each
    /// frame's stream and kind, or a JSON line.
    fn delivered_order(delivered: &[u8]) -> Vec<Result<(u16, FrameKind, u16), String>> {
        let mut reader = FrameReader::new(cmux_ipc::ReaderLimits::default());
        reader.negotiate_frames();
        reader.push(delivered);
        reader.mark_eof();
        let mut order = Vec::new();
        while let Some(message) = reader.next_message().unwrap() {
            order.push(match message {
                Message::Frame(frame) => {
                    let header = frame.header();
                    let method = header.call().map_or(0, |call| call.method_id);
                    Ok((header.stream(), header.kind(), method))
                }
                Message::Json(line) => Err(line.to_string()),
            });
        }
        order
    }

    const SEEDS: [u64; 8] =
        [0x9e37_79b9_7f4a_7c15, 1, 0xdead_beef, 42, 7, 0x1234_5678_9abc, 99_991, 0xfeed];

    /// `stream-end` and `input-failed` are JSON text on a frames connection,
    /// queued behind the stream's last items (pending_streams.rs): over the
    /// bridge they must still come after every frame of their stream.
    #[tokio::test]
    async fn a_stream_end_line_never_passes_the_frames_of_its_stream() {
        let mut wire = Vec::new();
        for round in 0..24_u64 {
            for stream in STREAMS {
                let payload = vec![round as u8; 1 + (round as usize * 977) % (CHUNK_BYTES + 9)];
                wire.extend_from_slice(&encode(&data(FrameKind::Output, stream, round, payload)));
            }
        }
        let control = b"{\"event\":\"workspace-changed\",\"workspace\":1}\n";
        wire.extend_from_slice(control);
        wire.extend_from_slice(
            b"{\"event\":\"input-failed\",\"stream\":1,\"reason\":\"overflow\",\"bytes\":4}\n",
        );
        wire.extend_from_slice(
            b"{\"event\":\"stream-end\",\"stream\":1,\"reason\":\"overflow\"}\n",
        );
        wire.extend_from_slice(
            b"{\"event\":\"stream-end\",\"stream\":2,\"reason\":\"attach_failed\"}\n",
        );
        let lanes = cut_into_lanes(&wire, FrameDirection::ToClient).await;
        assert_eq!(
            lanes[Lane::Control as usize].len(),
            1,
            "only the unrelated event rides control"
        );
        for seed in SEEDS {
            let order = delivered_order(&deliver(lanes.clone(), seed));
            for stream in [1_u16, 2] {
                let last_frame = order
                    .iter()
                    .rposition(|message| matches!(message, Ok((id, _, _)) if *id == stream))
                    .unwrap();
                let needle = format!("\"stream\":{stream},");
                for (index, message) in order.iter().enumerate() {
                    if let Err(line) = message
                        && line.contains(&needle)
                    {
                        assert!(
                            index > last_frame,
                            "seed {seed:#x}: {line} passed a frame of stream {stream}"
                        );
                    }
                }
            }
        }
    }

    fn request(stream: u16, request_id: u32, method: &cmux_ipc::MethodAttrs) -> Frame {
        let call = CallAux {
            request_id,
            method_id: method.id.raw(),
            priority: method.priority,
            flags: CallFlags::empty(),
        };
        Frame::new(FrameKind::Request, stream, Aux::Call(call), Bytes::from_static(b"{}")).unwrap()
    }

    /// A framed control-priority mutation on stream 0 (`close-surface`) rides
    /// with the INPUT sent before it, as a JSON mutation line does; only a
    /// read-only `independent` read may leave that lane.
    #[tokio::test]
    async fn a_framed_close_never_passes_input_sent_before_it() {
        let tables = cmux_ipc::MethodTables::schema();
        let close = tables.v12_id("close-surface").and_then(|id| tables.method(id)).unwrap();
        assert_eq!(close.priority, PriorityHint::Control);
        let read = tables
            .v12_families()
            .flat_map(cmux_ipc::FamilyTable::iter)
            .find(|method| {
                method.ordering == cmux_ipc::Ordering::Independent
                    && method.durability == cmux_ipc::Durability::ReadOnly
                    && method.priority == PriorityHint::Control
            })
            .expect("the schema has an independent control read");
        let mut wire = Vec::new();
        for round in 0..32_u64 {
            let keys = vec![b'k'; 1 + (round as usize * 131) % (CHUNK_BYTES * 2)];
            let input = Frame::new(FrameKind::Input, 1, Aux::FlowId(round), Bytes::from(keys));
            wire.extend_from_slice(&encode(&input.unwrap()));
        }
        wire.extend_from_slice(&encode(&request(0, 7, read)));
        wire.extend_from_slice(&encode(&request(0, 8, close)));
        let lanes = cut_into_lanes(&wire, FrameDirection::ToDaemon).await;
        assert_eq!(lanes[Lane::Control as usize].len(), 1, "only the read leaves the input lane");
        for seed in SEEDS {
            let order = delivered_order(&deliver(lanes.clone(), seed));
            let last_input = order
                .iter()
                .rposition(|message| matches!(message, Ok((1, FrameKind::Input, _))))
                .unwrap();
            let closed = order
                .iter()
                .position(|message| matches!(message, Ok((0, _, id)) if *id == close.id.raw()))
                .unwrap();
            assert!(closed > last_input, "seed {seed:#x}: close-surface passed accepted input");
        }
    }

    /// Delivers the lanes as independent carriers do: FIFO within a lane, any
    /// interleaving across lanes (a seeded xorshift picks the next lane).
    fn deliver(mut lanes: [VecDeque<Bytes>; 4], mut seed: u64) -> Vec<u8> {
        let mut assembler = MuxLineAssembler::<()>::with_maximum(MAX_MUX_DOWNLOAD_LINE_BYTES);
        let mut out = Vec::new();
        while lanes.iter().any(|lane| !lane.is_empty()) {
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            let ready: Vec<usize> = (0..4).filter(|lane| !lanes[*lane].is_empty()).collect();
            let index = ready[(seed % ready.len() as u64) as usize];
            let packet = lanes[index].pop_front().unwrap();
            if let Some(message) = assembler.push_retaining(Lane::ALL[index], packet, ()).unwrap() {
                out.extend_from_slice(message.payload());
            }
        }
        out
    }

    #[tokio::test]
    async fn three_interleaved_streams_keep_per_stream_order_and_bytes() {
        let (wire, expected, expected_lines) = daemon_wire();
        let lanes = cut_into_lanes(&wire, FrameDirection::ToClient).await;
        assert!(lanes[Lane::Bulk as usize].len() > 120, "stream data rides the bulk lane");
        let replies = lanes[Lane::Interactive as usize].len();
        assert_eq!(replies, 8, "only the stream-0 replies of a sequenced method ride interactive");
        for seed in [0x9e37_79b9_7f4a_7c15, 1, 0xdead_beef, 42] {
            let delivered = deliver(lanes.clone(), seed);
            let mut reader = FrameReader::new(cmux_ipc::ReaderLimits::default());
            reader.negotiate_frames();
            reader.push(&delivered);
            reader.mark_eof();
            let mut per_stream = BTreeMap::<u16, Vec<Frame>>::new();
            let mut lines = Vec::new();
            while let Some(message) = reader.next_message().unwrap() {
                match message {
                    Message::Frame(frame) => {
                        per_stream.entry(frame.header().stream()).or_default().push(frame);
                    }
                    Message::Json(line) => lines.push(format!("{line}\n").into_bytes()),
                }
            }
            assert_eq!(per_stream, expected, "seed {seed:#x}: a stream lost order or bytes");
            lines.sort();
            let mut want = expected_lines.clone();
            want.sort();
            assert_eq!(lines, want, "seed {seed:#x}: JSON lines changed");
        }
    }

    #[test]
    fn a_reassembled_frame_must_match_its_header() {
        let frame = encode(&data(FrameKind::Output, 1, 0, vec![7; 40]));
        let maximum = MAX_MUX_DOWNLOAD_LINE_BYTES;
        let assemble = |bytes: &[u8]| {
            let mut assembler = MuxLineAssembler::<()>::with_maximum(maximum);
            let packet = encode_line_with_limit(1, bytes, maximum).unwrap().remove(0);
            assembler.push_retaining(Lane::Bulk, packet, ()).map(|line| line.map(|_| ()))
        };
        assert_eq!(assemble(&frame), Ok(Some(())));
        let mut trailing = frame.clone();
        trailing.extend_from_slice(b"{\"cmd\":\"x\"}\n");
        assert_eq!(assemble(&trailing), Err(MuxCodecError::InvalidPacket));
        assert!(matches!(
            assemble(&frame[..30]),
            Err(MuxCodecError::Frame(BadMessage::Truncated { have: 30, need: 56 }))
        ));
        let mut bad_kind = frame;
        bad_kind[1] = 0x7f;
        assert!(matches!(
            assemble(&bad_kind),
            Err(MuxCodecError::Frame(BadMessage::UnknownKind { kind: 0x7f }))
        ));
    }

    #[tokio::test]
    async fn a_frame_without_bridge_frames_v1_is_refused() {
        let frame = encode(&data(FrameKind::Output, 1, 0, b"a".to_vec()));
        let mut wire = frame.as_slice();
        let maximum = MAX_MUX_UPLOAD_LINE_BYTES;
        let error =
            read_bounded_message(&mut wire, &mut Vec::new(), maximum, false).await.unwrap_err();
        assert!(matches!(
            error,
            MuxReadError::Codec(MuxCodecError::Frame(BadMessage::FramesNotNegotiated))
        ));
    }

    #[tokio::test]
    async fn an_oversize_frame_is_refused_from_its_header() {
        let mut header = encode(&data(FrameKind::Output, 1, 0, Vec::new()));
        let declared = u32::try_from(MAX_MUX_UPLOAD_LINE_BYTES).unwrap();
        header[4..8].copy_from_slice(&declared.to_le_bytes());
        let mut wire = header.as_slice();
        let maximum = MAX_MUX_UPLOAD_LINE_BYTES;
        let error =
            read_bounded_message(&mut wire, &mut Vec::new(), maximum, true).await.unwrap_err();
        assert!(matches!(
            error,
            MuxReadError::Codec(MuxCodecError::Frame(BadMessage::Oversize { .. }))
        ));
    }

    #[tokio::test]
    async fn a_frame_cut_short_by_the_peer_is_truncated() {
        let frame = encode(&data(FrameKind::Output, 2, 7, vec![1; 100]));
        let maximum = MAX_MUX_UPLOAD_LINE_BYTES;
        for cut in [3, 16, 60] {
            let mut wire = &frame[..cut];
            let error =
                read_bounded_message(&mut wire, &mut Vec::new(), maximum, true).await.unwrap_err();
            let MuxReadError::Codec(MuxCodecError::Frame(BadMessage::Truncated { have, .. })) =
                error
            else {
                panic!("cut at {cut}: {error:?}");
            };
            assert_eq!(have, cut);
        }
    }

    #[tokio::test]
    async fn lines_are_cut_as_before_with_or_without_frames() {
        let maximum = MAX_MUX_UPLOAD_LINE_BYTES;
        for frames in [false, true] {
            let mut wire = &b"{\"cmd\":\"ping\"}\n{\"id\":2}"[..];
            let mut message = Vec::new();
            let first = read_bounded_message(&mut wire, &mut message, maximum, frames).await;
            assert_eq!(first.unwrap(), Some(MuxMessage::Line));
            assert_eq!(message, b"{\"cmd\":\"ping\"}\n");
            let second = read_bounded_message(&mut wire, &mut message, maximum, frames).await;
            assert_eq!(second.unwrap(), Some(MuxMessage::Line));
            assert_eq!(message, b"{\"id\":2}");
            let end = read_bounded_message(&mut wire, &mut message, maximum, frames).await;
            assert_eq!(end.unwrap(), None);
        }
    }
}
