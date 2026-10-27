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
    /// The socket came from `--socket` (not derived): a timeout hints at a wrong socket.
    given: bool,
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
    if super::super::federation::agent_marker(|key| std::env::var(key).ok()).is_some() {
        // A request-origin claim may only narrow the daemon-derived origin;
        // it gives history a durable agent/person distinction without
        // granting an agent any additional rights.
        line["origin"] = json!({"claim": "agent"});
    }
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
        Ok(Self { reader: BufReader::new(stream), writer, next_id: 1, given: !derived })
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
                .map_err(|e| read_failed(e, self.given))?
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
            // cx-8mla8: operation.failed carries the reason as its message and
            // the daemon's own words in details.extra.message; show those.
            let detail = error
                .pointer("/details/extra/message")
                .and_then(Value::as_str)
                .filter(|m| !m.trim().is_empty());
            let mut message =
                detail.map_or_else(|| text("message"), crate::cli::wire::sanitize_remote_text);
            if let Some(id) = error.pointer("/details/extra/request_id").and_then(Value::as_str) {
                let id = crate::cli::wire::sanitize_remote_text(id);
                message.push_str(&format!(" (Request ID {id})"));
            }
            return Err(LinkError::Rejected { code, message });
        }
    }

    /// Sends a raw session command (`conversation-agent-token`,
    /// `conversation-create`: the Chief's bootstrap, which has no v2
    /// operation) and waits for its answer.
    pub(super) fn command(&mut self, cmd: &str, params: Value) -> Result<Value, LinkError> {
        let id = format!("chief-{}", self.next_id);
        self.next_id += 1;
        let mut body = match params {
            Value::Object(map) => map,
            _ => serde_json::Map::new(),
        };
        body.insert("id".into(), json!(id));
        body.insert("cmd".into(), json!(cmd));
        let line = Value::Object(body).to_string();
        self.writer
            .write_all(line.as_bytes())
            .and_then(|()| self.writer.write_all(b"\n"))
            .and_then(|()| self.writer.flush())
            .map_err(|e| LinkError::Transport(e.to_string()))?;
        loop {
            let value = read_line(&mut self.reader)
                .map_err(|e| read_failed(e, self.given))?
                .ok_or_else(|| LinkError::Transport(super::messages::messages().lost.into()))?;
            if value.get("id").and_then(Value::as_str) != Some(&id) || value.get("type").is_some() {
                continue;
            }
            if value.get("ok").and_then(Value::as_bool) == Some(true) {
                return Ok(value.get("data").cloned().unwrap_or(Value::Null));
            }
            let text = |key: &str| value.get(key).and_then(Value::as_str).unwrap_or("").to_owned();
            // A cloud refusal names its reason beside the code (home-cloud-proxy.md section 4).
            let code = match text("reason") {
                reason if reason.is_empty() => text("error_code"),
                reason => format!("{}: {reason}", text("error_code")),
            };
            return Err(LinkError::Rejected { code, message: text("error") });
        }
    }

    /// Turns this connection into the conversation's event stream: opens
    /// `conversation.events` (`tail` messages in its snapshot item), then a
    /// thread forwards every item to `sink` until the stream ends (or the
    /// returned handle is dropped).
    pub(super) fn into_events(
        mut self,
        conversation: &str,
        tail: usize,
        sink: Sender<super::Input>,
    ) -> Result<EventsHandle, LinkError> {
        let stream_id = format!("stream_{}", uuid::Uuid::new_v4().simple());
        let params =
            json!({"conversation": conversation, "stream_id": stream_id, "tail": tail.min(500)});
        self.call("conversation.events", params, None)?;
        let _ = self.reader.get_ref().set_read_timeout(None);
        let handle = EventsHandle::of(self.writer.as_ref())?;
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
            .map(|_| handle)
            .map_err(|e| LinkError::Transport(e.to_string()))
    }

    /// The cloud counterpart of `into_events`: `subscribe` with typing
    /// (`set-client-info`), `cloud-conversation-subscribe`, then a snapshot of
    /// the last `tail` messages; a thread forwards each cloud event of
    /// `conversation` as a `conversation.events` item (`backend::cloud_item`).
    /// Events that come before the snapshot answer follow it.
    pub(super) fn into_cloud_events(
        mut self,
        conversation: &str,
        tail: usize,
        sink: Sender<super::Input>,
    ) -> Result<EventsHandle, LinkError> {
        let capabilities = super::backend::cloud_event_capabilities();
        // Best effort: an older daemon without typing still streams the rest.
        let _ = self.command("set-client-info", json!({"capabilities": capabilities}));
        self.command("subscribe", json!({}))?;
        self.command("cloud-conversation-subscribe", json!({"conversation": conversation}))?;
        let snapshot_id = format!("chief-{}", self.next_id);
        self.next_id += 1;
        let request = json!({"id": snapshot_id, "cmd": "cloud-conversation-snapshot",
                             "conversation": conversation, "tail": tail.clamp(1, 50)});
        self.writer
            .write_all(format!("{request}\n").as_bytes())
            .and_then(|()| self.writer.flush())
            .map_err(|e| LinkError::Transport(e.to_string()))?;
        let _ = self.reader.get_ref().set_read_timeout(None);
        let handle = EventsHandle::of(self.writer.as_ref())?;
        let mut reader = self.reader;
        let conversation = conversation.to_owned();
        std::thread::Builder::new()
            .name("chief-cloud-events".into())
            .spawn(move || {
                let mut early: Option<Vec<Value>> = Some(Vec::new());
                let mut reason = String::from("closed");
                while let Ok(Some(value)) = read_line(&mut reader) {
                    if value.get("event").is_none() {
                        if value.get("id").and_then(Value::as_str) != Some(&snapshot_id) {
                            continue;
                        }
                        if value.get("ok").and_then(Value::as_bool) != Some(true) {
                            reason = value
                                .get("error")
                                .and_then(Value::as_str)
                                .unwrap_or("snapshot refused")
                                .to_owned();
                            break;
                        }
                        let data = value.get("data").cloned().unwrap_or(Value::Null);
                        let snapshot = super::backend::cloud_snapshot_item(&data);
                        if sink.send(super::Input::Daemon(snapshot)).is_err() {
                            return;
                        }
                        for item in early.take().unwrap_or_default() {
                            if sink.send(super::Input::Daemon(item)).is_err() {
                                return;
                            }
                        }
                        continue;
                    }
                    if value.get("event").and_then(Value::as_str)
                        == Some("cloud-subscription-state")
                        && value.get("conversation").and_then(Value::as_str) == Some(&conversation)
                        && value.get("state").and_then(Value::as_str) == Some("closed")
                    {
                        reason = "closed".into();
                        break;
                    }
                    let Some(item) = super::backend::cloud_item(&value, &conversation) else {
                        continue;
                    };
                    match early.as_mut() {
                        Some(waiting) => waiting.push(item),
                        None => {
                            if sink.send(super::Input::Daemon(item)).is_err() {
                                return;
                            }
                        }
                    }
                }
                let _ = sink.send(super::Input::Closed(reason));
            })
            .map(|_| handle)
            .map_err(|e| LinkError::Transport(e.to_string()))
    }
}

