//! `_acpmux/history/read {sessionId, range? | seq? | compacted?, limit?, before?, offset?, fresh?}`
//! (`hub/compaction_outline.rs`): a chat's packed history read back as an outline, a range's
//! digest or one record by seq, for the `chat_history` MCP tool. Answers are bounded there.
//!
//! Like the goal and background-task methods it belongs to the chat's own agent (a connection
//! that proved it runs in that chat, `hub/person.rs` (a)) and the person; a remote WebSocket
//! device and a peer are refused. It reads the pack from disk, so it runs off the async threads.

use super::{Conn, str_param};
use crate::hub::Hub;
use crate::rpc::{RpcError, method};
use serde_json::Value;
use std::sync::Arc;

/// The reply to a history method, or None for any other method.
pub(super) async fn dispatch(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    params: &Value,
) -> Option<Result<Value, RpcError>> {
    if m != method::MUX_HISTORY_READ {
        return None;
    }
    if conn.origin.web_class() {
        return Some(Err(RpcError::method_not_found(&format!(
            "{m} (not served to a remote WebSocket connection or a peer)"
        ))));
    }
    Some(handle(hub, conn, params).await)
}

async fn handle(hub: &Arc<Hub>, conn: &Conn, params: &Value) -> Result<Value, RpcError> {
    let key = str_param(params, "sessionId")
        .ok_or_else(|| RpcError::invalid_params("sessionId is required"))?;
    let session = hub.resolve(key)?;
    if conn.caller() != Some(session.id.as_str()) && !conn.is_person() {
        return Err(RpcError::invalid_params("a chat reaches only its own history"));
    }
    let (hub, params) = (hub.clone(), params.clone());
    tokio::task::spawn_blocking(move || hub.history_read(&session, &params))
        .await
        .map_err(|e| RpcError::internal(format!("history: {e}")))?
}
