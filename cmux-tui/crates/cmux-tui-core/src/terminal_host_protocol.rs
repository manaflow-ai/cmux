//! Binary framing for the local terminal-host data plane.
//!
//! The public cmux-tui control protocol remains JSON. This framing is for
//! bounded, local Unix-socket streams between a terminal host, its daemon,
//! and disposable renderers. The header is deliberately fixed-width and
//! little-endian so non-Rust clients can implement it without sharing a
//! serializer or ABI.

use std::fmt;
use std::io::{self, Read, Write};

pub const MAGIC: [u8; 4] = *b"CMTH";
pub const HEADER_LEN: usize = 32;
pub const PROTOCOL_VERSION: u16 = 1;
pub const MAX_FRAME_PAYLOAD: usize = 16 * 1024 * 1024;
/// The live Output or Resized payload is not independently renderable. Its
/// immediately following sequenced frame must be Colors, and consumers must
/// apply both before publishing terminal state.
pub const FLAG_COLORS_FOLLOW: u32 = 1 << 0;
/// ClientHello opt-in and HostHello acknowledgement for targeted ViewerSize
/// control responses. This handshake-only flag lets v1 peers negotiate the
/// optimization without exposing an unknown ResizeAck to legacy renderers.
pub const FLAG_VIEWER_SIZE_ACKS: u32 = 1 << 1;
/// ResizeAck payload flag: this request changed the canonical grid and its
/// sequenced Resized+Colors transition was enqueued immediately before the
/// targeted acknowledgement.
pub const RESIZE_ACK_CANONICAL_CHANGED: u32 = 1 << 0;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u16)]
pub enum MessageKind {
    Bootstrap = 1,
    Ready = 2,
    ClientHello = 3,
    HostHello = 4,
    Snapshot = 5,
    Output = 6,
    Resized = 7,
    Colors = 8,
    Title = 9,
    Pwd = 10,
    Bell = 11,
    Exit = 12,
    ResyncRequired = 13,
    Launch = 14,
    /// Response to `MintCapability`; payload is one 32-byte capability.
    Capability = 15,
    /// Targeted response to an acknowledged `ViewerSize`; payload is
    /// canonical cols:u16 + rows:u16 + result_flags:u32.
    ResizeAck = 16,
    Input = 100,
    Paste = 101,
    ViewerSize = 102,
    ReleaseViewer = 103,
    Terminate = 104,
    /// Admin request: little-endian rights:u32 + ttl_ms:u32.
    MintCapability = 105,
}

impl TryFrom<u16> for MessageKind {
    type Error = ProtocolError;

