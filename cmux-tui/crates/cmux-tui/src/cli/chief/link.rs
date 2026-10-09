//! The session daemon, as `cmux chief` uses it: the `cmux.protocol/2`
//! conversation operations (`conversation.list`, `get`, `history`, `send`
//! and the stream `conversation.events`), the same API every SDK and script
//! uses. An unbound trusted local connection is `user_local`, the person
//! Home writes as; the daemon admits it only to conversations it takes part
//! in.

use std::io::{self, BufRead, BufReader, Read, Write};
use std::path::Path;
use std::sync::mpsc::Sender;
use std::time::Duration;

use cmux_tui_core::platform::transport::Stream;
use serde_json::{Value, json};

use super::adapter::AGENT_MUX;

/// The largest response line read.
const LINE_LIMIT: usize = 16 << 20;
const REQUEST_TIMEOUT: Duration = Duration::from_secs(15);
const PROTOCOL: &str = "cmux.protocol/2";

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) enum LinkError {
    /// The socket could not be reached or closed mid-request.
    Transport(String),
    /// The daemon refused the request: its error code and message.
    Rejected { code: String, message: String },
}

impl std::fmt::Display for LinkError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            LinkError::Transport(message) => f.write_str(message),
            LinkError::Rejected { code, message } if message.is_empty() => f.write_str(code),
            LinkError::Rejected { message, .. } => f.write_str(message),
        }
    }
}

pub(super) struct Link {
    reader: BufReader<Box<dyn Stream>>,
    writer: Box<dyn Stream>,
    next_id: u64,
}

/// A Chief brain's own session lives under `~/.cmux/brains/`; every
/// unbound client there acts as the Chief (its daemon-wide lease), so the
/// CLI never writes through it.
pub(super) fn is_brain_socket(path: &Path) -> bool {
    let parts: Vec<_> = path.components().map(|c| c.as_os_str().to_owned()).collect();
    parts.windows(2).any(|pair| pair[0] == ".cmux" && pair[1] == "brains")
}

/// The request line of `operation` on the current session.
pub(super) fn envelope(id: &str, operation: &str, params: Value, key: Option<&str>) -> Value {
    let mut params = match params {
        Value::Object(map) => map,
        _ => serde_json::Map::new(),
    };
    params.insert("machine".into(), json!("current"));
    params.insert("session".into(), json!("current"));
    let mut line = json!({"protocol": PROTOCOL, "type": "request", "id": id, "operation": operation, "params": params});
    if let Some(key) = key {
        line["idempotency_key"] = json!(key);
    }
    line
}

impl Link {
    pub(super) fn connect(socket: &Path, derived: bool) -> io::Result<Self> {
        let stream = cmux_tui_core::server::connect_session_socket(socket, derived)?;
        stream.set_read_timeout(Some(REQUEST_TIMEOUT))?;
        let writer = stream.try_clone_box()?;
        Ok(Self { reader: BufReader::new(stream), writer, next_id: 1 })
    }

    /// Sends `operation` and waits for its response, skipping other lines.
    pub(super) fn call(
        &mut self,
        operation: &str,
        params: Value,
        key: Option<&str>,
    ) -> Result<Value, LinkError> {
        let id = format!("chief-{}", self.next_id);
        self.next_id += 1;
        let line = envelope(&id, operation, params, key).to_string();
        self.writer
            .write_all(line.as_bytes())
            .and_then(|()| self.writer.write_all(b"\n"))
            .and_then(|()| self.writer.flush())
            .map_err(|e| LinkError::Transport(e.to_string()))?;
        loop {
            let value = read_line(&mut self.reader)
                .map_err(|e| LinkError::Transport(e.to_string()))?
                .ok_or_else(|| LinkError::Transport(super::messages::messages().lost.into()))?;
            if value.get("type").and_then(Value::as_str) != Some("response")
                || value.get("id").and_then(Value::as_str) != Some(&id)
            {
                continue;
            }
            if value.get("ok").and_then(Value::as_bool) == Some(true) {
                return Ok(value.get("result").cloned().unwrap_or(Value::Null));
            }
            let error = value.get("error").cloned().unwrap_or(Value::Null);
            let text = |key: &str| error.get(key).and_then(Value::as_str).unwrap_or("").to_owned();
            let reason = error.pointer("/details/reason").and_then(Value::as_str);
            let code = match reason {
                Some(reason) if !reason.is_empty() => format!("{}: {reason}", text("code")),
                _ => text("code"),
            };
            return Err(LinkError::Rejected { code, message: text("message") });
        }
    }

