//! The JSON-lines form of connector frames on this server's host channel,
//! the same form the host writes and reads (cmux-tui
//! `terminal_backend/wire.rs`):
//! `{"t":"data","channel","offset","bytes":"<base64>"}`,
//! `{"t":"credit","channel","direction":"in|out","bytes"}`,
//! `{"t":"end","channel","exit":{...}}` or `{"t":"end","channel","lost":{reason,retryable}}`.

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use cmux_terminal_iface::{Direction, End, ExitStatus, Frame, FrameBody, Lost};
use serde_json::{Value, json};

/// The `t` of every frame line.
pub(crate) const FRAME_TYPES: [&str; 3] = ["data", "credit", "end"];

/// Whether `line` is a frame line.
pub(crate) fn is_frame_line(line: &Value) -> bool {
    line.get("t").and_then(Value::as_str).is_some_and(|t| FRAME_TYPES.contains(&t))
}

fn text<'a>(line: &'a Value, key: &str) -> Result<&'a str, String> {
    line.get(key).and_then(Value::as_str).ok_or_else(|| format!("{key} must be a string"))
}

fn number(line: &Value, key: &str) -> Result<u64, String> {
    line.get(key).and_then(Value::as_u64).ok_or_else(|| format!("{key} must be a whole number"))
}

/// One frame line from the host.
pub(crate) fn frame_from_line(line: &Value) -> Result<Frame, String> {
    let channel = text(line, "channel")?.to_owned();
    let body = match line.get("t").and_then(Value::as_str) {
        Some("data") => FrameBody::Data {
            offset: number(line, "offset")?,
            bytes: STANDARD.decode(text(line, "bytes")?).map_err(|_| "bytes must be base64")?,
        },
        Some("credit") => FrameBody::Credit {
            direction: match text(line, "direction")? {
                "in" => Direction::In,
                "out" => Direction::Out,
                _ => return Err("direction must be in or out".into()),
            },
            bytes: u32::try_from(number(line, "bytes")?)
                .map_err(|_| "credit bytes must fit in 32 bits")?,
        },
        Some("end") => FrameBody::End(match (line.get("exit"), line.get("lost")) {
            (Some(_), None) => End::Exit(ExitStatus::default()),
            (None, Some(lost)) => End::Lost(Lost::new(
                text(lost, "reason")?,
                lost.get("retryable") == Some(&Value::Bool(true)),
            )),
            _ => return Err("end carries exactly one of exit and lost".into()),
        }),
        _ => return Err("t must be data, credit or end".into()),
    };
    Ok(Frame { channel, body })
}

/// The line for one frame of `channel`.
pub(crate) fn frame_line(channel: &str, body: &FrameBody) -> Value {
    match body {
        FrameBody::Data { offset, bytes } => json!({
            "t": "data", "channel": channel, "offset": offset, "bytes": STANDARD.encode(bytes),
        }),
        FrameBody::Credit { direction, bytes } => json!({
            "t": "credit", "channel": channel, "direction": direction.name(), "bytes": bytes,
        }),
        FrameBody::End(End::Lost(lost)) => json!({
            "t": "end", "channel": channel,
            "lost": { "reason": lost.reason, "retryable": lost.retryable },
        }),
        FrameBody::End(End::Exit(exit)) => json!({
            "t": "end", "channel": channel,
            "exit": {
                "code": exit.code, "signal": exit.signal,
                "core_dumped": exit.core_dumped, "message": exit.message,
            },
        }),
    }
}
