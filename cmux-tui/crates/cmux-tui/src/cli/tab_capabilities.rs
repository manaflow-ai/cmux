//! Public clients understand conversation-backed tabs, including agent sessions
//! and app pages. Declare that before any reads on each fresh connection so the
//! daemon does not apply its browser compatibility projection.
use super::{resolve, wire};
use cmux_tui_core::platform::transport;
use serde_json::{Value, json};
use std::io::BufReader;

pub(super) fn negotiate(
    reader: &mut BufReader<Box<dyn transport::Stream>>,
) -> Result<(), resolve::Failure> {
    let id = wire::random_request_id()
        .map_err(|error| resolve::Failure::Transport(error.to_string()))?;
    let request = json!({"id":id,"cmd":"set-client-info","capabilities":[
        "conversation-tabs-v1","agent-session-tabs-v1","page-tabs-v1"
    ]});
    let bytes = resolve::encode_request_bytes(&request).map_err(resolve::Failure::Transport)?;
    resolve::send(reader, &bytes).map_err(resolve::Failure::Transport)?;
    let response = wire::read_envelope(reader, false)
        .map_err(resolve::Failure::Transport)?
        .ok_or_else(|| {
            resolve::Failure::Transport(
                "transport closed before client capabilities response".into(),
            )
        })?;
    if response["type"] == "refused" {
        return Err(resolve::Failure::Resource(json!({"code":"session.busy",
            "message":"session is busy","details":{},"retryable":true})));
    }
    // A not-yet-ready daemon may reject any request with the normal v2 error.
    if response["protocol"] == cmux_tui_core::resource::PROTOCOL && response["ok"] == false {
        let error: cmux_tui_core::resource::ResponseEnvelope = serde_json::from_value(response)
            .map_err(|error| resolve::Failure::Transport(format!("protocol error: {error}")))?;
        error.validate().map_err(|error| resolve::Failure::Transport(error.message))?;
        return Err(resolve::Failure::Resource(
            serde_json::to_value(error.error).unwrap_or(Value::Null),
        ));
    }
    if response["id"] != id || response["ok"] != true {
        return Err(resolve::Failure::Transport(
            "protocol error: invalid client capabilities response".into(),
        ));
    }
    Ok(())
}