    /// Turns this connection into the conversation's event stream: opens
    /// `conversation.events` (`tail` messages in its snapshot item), then a
    /// thread forwards every item to `sink` until the stream ends.
    pub(super) fn into_events(
        mut self,
        conversation: &str,
        tail: usize,
        sink: Sender<super::Input>,
    ) -> Result<(), LinkError> {
        let stream_id = format!("stream_{}", uuid::Uuid::new_v4().simple());
        let params =
            json!({"conversation": conversation, "stream_id": stream_id, "tail": tail.min(500)});
        self.call("conversation.events", params, None)?;
        let _ = self.reader.get_ref().set_read_timeout(None);
        let mut reader = self.reader;
        std::thread::Builder::new()
            .name("chief-events".into())
            .spawn(move || {
                let mut reason = String::from("closed");
                while let Ok(Some(value)) = read_line(&mut reader) {
                    if value.get("stream_id").and_then(Value::as_str) != Some(&stream_id) {
                        continue;
                    }
                    match value.get("type").and_then(Value::as_str) {
                        Some("stream_item") => {
                            let item = value.get("item").cloned().unwrap_or(Value::Null);
                            if sink.send(super::Input::Daemon(item)).is_err() {
                                return;
                            }
                        }
                        Some("stream_end") => {
                            reason = value
                                .get("reason")
                                .and_then(Value::as_str)
                                .unwrap_or("closed")
                                .to_owned();
                            break;
                        }
                        _ => {}
                    }
                }
                let _ = sink.send(super::Input::Closed(reason));
            })
            .map(|_| ())
            .map_err(|e| LinkError::Transport(e.to_string()))
    }
}

fn read_line(reader: &mut BufReader<Box<dyn Stream>>) -> io::Result<Option<Value>> {
    let mut bytes = Vec::new();
    let read = reader.by_ref().take(LINE_LIMIT as u64 + 1).read_until(b'\n', &mut bytes)?;
    if read == 0 {
        return Ok(None);
    }
    if bytes.len() > LINE_LIMIT {
        return Err(io::Error::other("response line exceeds 16 MiB"));
    }
    serde_json::from_slice(&bytes).map(Some).map_err(io::Error::other)
}

/// The Chief conversation by the rule Home and the brain share: the oldest
/// conversation with `agent_mux`, by `created_at`, then id.
pub(super) fn select_chief(conversations: &[Value]) -> Option<&Value> {
    let text = |c: &Value, key: &str| c.get(key).and_then(Value::as_str).unwrap_or("").to_owned();
    conversations
        .iter()
        .filter(|c| {
            c.get("participants").and_then(Value::as_array).is_some_and(|ps| {
                ps.iter().any(|p| p.get("id").and_then(Value::as_str) == Some(AGENT_MUX))
            })
        })
        .min_by_key(|c| (text(c, "created_at"), text(c, "id")))
}

/// A new client message id (also the send's idempotency key).
pub(super) fn new_message_id() -> String {
    format!("cli-{}", uuid::Uuid::new_v4().simple())
}

/// The `conversation.send` params of `text`.
pub(super) fn send_params(conversation: &str, text: &str) -> Value {
    json!({"conversation": conversation, "text": text})
}