    fn try_from(value: u16) -> Result<Self, Self::Error> {
        match value {
            1 => Ok(Self::Bootstrap),
            2 => Ok(Self::Ready),
            3 => Ok(Self::ClientHello),
            4 => Ok(Self::HostHello),
            5 => Ok(Self::Snapshot),
            6 => Ok(Self::Output),
            7 => Ok(Self::Resized),
            8 => Ok(Self::Colors),
            9 => Ok(Self::Title),
            10 => Ok(Self::Pwd),
            11 => Ok(Self::Bell),
            12 => Ok(Self::Exit),
            13 => Ok(Self::ResyncRequired),
            14 => Ok(Self::Launch),
            15 => Ok(Self::Capability),
            16 => Ok(Self::ResizeAck),
            100 => Ok(Self::Input),
            101 => Ok(Self::Paste),
            102 => Ok(Self::ViewerSize),
            103 => Ok(Self::ReleaseViewer),
            104 => Ok(Self::Terminate),
            105 => Ok(Self::MintCapability),
            other => Err(ProtocolError::UnknownMessageKind(other)),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Frame {
    pub version: u16,
    pub kind: MessageKind,
    pub flags: u32,
    pub request_id: u64,
    /// Host-to-client live-stream position.
    ///
    /// Snapshot and its immediately following full-state Colors frame carry
    /// the same boundary and consume no sequence numbers. Every subsequent
    /// live Output, Colors, Resized, Title, Pwd, Bell, Exit, or
    /// ResyncRequired frame consumes exactly one contiguous number. Control
    /// request/response frames have a nonzero `request_id`, carry sequence
    /// zero, and are outside that ordered stream. A client that sees a gap or
    /// duplicate must disconnect and take a new Snapshot; continuing would
    /// silently corrupt its terminal mirror.
    ///
    /// When Output changes application-authored colors it carries
    /// [`FLAG_COLORS_FOLLOW`], and its full-state Colors frame is exactly the
    /// next sequence. Resized always carries that flag and likewise has its
    /// complete Colors state exactly next. Producers publish each pair
    /// atomically; consumers stage the first frame and expose only the paired
    /// state. Snapshot keeps flags zero: its same-boundary Colors frame is a
    /// mandatory bootstrap rule rather than a live-stream transition.
    /// ClientHello/HostHello may negotiate [`FLAG_VIEWER_SIZE_ACKS`]. Unknown
    /// flags, flags on Colors or other message kinds, an unflagged Resized, and
    /// a flagged live frame not followed by Colors are protocol errors.
    pub sequence: u64,
    pub payload: Vec<u8>,
}

impl Frame {
    pub fn new(kind: MessageKind, payload: Vec<u8>) -> Self {
        Self { version: PROTOCOL_VERSION, kind, flags: 0, request_id: 0, sequence: 0, payload }
    }
}

#[derive(Debug)]
pub enum ProtocolError {
    Io(io::Error),
    InvalidMagic([u8; 4]),
    InvalidVersion(u16),
    UnknownMessageKind(u16),
    PayloadTooLarge { len: usize, max: usize },
    Truncated { expected: usize, actual: usize },
    DecoderFailed,
}

impl fmt::Display for ProtocolError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io(error) => write!(f, "terminal-host protocol I/O failed: {error}"),
            Self::InvalidMagic(actual) => {
                write!(f, "bad terminal-host protocol magic {actual:?}")
            }
            Self::InvalidVersion(version) => {
                write!(f, "bad terminal-host protocol version {version}")
            }
            Self::UnknownMessageKind(kind) => {
                write!(f, "unknown terminal-host message kind {kind}")
            }
            Self::PayloadTooLarge { len, max } => {
                write!(f, "terminal-host payload is {len} bytes; maximum is {max}")
            }
            Self::Truncated { expected, actual } => {
                write!(f, "truncated terminal-host frame: expected {expected} bytes, got {actual}")
            }
            Self::DecoderFailed => write!(f, "terminal-host decoder is unusable after an error"),
        }
    }
}

impl std::error::Error for ProtocolError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Io(error) => Some(error),
            _ => None,
        }
    }
}

impl From<io::Error> for ProtocolError {
    fn from(value: io::Error) -> Self {
        Self::Io(value)
    }
}

#[derive(Debug, Clone, Copy)]
struct Header {
    version: u16,
    kind: MessageKind,
    flags: u32,
    payload_len: usize,
    request_id: u64,
    sequence: u64,
}

fn parse_header(bytes: &[u8], max_payload: usize) -> Result<Header, ProtocolError> {
    debug_assert_eq!(bytes.len(), HEADER_LEN);
    let magic = <[u8; 4]>::try_from(&bytes[0..4]).expect("fixed header magic slice");
    if magic != MAGIC {
        return Err(ProtocolError::InvalidMagic(magic));
    }
    let version = u16::from_le_bytes([bytes[4], bytes[5]]);
    if version == 0 {
        return Err(ProtocolError::InvalidVersion(version));
    }
    let kind = MessageKind::try_from(u16::from_le_bytes([bytes[6], bytes[7]]))?;
    let flags = u32::from_le_bytes(bytes[8..12].try_into().expect("fixed flags slice"));
    let payload_len =
        u32::from_le_bytes(bytes[12..16].try_into().expect("fixed payload-length slice")) as usize;
    if payload_len > max_payload {
        return Err(ProtocolError::PayloadTooLarge { len: payload_len, max: max_payload });
    }
    let request_id = u64::from_le_bytes(bytes[16..24].try_into().expect("fixed request-id slice"));
    let sequence = u64::from_le_bytes(bytes[24..32].try_into().expect("fixed sequence slice"));
    Ok(Header { version, kind, flags, payload_len, request_id, sequence })
}

