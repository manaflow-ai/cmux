//! Requests a Cloud machine's agents make for files and secrets of the person's Mac
//! (`access-request-v1`, Move to Cloud, cmuxterm-hq#1874 slice 6). An agent
//! on this machine asks (`cmux link access request`); the app on the
//! person's Mac lists the requests through its machine link, decides on the
//! Mac (a grant, or the person's answer on an inline card), pushes what it
//! shares itself (`fs-v1`) and answers here. This daemon only keeps the
//! requests: it never reaches the Mac and nothing here grants anything.
//!
//! - `access-request {kind:"file", path, session?, reason?}` or
//!   `{kind:"secret", name, session?, reason?}`: answers `{request_id}`.
//!   `path` is the absolute path on the Mac the agent asks for, `name` the
//!   secret's name (plain, at most 128 bytes), `session` the asking chat's
//!   agent session (`CMUX_AGENT_SESSION`), `reason` a line for the person.
//! - `access-request-status {request_id}`: `{state, path?, value?, reason?}`,
//!   where `state` is `pending`, `delivered` (with the `path` on this machine
//!   the Mac put the file at, or a secret's `value`) or `denied` (with the
//!   Mac's `reason`, if any). A secret's value is answered to the first
//!   status read only, then wiped here (`{state:"delivered", taken:true}`).
//! - `access-request-list {}`: the pending requests, oldest first, as
//!   `{requests:[{request_id, kind, path, name, session, reason, age_ms}]}`.
//! - `access-request-answer {request_id, outcome:"delivered", path}` (a
//!   file), `{request_id, outcome:"delivered", value}` (a secret, at most 64
//!   KiB) or `{request_id, outcome:"denied", reason?}`: a pending request
//!   only.
//!
//! A secret value is held in memory only, never written or logged, and
//! wiped when forgotten; only the first status read of its request answers
//! it (moved into that reply). Best effort: the frame and reply lines are
//! plain buffers while they are read and written.
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
//! up to 1000, sessions up to 200 plain characters, secret names up to 128,
//! secret values up to 64 KiB.

use crate::panic_free::JsonFields;
use cmux_threads::sync::Mutex;
use std::collections::BTreeMap;
use std::time::{Duration, Instant};

use serde::Deserialize;
use serde_json::{Map, Value, json};
use zeroize::Zeroizing;

use crate::server::remote_relay::gate::COMMAND_PARAMS;
use crate::server::responses::send_response_with_details;
use crate::server::routes::{Route, RouteLine, RouteName};
use crate::server::{FrameStage, MessageWriter, Response};

pub const ACCESS_REQUEST_CAPABILITY: &str = "access-request-v1";

const MAX_REQUESTS: usize = 64;
const KEPT: Duration = Duration::from_secs(15 * 60);
const MAX_PATH_BYTES: usize = 4096;
const MAX_REASON_BYTES: usize = 1000;
const MAX_SESSION_BYTES: usize = 200;
const MAX_NAME_BYTES: usize = 128;
/// The largest secret value a person can share.
const MAX_SECRET_BYTES: usize = 64 * 1024;

/// The requests this daemon keeps.
#[derive(Default)]
pub(crate) struct AccessRequests {
    requests: Mutex<BTreeMap<String, Request>>,
}

struct Request {
    kind: &'static str,
    /// A file request's path on the Mac.
    path: Option<String>,
    /// A secret request's name.
    name: Option<String>,
    session: Option<String>,
    reason: Option<String>,
    made: Instant,
    /// When it was answered, and how.
    answer: Option<(Instant, Answer)>,
}

