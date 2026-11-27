//! Whether a conversation owner does no work now, so the app may restart it
//! (`cmux.protocol/2` reads only). Idle means both:
//! - no participant types in any conversation (`conversation.list`, then
//!   `conversation.get`'s `typing`): a Chief types for its whole turn;
//! - no other app, page, chat or call is connected (`client.list`: a client
//!   of a busy kind, a WebSocket client, or a local client that names no kind
//!   and connected under `call_seconds` ago, other than this connection).
//!
//! Any error answers busy: a probe that cannot see the owner never restarts it.
//! The app does the reads in order and feeds each reply here.

use serde_json::Value;

/// A minute: a CLI or MCP call takes seconds.
pub const STANDARD_CALL_SECONDS: f64 = 60.0;
/// Client kinds that keep the owner busy: another app and an open `cmux chief` chat.
pub const BUSY_CLIENT_KINDS: [&str; 2] = ["frontend", "chief-chat"];

/// What `client.list` says.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Clients {
    Busy,
    /// Busy at most with local clients without a kind: the youngest is a
    /// standing connection in this many seconds (0: none).
    Call(f64),
}

/// `connected_seconds` (a decimal string on the wire, whole seconds);
/// unreadable counts as just connected.
fn connected_seconds(client: &Value) -> f64 {
    match client.get("connected_seconds") {
        Some(Value::String(text)) => text.trim().parse::<f64>().unwrap_or(0.0),
        Some(Value::Number(number)) => number.as_f64().unwrap_or(0.0),
        _ => 0.0,
    }
}

/// The verdict of a `client.list` result (a non-array lists no client).
pub fn clients(list: &Value, call_seconds: f64) -> Clients {
    let mut call: f64 = 0.0;
    for client in list.as_array().map(Vec::as_slice).unwrap_or_default() {
        if client.get("self").and_then(Value::as_bool) == Some(true) {
            continue;
        }
        if client.get("transport").and_then(Value::as_str) != Some("unix") {
            return Clients::Busy;
        }
        match client.get("client_kind").and_then(Value::as_str) {
            None => call = call.max(call_seconds - connected_seconds(client)),
            Some(kind) if BUSY_CLIENT_KINDS.contains(&kind) => return Clients::Busy,
            Some(_) => {}
        }
    }
    Clients::Call(call)
}

/// The conversation ids of a `conversation.list` result, or `None` (busy)
/// when a summary has no id.
pub fn conversation_ids(list: &Value) -> Option<Vec<String>> {
    list.as_array()
        .map(Vec::as_slice)
        .unwrap_or_default()
        .iter()
        .map(|summary| summary.get("id").and_then(Value::as_str).map(str::to_string))
        .collect()
}

/// A `conversation.get` snapshot with nobody typing (a `typing` array, empty).
pub fn nobody_types(snapshot: &Value) -> bool {
    snapshot.get("typing").and_then(Value::as_array).is_some_and(Vec::is_empty)
}

/// Whether an owner event can make a busy owner idle: a client left or
/// changed its kind, the client list changed, or a typing set changed.
pub fn may_end_busy(kind: &str, name: Option<&str>) -> bool {
    match kind {
        "client" => {
            matches!(name, Some("client-detached" | "client-changed" | "client-list-invalidated"))
        }
        "conversation_typing" => true,
        _ => false,
    }
}
