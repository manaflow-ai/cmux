//! Public clients understand conversation-backed tabs, including agent sessions
//! and app pages. Declare that before any reads on each fresh connection so the
//! daemon does not apply its browser compatibility projection.
//!
//! They also keep a `session.events` cursor whole, so they ask for its live
//! position (`session-live-cursor-v1`): a resume (`agents events --after`,
//! the wait of `agent start`) then gets only the terminals whose live facts
//! changed after the cursor, not every terminal that has one. A daemon
//! without the capability ignores the name and sends cursors with no `live`.
use super::{resolve, wire};
use cmux_tui_core::platform::transport;
use serde_json::{Value, json};
use std::io::BufReader;

/// What each CLI connection sends in `set-client-info`.
pub(super) const CAPABILITIES: [&str; 5] = [
    "conversation-tabs-v1",
    "agent-session-tabs-v1",
    "page-tabs-v1",
    "closed-conversation-tabs-v1",
    cmux_tui_core::server::SESSION_LIVE_CURSOR_CAPABILITY,
];

pub(super) fn negotiate(
    reader: &mut BufReader<Box<dyn transport::Stream>>,
) -> Result<(), resolve::Failure> {
    let id = wire::random_request_id()
        .map_err(|error| resolve::Failure::Transport(error.to_string()))?;
    let request = json!({"id":id,"cmd":"set-client-info","capabilities":CAPABILITIES});
    let bytes = resolve::encode_request_bytes(&request).map_err(resolve::Failure::Transport)?;
    resolve::send_request(reader, &bytes)?;
    let response = wire::read_envelope(reader, false)
        .map_err(resolve::Failure::Transport)?
        .ok_or_else(|| {
            resolve::Failure::Transport(
                "transport closed before client capabilities response".into(),
            )
        })?;
    if response.get("type").and_then(Value::as_str) == Some("refused") {
        return Err(resolve::Failure::Refused);
    }
    // A daemon that is not ready can refuse every frame with the normal v2
    // resource error. Preserve that error; it is not an unsupported hello.
    if response.get("protocol").and_then(Value::as_str) == Some(cmux_tui_core::resource::PROTOCOL) {
        let reply: cmux_tui_core::resource::ResponseEnvelope = serde_json::from_value(response)
            .map_err(|error| resolve::Failure::Transport(format!("protocol error: {error}")))?;
        reply.validate().map_err(|error| resolve::Failure::Transport(error.message))?;
        if reply.id.as_str() != id {
            return Err(resolve::Failure::Transport(
                "protocol error: client capabilities response id mismatch".into(),
            ));
        }
        if let Some(error) = reply.error {
            return Err(resolve::Failure::Resource(
                serde_json::to_value(error).unwrap_or(Value::Null),
            ));
        }
        return Err(resolve::Failure::Transport(
            "protocol error: expected raw client capabilities response".into(),
        ));
    }
    // Neither a cmux.protocol/2 envelope nor the raw answer to this hello (its id, a
    // boolean `ok`): a server that speaks another protocol, an older cmux or another
    // program. The same error as the request path's (`wire.rs`, `protocol.mismatch`, not
    // retryable, exit 3), not a bare "invalid response" (cx-fud2vx).
    if response.get("id").and_then(Value::as_str) != Some(id.as_str())
        || !response.get("ok").is_some_and(Value::is_boolean)
    {
        let message = crate::localization::catalog().cli_connection.wrong_protocol();
        return Err(resolve::Failure::Local {
            error: json!({
                "code": "protocol.mismatch",
                "message": format!("protocol error: {message}"),
                "details": {},
                "retryable": false,
            }),
            exit: 3,
        });
    }
    // An older daemon may reject this optional hello. Its ordinary resource
    // operations remain usable with the existing browser compatibility view.
    Ok(())
}
