//! Read-only agent session observation (`agent-session-observe-v1`).
//!
//! Observation uses the same trusted local routing and attachment lifecycle as
//! `agent-session-attach`, but marks the attachment so session mutations are
//! refused while history and live records remain available.

use std::sync::Arc;

use serde_json::Value;

use super::{MessageWriter, Mux, PageParams, Refusal, attach, refuse};

pub const AGENT_SESSION_OBSERVE_CAPABILITY: &str = "agent-session-observe-v1";

/// Handles the observer command before the writable attach command parser.
pub(super) fn try_handle(
    mux: &Arc<Mux>,
    client: u64,
    message: &str,
    writer: &MessageWriter,
    author: Option<Value>,
    pinned: Option<String>,
) -> Option<bool> {
    if !message.contains("\"agent-session-") {
        return None;
    }
    let Ok(Value::Object(mut object)) = serde_json::from_str::<Value>(message) else {
        return None;
    };
    let Some(Value::String(cmd)) = object.remove("cmd") else {
        return None;
    };
    if cmd != "agent-session-observe" {
        return None;
    }
    let id = object.remove("id");
    let Ok(params) = serde_json::from_value::<PageParams>(Value::Object(object)) else {
        return Some(refuse(writer, id, Refusal::BadRequest));
    };
    if !mux.control_clients.is_unix(client) || mux.is_remote_client(client) {
        return Some(refuse(writer, id, Refusal::NotTrusted));
    }
    let sessions = &mux.control_clients.agent_sessions;
    let Some(socket) = sessions.socket() else {
        return Some(refuse(writer, id, Refusal::Unavailable));
    };
    Some(attach(mux, client, id, socket, params, true, author, pinned, writer))
}
