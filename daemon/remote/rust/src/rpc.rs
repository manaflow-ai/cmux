use std::io::{self, BufRead, Write};

use serde::{Deserialize, Serialize};
use serde_json::Value;

pub const MAX_FRAME_BYTES: usize = 4 * 1024 * 1024;

#[derive(Debug, Clone, Deserialize)]
pub struct Request {
    #[serde(default)]
    pub id: Option<Value>,
    #[serde(default)]
    pub method: String,
    #[serde(default = "empty_object")]
    pub params: Value,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ErrorPayload {
    pub code: String,
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Response {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<Value>,
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<ErrorPayload>,
}

pub enum FrameRead {
    Eof,
    Frame(Vec<u8>),
    Oversized,
}

pub fn read_frame<R: BufRead>(reader: &mut R) -> io::Result<FrameRead> {
    let mut frame = Vec::with_capacity(1024);
    loop {
        let available = reader.fill_buf()?;
        if available.is_empty() {
            if frame.is_empty() {
                return Ok(FrameRead::Eof);
            }
            return Ok(FrameRead::Frame(frame));
        }

        if let Some(newline) = available.iter().position(|byte| *byte == b'\n') {
            let take = newline + 1;
            if frame.len() + take > MAX_FRAME_BYTES {
                reader.consume(take);
                return Ok(FrameRead::Oversized);
            }
            frame.extend_from_slice(&available[..take]);
            reader.consume(take);
            return Ok(FrameRead::Frame(frame));
        }

        if frame.len() + available.len() > MAX_FRAME_BYTES {
            let len = available.len();
            reader.consume(len);
            discard_until_newline(reader)?;
            return Ok(FrameRead::Oversized);
        }
        frame.extend_from_slice(available);
        let len = available.len();
        reader.consume(len);
    }
}

pub fn write_response<W: Write>(writer: &mut W, response: &Response) -> io::Result<()> {
    serde_json::to_writer(&mut *writer, response)?;
    writer.write_all(b"\n")?;
    writer.flush()
}

pub fn ok(id: Option<Value>, result: Value) -> Response {
    Response {
        id,
        ok: true,
        result: Some(result),
        error: None,
    }
}

pub fn error(id: Option<Value>, code: &str, message: impl Into<String>) -> Response {
    Response {
        id,
        ok: false,
        result: None,
        error: Some(ErrorPayload {
            code: code.to_string(),
            message: message.into(),
        }),
    }
}

fn empty_object() -> Value {
    Value::Object(Default::default())
}

fn discard_until_newline<R: BufRead>(reader: &mut R) -> io::Result<()> {
    loop {
        let available = reader.fill_buf()?;
        if available.is_empty() {
            return Ok(());
        }
        if let Some(newline) = available.iter().position(|byte| *byte == b'\n') {
            reader.consume(newline + 1);
            return Ok(());
        }
        let len = available.len();
        reader.consume(len);
    }
}
