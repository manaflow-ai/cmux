//! The agent VM daemon's chat namespace authorities (RFD 0007, "Projection as the view layer of
//! the fleet filesystem"): one `cmux_projection::chat_ns::Authority` per chat, holding that chat's
//! per-path versions and leases. Bytes never pass through here.
//!
//! The internal API is one JSON request per call ([`answer`]), the shape the members' dial will
//! carry: `{"cmd", "chat", ...}` answered `{"ok": true, "data"}` or `{"ok": false, "error",
//! "error_code"}`.
//!
//! - `ns.open {chat, member, path, cached_seq?}` -> `{version, stale}`
//! - `ns.acquire {chat, member, actor, path}` -> `{acquire: "granted" | "wait" | "private", ...}`
//! - `ns.close {chat, token, meta}` -> `{path, version, invalidate, released, conflict}`
//! - `ns.heartbeat {chat, member}` -> `{renewed}` (every `chat_ns::RENEW_EVERY_MS`)
//! - `ns.invalidations {chat, member}` -> `{paths}`
//! - `ns.conflicts {chat}` -> `{events}` (popover 2, and `cmux fs stranded --json`)
//! - `ns.resolve {chat, id, choice}` -> `{event, choice}`
//!
//! A chat's authority starts on its first call, with the chat's own agent (`owners`, given on
//! the first call or by [`host`]) as owner. [`take`] and [`restore`] carry it whole across a
//! session move, inside the RFD 0138 fence.

use std::collections::HashMap;
use std::sync::{Mutex, OnceLock, PoisonError};
use std::time::Instant;

use cmux_projection::chat_ns::{Authority, Choice, Meta, NsError, Writer};
use serde::Deserialize;
use serde_json::{Value, json};

fn authorities() -> &'static Mutex<HashMap<String, Authority>> {
    static AUTHORITIES: OnceLock<Mutex<HashMap<String, Authority>>> = OnceLock::new();
    AUTHORITIES.get_or_init(Mutex::default)
}

/// This daemon's monotonic clock, in milliseconds since it first read it.
fn now_ms() -> u64 {
    static START: OnceLock<Instant> = OnceLock::new();
    u64::try_from(START.get_or_init(Instant::now).elapsed().as_millis()).unwrap_or(u64::MAX)
}

/// Starts (or keeps) `chat`'s authority with `owners` among its owner actors.
pub fn host(chat: &str, owners: &[String]) {
    let mut map = authorities().lock().unwrap_or_else(PoisonError::into_inner);
    let authority =
        map.entry(chat.to_owned()).or_insert_with(|| Authority::new(chat, owners.iter().cloned()));
    for owner in owners {
        authority.add_owner(owner.clone());
    }
}

/// Ends `chat`'s authority here and hands it over (a session move, or the chat's end).
pub fn take(chat: &str) -> Option<Authority> {
    authorities().lock().unwrap_or_else(PoisonError::into_inner).remove(chat)
}

/// Hosts an authority that arrived from another machine, re-timed on this daemon's clock.
pub fn restore(authority: Authority) {
    let authority = authority.moved(now_ms());
    authorities()
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .insert(authority.chat().to_owned(), authority);
}

#[derive(Deserialize)]
struct Request {
    cmd: String,
    chat: String,
    #[serde(default)]
    owners: Vec<String>,
    #[serde(default)]
    member: String,
    #[serde(default)]
    actor: String,
    #[serde(default)]
    path: String,
    #[serde(default)]
    cached_seq: Option<u64>,
    #[serde(default)]
    token: u64,
    #[serde(default)]
    meta: Meta,
    #[serde(default)]
    id: u64,
    #[serde(default)]
    choice: Option<Choice>,
}

/// One request to a chat's authority at this daemon's clock (module docs).
#[must_use]
pub fn answer(request: &Value) -> Value {
    answer_at(request, now_ms())
}

/// [`answer`] at `now_ms`.
#[must_use]
pub fn answer_at(request: &Value, now_ms: u64) -> Value {
    match data(request, now_ms) {
        Ok(data) => json!({"ok": true, "data": data}),
        Err((code, error)) => json!({"ok": false, "error": error, "error_code": code}),
    }
}

fn data(request: &Value, now_ms: u64) -> Result<Value, (&'static str, String)> {
    let request: Request = serde_json::from_value(request.clone())
        .map_err(|error| ("ns.params_invalid", format!("bad request: {error}")))?;
    if request.chat.is_empty() {
        return Err(("ns.params_invalid", "a request names its chat".into()));
    }
    host(&request.chat, &request.owners);
    let mut map = authorities().lock().unwrap_or_else(PoisonError::into_inner);
    let ns = map
        .get_mut(&request.chat)
        .ok_or(("ns.unknown", format!("no authority for chat {}", request.chat)))?;
    let needs = |field: &str, value: &str| {
        if value.is_empty() {
            Err(("ns.params_invalid", format!("{} needs {field}", request.cmd)))
        } else {
            Ok(())
        }
    };
    let refused = |error: NsError| match error {
        NsError::UnknownToken(_) => ("ns.unknown_token", error.to_string()),
        NsError::UnknownEvent(_) => ("ns.unknown_event", error.to_string()),
    };
    match request.cmd.as_str() {
        "ns.open" => {
            needs("member", &request.member)?;
            needs("path", &request.path)?;
            Ok(to_json(&ns.open(&request.member, &request.path, request.cached_seq, now_ms)))
        }
        "ns.acquire" => {
            needs("member", &request.member)?;
            needs("actor", &request.actor)?;
            needs("path", &request.path)?;
            let writer = Writer { member: request.member, actor: request.actor };
            Ok(to_json(&ns.acquire(&writer, &request.path, now_ms)))
        }
        "ns.close" => Ok(to_json(&ns.close(request.token, request.meta, now_ms).map_err(refused)?)),
        "ns.heartbeat" => {
            needs("member", &request.member)?;
            Ok(json!({"renewed": ns.heartbeat(&request.member, now_ms)}))
        }
        "ns.invalidations" => {
            needs("member", &request.member)?;
            Ok(json!({"paths": ns.take_invalidations(&request.member)}))
        }
        "ns.conflicts" => Ok(json!({"events": ns.pending()})),
        "ns.resolve" => {
            let choice = request
                .choice
                .ok_or(("ns.params_invalid", "ns.resolve needs a choice".to_owned()))?;
            let (event, choice) = ns.resolve(request.id, choice).map_err(refused)?;
            Ok(json!({"event": event, "choice": choice}))
        }
        other => Err(("ns.unknown_cmd", format!("unknown command {other}"))),
    }
}

fn to_json(value: &impl serde::Serialize) -> Value {
    serde_json::to_value(value).unwrap_or(Value::Null)
}

#[cfg(test)]
#[path = "projection_ns_tests.rs"]
mod tests;
