//! `_acpmux/memory_resolve {sessionId, offerId, file, accept, dismiss}`: the person's Accept or
//! Dismiss on a chat's memory offer (`hub/memory_inbox.rs`), answering `{file, accepted,
//! dismissed, wrote}`. Only the person writes a project's instructions file: a chat's own agent,
//! another agent, a peer and a remote WebSocket device are refused.

use super::{Conn, str_param};
use crate::hub::Hub;
use crate::rpc::{RpcError, method};
use serde_json::Value;
use std::sync::Arc;

/// The reply to `memory_resolve`, or None for any other method.
pub(super) async fn dispatch(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    params: &Value,
) -> Option<Result<Value, RpcError>> {
    if m != method::MUX_MEMORY_RESOLVE {
        return None;
    }
    if conn.origin.web_class() || !conn.is_person() {
        return Some(Err(RpcError::invalid_params(
            "only the person accepts or dismisses what a chat learned",
        )));
    }
    Some(handle(hub, params).await)
}

async fn handle(hub: &Arc<Hub>, params: &Value) -> Result<Value, RpcError> {
    let key = str_param(params, "sessionId")
        .ok_or_else(|| RpcError::invalid_params("sessionId is required"))?;
    let session = hub.resolve(key)?;
    let offer = str_param(params, "offerId")
        .ok_or_else(|| RpcError::invalid_params("offerId is required"))?;
    let file =
        str_param(params, "file").ok_or_else(|| RpcError::invalid_params("file is required"))?;
    let accept = facts(params, "accept")?;
    let dismiss = facts(params, "dismiss")?;
    if accept.is_empty() && dismiss.is_empty() {
        return Err(RpcError::invalid_params("accept or dismiss at least one fact"));
    }
    hub.memory_resolve(&session, offer, file, accept, dismiss).await
}

/// A list of at most three one-line facts, as offered.
fn facts(params: &Value, key: &str) -> Result<Vec<String>, RpcError> {
    let list = match params.get(key) {
        None | Some(Value::Null) => return Ok(Vec::new()),
        Some(Value::Array(list)) => list,
        Some(_) => return Err(RpcError::invalid_params(format!("{key} is a list of facts"))),
    };
    if list.len() > crate::acpmux_mcp::WRAP_UP_MAX_LEARNED {
        return Err(RpcError::invalid_params(format!("{key} has more facts than an offer")));
    }
    list.iter()
        .map(|v| {
            v.as_str()
                .map(str::trim)
                .filter(|f| {
                    !f.is_empty()
                        && !f.contains(['\n', '\r'])
                        && f.chars().count() <= crate::acpmux_mcp::WRAP_UP_MAX_FACT
                })
                .map(str::to_owned)
                .ok_or_else(|| RpcError::invalid_params(format!("{key} holds one-line facts")))
        })
        .collect()
}
