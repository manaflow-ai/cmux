use std::fmt;

use base64::Engine;
use bytes::{BufMut, Bytes, BytesMut};
use cmux_remote_protocol::MAX_FRAME_PAYLOAD;
use serde_json::{Value, json};

const MAGIC: [u8; 4] = *b"CMXI";
const HEADER_BYTES: usize = 4 + 8 + 8;
const MAX_INPUT_BYTES: usize = MAX_FRAME_PAYLOAD - HEADER_BYTES;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct MuxInput {
    pub(crate) request: u64,
    pub(crate) surface: u64,
    pub(crate) bytes: Bytes,
}

impl MuxInput {
    pub(crate) fn into_local_line(self) -> Result<Vec<u8>, MuxInputError> {
        let bytes = base64::engine::general_purpose::STANDARD.encode(&self.bytes);
        let mut line = serde_json::to_vec(&json!({
            "id": self.request,
            "cmd": "send",
            "surface": self.surface,
            "bytes": bytes,
        }))?;
        line.push(b'\n');
        Ok(line)
    }
}

/// Convert an explicitly one-way local mux `send` command to its compact
/// network representation. Commands outside this narrow shape stay on the
/// backwards-compatible JSON mux-control path.
pub(crate) fn encode_local_line(line: &[u8]) -> Result<Option<Bytes>, MuxInputError> {
    let Ok(value) = serde_json::from_slice::<Value>(line) else { return Ok(None) };
    if value.get("cmd").and_then(Value::as_str) != Some("send")
        || value.get("no_reply").and_then(Value::as_bool) != Some(true)
        || value.get("paste").is_some_and(|paste| paste.as_bool() != Some(false))
        || value.get("text").is_some_and(|text| text.as_str() != Some(""))
    {
        return Ok(None);
    }
    let Some(request) = value.get("id").and_then(Value::as_u64) else { return Ok(None) };
    let Some(surface) = value.get("surface").and_then(Value::as_u64) else { return Ok(None) };
    let Some(encoded) = value.get("bytes").and_then(Value::as_str) else { return Ok(None) };
    let Ok(bytes) = base64::engine::general_purpose::STANDARD.decode(encoded) else {
        return Ok(None);
    };
    if bytes.len() > MAX_INPUT_BYTES {
        return Ok(None);
    }

    let mut packet = BytesMut::with_capacity(HEADER_BYTES + bytes.len());
    packet.extend_from_slice(&MAGIC);
    packet.put_u64(request);
    packet.put_u64(surface);
    packet.extend_from_slice(&bytes);
    Ok(Some(packet.freeze()))
}

pub(crate) fn decode_packet(packet: &Bytes) -> Result<Option<MuxInput>, MuxInputError> {
    if packet.len() < MAGIC.len() || packet[..MAGIC.len()] != MAGIC {
        return Ok(None);
    }
    if packet.len() < HEADER_BYTES {
        return Err(MuxInputError::InvalidPacket);
    }
    Ok(Some(MuxInput {
        request: u64::from_be_bytes(packet[4..12].try_into().unwrap()),
        surface: u64::from_be_bytes(packet[12..20].try_into().unwrap()),
        bytes: packet.slice(HEADER_BYTES..),
    }))
}

#[derive(Debug)]
pub enum MuxInputError {
    Json(serde_json::Error),
    InvalidPacket,
}

impl fmt::Display for MuxInputError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Json(error) => write!(formatter, "mux input JSON failed: {error}"),
            Self::InvalidPacket => formatter.write_str("invalid compact mux input packet"),
        }
    }
}

impl std::error::Error for MuxInputError {}

impl From<serde_json::Error> for MuxInputError {
    fn from(error: serde_json::Error) -> Self {
        Self::Json(error)
    }
}
