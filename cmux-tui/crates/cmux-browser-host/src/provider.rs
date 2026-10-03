//! Provider connection frames (app <-> host).
//!
//! The Mac app dials the host as an engine provider
//! (`plans/cmux-next/browser-host.md`, "Provider connection"). Each frame is
//! a big-endian `u32` byte length followed by that many bytes of UTF-8 JSON.

use crate::protocol::DriverError;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::fmt;
use std::io::{self, Read, Write};

/// Provider protocol version sent in `hello`.
pub const PROVIDER_VERSION: u32 = 1;

/// Largest frame either side accepts (screenshots and PDFs travel as base64).
pub const MAX_FRAME_BYTES: usize = 64 << 20;

/// The per-launch provider secret. Never printed: `Debug` is redacted.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct ProviderSecret(String);

impl ProviderSecret {
    pub fn new(value: impl Into<String>) -> Self {
        ProviderSecret(value.into())
    }

    /// Constant-time comparison, so a wrong guess does not leak a prefix length.
    pub fn matches(&self, other: &ProviderSecret) -> bool {
        let (a, b) = (self.0.as_bytes(), other.0.as_bytes());
        if a.len() != b.len() {
            return false;
        }
        a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
    }
}

impl fmt::Debug for ProviderSecret {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("ProviderSecret(<redacted>)")
    }
}

/// A tab the provider renders.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TabAnnounce {
    #[serde(rename = "targetId")]
    pub target_id: String,
    /// `webkit` or `cef`.
    pub engine: String,
    pub workspace: String,
    pub profile: String,
    pub url: String,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub visible: bool,
}

/// An automation lease the app shows as a "driven by" badge.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Lease {
    pub session: String,
    pub actor: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub on_behalf_of: Option<String>,
    pub origin: String,
    pub label: String,
    pub since_ms: u64,
}

/// One provider frame, tagged by `t`.
#[derive(Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "t")]
pub enum Frame {
    #[serde(rename = "hello")]
    Hello {
        version: u32,
        provider_id: String,
        install_id: String,
        secret: ProviderSecret,
        engines: Vec<String>,
        #[serde(default)]
        tabs: Vec<TabAnnounce>,
    },
    /// The host accepted `hello`: the page agent bundle for the app to install.
    #[serde(rename = "hello.ack")]
    HelloAck { agent_bundle: String, agent_bundle_sha: String },
    /// A driver protocol call on a provider tab (host -> app).
    #[serde(rename = "call")]
    Call {
        id: u64,
        method: String,
        #[serde(default)]
        params: Value,
    },
    /// The answer to a `call`; exactly one of `result` and `error` is meaningful.
    #[serde(rename = "result")]
    Result {
        id: u64,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        result: Option<Value>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        error: Option<DriverError>,
    },
    /// A driver protocol event or a provider event (`tab.announced`, `tab.gone`).
    #[serde(rename = "event")]
    Event {
        name: String,
        #[serde(default)]
        payload: Value,
    },
    #[serde(rename = "cdp.attach")]
    CdpAttach {
        #[serde(rename = "targetId")]
        target_id: String,
    },
    #[serde(rename = "cdp.detach")]
    CdpDetach {
        #[serde(rename = "targetId")]
        target_id: String,
    },
    /// One raw CDP message for a CEF tab, passed through unparsed by the app.
    #[serde(rename = "cdp")]
    Cdp {
        #[serde(rename = "targetId")]
        target_id: String,
        message: String,
    },
    #[serde(rename = "lease")]
    Lease {
        #[serde(rename = "targetId")]
        target_id: String,
        #[serde(default)]
        lease: Option<Lease>,
    },
    /// A person used a leased tab; the host pauses the lease.
    #[serde(rename = "user.input")]
    UserInput {
        #[serde(rename = "targetId")]
        target_id: String,
    },
}

