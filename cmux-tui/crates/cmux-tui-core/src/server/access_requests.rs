//! Requests a Cloud machine's agents make for files of the person's Mac
//! (`access-request-v1`, Move to Cloud, cmuxterm-hq#1874 slice 6). An agent
//! on this machine asks (`cmux link access request`); the app on the
//! person's Mac lists the requests through its machine link, decides on the
//! Mac (a grant, or the person's answer on an inline card), pushes what it
//! shares itself (`fs-v1`) and answers here. This daemon only keeps the
//! requests: it never reaches the Mac and nothing here grants anything.
//!
//! - `access-request {kind:"file", path, session?, reason?}`: answers
//!   `{request_id}`. `path` is the absolute path on the Mac the agent asks
//!   for, `session` the asking chat's agent session (`CMUX_AGENT_SESSION`),
//!   `reason` a line for the person.
//! - `access-request-status {request_id}`: `{state, path?, reason?}`, where
//!   `state` is `pending`, `delivered` (with the `path` on this machine the
//!   Mac put the file at) or `denied` (with the Mac's `reason`, if any).
//! - `access-request-list {}`: the pending requests, oldest first, as
//!   `{requests:[{request_id, kind, path, session, reason, age_ms}]}`.
//! - `access-request-answer {request_id, outcome:"delivered", path}` or
//!   `{request_id, outcome:"denied", reason?}`: a pending request only.
//!
//! Who: trusted local (Unix) connections that are not remote clients, on a
//! Cloud host only (`agent-transfer-v1`'s host, read at start). The agents
//! here and the Mac's link client both arrive that way, so an agent can
//! answer its own request; it then learns only what it wrote itself. The
//! remote relay (`cmux link`'s gate) does not list these verbs. Unknown and
//! command-bearing params are refused.
//!
//! Bounds: 64 requests kept, pending or answered; a request is forgotten 15
//! minutes after it was made or answered. Paths up to 4096 bytes, reasons
//! up to 1000, sessions up to 200 plain characters.

use std::collections::BTreeMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde_json::{Map, Value, json};

use super::remote_relay::gate::COMMAND_PARAMS;
use super::responses::send_response_with_details;
use super::{MessageWriter, Response};
use crate::mux::Mux;

pub const ACCESS_REQUEST_CAPABILITY: &str = "access-request-v1";

const MAX_REQUESTS: usize = 64;
const KEPT: Duration = Duration::from_secs(15 * 60);
const MAX_PATH_BYTES: usize = 4096;
const MAX_REASON_BYTES: usize = 1000;
const MAX_SESSION_BYTES: usize = 200;

/// The requests this daemon keeps.
#[derive(Default)]
pub(crate) struct AccessRequests {
    requests: Mutex<BTreeMap<String, Request>>,
}

struct Request {
    kind: &'static str,
    path: String,
    session: Option<String>,
    reason: Option<String>,
    made: Instant,
    /// When it was answered, and how.
    answer: Option<(Instant, Answer)>,
}

enum Answer {
    Delivered(String),
    Denied(Option<String>),
}

#[derive(Clone, Copy)]
enum Refusal {
    NotTrusted,
    Unavailable,
    BadRequest,
    UnknownRequest,
    Answered,
    Limit,
}

impl Refusal {
    fn code(self) -> &'static str {
        match self {
            Self::NotTrusted => "access_request.not_trusted",
            Self::Unavailable => "access_request.unavailable",
            Self::BadRequest => "access_request.bad_request",
            Self::UnknownRequest => "access_request.unknown_request",
            Self::Answered => "access_request.answered",
            Self::Limit => "access_request.limit",
        }
    }

    fn message(self) -> &'static str {
        match self {
            Self::NotTrusted => "access requests are served to trusted local clients only",
            Self::Unavailable => "access requests are served on a Cloud machine only",
            Self::BadRequest => "bad access request",
            Self::UnknownRequest => "no such access request",
            Self::Answered => "the access request was already answered",
            Self::Limit => "too many access requests; wait for some to be answered",
        }
    }
}

fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|e| e.into_inner())
}

/// Handles an `access-request*` line; None for any other line.
pub(super) fn try_handle(
    mux: &Mux,
    client: u64,
    message: &str,
    writer: &MessageWriter,
) -> Option<bool> {
    if !message.contains("\"access-request") {
        return None;
    }
    let Ok(Value::Object(mut object)) = serde_json::from_str::<Value>(message) else {
        return None;
    };
    let cmd = match object.remove("cmd") {
        Some(Value::String(cmd))
            if cmd == "access-request" || cmd.starts_with("access-request-") =>
        {
            cmd
        }
        _ => return None,
    };
    let id = object.remove("id");
    // Trust first: an untrusted client gets one answer whatever it sent.
    if !mux.control_clients.is_unix(client) || mux.is_remote_client(client) {
        return Some(reply(writer, id, Err(Refusal::NotTrusted)));
    }
    if !mux.on_cloud_host() {
        return Some(reply(writer, id, Err(Refusal::Unavailable)));
    }
    let result = handle(&mux.access_requests, &cmd, object, Instant::now());
    Some(reply(writer, id, result))
}

