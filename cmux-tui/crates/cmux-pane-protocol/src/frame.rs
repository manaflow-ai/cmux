//! Message framing on byte streams (unix sockets, socketpairs, pipes).
//!
//! Each message is a 4-byte big-endian header and then the message bytes.
//! The low 31 bits of the header are the length, at most [`MAX_MESSAGE`]
//! (16 MiB). Bit 31 marks a binary message; it is clear for a JSON text
//! message. A peer that only ever sends text therefore writes exactly the
//! spec's plain length prefix, and a binary header reads as an oversized
//! length to a peer that does not know the flag, so it fails closed.
//!
//! A binary message is a byte-stream data frame:
//! `[u32 stream id BE][u32 credit BE][payload]` ([`DataFrame`]).

use bytes::Bytes;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

/// The largest message, text or binary: 16 MiB.
pub const MAX_MESSAGE: usize = 16 * 1024 * 1024;

const BINARY_FLAG: u32 = 1 << 31;

/// One message on any transport.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Message {
    /// A JSON envelope.
    Text(String),
    /// A byte-stream data frame.
    Binary(Bytes),
    /// Close the connection after the messages queued before it. WebSocket
    /// adapters send this close code and reason; byte-stream framing has no
    /// close frame and just ends the stream.
    Close(u16, String),
}

impl Message {
    pub fn len(&self) -> usize {
        match self {
            Self::Text(text) => text.len(),
            Self::Binary(bytes) => bytes.len(),
            Self::Close(..) => 0,
        }
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

#[derive(Debug)]
pub enum FrameError {
    /// The header names a length above 16 MiB.
    TooLarge(usize),
    /// A text message is not UTF-8.
    NotUtf8,
    Io(std::io::Error),
}

impl std::fmt::Display for FrameError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::TooLarge(length) => write!(formatter, "message of {length} bytes exceeds 16 MiB"),
            Self::NotUtf8 => formatter.write_str("text message is not UTF-8"),
            Self::Io(error) => write!(formatter, "{error}"),
        }
    }
}

impl std::error::Error for FrameError {}

impl From<std::io::Error> for FrameError {
    fn from(error: std::io::Error) -> Self {
        Self::Io(error)
    }
}

/// The 4-byte header for `message`.
pub fn header(message: &Message) -> Result<[u8; 4], FrameError> {
    let length = message.len();
    if length > MAX_MESSAGE {
        return Err(FrameError::TooLarge(length));
    }
    let flag = match message {
        Message::Text(_) => 0,
        Message::Binary(_) => BINARY_FLAG,
        Message::Close(..) => {
            return Err(FrameError::Io(std::io::Error::other("a close has no frame")));
        }
    };
    // MAX_MESSAGE is below 2^31, so the length fits in the low 31 bits.
    let length = u32::try_from(length).map_err(|_| FrameError::TooLarge(length))?;
    Ok((length | flag).to_be_bytes())
}

/// The header and body of `message` as one buffer.
pub fn encode(message: &Message) -> Result<Vec<u8>, FrameError> {
    let mut out = Vec::with_capacity(4 + message.len());
    out.extend_from_slice(&header(message)?);
    match message {
        Message::Text(text) => out.extend_from_slice(text.as_bytes()),
        Message::Binary(bytes) => out.extend_from_slice(bytes),
        Message::Close(..) => {}
    }
    Ok(out)
}

/// Decode a header into (is binary, length).
pub fn parse_header(header: [u8; 4]) -> Result<(bool, usize), FrameError> {
    let raw = u32::from_be_bytes(header);
    let binary = raw & BINARY_FLAG != 0;
    let length = usize::try_from(raw & !BINARY_FLAG).unwrap_or(usize::MAX);
    if length > MAX_MESSAGE {
        return Err(FrameError::TooLarge(length));
    }
    Ok((binary, length))
}

/// Decode one complete frame from `bytes`, returning the message and the
/// number of bytes consumed, or `None` when more bytes are needed.
pub fn decode(bytes: &[u8]) -> Result<Option<(Message, usize)>, FrameError> {
    let Some((header, rest)) = bytes.split_first_chunk::<4>() else { return Ok(None) };
    let (binary, length) = parse_header(*header)?;
    let Some(body) = rest.get(..length) else { return Ok(None) };
    // `length` is at most MAX_MESSAGE (16 MiB), so the sum cannot overflow.
    let consumed = length.saturating_add(4);
    Ok(Some((to_message(binary, body.to_vec())?, consumed)))
}

fn to_message(binary: bool, body: Vec<u8>) -> Result<Message, FrameError> {
    if binary {
        Ok(Message::Binary(Bytes::from(body)))
    } else {
        String::from_utf8(body).map(Message::Text).map_err(|_| FrameError::NotUtf8)
    }
}

/// Read one message; `Ok(None)` at a clean end of stream between messages.
pub async fn read_message<R: AsyncRead + Unpin>(
    reader: &mut R,
) -> Result<Option<Message>, FrameError> {
    let mut header = [0u8; 4];
    match reader.read_exact(&mut header).await {
        Ok(_) => {}
        Err(error) if error.kind() == std::io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(error) => return Err(error.into()),
    }
    let (binary, length) = parse_header(header)?;
    let mut body = vec![0u8; length];
    reader.read_exact(&mut body).await?;
    to_message(binary, body).map(Some)
}

/// Write one message without flushing. A close writes nothing.
pub async fn write_message<W: AsyncWrite + Unpin>(
    writer: &mut W,
    message: &Message,
) -> Result<(), FrameError> {
    let body: &[u8] = match message {
        Message::Text(text) => text.as_bytes(),
        Message::Binary(bytes) => bytes,
        Message::Close(..) => return Ok(()),
    };
    writer.write_all(&header(message)?).await?;
    writer.write_all(body).await?;
    Ok(())
}

/// A byte-stream data frame, the body of a binary message.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DataFrame {
    pub stream: u32,
    /// Credit granted back to the peer for this stream (bytes), or 0.
    pub credit: u32,
    pub payload: Bytes,
}

impl DataFrame {
    pub const HEADER: usize = 8;

    pub fn encode(&self) -> Bytes {
        let mut out = Vec::with_capacity(Self::HEADER + self.payload.len());
        out.extend_from_slice(&self.stream.to_be_bytes());
        out.extend_from_slice(&self.credit.to_be_bytes());
        out.extend_from_slice(&self.payload);
        Bytes::from(out)
    }

    pub fn decode(bytes: &Bytes) -> Option<Self> {
        let ([s0, s1, s2, s3, c0, c1, c2, c3], _) =
            bytes.split_first_chunk::<{ Self::HEADER }>()?;
        let stream = u32::from_be_bytes([*s0, *s1, *s2, *s3]);
        let credit = u32::from_be_bytes([*c0, *c1, *c2, *c3]);
        Some(Self { stream, credit, payload: bytes.slice(Self::HEADER..) })
    }
}
