//! The MCP connect methods (`hub/mcp_connect.rs`) and the connection methods (`hub/mcp_calls.rs`), routed with the secret methods before peer
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
    if matches!(m, method::MUX_MCP_CONNECT_REQUEST | method::MUX_MCP_CONNECT_ANSWER) {
        return Some(handle(hub, conn, m, params).await);
    }
    if matches!(
        m,
        method::MUX_MCP_TOOLS
            | method::MUX_MCP_CALL
            | method::MUX_MCP_WATCH
            | method::MUX_MCP_CONNECTIONS
            | method::MUX_MCP_CALL_ANSWER
            | method::MUX_MCP_POLICY
            | method::MUX_MCP_SET_KEY
            | method::MUX_MCP_SIGN_IN
            | method::MUX_MCP_REMOVE
            | method::MUX_MCP_AUDIT
    ) {
        return Some(connections(hub, conn, m, params).await);
    }
    None
}

/// How long `_acpmux/mcp_watch` holds before it answers the same version.
const WATCH_HOLD: std::time::Duration = std::time::Duration::from_secs(50);

/// The chat a connection's agent methods act for: the session the caller token proved
/// (`hub/person.rs` (a)), which must be the `sessionId` it names. A chat cannot read, call or
/// watch another chat's connections (T7).
fn caller_session(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    params: &Value,
) -> Result<Arc<crate::hub::Session>, RpcError> {
    let key = str_param(params, "sessionId")
        .ok_or_else(|| RpcError::invalid_params("sessionId is required"))?;
    let session = hub.resolve(key)?;
    if conn.origin != Origin::Local || conn.caller() != Some(session.id.as_str()) {
        return Err(RpcError::invalid_params(
            "MCP connections answer only the chat's own proxy (its caller token, on the unix socket)",
        ));
    }
    Ok(session)
}

async fn connections(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    params: &Value,
) -> Result<Value, RpcError> {
    match m {
        method::MUX_MCP_TOOLS => {
            let session = caller_session(hub, conn, params)?;
            Ok(hub.mcp_tools(&session))
        }
        method::MUX_MCP_CALL => {
            let session = caller_session(hub, conn, params)?;
            let name = str_param(params, "name")
                .ok_or_else(|| RpcError::invalid_params("name is required"))?;
            let arguments = params.get("arguments").cloned().unwrap_or_else(|| json!({}));
            Ok(hub.mcp_call(&session, name, arguments).await)
        }
        method::MUX_MCP_WATCH => {
            let session = caller_session(hub, conn, params)?;
            let seen = params.get("version").and_then(Value::as_u64).unwrap_or(0);
            let mut rx = hub.mcp_store.watch();
            let _ = tokio::time::timeout(WATCH_HOLD, rx.wait_for(|v| *v != seen)).await;
            drop(session);
            Ok(json!({"version": hub.mcp_store.version()}))
        }
        method::MUX_MCP_CONNECTIONS
            if conn.is_person() && str_param(params, "sessionId").is_none() =>
        {
            Ok(hub.mcp_connections_all())
        }
        method::MUX_MCP_CONNECTIONS => {
            let session = caller_session(hub, conn, params)?;
            Ok(hub.mcp_list_for(&session))
        }
        _ => {
            // Settings and cards: the person's only.
            if !conn.is_person() {
                return Err(crate::hub::person::person_required("changing MCP connections"));
            }
            let id = || {
                str_param(params, "id").ok_or_else(|| RpcError::invalid_params("id is required"))
            };
            match m {
                method::MUX_MCP_CALL_ANSWER => {
                    let key = str_param(params, "sessionId")
                        .ok_or_else(|| RpcError::invalid_params("sessionId is required"))?;
                    let session = hub.resolve(key)?;
                    let request = str_param(params, "requestId")
                        .ok_or_else(|| RpcError::invalid_params("requestId is required"))?;
                    let approve = params.get("approve").and_then(Value::as_bool).unwrap_or(false);
                    let always = params.get("always").and_then(Value::as_bool).unwrap_or(false);
                    hub.answer_mcp_call(&session, request, approve, always)?;
                    Ok(json!({}))
                }
                method::MUX_MCP_POLICY => hub.mcp_set_policy(
                    id()?,
                    str_param(params, "tool")
                        .ok_or_else(|| RpcError::invalid_params("tool is required"))?,
                    str_param(params, "policy").unwrap_or_default(),
                ),
                method::MUX_MCP_SET_KEY => {
                    let key = str_param(params, "key")
                        .map(|k| zeroize::Zeroizing::new(k.to_owned()))
                        .ok_or_else(|| RpcError::invalid_params("key is required"))?;
                    hub.mcp_set_key(id()?, key).await
                }
                method::MUX_MCP_SIGN_IN => hub.mcp_sign_in(id()?).await,
                method::MUX_MCP_REMOVE => hub.mcp_remove(id()?),
                method::MUX_MCP_AUDIT => {
                    Ok(hub.mcp_audit(
                        params.get("limit").and_then(Value::as_u64).unwrap_or(200) as usize
                    ))
                }
                _ => Err(RpcError::invalid_params("unknown MCP method")),
            }
        }
    }
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
