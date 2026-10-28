//! The agent tool servers this daemon serves on its own socket
//! (p07-memory-092, `subsession_mcp::DaemonTools`): a unix connection whose
//! first `initialize` carries a caller token that proves its session
//! (`hub/person.rs` (a)) and names a server ([`SERVER_FIELD`]) is that
//! session's MCP server for its whole life. Every later line is MCP
//! (`initialize`, `ping`, `tools/list`, `tools/call`), never ACP; the tools
//! act as the proven session only, through the same request router as any
//! other connection (`chats::route`), so each tool keeps its own checks. A
//! token that proves no session, or another session's, is refused at that
//! first request.

use super::{Conn, chats};
use crate::hub::Hub;
use crate::no_panic::JsonExt;
use crate::rpc::{RpcError, method};
use crate::subsession_mcp::{DaemonTools, SERVER_FIELD, ToolRequests};
use serde_json::{Value, json};
use std::future::Future;
use std::sync::Arc;

/// The MCP protocol version when the client names none.
const PROTOCOL_VERSION: &str = "2025-06-18";

/// Remove [`SERVER_FIELD`] from a request's params and return it. Only a
/// first unix `initialize` is read (`server/mod.rs`); everywhere else it is
/// dropped unread.
pub(super) fn take_server(params: &mut Value) -> Option<String> {
    let taken = params
        .pointer_mut("/_meta/acpmux")
        .and_then(Value::as_object_mut)
        .and_then(|meta| meta.remove(SERVER_FIELD))?;
    taken.as_str().map(str::to_owned)
}

/// The tool set a first `initialize` naming `server` attaches, when the
/// connection proved its session (`Conn::bind_person` ran first).
pub(super) fn attach(conn: &Conn, server: &str) -> Result<DaemonTools, RpcError> {
    let tools = DaemonTools::from_server_name(server).ok_or_else(|| {
        RpcError::invalid_params(format!("this daemon serves no agent tool server {server}"))
            .with_data(json!({"reason": "agentTools.unknown_server"}))
    })?;
    if conn.caller().is_some() {
        return Ok(tools);
    }
    let named = conn
        .unproven_caller
        .get()
        .map_or_else(|| "no session".to_owned(), |session| format!("session {session}"));
    Err(RpcError::new(
        -32000,
        format!(
            "{server}: the caller token does not prove {named} on this daemon, which serves an agent's tools only to that agent's own token (acpmux session restart gives the session a new one)"
        ),
    )
    .with_data(json!({"reason": "agentTools.caller_required"})))
}

/// The MCP `initialize` result of `tools`.
pub(super) fn initialize(tools: DaemonTools, params: &Value) -> Value {
    let version = params["protocolVersion"].as_str().unwrap_or(PROTOCOL_VERSION);
    let mut reply = json!({
        "protocolVersion": version,
        "capabilities": {"tools": {}},
        "serverInfo": {"name": tools.server_name(), "version": env!("CARGO_PKG_VERSION")},
    });
    if let Some(text) = tools.instructions() {
        reply.set("instructions", json!(text));
    }
    reply
}

/// One MCP request on an attached connection.
pub(super) async fn handle(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    tools: DaemonTools,
    m: &str,
    params: Value,
) -> Result<Value, RpcError> {
    match m {
        method::INITIALIZE => Ok(initialize(tools, &params)),
        "ping" => Ok(json!({})),
        "tools/list" => Ok(json!({"tools": tools.tools()})),
        "tools/call" => {
            // Attached only once proven (`attach`), so always set here.
            let session = conn.caller().ok_or_else(|| RpcError::internal("no proven caller"))?;
            Ok(tools.call(&InDaemon { hub, conn }, session, &params).await)
        }
        other => Err(RpcError::method_not_found(other)),
    }
}

/// The tools' daemon requests, routed in this process as this connection's.
struct InDaemon<'a> {
    hub: &'a Arc<Hub>,
    conn: &'a Arc<Conn>,
}

impl ToolRequests for InDaemon<'_> {
    fn request(
        &self,
        m: &'static str,
        mut params: Value,
    ) -> impl Future<Output = anyhow::Result<Value>> + Send {
        // What the wire strips from every request (`Conn::bind_person`): tool
        // arguments never carry a person key, a caller or a server name.
        let _ = crate::hub::person::take_key(&mut params);
        let _ = crate::hub::person::take_caller(&mut params);
        let _ = take_server(&mut params);
        async move {
            chats::route(self.hub, self.conn, m, params)
                .await
                .map_err(|e| anyhow::Error::new(crate::client::DaemonError(e)))
        }
    }
}
