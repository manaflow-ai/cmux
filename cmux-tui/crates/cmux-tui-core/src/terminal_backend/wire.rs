//! JSON-lines form of the terminal interfaces on a native server's stdin
//! and stdout (apps/servers.rs carries the lines).
//!
//! Frames, both directions:
//! `{"t":"data","channel","offset","bytes":"<base64>"}`,
//! `{"t":"credit","channel","direction":"in|out","bytes"}`,
//! `{"t":"end","channel","exit":{code?,signal?,core_dumped,message?}}` or
//! `{"t":"end","channel","lost":{reason,retryable}}`.
//! Host op errors: `host.error {code, message, retryable, details?}` with the
//! interface codes (`denied`, `invalid`, `unavailable`, `unsupported`,
//! `hostKey` with details `{decision, fingerprint}`).

use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use serde_json::{Value, json};

use super::{
    BackendError, Direction, End, ExitStatus, Frame, FrameBody, LinkAnswer, LinkOpen, Lost,
    MAX_EXIT_MESSAGE, OpenToken,
};

/// The `t` of every frame line.
pub(crate) const FRAME_TYPES: [&str; 3] = ["data", "credit", "end"];

/// The host op that opens a connector link.
pub(crate) const CONNECTOR_OPEN: &str = "cmux.terminal.connector.open";
/// The host event that asks an app to close a link.
pub(crate) const CONNECTOR_CLOSE: &str = "cmux.terminal.connector.close";

fn field<'a>(value: &'a Value, key: &str) -> Result<&'a Value, BackendError> {
    value.get(key).ok_or_else(|| BackendError::invalid(format!("{key} is missing")))
}

fn text(value: &Value, key: &str) -> Result<String, BackendError> {
    field(value, key)?
        .as_str()
        .map(str::to_owned)
        .ok_or_else(|| BackendError::invalid(format!("{key} must be a string")))
}

fn number(value: &Value, key: &str) -> Result<u64, BackendError> {
    field(value, key)?
        .as_u64()
        .ok_or_else(|| BackendError::invalid(format!("{key} must be a non-negative integer")))
}

/// A frame line from a server.
pub(crate) fn frame_from_json(value: &Value) -> Result<Frame, BackendError> {
    let channel = text(value, "channel")?;
    let body = match value["t"].as_str() {
        Some("data") => {
            let bytes = STANDARD
                .decode(text(value, "bytes")?)
                .map_err(|_| BackendError::invalid("bytes must be base64"))?;
            FrameBody::Data { offset: number(value, "offset")?, bytes }
        }
        Some("credit") => {
            let direction = match text(value, "direction")?.as_str() {
                "in" => Direction::In,
                "out" => Direction::Out,
                _ => return Err(BackendError::invalid("direction must be in or out")),
            };
            let bytes = u32::try_from(number(value, "bytes")?)
                .map_err(|_| BackendError::invalid("credit bytes must fit in 32 bits"))?;
            FrameBody::Credit { direction, bytes }
        }
        Some("end") => FrameBody::End(end_from_json(value)?),
        _ => return Err(BackendError::invalid("t must be data, credit or end")),
    };
    Ok(Frame { channel, body })
}

fn end_from_json(value: &Value) -> Result<End, BackendError> {
    match (value.get("exit"), value.get("lost")) {
        (Some(exit), None) => {
            let message = exit.get("message").and_then(Value::as_str).map(|m| {
                let mut end = m.len().min(MAX_EXIT_MESSAGE);
                while !m.is_char_boundary(end) {
                    end -= 1;
                }
                m[..end].to_owned()
            });
            Ok(End::Exit(ExitStatus {
                code: exit.get("code").and_then(Value::as_i64).and_then(|c| i32::try_from(c).ok()),
                signal: exit.get("signal").and_then(Value::as_str).map(str::to_owned),
                core_dumped: exit.get("core_dumped") == Some(&Value::Bool(true)),
                message,
            }))
        }
        (None, Some(lost)) => Ok(End::Lost(Lost::new(
            text(lost, "reason")?,
            lost.get("retryable") == Some(&Value::Bool(true)),
        ))),
        _ => Err(BackendError::invalid("end carries exactly one of exit and lost")),
    }
}

/// A frame line for a server.
pub(crate) fn frame_to_json(frame: &Frame) -> Value {
    let channel = &frame.channel;
    match &frame.body {
        FrameBody::Data { offset, bytes } => json!({
            "t": "data", "channel": channel, "offset": offset, "bytes": STANDARD.encode(bytes),
        }),
        FrameBody::Credit { direction, bytes } => json!({
            "t": "credit", "channel": channel, "direction": direction.name(), "bytes": bytes,
        }),
        FrameBody::End(End::Exit(exit)) => json!({
            "t": "end", "channel": channel,
            "exit": {
                "code": exit.code, "signal": exit.signal,
                "core_dumped": exit.core_dumped, "message": exit.message,
            },
        }),
        FrameBody::End(End::Lost(lost)) => json!({
            "t": "end", "channel": channel,
            "lost": { "reason": lost.reason, "retryable": lost.retryable },
        }),
    }
}

/// The params of `cmux.terminal.connector.open`. Missing fields read as
/// empty so the call still reaches the token check (every attempt burns the
/// token); the registry then refuses the empty kind or target.
pub(crate) fn link_open_from_params(params: &Value) -> LinkOpen {
    let get = |key: &str| params.get(key).and_then(Value::as_str).unwrap_or("").to_owned();
    LinkOpen { kind: get("kind"), target: get("target"), open_token: OpenToken(get("open_token")) }
}

/// The `host.result` of `cmux.terminal.connector.open`.
pub(crate) fn link_answer_reply(id: &Value, answer: &LinkAnswer) -> Value {
    json!({
        "t": "host.result", "id": id,
        "value": { "channel": answer.channel, "window_bytes": answer.window_bytes },
    })
}

/// A `host.error` for an interface error.
pub(crate) fn error_reply(id: &Value, error: &BackendError) -> Value {
    let mut reply = json!({
        "t": "host.error", "id": id, "code": error.code(),
        "message": error.to_string(), "retryable": error.retryable(),
    });
    if let BackendError::HostKey { decision, fingerprint } = error {
        reply["details"] = json!({ "decision": decision.name(), "fingerprint": fingerprint });
    }
    reply
}

/// The host event that asks the app to close `channel`.
pub(crate) fn close_event(channel: &str) -> Value {
    json!({ "t": "host.event", "op": CONNECTOR_CLOSE, "data": { "channel": channel } })
}
