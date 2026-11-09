//! The session daemon, as `cmux chief` uses it: the `cmux.protocol/2`
//! conversation operations (`conversation.list`, `get`, `history`, `send`
//! and the stream `conversation.events`) and the older `cmd` lines the
//! Chief's bootstrap and cloud chats still use, both through the cmux SDK,
//! the client every SDK user and the app share. An unbound trusted local
//! connection is `user_local`, the person Home writes as; the daemon admits
//! it only to conversations it takes part in.

use std::io;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::Sender;
use std::time::Duration;

use cmux::raw::{Client as RawClient, ClientConfig as RawConfig, StreamCloser};
use cmux::{CallKind, Error as SdkError, MutationOptions, StreamCancellation};
use serde_json::{Map, Value, json};

use super::adapter::AGENT_MUX;

/// The largest response line read.
const LINE_LIMIT: usize = 16 << 20;
const REQUEST_TIMEOUT: Duration = Duration::from_secs(15);

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

/// One session's connections: the SDK's `cmux.protocol/2` client, and the
/// older command lines' client, opened on the first command.
pub(super) struct Link {
    client: cmux::Client,
    raw: Option<RawClient>,
    socket: PathBuf,
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

/// The request-origin claim the CLI makes: `agent` when an agent runs it.
/// A claim may only narrow the daemon-derived origin; it gives history a
/// durable agent/person distinction without granting an agent any rights.
fn origin_claim() -> Option<&'static str> {
    super::super::federation::agent_marker(|key| std::env::var(key).ok()).map(|_| "agent")
}

impl Link {
    pub(super) fn connect(socket: &Path, derived: bool) -> io::Result<Self> {
        if derived {
            cmux_tui_core::server::verify_session_socket_directory(socket)?;
        }
        let config = cmux::Config::from_socket_path(socket)
            .with_timeout(REQUEST_TIMEOUT)
            .with_response_limit(LINE_LIMIT);
        let client = cmux::Client::connect(config).map_err(io_error)?;
        let client = match origin_claim() {
            Some(claim) => client.with_origin_claim(claim).map_err(io_error)?,
            None => client,
        };
        Ok(Self { client, raw: None, socket: socket.to_owned(), given: !derived })
    }

    /// Sends `operation` (a mutation when it has an idempotency `key`) and
    /// waits for its result.
    pub(super) fn call(
        &mut self,
        operation: &str,
        params: Value,
        key: Option<&str>,
    ) -> Result<Value, LinkError> {
        let kind = match key {
            Some(key) => CallKind::Mutation(
                MutationOptions::new(key).map_err(|e| LinkError::Transport(e.to_string()))?,
            ),
            None => CallKind::Read,
        };
        let mut params = match params {
            Value::Object(map) => map,
            _ => Map::new(),
        };
        params.insert("machine".into(), json!("current"));
        params.insert("session".into(), json!("current"));
        self.client
            .call(operation, kind, Value::Object(params))
            .map_err(|e| sdk_failed(e, self.given))
    }

    /// Sends a raw session command (`conversation-agent-token`,
    /// `conversation-create`: the Chief's bootstrap, which has no v2
    /// operation) and waits for its answer.
    pub(super) fn command(&mut self, cmd: &str, params: Value) -> Result<Value, LinkError> {
        let given = self.given;
        if self.raw.is_none() {
            self.raw = Some(connect_raw(&self.socket, given)?);
        }
        let raw = self.raw.as_mut().ok_or_else(|| LinkError::Transport("closed".into()))?;
        command(raw, cmd, params, given)
    }

    /// Turns this link into the conversation's event stream: opens
    /// `conversation.events` (`tail` messages in its snapshot item), then a
    /// thread forwards every item to `sink` until the stream ends (or the
    /// returned handle is dropped).
    pub(super) fn into_events(
        self,
        conversation: &str,
        tail: usize,
        sink: Sender<super::Input>,
    ) -> Result<EventsHandle, LinkError> {
        let params = json!({"machine": "current", "session": "current",
                            "conversation": conversation, "tail": tail.min(500)});
        let mut stream = self
            .client
            .subscribe("conversation.events", params)
            .map_err(|e| sdk_failed(e, self.given))?;
        let handle = EventsHandle::stream(stream.cancellation());
        let dropped = Arc::clone(&handle.dropped);
        std::thread::Builder::new()
            .name("chief-events".into())
            .spawn(move || {
                let mut reason = String::from("closed");
                while !dropped.load(Ordering::Acquire) {
                    match stream.recv() {
                        Ok(Some(item)) if !dropped.load(Ordering::Acquire) => {
                            if sink.send(super::Input::Daemon(item.value)).is_err() {
                                return;
                            }
                        }
                        Ok(Some(_)) | Err(_) => break,
                        Ok(None) => {
                            if let Some(end) = stream.end() {
                                reason = end_reason(end.reason).to_owned();
                            }
                            break;
                        }
                    }
                }
                let _ = sink.send(super::Input::Closed(reason));
            })
            .map(|_| handle)
            .map_err(|e| LinkError::Transport(e.to_string()))
    }

