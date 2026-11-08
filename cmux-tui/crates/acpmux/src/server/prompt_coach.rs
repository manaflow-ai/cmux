//! `_acpmux/prompt_coach {sessionId, coachId}`: the chat page that shows a chat's prompt coach
//! offer asks for its rewrite (`hub/prompt_coach.rs`), answering `{made}` once the `coach` record
//! is logged or there is nothing to make. Only a person's view asks, here or through a peer link
//! that proved the person: a chat's own agent and another agent are refused, so no agent spends
//! a model call through it.

use super::{Conn, str_param};
use crate::hub::Hub;
use crate::rpc::{RpcError, method};
use serde_json::Value;
use std::sync::Arc;

/// The reply to `prompt_coach`, or None for any other method.
pub(super) async fn dispatch(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    params: &Value,
) -> Option<Result<Value, RpcError>> {
    if m != method::MUX_PROMPT_COACH {
        return None;
    }
    // The person at the app, a paired phone, or a peer link forwarding a request its own daemon
    // proved the person's (`remote_guard::PERSON_PROVEN`).
    if !super::requests::person_asks(conn) && !super::requests::person_admitted(conn, params) {
        return Some(Err(RpcError::invalid_params("only a person's view asks for the rewrite")));
    }
    Some(handle(hub, params).await)
}

async fn handle(hub: &Arc<Hub>, params: &Value) -> Result<Value, RpcError> {
    let key = str_param(params, "sessionId")
        .ok_or_else(|| RpcError::invalid_params("sessionId is required"))?;
    let session = hub.resolve(key)?;
    let coach = str_param(params, "coachId")
        .ok_or_else(|| RpcError::invalid_params("coachId is required"))?;
    hub.prompt_coach(&session, coach).await
}