/// Debug output names the frame and its ids only: `call` params, raw CDP
/// messages and results can carry typed text and page data.
impl fmt::Debug for Frame {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Frame::Hello { version, provider_id, install_id, engines, tabs, .. } => f
                .debug_struct("Hello")
                .field("version", version)
                .field("provider_id", provider_id)
                .field("install_id", install_id)
                .field("engines", engines)
                .field("tabs", &tabs.len())
                .finish_non_exhaustive(),
            Frame::HelloAck { agent_bundle, agent_bundle_sha } => f
                .debug_struct("HelloAck")
                .field("agent_bundle_bytes", &agent_bundle.len())
                .field("agent_bundle_sha", agent_bundle_sha)
                .finish(),
            Frame::Call { id, method, .. } => f
                .debug_struct("Call")
                .field("id", id)
                .field("method", method)
                .finish_non_exhaustive(),
            Frame::Result { id, error, .. } => f
                .debug_struct("Result")
                .field("id", id)
                .field("error", &error.as_ref().map(|e| e.code))
                .finish_non_exhaustive(),
            Frame::Event { name, .. } => {
                f.debug_struct("Event").field("name", name).finish_non_exhaustive()
            }
            Frame::CdpAttach { target_id } => {
                f.debug_struct("CdpAttach").field("target_id", target_id).finish()
            }
            Frame::CdpDetach { target_id } => {
                f.debug_struct("CdpDetach").field("target_id", target_id).finish()
            }
            Frame::Cdp { target_id, message } => f
                .debug_struct("Cdp")
                .field("target_id", target_id)
                .field("bytes", &message.len())
                .finish_non_exhaustive(),
            Frame::Lease { target_id, lease } => {
                f.debug_struct("Lease").field("target_id", target_id).field("lease", lease).finish()
            }
            Frame::UserInput { target_id } => {
                f.debug_struct("UserInput").field("target_id", target_id).finish()
            }
        }
    }
}

impl Frame {
    /// The result of a `result` frame as the driver protocol defines it: an
    /// error wins, a missing result is `null`.
    pub fn into_call_result(self) -> Option<(u64, Result<Value, DriverError>)> {
        match self {
            Frame::Result { id, error: Some(error), .. } => Some((id, Err(error))),
            Frame::Result { id, result, .. } => Some((id, Ok(result.unwrap_or(Value::Null)))),
            _ => None,
        }
    }
}

#[derive(Debug)]
pub enum CodecError {
    Io(io::Error),
    TooLarge(usize),
    Json(serde_json::Error),
    /// The stream ended inside a frame.
    Truncated,
}

impl fmt::Display for CodecError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            CodecError::Io(error) => write!(f, "provider connection I/O: {error}"),
            CodecError::TooLarge(len) => {
                write!(f, "provider frame of {len} bytes exceeds {MAX_FRAME_BYTES}")
            }
            CodecError::Json(error) => write!(f, "provider frame is not valid JSON: {error}"),
            CodecError::Truncated => f.write_str("provider connection ended inside a frame"),
        }
    }
}

impl std::error::Error for CodecError {}

/// Encodes one frame with its length prefix.
pub fn encode(frame: &Frame) -> Result<Vec<u8>, CodecError> {
    let body = serde_json::to_vec(frame).map_err(CodecError::Json)?;
    if body.len() > MAX_FRAME_BYTES {
        return Err(CodecError::TooLarge(body.len()));
    }
    let mut out = Vec::with_capacity(body.len() + 4);
    out.extend_from_slice(&(body.len() as u32).to_be_bytes());
    out.extend_from_slice(&body);
    Ok(out)
}

pub fn write_frame(writer: &mut impl Write, frame: &Frame) -> Result<(), CodecError> {
    let bytes = encode(frame)?;
    writer.write_all(&bytes).map_err(CodecError::Io)?;
    writer.flush().map_err(CodecError::Io)
}

/// Largest frame accepted before the provider is authenticated (`hello`).
pub const MAX_HELLO_BYTES: usize = 1 << 20;