    /// The cloud counterpart of `into_events`: on a connection of its own,
    /// `subscribe` with typing (`set-client-info`),
    /// `cloud-conversation-subscribe`, then a snapshot of the last `tail`
    /// messages; a thread forwards each cloud event of `conversation` as a
    /// `conversation.events` item (`backend::cloud_item`). Events that come
    /// before the snapshot answer follow it.
    pub(super) fn into_cloud_events(
        self,
        conversation: &str,
        tail: usize,
        sink: Sender<super::Input>,
    ) -> Result<EventsHandle, LinkError> {
        let given = self.given;
        let mut raw = match self.raw {
            Some(raw) => raw,
            None => connect_raw(&self.socket, given)?,
        };
        let capabilities = super::backend::cloud_event_capabilities();
        // Best effort: an older daemon without typing still streams the rest.
        let _ = command(&mut raw, "set-client-info", json!({"capabilities": capabilities}), given);
        command(&mut raw, "subscribe", json!({}), given)?;
        command(
            &mut raw,
            "cloud-conversation-subscribe",
            json!({"conversation": conversation}),
            given,
        )?;
        let handle = EventsHandle::raw(raw.closer().map_err(|e| sdk_failed(e, given))?);
        let conversation = conversation.to_owned();
        std::thread::Builder::new()
            .name("chief-cloud-events".into())
            .spawn(move || {
                let reason = forward_cloud_events(&mut raw, &conversation, tail, &sink);
                if let Some(reason) = reason {
                    let _ = sink.send(super::Input::Closed(reason));
                }
            })
            .map(|_| handle)
            .map_err(|e| LinkError::Transport(e.to_string()))
    }
}

/// The cloud event thread's work: the snapshot, then every event of
/// `conversation` until the subscription closes. Returns the reason to
/// report, or none when the sink is gone.
fn forward_cloud_events(
    raw: &mut RawClient,
    conversation: &str,
    tail: usize,
    sink: &Sender<super::Input>,
) -> Option<String> {
    let request = json!({"cmd": "cloud-conversation-snapshot",
                         "conversation": conversation, "tail": tail.clamp(1, 50)});
    let Value::Object(request) = request else { return Some("closed".into()) };
    let reply = match raw.request_raw_reply(request) {
        Ok(reply) => reply,
        Err(_) => return Some("closed".into()),
    };
    if reply.get("ok").and_then(Value::as_bool) != Some(true) {
        let reason = reply.get("error").and_then(Value::as_str).unwrap_or("snapshot refused");
        return Some(reason.to_owned());
    }
    let data = reply.get("data").cloned().unwrap_or(Value::Null);
    sink.send(super::Input::Daemon(super::backend::cloud_snapshot_item(&data))).ok()?;
    while let Ok(value) = raw.recv_event_frame() {
        if value.get("event").and_then(Value::as_str) == Some("cloud-subscription-state")
            && value.get("conversation").and_then(Value::as_str) == Some(conversation)
            && value.get("state").and_then(Value::as_str) == Some("closed")
        {
            break;
        }
        if let Some(item) = super::backend::cloud_item(&value, conversation) {
            sink.send(super::Input::Daemon(item)).ok()?;
        }
    }
    Some("closed".into())
}

/// A raw command on `raw`: its `data`, or the refusal as the CLI says it.
fn command(raw: &mut RawClient, cmd: &str, params: Value, given: bool) -> Result<Value, LinkError> {
    let mut body = match params {
        Value::Object(map) => map,
        _ => Map::new(),
    };
    body.insert("cmd".into(), json!(cmd));
    let value = raw.request_raw_reply(body).map_err(|e| sdk_failed(e, given))?;
    if value.get("ok").and_then(Value::as_bool) == Some(true) {
        return Ok(value.get("data").cloned().unwrap_or(Value::Null));
    }
    let text = |key: &str| value.get(key).and_then(Value::as_str).unwrap_or("").to_owned();
    // A cloud refusal names its reason beside the code (home-cloud-proxy.md section 4).
    let code = match text("reason") {
        reason if reason.is_empty() => text("error_code"),
        reason => format!("{}: {reason}", text("error_code")),
    };
    Err(LinkError::Rejected { code, message: text("error") })
}

fn connect_raw(socket: &Path, given: bool) -> Result<RawClient, LinkError> {
    let config = RawConfig::from_socket_path(socket)
        .with_timeout(REQUEST_TIMEOUT)
        .with_max_frame_bytes(LINE_LIMIT);
    RawClient::connect(config).map_err(|e| sdk_failed(e, given))
}

/// Ends an event stream when dropped (a chat switch, the end of a script):
/// its thread forwards nothing more and ends.
pub(super) struct EventsHandle {
    dropped: Arc<AtomicBool>,
    stop: Stop,
}

enum Stop {
    Stream(StreamCancellation),
    Raw(StreamCloser),
}

