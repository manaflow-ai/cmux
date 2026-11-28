//! Parked waits (`parked_wait.rs`): `_acpmux/wait/park {sessionId, toolCallId, wakeAt}` hands a
//! chat's tool call's wait to the platform, and `_acpmux/wait/unpark {sessionId, toolCallId}`
//! takes it back. Local only, like the background-task methods: a remote WebSocket device and a
//! peer are refused, and only the chat's own agent (its proven caller token, which its Bash
//! calls carry) or the person park its calls.

use super::{Conn, str_param};
use crate::hub::Hub;
use crate::parked_wait::{ParkedWait, PlatformWaits as _, Wake};
use crate::rpc::{RpcError, method};
use serde_json::{Value, json};
use std::sync::Arc;

/// The reply to a parked-wait method, or None for any other method.
pub(super) fn dispatch(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    params: &Value,
) -> Option<Result<Value, RpcError>> {
    if !matches!(m, method::MUX_WAIT_PARK | method::MUX_WAIT_UNPARK) {
        return None;
    }
    if conn.origin.web_class() {
        return Some(Err(RpcError::method_not_found(&format!(
            "{m} (not served to a remote WebSocket connection or a peer)"
        ))));
    }
    Some(handle(hub, conn, m, params))
}

fn handle(hub: &Hub, conn: &Conn, m: &str, params: &Value) -> Result<Value, RpcError> {
    let key = str_param(params, "sessionId")
        .ok_or_else(|| RpcError::invalid_params("sessionId is required"))?;
    let session = hub.resolve(key)?;
    if conn.caller() != Some(session.id.as_str()) && !conn.is_person() {
        return Err(RpcError::invalid_params("a chat parks only its own tool calls"));
    }
    let call = str_param(params, "toolCallId")
        .filter(|c| !c.is_empty())
        .ok_or_else(|| RpcError::invalid_params("toolCallId is required"))?;
    if m == method::MUX_WAIT_UNPARK {
        hub.parked.unpark(&session.id, call);
        return Ok(json!({}));
    }
    let at_ms = params
        .get("wakeAt")
        .and_then(Value::as_u64)
        .ok_or_else(|| RpcError::invalid_params("wakeAt (Unix ms) is required"))?;
    let session = session.id.clone();
    hub.parked.park(ParkedWait { session, call: call.to_owned(), wake: Wake::Timer { at_ms } });
    Ok(json!({}))
}
