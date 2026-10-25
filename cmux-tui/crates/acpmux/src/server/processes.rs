//! The background-process methods (`hub/processes.rs`,
//! docs/background-processes.md): `_acpmux/process/list {sessionId?}`,
//! `_acpmux/process/tail {processId, fromByte?, maxBytes?}` and
//! `_acpmux/process/kill {processId, sessionId?, signal?}` (a named chat must
//! be the process's),
//! `_acpmux/process/background {sessionId, toolCallId?}` (Ctrl-B), and the
//! `_acpmux/process_update {process}` notification.
//!
//! Routed before every other method (`chats.rs`), like the secret methods:
//! they never reach a peer, and they check their own callers. Only this
//! machine's clients (the unix socket and the local app) get them: a
//! process's command line and output are local state, and a kill acts on
//! a local process (and Ctrl-B moves one), so a remote WebSocket device and
//! a peer daemon are refused before anything is read.

use super::{Conn, HubEvent, str_param};
use crate::hub::Hub;
use crate::protocol::process::ProcessBackgroundParams;
use crate::rpc::{Message, RpcError, method};
use serde_json::{Value, json};
use std::sync::Arc;
use std::sync::atomic::Ordering;

/// The reply to a process method, or None for any other method.
pub(super) async fn dispatch(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    params: &Value,
) -> Option<Result<Value, RpcError>> {
    if !matches!(
        m,
        method::MUX_PROCESS_LIST
            | method::MUX_PROCESS_TAIL
            | method::MUX_PROCESS_KILL
            | method::MUX_PROCESS_BACKGROUND
    ) {
        return None;
    }
    if conn.origin.web_class() {
        return Some(Err(RpcError::method_not_found(&format!(
            "{m} (not served to a remote WebSocket connection or a peer)"
        ))));
    }
    Some(handle(hub, m, params).await)
}

async fn handle(hub: &Arc<Hub>, m: &str, params: &Value) -> Result<Value, RpcError> {
    if m == method::MUX_PROCESS_LIST {
        return match params.get("sessionId").filter(|v| !v.is_null()) {
            None => Ok(hub.list_processes(None)),
            Some(key) => {
                let key = key
                    .as_str()
                    .ok_or_else(|| RpcError::invalid_params("sessionId must be a string"))?;
                let session = hub.resolve(key)?;
                Ok(hub.list_processes(Some(&*session)))
            }
        };
    }
    if m == method::MUX_PROCESS_BACKGROUND {
        let p: ProcessBackgroundParams = serde_json::from_value(params.clone())
            .map_err(|e| RpcError::invalid_params(format!("bad params: {e}")))?;
        return hub.background_work(&p.session_id, p.tool_call_id.as_deref()).await;
    }
    let id = str_param(params, "processId")
        .ok_or_else(|| RpcError::invalid_params("processId is required"))?;
    if m == method::MUX_PROCESS_TAIL {
        let from = byte_param(params, "fromByte")?;
        let max = byte_param(params, "maxBytes")?;
        return hub.tail_process(id, from, max).await;
    }
    // Claude Code's stop_task has no signal: both stop the task.
    match params.get("signal").filter(|v| !v.is_null()) {
        None => {}
        Some(signal) if matches!(signal.as_str(), Some("term" | "kill")) => {}
        Some(_) => return Err(RpcError::invalid_params("signal must be term or kill")),
    }
    // A kill that names its chat (the agent pane's, whose host lets it name only a chat in the
    // pane's scope) stops only a process of that chat.
    if let Some(key) = params.get("sessionId").filter(|v| !v.is_null()) {
        let key =
            key.as_str().ok_or_else(|| RpcError::invalid_params("sessionId must be a string"))?;
        let session = hub.resolve(key)?;
        if id.split_once('/').map(|(sid, _)| sid) != Some(session.id.as_str()) {
            return Err(RpcError::invalid_params("processId is not a process of sessionId")
                .with_data(json!({"reason": "process.other_session"})));
        }
    }
    hub.kill_process(id).await
}

/// A byte count or offset: absent, null or a non-negative integer.
fn byte_param(params: &Value, key: &str) -> Result<Option<u64>, RpcError> {
    match params.get(key).filter(|v| !v.is_null()) {
        None => Ok(None),
        Some(v) => v
            .as_u64()
            .map(Some)
            .ok_or_else(|| RpcError::invalid_params(format!("{key} must be a byte count"))),
    }
}

/// A logged `process_update` as `_acpmux/process_update`, to a connection
/// attached to its session or watching every session, never to a remote
/// WebSocket device or a peer.
pub(super) fn push_update(conn: &Conn, ev: &HubEvent) {
    let rec = &ev.record;
    if rec.dir != "mux" || rec.kind != "process_update" || ev.remote.is_some() {
        return;
    }
    if conn.origin.web_class() {
        return;
    }
    if !conn.watch_all.load(Ordering::SeqCst) && conn.sub_opts(&ev.session_id).is_none() {
        return;
    }
    let process = rec.msg.get("process").cloned().unwrap_or(Value::Null);
    conn.send(&Message::notification(method::MUX_PROCESS_UPDATE, json!({"process": process})));
}