impl EventsHandle {
    fn stream(cancellation: StreamCancellation) -> Self {
        Self { dropped: Arc::default(), stop: Stop::Stream(cancellation) }
    }

    fn raw(closer: StreamCloser) -> Self {
        Self { dropped: Arc::default(), stop: Stop::Raw(closer) }
    }
}

impl Drop for EventsHandle {
    fn drop(&mut self) {
        self.dropped.store(true, Ordering::Release);
        match &self.stop {
            Stop::Stream(cancellation) => {
                let _ = cancellation.cancel();
            }
            Stop::Raw(closer) => closer.close(),
        }
    }
}

fn end_reason(reason: cmux::StreamEndReason) -> &'static str {
    match reason {
        cmux::StreamEndReason::Completed => "completed",
        cmux::StreamEndReason::Canceled => "canceled",
        cmux::StreamEndReason::Closed => "closed",
        cmux::StreamEndReason::Gap => "gap",
        cmux::StreamEndReason::Error => "error",
    }
}

/// A connect failure as an I/O error, keeping its kind (a missing or
/// refused socket reads as one in `wire::connect_failure`).
fn io_error(error: SdkError) -> io::Error {
    match error {
        SdkError::ConnectionIo { message, kind } => io::Error::new(kind, message),
        other => io::Error::other(other.to_string()),
    }
}

/// An SDK failure as the CLI says it. A refusal keeps the daemon's code
/// (with its reason) and words; a request that met the timeout names the
/// timeout, not "Resource temporarily unavailable", and on a `--socket` the
/// CLI did not derive, a wrong socket too; a closed connection says so.
fn sdk_failed(error: SdkError, given: bool) -> LinkError {
    let m = super::messages::messages();
    match error {
        SdkError::Protocol { code, message, details, .. } => rejected(code, message, &details),
        SdkError::MutationTransport { source, .. } => sdk_failed(*source, given),
        SdkError::Timeout(_) => LinkError::Transport(
            if given { m.no_answer_socket } else { m.no_answer }
                .replace("{secs}", &REQUEST_TIMEOUT.as_secs().to_string()),
        ),
        SdkError::ConnectionIo {
            kind: io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut,
            ..
        } => sdk_failed(SdkError::Timeout(String::new()), given),
        SdkError::Connection(message) if message == "session socket closed" => {
            LinkError::Transport(m.lost.into())
        }
        SdkError::Closed => LinkError::Transport(m.lost.into()),
        other => match other.error_code() {
            Some(code) => LinkError::Rejected { code: code.to_owned(), message: other.to_string() },
            None => LinkError::Transport(other.to_string()),
        },
    }
}

/// A `cmux.protocol/2` refusal: the code with its reason, and the daemon's
/// own words (cx-8mla8: `operation.failed` carries the reason as its
/// message and the daemon's words in `details.extra.message`).
fn rejected(code: String, message: String, details: &Value) -> LinkError {
    let code = match details.pointer("/reason").and_then(Value::as_str) {
        Some(reason) if !reason.is_empty() => format!("{code}: {reason}"),
        _ => code,
    };
    let detail =
        details.pointer("/extra/message").and_then(Value::as_str).filter(|m| !m.trim().is_empty());
    let mut message = detail.map_or(message, crate::cli::wire::sanitize_remote_text);
    if let Some(id) = details.pointer("/extra/request_id").and_then(Value::as_str) {
        let id = crate::cli::wire::sanitize_remote_text(id);
        message.push_str(&format!(" (Request ID {id})"));
    }
    LinkError::Rejected { code, message }
}

/// The Chief conversation by the rule Home and the brain share: the oldest
/// conversation with `agent_mux`, by `created_at`, then id.
pub(super) fn select_chief(conversations: &[Value]) -> Option<&Value> {
    select_chief_of(conversations, AGENT_MUX)
}

/// Chief `chief`'s own conversation by the brain's rule (optchat-chief
/// `daemon::select_chief_of`): for agent_mux the oldest with it; for another
/// Chief its oldest DM with the person (the person, their paired devices and
/// the Chief only), never a group it is in.
pub(super) fn select_chief_of<'a>(conversations: &'a [Value], chief: &str) -> Option<&'a Value> {
    let text = |c: &Value, key: &str| c.get(key).and_then(Value::as_str).unwrap_or("").to_owned();
    let id = |p: &Value| p.get("id").and_then(Value::as_str).map(str::to_owned);
    let person = |p: &Value| {
        id(p).as_deref() == Some("user_local")
            || p.get("person").and_then(Value::as_str) == Some("user_local")
    };
    conversations
        .iter()
        .filter(|c| {
            let ps = c.get("participants").and_then(Value::as_array);
            let ps: &[Value] = ps.map_or(&[], Vec::as_slice);
            let has = |who: &str| ps.iter().any(|p| id(p).as_deref() == Some(who));
            if chief == AGENT_MUX {
                return has(chief);
            }
            has(chief)
                && has("user_local")
                && ps.iter().all(|p| id(p).as_deref() == Some(chief) || person(p))
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