fn handle(
    requests: &AccessRequests,
    cmd: &str,
    params: Map<String, Value>,
    now: Instant,
) -> Result<Value, Refusal> {
    if params.keys().any(|key| COMMAND_PARAMS.contains(&key.as_str())) {
        return Err(Refusal::BadRequest);
    }
    let mut kept = lock(&requests.requests);
    kept.retain(|_, request| {
        let since = request.answer.as_ref().map_or(request.made, |(at, _)| *at);
        now.duration_since(since) < KEPT
    });
    match cmd {
        "access-request" => {
            let params = Params::take(params, &["kind", "path", "session", "reason"])?;
            let kind = match params.text("kind")? {
                Some("file") => "file",
                _ => return Err(Refusal::BadRequest),
            };
            let path = params
                .text("path")?
                .filter(|path| path.starts_with('/') && path.len() <= MAX_PATH_BYTES)
                .filter(|path| !path.chars().any(char::is_control))
                .ok_or(Refusal::BadRequest)?;
            let session = params.text("session")?;
            if session.is_some_and(|session| !plain_session(session)) {
                return Err(Refusal::BadRequest);
            }
            let reason = params.text("reason")?;
            if reason.is_some_and(|reason| reason.len() > MAX_REASON_BYTES) {
                return Err(Refusal::BadRequest);
            }
            if kept.len() >= MAX_REQUESTS {
                return Err(Refusal::Limit);
            }
            let request_id = new_id().ok_or(Refusal::Limit)?;
            kept.insert(
                request_id.clone(),
                Request {
                    kind,
                    path: path.to_string(),
                    session: session.map(str::to_string),
                    reason: reason.map(str::to_string),
                    made: now,
                    answer: None,
                },
            );
            Ok(json!({ "request_id": request_id }))
        }
        "access-request-status" => {
            let params = Params::take(params, &["request_id"])?;
            let request_id = params.text("request_id")?.ok_or(Refusal::BadRequest)?;
            let request = kept.get(request_id).ok_or(Refusal::UnknownRequest)?;
            Ok(match &request.answer {
                None => json!({"state": "pending"}),
                Some((_, Answer::Delivered(path))) => json!({"state": "delivered", "path": path}),
                Some((_, Answer::Denied(reason))) => json!({"state": "denied", "reason": reason}),
            })
        }
        "access-request-list" => {
            Params::take(params, &[])?;
            let mut pending: Vec<(&String, &Request)> =
                kept.iter().filter(|(_, request)| request.answer.is_none()).collect();
            pending.sort_by_key(|(_, request)| request.made);
            let requests: Vec<Value> = pending
                .into_iter()
                .map(|(request_id, request)| {
                    json!({
                        "request_id": request_id,
                        "kind": request.kind,
                        "path": request.path,
                        "session": request.session,
                        "reason": request.reason,
                        "age_ms": now.duration_since(request.made).as_millis() as u64,
                    })
                })
                .collect();
            Ok(json!({ "requests": requests }))
        }
        "access-request-answer" => {
            let params = Params::take(params, &["request_id", "outcome", "path", "reason"])?;
            let request_id = params.text("request_id")?.ok_or(Refusal::BadRequest)?;
            let answer = match params.text("outcome")? {
                Some("delivered") => Answer::Delivered(
                    params
                        .text("path")?
                        .filter(|path| path.starts_with('/') && path.len() <= MAX_PATH_BYTES)
                        .ok_or(Refusal::BadRequest)?
                        .to_string(),
                ),
                Some("denied") => {
                    let reason = params.text("reason")?;
                    if reason.is_some_and(|reason| reason.len() > MAX_REASON_BYTES) {
                        return Err(Refusal::BadRequest);
                    }
                    Answer::Denied(reason.map(str::to_string))
                }
                _ => return Err(Refusal::BadRequest),
            };
            let request = kept.get_mut(request_id).ok_or(Refusal::UnknownRequest)?;
            if request.answer.is_some() {
                return Err(Refusal::Answered);
            }
            request.answer = Some((now, answer));
            Ok(json!({}))
        }
        _ => Err(Refusal::BadRequest),
    }
}

/// A frame's params, with none but the listed ones.
struct Params(Map<String, Value>);

impl Params {
    fn take(params: Map<String, Value>, allowed: &[&str]) -> Result<Self, Refusal> {
        if params.keys().any(|key| !allowed.contains(&key.as_str())) {
            return Err(Refusal::BadRequest);
        }
        Ok(Self(params))
    }

    /// The string param `key`; a non-string value is refused.
    fn text(&self, key: &str) -> Result<Option<&str>, Refusal> {
        match self.0.get(key) {
            None | Some(Value::Null) => Ok(None),
            Some(Value::String(text)) => Ok(Some(text)),
            Some(_) => Err(Refusal::BadRequest),
        }
    }
}

fn plain_session(session: &str) -> bool {
    !session.is_empty()
        && session.len() <= MAX_SESSION_BYTES
        && session.bytes().all(|byte| byte.is_ascii_alphanumeric() || b"._:-".contains(&byte))
}

/// A new request id: 16 random bytes in hex.
fn new_id() -> Option<String> {
    let mut bytes = [0u8; 16];
    getrandom::fill(&mut bytes).ok()?;
    Some(bytes.iter().map(|byte| format!("{byte:02x}")).collect())
}

fn reply(writer: &MessageWriter, id: Option<Value>, result: Result<Value, Refusal>) -> bool {
    let (data, error, code) = match result {
        Ok(data) => (Some(data), None, None),
        Err(refusal) => (None, Some(refusal.message().to_string()), Some(refusal.code())),
    };
    send_response_with_details(
        writer,
        Response {
            id,
            ok: data.is_some(),
            data,
            error,
            error_code: code.map(str::to_owned),
            error_delivery: None,
        },
        None,
        None,
        None,
    )
}