fn encode_header(frame: &Frame, max_payload: usize) -> Result<[u8; HEADER_LEN], ProtocolError> {
    if frame.version == 0 {
        return Err(ProtocolError::InvalidVersion(frame.version));
    }
    if frame.payload.len() > max_payload {
        return Err(ProtocolError::PayloadTooLarge { len: frame.payload.len(), max: max_payload });
    }
    let payload_len = u32::try_from(frame.payload.len()).map_err(|_| {
        ProtocolError::PayloadTooLarge { len: frame.payload.len(), max: max_payload }
    })?;
    let mut header = [0u8; HEADER_LEN];
    header[0..4].copy_from_slice(&MAGIC);
    header[4..6].copy_from_slice(&frame.version.to_le_bytes());
    header[6..8].copy_from_slice(&(frame.kind as u16).to_le_bytes());
    header[8..12].copy_from_slice(&frame.flags.to_le_bytes());
    header[12..16].copy_from_slice(&payload_len.to_le_bytes());
    header[16..24].copy_from_slice(&frame.request_id.to_le_bytes());
    header[24..32].copy_from_slice(&frame.sequence.to_le_bytes());
    Ok(header)
}

pub fn write_frame(writer: &mut impl Write, frame: &Frame) -> Result<(), ProtocolError> {
    let header = encode_header(frame, MAX_FRAME_PAYLOAD)?;
    writer.write_all(&header)?;
    writer.write_all(&frame.payload)?;
    writer.flush()?;
    Ok(())
}

pub fn encode_frame(frame: &Frame) -> Result<Vec<u8>, ProtocolError> {
    let mut bytes = Vec::with_capacity(HEADER_LEN.saturating_add(frame.payload.len()));
    write_frame(&mut bytes, frame)?;
    Ok(bytes)
}

/// Read one complete frame. Clean EOF before a header returns `None`; EOF
/// after any part of a frame is a truncation error.
pub fn read_frame(
    reader: &mut impl Read,
    max_payload: usize,
) -> Result<Option<Frame>, ProtocolError> {
    let max_payload = max_payload.min(MAX_FRAME_PAYLOAD);
    let mut header_bytes = [0u8; HEADER_LEN];
    let mut header_read = 0;
    while header_read < HEADER_LEN {
        match reader.read(&mut header_bytes[header_read..]) {
            Ok(0) if header_read == 0 => return Ok(None),
            Ok(0) => {
                return Err(ProtocolError::Truncated { expected: HEADER_LEN, actual: header_read });
            }
            Ok(count) => header_read += count,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) => return Err(error.into()),
        }
    }
    let header = parse_header(&header_bytes, max_payload)?;
    let mut payload = vec![0u8; header.payload_len];
    let mut payload_read = 0;
    while payload_read < payload.len() {
        match reader.read(&mut payload[payload_read..]) {
            Ok(0) => {
                return Err(ProtocolError::Truncated {
                    expected: HEADER_LEN + payload.len(),
                    actual: HEADER_LEN + payload_read,
                });
            }
            Ok(count) => payload_read += count,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) => return Err(error.into()),
        }
    }
    Ok(Some(Frame {
        version: header.version,
        kind: header.kind,
        flags: header.flags,
        request_id: header.request_id,
        sequence: header.sequence,
        payload,
    }))
}

/// Incremental decoder for nonblocking or callback-driven stream readers.
/// It parses and validates the header before retaining any payload bytes, so
/// an advertised oversized frame cannot force a correspondingly large
/// allocation.
pub struct FrameDecoder {
    buffer: Vec<u8>,
    expected_total: Option<usize>,
    max_payload: usize,
    failed: bool,
}

