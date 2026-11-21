//! The MCP connect methods (`hub/mcp_connect.rs`), routed with the secret methods before peer
//! forwarding: a card belongs to the daemon whose chat asked. The unix socket asks; only the
//! person answers.

use super::{Conn, Origin, str_param};
use crate::hub::Hub;
use crate::rpc::{RpcError, method};
use serde_json::{Value, json};
use std::sync::Arc;

/// The reply to an MCP connect method, or None for any other method.
pub(super) async fn dispatch(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    params: &Value,
) -> Option<Result<Value, RpcError>> {
    if !matches!(m, method::MUX_MCP_CONNECT_REQUEST | method::MUX_MCP_CONNECT_ANSWER) {
        return None;
    }
    Some(handle(hub, conn, m, params).await)
}

async fn handle(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    params: &Value,
) -> Result<Value, RpcError> {
    let key = str_param(params, "sessionId")
        .ok_or_else(|| RpcError::invalid_params("sessionId is required"))?;
    let session = hub.resolve(key)?;
    if m == method::MUX_MCP_CONNECT_ANSWER {
        // The card is the person's: never the agent that asked (T1, T2).
        if !conn.is_person() {
            return Err(crate::hub::person::person_required("answering an MCP connect card"));
        }
        let id = str_param(params, "requestId")
            .ok_or_else(|| RpcError::invalid_params("requestId is required"))?;
        let approve = params.get("approve").and_then(Value::as_bool).unwrap_or(false);
        // A key typed into the card's secure field: held in memory for the connect only.
        let typed = params
            .get("key")
            .and_then(Value::as_str)
            .filter(|k| !k.is_empty())
            .map(|k| zeroize::Zeroizing::new(k.to_owned()));
        hub.answer_mcp_connect(&session, id, approve, str_param(params, "scope"), typed)?;
        return Ok(json!({}));
    }
    if conn.origin != Origin::Local {
        return Err(RpcError::invalid_params(
            "asking to connect an MCP server is accepted only over the local unix socket",
        ));
    }
    let server = str_param(params, "server").ok_or_else(|| {
        RpcError::invalid_params("server is required: a name, an https URL or a command")
    })?;
    let scope = str_param(params, "scope").unwrap_or("chat");
    let reason = str_param(params, "reason").unwrap_or_default();
    hub.request_mcp_connect(&session, server, scope, reason).await
}
