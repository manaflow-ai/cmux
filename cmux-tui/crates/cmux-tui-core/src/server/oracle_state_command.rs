//! The `oracle-state` and `oracle-restore-preview` request lines
//! (`crate::oracle_state`, spec/commands.md).
//!
//! They are answered before the `Command` parse, as `script-*` and
//! `loopback-*` lines are, so the commands are not in the `Command` enum, its
//! name table or the SDK catalog. The module exists only in debug and
//! `--features oracle` builds; a release daemon answers the lines as unknown
//! commands. Remote clients never reach it (`remote_relay::handle_frame`
//! takes their frames first), and only the trusted local connection gets a
//! reply.

use std::sync::Arc;

use serde_json::{Map, Value};

use super::{MessageWriter, Response, send_request_error, send_response};
use crate::Mux;

/// The daemon facet extras' `cmd`.
pub(super) const COMMAND: &str = "oracle-state";
/// The journal restore preview's `cmd` (invariant I9, p15-oracle task 205).
pub(super) const RESTORE_PREVIEW: &str = "oracle-restore-preview";
const COMMANDS: [&str; 2] = [COMMAND, RESTORE_PREVIEW];

/// The `cmd` names this module answers (server/routes.rs).
pub(in crate::server) const ROUTES: &[crate::server::routes::Route] =
    &[crate::server::routes::Route {
        names: &[crate::server::routes::RouteName::OneOf(&COMMANDS)],
        stage: crate::server::FrameStage::Route,
        entry: |line| try_handle(line.mux, line.client, line.message, line.writer),
    }];

/// Answer an `oracle-state` or `oracle-restore-preview` line; `None` for any
/// other line.
pub(super) fn try_handle(
    mux: &Arc<Mux>,
    client: u64,
    message: &str,
    writer: &MessageWriter,
) -> Option<bool> {
    if !message.contains("oracle-") {
        return None;
    }
    let Ok(Value::Object(mut request)) = crate::line_parses::parse::<Value>(message) else {
        return None;
    };
    let command = COMMANDS
        .into_iter()
        .find(|command| request.get("cmd").and_then(Value::as_str) == Some(*command))?;
    let id = request.remove("id");
    request.remove("cmd");
    let reply = if mux.control_clients.is_unix(client) {
        answer(mux, client, command, request)
    } else {
        Err(anyhow::anyhow!("oracle state requires a trusted local connection"))
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

fn answer(
    mux: &Mux,
    client: u64,
    command: &str,
    mut fields: Map<String, Value>,
) -> anyhow::Result<Value> {
    if command == COMMAND {
        if let Some(field) = fields.keys().next() {
            anyhow::bail!("bad request: {COMMAND} takes no field {field:?}");
        }
        return Ok(serde_json::to_value(crate::oracle_state::oracle_state(mux, client)?)?);
    }
    let selector = match fields.remove("checkpoint") {
        None => "latest".to_string(),
        Some(Value::String(selector)) if !selector.is_empty() => selector,
        Some(_) => anyhow::bail!("bad request: {RESTORE_PREVIEW} checkpoint must be a string"),
    };
    let through = match fields.remove("through") {
        None => None,
        Some(Value::Number(through)) if through.as_u64().is_some() => through.as_u64(),
        Some(_) => anyhow::bail!("bad request: {RESTORE_PREVIEW} through must be a sequence"),
    };
    if let Some(field) = fields.keys().next() {
        anyhow::bail!("bad request: {RESTORE_PREVIEW} takes no field {field:?}");
    }
    let reply = crate::oracle_state::oracle_restore_preview(mux, &selector, through)?;
    Ok(serde_json::to_value(reply)?)
}

#[cfg(test)]
#[path = "oracle_state_command_tests.rs"]
mod tests;
