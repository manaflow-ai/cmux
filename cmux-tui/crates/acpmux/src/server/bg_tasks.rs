//! The background-task methods (`hub/bg_tasks.rs`, docs/hibernation.md):
//! `_acpmux/bg/start {sessionId, command, cwd?}`, `_acpmux/bg/list {sessionId}`,
//! `_acpmux/bg/output {sessionId, id, fromByte?, maxBytes?}` and `_acpmux/bg/stop {sessionId, id}`.
//!
//! Like the process methods (`processes.rs`) they are local: a task's command line, output and
//! stop never leave the machine, so a remote WebSocket device and a peer are refused. Only the
//! chat's own agent (a connection that proved it runs in that chat, `hub/person.rs` (a): the
//! `acpmux` MCP server) and the person reach a chat's tasks.

use super::{Conn, str_param};
use crate::hub::Hub;
use crate::rpc::{RpcError, method};
use serde_json::Value;
use std::sync::Arc;

/// The reply to a background-task method, or None for any other method.
pub(super) async fn dispatch(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    params: &Value,
) -> Option<Result<Value, RpcError>> {
    if !matches!(
        m,
        method::MUX_BG_START | method::MUX_BG_LIST | method::MUX_BG_OUTPUT | method::MUX_BG_STOP
    ) {
        return None;
    }
    if conn.origin.web_class() {
        return Some(Err(RpcError::method_not_found(&format!(
            "{m} (not served to a remote WebSocket connection or a peer)"
        ))));
    }
    Some(handle(hub, conn, m, params).await)
}

async fn handle(hub: &Arc<Hub>, conn: &Conn, m: &str, params: &Value) -> Result<Value, RpcError> {
    let key = str_param(params, "sessionId")
        .ok_or_else(|| RpcError::invalid_params("sessionId is required"))?;
    let session = hub.resolve(key)?;
    // The chat's own agent (its proven caller token) or the person; nothing else.
    if conn.caller() != Some(session.id.as_str()) && !conn.is_person() {
        return Err(RpcError::invalid_params("a chat reaches only its own background tasks"));
    }
    let byte = |k: &str| match params.get(k).filter(|v| !v.is_null()) {
        None => Ok(None),
        Some(v) => v
            .as_u64()
            .map(Some)
            .ok_or_else(|| RpcError::invalid_params(format!("{k} must be a byte count"))),
    };
    let id = || str_param(params, "id").ok_or_else(|| RpcError::invalid_params("id is required"));
    match m {
        method::MUX_BG_START => {
            let command = str_param(params, "command")
                .ok_or_else(|| RpcError::invalid_params("command is required"))?;
            let cwd = str_param(params, "cwd").filter(|c| !c.is_empty()).map(Into::into);
            hub.bg_start(&session, command, cwd).await
        }
        method::MUX_BG_LIST => Ok(hub.bg_list(&session)),
        method::MUX_BG_OUTPUT => {
            hub.bg_output(&session, id()?, byte("fromByte")?, byte("maxBytes")?)
        }
        _ => hub.bg_stop(&session, id()?).await,
    }
}
