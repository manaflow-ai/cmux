//! `_acpmux/status_line {sessionId}`: the chat page asks for the person's own status line under
//! the chat's prompt (`hub/status_line.rs`), answering `{line}`. Only a person's view asks, here or
//! through a peer link that proved the person: an agent never makes acpmux run the command.

use super::{Conn, str_param};
use crate::hub::Hub;
use crate::rpc::{RpcError, method};
use serde_json::Value;
use std::sync::Arc;

/// The reply to `status_line`, or None for any other method.
pub(super) async fn dispatch(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    params: &Value,
) -> Option<Result<Value, RpcError>> {
    if m != method::MUX_STATUS_LINE {
        return None;
    }
    if !super::requests::person_asks(conn) && !super::requests::person_admitted(conn, params) {
        return Some(Err(RpcError::invalid_params(
            "only a person's view asks for the status line",
        )));
    }
    Some(handle(hub, params).await)
}

async fn handle(hub: &Arc<Hub>, params: &Value) -> Result<Value, RpcError> {
    let key = str_param(params, "sessionId")
        .ok_or_else(|| RpcError::invalid_params("sessionId is required"))?;
    let session = hub.resolve(key)?;
    hub.status_line(&session).await
}