enum Answer {
    Delivered(String),
    /// A secret the person shared, until its first status read takes it
    /// (then None). Wiped from memory when taken or forgotten.
    Secret(Option<Zeroizing<String>>),
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

/// The `access-request*` commands, decoded by their `cmd`. A null optional
/// field is absent; any other field or a non-string value is a bad request.
/// spec/sdk-schema.json types each variant (check-sdk-schema.py compares the
/// fields).
#[derive(Deserialize)]
#[serde(tag = "cmd", deny_unknown_fields)]
enum Command {
    #[serde(rename = "access-request")]
    Make {
        kind: String,
        #[serde(default)]
        path: Option<String>,
        #[serde(default)]
        name: Option<String>,
        #[serde(default)]
        session: Option<String>,
        #[serde(default)]
        reason: Option<String>,
    },
    #[serde(rename = "access-request-status")]
    Status { request_id: String },
    #[serde(rename = "access-request-list")]
    List {},
    #[serde(rename = "access-request-answer")]
    Answer {
        request_id: String,
        outcome: String,
        #[serde(default)]
        path: Option<String>,
        #[serde(default)]
        value: Option<String>,
        #[serde(default)]
        reason: Option<String>,
    },
}

impl Command {
    /// The command of a frame (its `cmd` and params, `id` taken out).
    fn parse(frame: Map<String, Value>) -> Result<Self, Refusal> {
        if frame.keys().any(|key| COMMAND_PARAMS.contains(&key.as_str())) {
            return Err(Refusal::BadRequest);
        }
        serde_json::from_value(Value::Object(frame)).map_err(|_| Refusal::BadRequest)
    }
}

/// The `cmd` names this module answers (server/routes.rs).
pub(in crate::server) const ROUTES: &[Route] = &[Route {
    names: &[RouteName::Exact("access-request"), RouteName::Prefix("access-request-")],
    stage: FrameStage::AgentTransfer,
    entry: handle,
}];

/// Answers an `access-request` or `access-request-*` line (the route found
/// it by name). The line's one decode is its `Value`, which gives every
/// reply the `id` as written, a refused one too, and then the typed
/// [`Command`]. `None` only for a line with no `Value` (a number past
/// `f64`, a lone surrogate); the `Command` parse answers it.
fn handle(line: &RouteLine<'_>) -> Option<bool> {
    let RouteLine { mux, client, message, writer, .. } = *line;
    let Ok(Value::Object(mut object)) = crate::line_parses::parse::<Value>(message) else {
        return None;
    };
    let id = object.remove("id");
    // Trust first: an untrusted client gets one answer whatever it sent.
    if !mux.control_clients.is_unix(client) || mux.is_remote_client(client) {
        return Some(reply(writer, id, Err(Refusal::NotTrusted)));
    }
    if !mux.on_cloud_host() {
        return Some(reply(writer, id, Err(Refusal::Unavailable)));
    }
    let result = Command::parse(object)
        .and_then(|command| serve(&mux.access_requests, command, Instant::now()));
    Some(reply(writer, id, result))
}

/// A file path on the Mac or on this machine: absolute, bounded, no control
/// character.
fn plain_path(path: &str) -> bool {
    path.starts_with('/') && path.len() <= MAX_PATH_BYTES && !path.chars().any(char::is_control)
}

fn serve(requests: &AccessRequests, command: Command, now: Instant) -> Result<Value, Refusal> {
    let mut kept = lock(&requests.requests);
    kept.retain(|_, request| {
        let since = request.answer.as_ref().map_or(request.made, |(at, _)| *at);
        now.duration_since(since) < KEPT
    });
    match command {
        Command::Make { kind, path, name, session, reason } => {
            let (kind, path, name) = match (kind.as_str(), path, name) {
                ("file", Some(path), None) if plain_path(&path) => ("file", Some(path), None),
                ("secret", None, Some(name)) if plain_name(&name) => ("secret", None, Some(name)),
                _ => return Err(Refusal::BadRequest),
            };
            if session.as_deref().is_some_and(|session| !plain_session(session)) {
                return Err(Refusal::BadRequest);
            }
            if reason.as_ref().is_some_and(|reason| reason.len() > MAX_REASON_BYTES) {
                return Err(Refusal::BadRequest);
            }
            if kept.len() >= MAX_REQUESTS {
                return Err(Refusal::Limit);
            }
            let request_id = new_id().ok_or(Refusal::Limit)?;
            kept.insert(
                request_id.clone(),
                Request { kind, path, name, session, reason, made: now, answer: None },
            );
            Ok(json!({ "request_id": request_id }))
        }
        Command::Status { request_id } => {
            let request = kept.get_mut(&request_id).ok_or(Refusal::UnknownRequest)?;
            Ok(match &mut request.answer {
                None => json!({"state": "pending"}),
                Some((_, Answer::Delivered(path))) => json!({"state": "delivered", "path": path}),
                // Only the first read gets the value; it is gone from here after.
                // Moved, not copied, into the reply; the reply line itself is
                // the one plain copy left, until it is written.
                Some((_, Answer::Secret(value))) => match value.take() {
                    Some(mut value) => {
                        let mut reply = json!({"state": "delivered"});
                        reply.insert("value", Value::String(std::mem::take(&mut *value)));
                        reply
                    }
                    None => json!({"state": "delivered", "taken": true}),
                },
                Some((_, Answer::Denied(reason))) => json!({"state": "denied", "reason": reason}),
            })
        }
        Command::List {} => {
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
                        "name": request.name,
                        "session": request.session,
                        "reason": request.reason,
                        "age_ms": now.duration_since(request.made).as_millis() as u64,
                    })
                })
                .collect();
            Ok(json!({ "requests": requests }))
        }
        Command::Answer { request_id, outcome, path, value, reason } => {
            // Moved out of the frame, so the only copy kept is wiped.
            let value = value.map(Zeroizing::new);
            let request = kept.get_mut(&request_id).ok_or(Refusal::UnknownRequest)?;
            let answer = match (outcome.as_str(), request.kind, path, value) {
                ("delivered", "file", Some(path), None) if plain_path(&path) => {
                    Answer::Delivered(path)
                }
                ("delivered", "secret", None, Some(value))
                    if !value.is_empty() && value.len() <= MAX_SECRET_BYTES =>
                {
                    Answer::Secret(Some(value))
                }
                ("denied", _, None, None) => {
                    if reason.as_ref().is_some_and(|reason| reason.len() > MAX_REASON_BYTES) {
                        return Err(Refusal::BadRequest);
                    }
                    Answer::Denied(reason)
                }
                _ => return Err(Refusal::BadRequest),
            };
            if request.answer.is_some() {
                return Err(Refusal::Answered);
            }
            request.answer = Some((now, answer));
            Ok(json!({}))
        }
    }
}

/// A secret's name: what the agent asks for (`GITHUB_TOKEN`, `npm.token`).
fn plain_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= MAX_NAME_BYTES
        && name.bytes().all(|byte| byte.is_ascii_alphanumeric() || b"._-".contains(&byte))
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

#[cfg(test)]
#[path = "access_requests_tests.rs"]
mod tests;
