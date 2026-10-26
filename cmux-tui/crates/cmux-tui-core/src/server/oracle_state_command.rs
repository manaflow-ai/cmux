//! The `oracle-state` request line (`crate::oracle_state`, spec/commands.md).
//!
//! It is answered before the `Command` parse, as `script-*` and `loopback-*`
//! lines are, so the command is not in the `Command` enum, its name table or
//! the SDK catalog. The module exists only in debug and `--features oracle`
//! builds; a release daemon answers the line as an unknown command. Remote
//! clients never reach it (`remote_relay::handle_frame` takes their frames
//! first), and only the trusted local connection gets a reply.

use std::sync::Arc;

use serde_json::Value;

use super::{MessageWriter, Response, send_request_error, send_response};
use crate::Mux;

/// The request's `cmd`.
pub(super) const COMMAND: &str = "oracle-state";

/// Answer an `oracle-state` line; `None` for any other line.
pub(super) fn try_handle(
    mux: &Arc<Mux>,
    client: u64,
    message: &str,
    writer: &MessageWriter,
) -> Option<bool> {
    if !message.contains(COMMAND) {
        return None;
    }
    let Ok(Value::Object(mut request)) = serde_json::from_str::<Value>(message) else {
        return None;
    };
    if request.get("cmd").and_then(Value::as_str) != Some(COMMAND) {
        return None;
    }
    let id = request.remove("id");
    request.remove("cmd");
    let reply = match request.keys().next() {
        Some(field) => Err(anyhow::anyhow!("bad request: oracle-state takes no field {field:?}")),
        None => answer(mux, client),
    };
    Some(match reply {
        Ok(data) => send_response(
            writer,
            Response {
                id,
                ok: true,
                data: Some(data),
                error: None,
                error_code: None,
                error_delivery: None,
            },
        ),
        Err(error) => send_request_error(writer, id, &error.to_string()),
    })
}

fn answer(mux: &Mux, client: u64) -> anyhow::Result<Value> {
    if !mux.control_clients.is_unix(client) {
        anyhow::bail!("oracle state requires a trusted local connection");
    }
    let state = crate::oracle_state::oracle_state(mux, client)?;
    Ok(serde_json::to_value(state)?)
}

#[cfg(test)]
#[path = "oracle_state_command_tests.rs"]
mod tests;