impl FrameDecoder {
    pub fn new(max_payload: usize) -> Self {
        Self {
            buffer: Vec::with_capacity(HEADER_LEN),
            expected_total: None,
            max_payload: max_payload.min(MAX_FRAME_PAYLOAD),
            failed: false,
        }
    }

    pub fn push(&mut self, mut input: &[u8]) -> Result<Vec<Frame>, ProtocolError> {
        if self.failed {
            return Err(ProtocolError::DecoderFailed);
        }
        let result = self.push_inner(&mut input);
        if result.is_err() {
            self.failed = true;
        }
        result
    }

    fn push_inner(&mut self, input: &mut &[u8]) -> Result<Vec<Frame>, ProtocolError> {
        let mut frames = Vec::new();
        loop {
            if self.expected_total.is_none() {
                if self.buffer.len() < HEADER_LEN {
                    if input.is_empty() {
                        break;
                    }
                    let count = (HEADER_LEN - self.buffer.len()).min(input.len());
                    self.buffer.extend_from_slice(&input[..count]);
                    *input = &input[count..];
                    if self.buffer.len() < HEADER_LEN {
                        break;
                    }
                }
                let header = parse_header(&self.buffer[..HEADER_LEN], self.max_payload)?;
                self.expected_total = Some(HEADER_LEN + header.payload_len);
                self.buffer.reserve(header.payload_len);
            }

            let expected_total = self.expected_total.expect("set after a valid header");
            if self.buffer.len() < expected_total {
                if input.is_empty() {
                    break;
                }
                let count = (expected_total - self.buffer.len()).min(input.len());
                self.buffer.extend_from_slice(&input[..count]);
                *input = &input[count..];
                if self.buffer.len() < expected_total {
                    break;
                }
            }

            let header = parse_header(&self.buffer[..HEADER_LEN], self.max_payload)?;
            self.buffer.drain(..HEADER_LEN);
            let payload = std::mem::take(&mut self.buffer);
            self.buffer = Vec::with_capacity(HEADER_LEN);
            self.expected_total = None;
            frames.push(Frame {
                version: header.version,
                kind: header.kind,
                flags: header.flags,
                request_id: header.request_id,
                sequence: header.sequence,
                payload,
            });
        }
        Ok(frames)
    }

    pub fn finish(&self) -> Result<(), ProtocolError> {
        if self.failed {
            return Err(ProtocolError::DecoderFailed);
        }
        if self.buffer.is_empty() && self.expected_total.is_none() {
            return Ok(());
        }
        Err(ProtocolError::Truncated {
            expected: self.expected_total.unwrap_or(HEADER_LEN),
            actual: self.buffer.len(),
        })
    }

