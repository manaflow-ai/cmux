//! Rust-owned Cloud chat relay for the iOS mobile RPC adapter.
//!
//! The phone never gets an acpmux socket.  The local mobile host forwards three
//! narrowly shaped commands here; this module opens a short lived AcpmuxLink,
//! validates and bounds the request, and returns the acpmux result.  Keeping the
//! chat/session rules here means the Swift adapter stays a transport forwarder.

use std::sync::Arc;
use std::time::Duration;

use serde_json::{Map, Value, json};

use super::agent_session_attach::agent_session_link::{AcpmuxLink, LinkError};
use super::*;

const CALL_TIMEOUT: Duration = Duration::from_secs(10);
const MAX_LIMIT: u64 = 200;
const MAX_TEXT_BYTES: usize = 64 * 1024;

/// Handles the three commands used by `mobile.chat.*`.  `None` means this is
/// another protocol line and lets the normal command parser handle it.
pub(super) fn try_handle(
    mux: &Arc<Mux>,
    client: u64,
    message: &str,
    writer: &MessageWriter,
) -> Option<bool> {
    if !message.contains("\"mobile-chat-") {
        return None;
    }
    let Ok(Value::Object(mut object)) = serde_json::from_str::<Value>(message) else {
        return None;
    };
    let Some(Value::String(command)) = object.remove("cmd") else { return None };
    if !matches!(
        command.as_str(),
        "mobile-chat-sessions" | "mobile-chat-history" | "mobile-chat-send"
    ) {
        return None;
    }
    let id = object.remove("id");
    if !mux.control_clients.is_unix(client) || mux.is_remote_client(client) {
        return Some(refuse(writer, id, "not_trusted", "mobile chat relay is local only"));
    }
    let Some(socket) = mux.control_clients.agent_sessions.socket() else {
        return Some(refuse(writer, id, "unavailable", "acpmux is unavailable"));
    };
    let params = Value::Object(object);
    let writer = writer.clone();
    std::thread::spawn(move || {
        let result = match AcpmuxLink::connect(&socket, |_| {}) {
            Ok(link) => dispatch(&link, &command, params),
            Err(_) => Err(("unavailable", "acpmux is unavailable".to_owned())),
        };
        match result {
            Ok(data) => {
                send_response(
                    &writer,
                    Response {
                        id,
                        ok: true,
                        data: Some(data),
                        error: None,
                        error_code: None,
                        error_delivery: None,
                    },
                );
            }
            Err((code, message)) => {
                refuse(&writer, id, code, &message);
            }
        }
    });
    Some(true)
}

fn dispatch(
    link: &AcpmuxLink,
    command: &str,
    params: Value,
) -> Result<Value, (&'static str, String)> {
    match command {
        "mobile-chat-sessions" => {
            let params = bounded_page_params(&params)?;
            link.call("_acpmux/sessions", params, CALL_TIMEOUT).map_err(link_error)
        }
        "mobile-chat-history" => {
            let session = required_text(&params, "session_id")?;
            let mut request = Map::new();
            request.insert("sessionId".into(), Value::String(session));
            for (mobile, wire) in [
                ("after_seq", "afterSeq"),
                ("before_seq", "beforeSeq"),
                ("limit", "limit"),
                ("kinds", "kinds"),
            ] {
                if let Some(value) = params.get(mobile) {
                    request.insert(wire.into(), value.clone());
                }
            }
            if let Some(limit) = request.get("limit").and_then(Value::as_u64) {
                if limit == 0 || limit > MAX_LIMIT {
                    return Err(("bad_request", "limit must be between 1 and 200".into()));
                }
            }
            link.call("_acpmux/attach", Value::Object(request), CALL_TIMEOUT).map_err(link_error)
        }
        "mobile-chat-send" => {
            let session = required_text(&params, "session_id")?;
            let text = required_text(&params, "text")?;
            if text.len() > MAX_TEXT_BYTES {
                return Err(("bad_request", "text exceeds 64 KiB".into()));
            }
            let prompt_id = required_text(&params, "prompt_id")?;
            if prompt_id.len() > 128
                || !prompt_id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
            {
                return Err((
                    "bad_request",
                    "prompt_id must contain only letters, numbers, '-' or '_'".into(),
                ));
            }
            link.send_ignoring_reply(
                "session/prompt",
                json!({
                    "sessionId": session,
                    "prompt": [{"type": "text", "text": text}],
                    "_meta": {"acpmux": {"promptId": prompt_id}},
                }),
            )
            .map_err(link_error)?;
            Ok(json!({"accepted": true, "prompt_id": prompt_id}))
        }
        _ => Err(("method_not_found", "unknown mobile chat command".into())),
    }
}

fn bounded_page_params(params: &Value) -> Result<Value, (&'static str, String)> {
    let mut result = Map::new();
    for key in ["limit", "cursor", "status"] {
        if let Some(value) = params.get(key) {
            result.insert(key.into(), value.clone());
        }
    }
    if let Some(limit) = result.get("limit").and_then(Value::as_u64) {
        if limit == 0 || limit > MAX_LIMIT {
            return Err(("bad_request", "limit must be between 1 and 200".into()));
        }
    }
    Ok(Value::Object(result))
}

fn required_text(params: &Value, key: &str) -> Result<String, (&'static str, String)> {
    params
        .get(key)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .map(str::to_owned)
        .ok_or(("bad_request", format!("{key} is required")))
}

fn link_error(error: LinkError) -> (&'static str, String) {
    match error {
        LinkError::Rpc(message, _) => ("acpmux_refused", message),
        LinkError::MethodNotFound(message) => ("unsupported", message),
        LinkError::Timeout => ("timeout", "acpmux did not answer in time".into()),
        LinkError::Busy => ("busy", "acpmux is busy".into()),
        LinkError::Closed => ("unavailable", "acpmux connection closed".into()),
        LinkError::BadList(message) => ("acpmux_invalid", message),
    }
}

fn refuse(writer: &MessageWriter, id: Option<Value>, code: &'static str, message: &str) -> bool {
    send_response(
        writer,
        Response {
            id,
            ok: false,
            data: None,
            error: Some(message.to_owned()),
            error_code: Some(code.to_owned()),
            error_delivery: None,
        },
    )
}
