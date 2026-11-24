use cmux_remote_protocol::RelayControl;
use worker::{Response, WebSocket, WebSocketIncomingMessage};

pub(crate) const MAX_CONTROL_MESSAGE_BYTES: usize = 4 * 1024;

pub(crate) fn decode_control(
    message: WebSocketIncomingMessage,
) -> Result<RelayControl, &'static str> {
    let WebSocketIncomingMessage::String(text) = message else {
        return Err("expected a text control message");
    };
    if text.len() > MAX_CONTROL_MESSAGE_BYTES {
        return Err("control message is too large");
    }
    serde_json::from_str(&text).map_err(|_| "control message is invalid")
}

pub(crate) fn send_control(socket: &WebSocket, message: &RelayControl) -> worker::Result<()> {
    let encoded = serde_json::to_string(message)?;
    if encoded.len() > MAX_CONTROL_MESSAGE_BYTES {
        return Err(worker::Error::RustError("outbound relay control message is too large".into()));
    }
    socket.send_with_str(encoded)
}

pub(crate) fn close(socket: &WebSocket, code: u16, reason: &str) {
    let _ = socket.close(Some(code), Some(reason));
}

pub(crate) fn websocket_upgrade(request: &worker::Request) -> worker::Result<bool> {
    Ok(request
        .headers()
        .get("Upgrade")?
        .is_some_and(|value| value.eq_ignore_ascii_case("websocket")))
}

pub(crate) fn upgrade_required() -> worker::Result<Response> {
    Response::error("WebSocket upgrade required", 426)
}

pub(crate) fn valid_opaque_identifier(value: &str, maximum: usize) -> bool {
    !value.is_empty()
        && value.len() <= maximum
        && value.bytes().all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
}

pub(crate) fn valid_circuit_id(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

#[cfg(test)]
#[path = "wire_tests.rs"]
mod tests;
