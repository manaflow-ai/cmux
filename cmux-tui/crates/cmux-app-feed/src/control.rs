//! The Feed's control methods (`FeedControl`) and the owner's reply errors (`FeedService`): the
//! op bodies `feed.request` and `feed.cancel` send, what `feed.request` returns, the debug matches,
//! and which control error an owner failure becomes.

use crate::json::{obj_at, str_at};
use serde::Serialize;
use serde_json::{Map, Value, json};

/// The longest `feed.request` waits for an answer (seconds).
pub const MAX_WAIT: i64 = 120;

/// A control error.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ControlError {
    pub code: String,
    pub message: String,
}

impl ControlError {
    fn new(code: &str, message: impl Into<String>) -> Self {
        Self { code: code.into(), message: message.into() }
    }

    fn invalid(message: &str) -> Self {
        Self::new("invalid_params", message)
    }
}

/// What `feed.request` sends and how long it then waits.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct RequestPlan {
    /// The `v1/ops` body.
    pub body: Value,
    /// Seconds to wait for the item to close, `0..=120`.
    pub wait: i64,
}

fn int_of(value: Option<&Value>) -> Option<i64> {
    let value = value?;
    value
        .as_i64()
        .or_else(|| value.as_f64().filter(|float| float.is_finite()).map(|float| float as i64))
}

/// `feed.request`'s plan from its params (`post`, `idempotency_key`, `wait_seconds`).
pub fn request(params: &Value) -> Result<RequestPlan, ControlError> {
    let post = obj_at(params, "post")
        .ok_or_else(|| ControlError::invalid("feed.request needs `post` (feed.post params)"))?;
    let key = str_at(params, "idempotency_key")
        .filter(|key| !key.is_empty())
        .ok_or_else(|| ControlError::invalid("feed.request needs `idempotency_key`"))?;
    let wait = int_of(params.get("wait_seconds")).unwrap_or(0).clamp(0, MAX_WAIT);
    Ok(RequestPlan {
        body: json!({"op": "feed.post", "params": post, "idempotency_key": key, "origin": "cli"}),
        wait,
    })
}

/// The posted item's id in a `feed.post` reply.
pub fn posted_id(reply: &Value) -> Result<String, ControlError> {
    reply
        .get("value")
        .and_then(|value| value.get("item"))
        .and_then(|item| str_at(item, "id"))
        .map(str::to_owned)
        .ok_or_else(|| ControlError::new("feed.bad_reply", "the owner returned no item"))
}

/// The `v1/read` body that reads item `id` back.
pub fn read_body(id: &str) -> Value {
    json!({"op": "feed.get", "params": {"item": id}})
}

/// `feed.request`'s result from the read-back reply: the item, and whether it is still open after
/// a wait.
pub fn request_result(read: &Value, wait: i64) -> Value {
    let item = read
        .get("value")
        .and_then(|value| value.get("item"))
        .cloned()
        .unwrap_or_else(crate::json::empty);
    let open = str_at(&item, "state") == Some("open");
    json!({"item": item, "timed_out": wait > 0 && open})
}

/// `feed.cancel`'s `v1/ops` body from its params (`item`, `reason`, `note`, `idempotency_key`).
pub fn cancel(params: &Value) -> Result<Value, ControlError> {
    let item =
        str_at(params, "item").ok_or_else(|| ControlError::invalid("feed.cancel needs `item`"))?;
    let mut body = Map::from_iter([("item".into(), item.into())]);
    let reason = str_at(params, "reason");
    if let Some(reason) = reason {
        body.insert("reason".into(), reason.into());
    }
    if let Some(note) = str_at(params, "note") {
        body.insert("note".into(), note.into());
    }
    let key = str_at(params, "idempotency_key")
        .map_or_else(|| format!("cancel:{item}:{}", reason.unwrap_or("poster")), str::to_owned);
    Ok(json!({"op": "feed.cancel", "params": body, "idempotency_key": key, "origin": "cli"}))
}

/// The owner's error in a reply (`{"error": {code, message}}`), when it has one.
pub fn reply_error(reply: &Value) -> Option<ControlError> {
    let error = reply.get("error").filter(|error| error.is_object())?;
    Some(ControlError::new(
        str_at(error, "code").unwrap_or("error"),
        str_at(error, "message").unwrap_or_default(),
    ))
}

/// How a call to the owner failed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum OwnerFailure {
    SignedOut,
    Owner { code: String, message: String },
    Other(String),
}

/// The control error an owner failure becomes.
pub fn owner_error(failure: &OwnerFailure) -> ControlError {
    match failure {
        OwnerFailure::SignedOut => {
            ControlError::new("feed.signed_out", "sign in to cmux to use the feed")
        }
        OwnerFailure::Owner { code, message } => ControlError::new(code, message.clone()),
        OwnerFailure::Other(description) => {
            ControlError::new("owner.unreachable", description.clone())
        }
    }
}

/// `debug.feed`'s matches: the items whose title contains `text`.
pub fn debug_matches(items: &[Value], text: &str) -> Vec<Value> {
    items
        .iter()
        .filter(|item| str_at(item, "title").unwrap_or_default().contains(text))
        .map(|item| {
            json!({
                "id": str_at(item, "id").unwrap_or_default(),
                "title": str_at(item, "title").unwrap_or_default(),
                "state": str_at(item, "state").unwrap_or("open"),
                "home": str_at(item, "home").unwrap_or("cloud"),
                "poster": item.get("poster").and_then(|poster| str_at(poster, "label")).unwrap_or_default(),
            })
        })
        .collect()
}

/// `debug.feed`'s connection line: `state: reason`, or `unavailable` without a view.
pub fn connection_line(connection: Option<&Value>) -> String {
    match connection {
        Some(connection) if connection.is_object() => {
            [str_at(connection, "state"), str_at(connection, "reason")]
                .into_iter()
                .flatten()
                .collect::<Vec<_>>()
                .join(": ")
        }
        _ => "unavailable".into(),
    }
}