    pub fn buffered_len(&self) -> usize {
        self.buffer.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_frame() -> Frame {
        Frame {
            version: PROTOCOL_VERSION,
            kind: MessageKind::Output,
            flags: 0x1122_3344,
            request_id: 0x0102_0304_0506_0708,
            sequence: 0x1112_1314_1516_1718,
            payload: vec![0xaa, 0xbb, 0xcc],
        }
    }

    #[test]
    fn golden_frame_is_explicit_little_endian() {
        let encoded = encode_frame(&sample_frame()).unwrap();
        assert_eq!(
            encoded,
            vec![
                b'C', b'M', b'T', b'H', // magic
                0x01, 0x00, // version
                0x06, 0x00, // output
                0x44, 0x33, 0x22, 0x11, // flags
                0x03, 0x00, 0x00, 0x00, // payload length
                0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01, // request id
                0x18, 0x17, 0x16, 0x15, 0x14, 0x13, 0x12, 0x11, // sequence
                0xaa, 0xbb, 0xcc,
            ]
        );
        let decoded = read_frame(&mut encoded.as_slice(), MAX_FRAME_PAYLOAD).unwrap().unwrap();
        assert_eq!(decoded, sample_frame());
    }

    #[test]
    fn fragmented_and_coalesced_frames_decode_without_boundary_assumptions() {
        let first = sample_frame();
        let mut second = Frame::new(MessageKind::ViewerSize, vec![80, 0, 24, 0]);
        second.request_id = 9;
        let mut stream = encode_frame(&first).unwrap();
        stream.extend_from_slice(&encode_frame(&second).unwrap());

        let mut decoder = FrameDecoder::new(1024);
        let mut decoded = Vec::new();
        for byte in &stream {
            decoded.extend(decoder.push(std::slice::from_ref(byte)).unwrap());
        }
        decoder.finish().unwrap();
        assert_eq!(decoded, vec![first.clone(), second.clone()]);

        let mut decoder = FrameDecoder::new(1024);
        assert_eq!(decoder.push(&stream).unwrap(), vec![first, second]);
        decoder.finish().unwrap();
    }

    #[test]
    fn malformed_headers_poison_the_incremental_decoder() {
        let mut bad_magic = encode_frame(&sample_frame()).unwrap();
        bad_magic[0] = b'X';
        let mut decoder = FrameDecoder::new(1024);
        assert!(matches!(decoder.push(&bad_magic), Err(ProtocolError::InvalidMagic(_))));
        assert!(matches!(decoder.push(&[]), Err(ProtocolError::DecoderFailed)));

        let mut unknown_kind = encode_frame(&sample_frame()).unwrap();
        unknown_kind[6..8].copy_from_slice(&999u16.to_le_bytes());
        let mut decoder = FrameDecoder::new(1024);
        assert!(matches!(decoder.push(&unknown_kind), Err(ProtocolError::UnknownMessageKind(999))));

        let mut zero_version = encode_frame(&sample_frame()).unwrap();
        zero_version[4..6].copy_from_slice(&0u16.to_le_bytes());
        let mut decoder = FrameDecoder::new(1024);
        assert!(matches!(decoder.push(&zero_version), Err(ProtocolError::InvalidVersion(0))));
    }

    #[test]
    fn oversized_length_is_rejected_before_payload_is_buffered() {
        let mut encoded = encode_frame(&sample_frame()).unwrap();
        encoded[12..16].copy_from_slice(&65u32.to_le_bytes());
        encoded.truncate(HEADER_LEN);
        let mut decoder = FrameDecoder::new(64);
        assert!(matches!(
            decoder.push(&encoded),
            Err(ProtocolError::PayloadTooLarge { len: 65, max: 64 })
        ));
        assert_eq!(decoder.buffered_len(), HEADER_LEN);
    }

    #[test]
    fn incomplete_header_and_payload_are_reported_as_truncated() {
        let encoded = encode_frame(&sample_frame()).unwrap();
        let mut decoder = FrameDecoder::new(1024);
        decoder.push(&encoded[..8]).unwrap();
        assert!(matches!(
            decoder.finish(),
            Err(ProtocolError::Truncated { expected: HEADER_LEN, actual: 8 })
        ));

        let mut decoder = FrameDecoder::new(1024);
        decoder.push(&encoded[..HEADER_LEN + 1]).unwrap();
        assert!(matches!(
            decoder.finish(),
            Err(ProtocolError::Truncated { expected, actual })
                if expected == HEADER_LEN + 3 && actual == HEADER_LEN + 1
        ));

        let error = read_frame(&mut &encoded[..HEADER_LEN + 2], 1024).unwrap_err();
        assert!(matches!(
            error,
            ProtocolError::Truncated { expected, actual }
                if expected == HEADER_LEN + 3 && actual == HEADER_LEN + 2
        ));
    }

    #[test]
    fn encoder_enforces_the_global_payload_budget() {
        let frame = Frame::new(MessageKind::Input, vec![0; MAX_FRAME_PAYLOAD + 1]);
        assert!(matches!(
            encode_frame(&frame),
            Err(ProtocolError::PayloadTooLarge { len, max })
                if len == MAX_FRAME_PAYLOAD + 1 && max == MAX_FRAME_PAYLOAD
        ));
    }
}