/// Ends an event stream's connection when dropped (a chat switch, the end of
/// a script), so its thread ends too.
pub(super) struct EventsHandle(Box<dyn Stream>);

impl EventsHandle {
    fn of(stream: &dyn Stream) -> Result<Self, LinkError> {
        stream.try_clone_box().map(Self).map_err(|e| LinkError::Transport(e.to_string()))
    }
}

impl Drop for EventsHandle {
    fn drop(&mut self) {
        let _ = self.0.shutdown(std::net::Shutdown::Both);
    }
}

/// A read error as the CLI says it: a request that met the read timeout
/// (EAGAIN on macOS) names the timeout, not "Resource temporarily
/// unavailable"; on a `--socket` the CLI did not derive, it also names a
/// wrong socket.
fn read_failed(error: io::Error, given: bool) -> LinkError {
    let m = super::messages::messages();
    match error.kind() {
        io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut => LinkError::Transport(
            if given { m.no_answer_socket } else { m.no_answer }
                .replace("{secs}", &REQUEST_TIMEOUT.as_secs().to_string()),
        ),
        _ => LinkError::Transport(error.to_string()),
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

/// The `conversation.send` params of `parts` (a reply to `reply_to` when
/// given); one text part with no reply is plain `text`.
pub(super) fn send_parts_params(
    conversation: &str,
    parts: Vec<Value>,
    reply_to: Option<Value>,
) -> Value {
    let only_text = match parts.as_slice() {
        [part] if part.get("type").and_then(Value::as_str) == Some("text") => {
            part.get("text").and_then(Value::as_str).map(str::to_owned)
        }
        _ => None,
    };
    let mut params = match only_text {
        Some(text) => send_params(conversation, &text),
        None => json!({"conversation": conversation, "parts": parts}),
    };
    if let (Some(reply_to), Some(fields)) = (reply_to, params.as_object_mut()) {
        fields.insert("reply_to".into(), reply_to);
    }
    params
}