/// Reads one frame. `Ok(None)` is a clean end of stream at a frame boundary.
pub fn read_frame(reader: &mut impl Read) -> Result<Option<Frame>, CodecError> {
    read_frame_limited(reader, MAX_FRAME_BYTES)
}

/// [`read_frame`] with a smaller size limit (use [`MAX_HELLO_BYTES`] until `hello`).
pub fn read_frame_limited(reader: &mut impl Read, max: usize) -> Result<Option<Frame>, CodecError> {
    let mut header = [0u8; 4];
    let mut filled = 0;
    while filled < header.len() {
        match reader.read(&mut header[filled..]) {
            Ok(0) if filled == 0 => return Ok(None),
            Ok(0) => return Err(CodecError::Truncated),
            Ok(n) => filled += n,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) => return Err(CodecError::Io(error)),
        }
    }
    let len = u32::from_be_bytes(header) as usize;
    if len > max.min(MAX_FRAME_BYTES) {
        return Err(CodecError::TooLarge(len));
    }
    let mut body = vec![0u8; len];
    reader.read_exact(&mut body).map_err(|error| match error.kind() {
        io::ErrorKind::UnexpectedEof => CodecError::Truncated,
        _ => CodecError::Io(error),
    })?;
    serde_json::from_slice(&body).map(Some).map_err(CodecError::Json)
}

/// Incremental decoder for non-blocking readers.
#[derive(Default)]
pub struct FrameDecoder {
    buffer: Vec<u8>,
}

impl FrameDecoder {
    pub fn push(&mut self, bytes: &[u8]) {
        self.buffer.extend_from_slice(bytes);
    }

