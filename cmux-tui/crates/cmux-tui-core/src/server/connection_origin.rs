//! Where a session socket connection really comes from, beyond the OS user
//! (plans/cmux-next/identity.md section 3, the remote bridge rule).
//!
//! The cmux-remote mux control bridge pumps a paired peer's bytes into this
//! same Unix socket, so the transport alone says "local". The bridge writes
//! [`remote_bridge_mark_line`] before any peer byte, and the connection is
//! then never a local principal: it cannot present a launch credential and
//! never becomes the frontend. The mark only removes rights, so any
//! connection may send it on any line, and nothing clears it.

use serde_json::{Value, json};

use super::{ClientRegistry, ClientTransport, MessageWriter, Response, send_response};

/// The command word of the mark.
pub const CONNECTION_ORIGIN_COMMAND: &str = "connection-origin";
/// The origin a cmux-remote bridge declares.
pub const REMOTE_BRIDGE_ORIGIN: &str = "remote_bridge";

/// The line (with its LF) a cmux-remote bridge writes first on a session
/// socket connection that carries a peer's bytes.
pub fn remote_bridge_mark_line() -> Vec<u8> {
    let mut line = json!({
        "id": 0,
        "cmd": CONNECTION_ORIGIN_COMMAND,
        "origin": REMOTE_BRIDGE_ORIGIN,
    })
    .to_string()
    .into_bytes();
    line.push(b'\n');
    line
}

/// What the bridge learns from the reply to its mark.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RemoteBridgeMarkReply {
    /// This daemon recorded the mark.
    Accepted,
    /// A daemon from before the mark: it has no launch credentials or
    /// frontend to protect, so the bridge may continue.
    UnknownToDaemon,
    /// Anything else: the bridge must close the connection.
    Refused,
}

/// Classify the reply line to [`remote_bridge_mark_line`].
pub fn remote_bridge_mark_reply(line: &str) -> RemoteBridgeMarkReply {
    let Ok(Value::Object(reply)) = serde_json::from_str::<Value>(line.trim()) else {
        return RemoteBridgeMarkReply::Refused;
    };
    if reply.get("id") != Some(&json!(0)) {
        return RemoteBridgeMarkReply::Refused;
    }
    if reply.get("ok") == Some(&Value::Bool(true))
        && reply.get("data").and_then(|data| data.get("origin")).and_then(Value::as_str)
            == Some(REMOTE_BRIDGE_ORIGIN)
    {
        return RemoteBridgeMarkReply::Accepted;
    }
    let error = reply.get("error").and_then(Value::as_str).unwrap_or_default();
    if reply.get("ok") == Some(&Value::Bool(false))
        && error.starts_with("bad request:")
        && error.contains(CONNECTION_ORIGIN_COMMAND)
    {
        return RemoteBridgeMarkReply::UnknownToDaemon;
    }
    RemoteBridgeMarkReply::Refused
}

/// Whether `message` is the remote bridge mark.
pub(super) fn is_remote_bridge_mark(message: &str) -> bool {
    let Ok(Value::Object(request)) = serde_json::from_str::<Value>(message.trim()) else {
        return false;
    };
    request.get("cmd").and_then(Value::as_str) == Some(CONNECTION_ORIGIN_COMMAND)
        && request.get("origin").and_then(Value::as_str) == Some(REMOTE_BRIDGE_ORIGIN)
}

/// Record the mark for `client` and acknowledge it.
pub(super) fn accept_remote_bridge_mark(
    registry: &ClientRegistry,
    client: u64,
    writer: &MessageWriter,
) -> bool {
    registry.mark_remote_bridge(client);
    send_response(
        writer,
        Response {
            id: Some(json!(0)),
            ok: true,
            data: Some(json!({ "origin": REMOTE_BRIDGE_ORIGIN })),
            error: None,
            error_code: None,
            error_delivery: None,
        },
    )
}

impl ClientRegistry {
    fn mark_remote_bridge(&self, client: u64) {
        if let Some(record) = self.state.lock().unwrap().clients.get_mut(&client) {
            record.remote_bridge = true;
        }
    }

    /// A connection on the local Unix socket that no remote bridge carries:
    /// the only kind that may present a launch credential or become the
    /// frontend. Other `is_unix` gates keep their meaning.
    pub(super) fn is_local_principal(&self, client: u64) -> bool {
        self.state.lock().unwrap().clients.get(&client).is_some_and(|record| {
            matches!(record.transport, ClientTransport::Unix) && !record.remote_bridge
        })
    }
}

#[cfg(test)]
#[path = "connection_origin_tests.rs"]
mod tests;
