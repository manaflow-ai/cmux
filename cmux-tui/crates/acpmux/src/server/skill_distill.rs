//! `_acpmux/skill_resolve {sessionId, offerId, action, name?, description?, body?}`: the person's
//! Save or Not now on a chat's skill offer (`hub/skill_distill.rs`), answering `{offerId, action,
//! name?, path?}`. Only the person writes a skill into their skills folder: a chat's own agent,
//! another agent, a peer and a remote WebSocket device are refused.

use super::{Conn, str_param};
use crate::hub::Hub;
use crate::rpc::{RpcError, method};
use serde_json::Value;
use std::sync::Arc;

/// The reply to `skill_resolve`, or None for any other method.
pub(super) async fn dispatch(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    params: &Value,
) -> Option<Result<Value, RpcError>> {
    if m != method::MUX_SKILL_RESOLVE {
        return None;
    }
    if conn.origin.web_class() || !conn.is_person() {
        return Some(Err(RpcError::invalid_params(
            "only the person saves or dismisses a skill offer",
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
    let action = str_param(params, "action")
        .filter(|a| matches!(*a, "save" | "dismiss"))
        .ok_or_else(|| RpcError::invalid_params("action is save or dismiss"))?;
    let text = |key: &str| -> Result<Option<String>, RpcError> {
        match params.get(key) {
            None | Some(Value::Null) => Ok(None),
            Some(Value::String(s)) => Ok(Some(s.clone())),
            Some(_) => Err(RpcError::invalid_params(format!("{key} is a string"))),
        }
    };
    let edits = (text("name")?, text("description")?, text("body")?);
    hub.skill_resolve(&session, offer, action, edits).await
}