    /// The next complete frame, if the buffer holds one.
    pub fn next_frame(&mut self) -> Result<Option<Frame>, CodecError> {
        if self.buffer.len() < 4 {
            return Ok(None);
        }
        let len =
            u32::from_be_bytes([self.buffer[0], self.buffer[1], self.buffer[2], self.buffer[3]])
                as usize;
        if len > MAX_FRAME_BYTES {
            return Err(CodecError::TooLarge(len));
        }
        if self.buffer.len() < 4 + len {
            return Ok(None);
        }
        let frame = serde_json::from_slice(&self.buffer[4..4 + len]).map_err(CodecError::Json);
        self.buffer.drain(..4 + len);
        frame.map(Some)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::ErrorCode;
    use serde_json::json;

    fn hello() -> Frame {
        Frame::Hello {
            version: PROVIDER_VERSION,
            provider_id: "app".into(),
            install_id: "inst_1".into(),
            secret: ProviderSecret::new("s3cret-value"),
            engines: vec!["webkit".into(), "cef".into()],
            tabs: vec![TabAnnounce {
                target_id: "tab_1".into(),
                engine: "cef".into(),
                workspace: "ws_1".into(),
                profile: "agent".into(),
                url: "https://example.com/".into(),
                title: "Example".into(),
                visible: false,
            }],
        }
    }

    #[test]
    fn frames_round_trip_with_protocol_tags() {
        let frames = vec![
            hello(),
            Frame::Call { id: 7, method: "tab.info".into(), params: json!({"targetId": "tab_1"}) },
            Frame::Result { id: 7, result: Some(json!({"url": "about:blank"})), error: None },
            Frame::Event { name: "tab.closed".into(), payload: json!({"targetId": "tab_1"}) },
            Frame::CdpAttach { target_id: "tab_1".into() },
            Frame::Cdp {
                target_id: "tab_1".into(),
                message: r#"{"id":1,"method":"Page.enable"}"#.into(),
            },
            Frame::Lease { target_id: "tab_1".into(), lease: None },
            Frame::UserInput { target_id: "tab_1".into() },
        ];
        let mut stream = Vec::new();
        for frame in &frames {
            write_frame(&mut stream, frame).unwrap();
        }
        let mut reader = stream.as_slice();
        for frame in &frames {
            assert_eq!(read_frame(&mut reader).unwrap().as_ref(), Some(frame));
        }
        assert!(read_frame(&mut reader).unwrap().is_none());

        let value = serde_json::to_value(&frames[5]).unwrap();
        assert_eq!(value["t"], "cdp");
        assert_eq!(value["targetId"], "tab_1");
        assert_eq!(serde_json::to_value(&frames[4]).unwrap()["t"], "cdp.attach");
    }

    #[test]
    fn secret_is_redacted_in_debug_output() {
        let text = format!("{:?}", hello());
        assert!(!text.contains("s3cret-value"), "{text}");
        assert!(format!("{:?}", ProviderSecret::new("s3cret-value")).contains("<redacted>"));
        assert!(ProviderSecret::new("abc").matches(&ProviderSecret::new("abc")));
        assert!(!ProviderSecret::new("abc").matches(&ProviderSecret::new("abd")));
        assert!(!ProviderSecret::new("abc").matches(&ProviderSecret::new("abcd")));
    }

    #[test]
    fn debug_output_hides_payloads() {
        let call = Frame::Call {
            id: 1,
            method: "input.insertText".into(),
            params: json!({"text": "hunter2"}),
        };
        let cdp = Frame::Cdp {
            target_id: "t".into(),
            message: r#"{"params":{"text":"hunter2"}}"#.into(),
        };
        let text = format!("{call:?} {cdp:?}");
        assert!(!text.contains("hunter2"), "{text}");
        assert!(text.contains("input.insertText"));
    }

    #[test]
    fn hello_reads_use_a_small_limit() {
        let mut reader: &[u8] = &((MAX_HELLO_BYTES as u32) + 1).to_be_bytes();
        assert!(matches!(
            read_frame_limited(&mut reader, MAX_HELLO_BYTES),
            Err(CodecError::TooLarge(_))
        ));
    }

    #[test]
    fn result_frames_map_to_call_results() {
        let ok = Frame::Result { id: 1, result: None, error: None };
        assert_eq!(ok.into_call_result(), Some((1, Ok(Value::Null))));
        let error = DriverError::new(ErrorCode::Stale, "gone");
        let failed = Frame::Result { id: 2, result: Some(json!(1)), error: Some(error.clone()) };
        assert_eq!(failed.into_call_result(), Some((2, Err(error))));
        assert_eq!(Frame::UserInput { target_id: "t".into() }.into_call_result(), None);
    }

    #[test]
    fn oversize_and_truncated_frames_are_errors() {
        let mut reader: &[u8] = &((MAX_FRAME_BYTES as u32) + 1).to_be_bytes();
        assert!(matches!(read_frame(&mut reader), Err(CodecError::TooLarge(_))));

        let bytes = encode(&Frame::UserInput { target_id: "t".into() }).unwrap();
        let mut reader: &[u8] = &bytes[..bytes.len() - 1];
        assert!(matches!(read_frame(&mut reader), Err(CodecError::Truncated)));
        let mut reader: &[u8] = &bytes[..2];
        assert!(matches!(read_frame(&mut reader), Err(CodecError::Truncated)));
    }

    #[test]
    fn incremental_decoder_waits_for_whole_frames() {
        let a = encode(&Frame::CdpDetach { target_id: "a".into() }).unwrap();
        let b = encode(&Frame::UserInput { target_id: "b".into() }).unwrap();
        let mut decoder = FrameDecoder::default();
        decoder.push(&a[..3]);
        assert!(decoder.next_frame().unwrap().is_none());
        decoder.push(&a[3..]);
        decoder.push(&b[..b.len() - 1]);
        assert_eq!(decoder.next_frame().unwrap(), Some(Frame::CdpDetach { target_id: "a".into() }));
        assert!(decoder.next_frame().unwrap().is_none());
        decoder.push(&b[b.len() - 1..]);
        assert_eq!(decoder.next_frame().unwrap(), Some(Frame::UserInput { target_id: "b".into() }));
    }
}
