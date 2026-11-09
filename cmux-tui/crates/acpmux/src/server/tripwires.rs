use super::{Conn, str_param};
use crate::hub::Hub;
use crate::rpc::{RpcError, method};
use serde_json::Value;
use std::sync::Arc;

/// Handles the structured declaration made by the agent that owns the current session.
pub(super) async fn dispatch(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    params: &Value,
) -> Option<Result<Value, RpcError>> {
    if m != method::MUX_TRIPWIRE_DECLARE {
        return None;
    }
    if conn.origin.web_class() {
        return Some(Err(RpcError::method_not_found(
            "tripwire declaration is not served to remote clients",
        )));
    }
    let Some(caller) = conn.caller() else {
        return Some(Err(RpcError::invalid_params(
            "tripwire declaration requires an agent session caller",
        )));
    };
    if !hub.resolve(caller).map(|session| session.meta().tripwire_enabled).unwrap_or(false) {
        return Some(Err(RpcError::invalid_params(
            "tripwires were not enabled for this plan build",
        )));
    }
    let requested = str_param(params, "sessionId").unwrap_or(caller);
    if requested != caller {
        return Some(Err(RpcError::invalid_params(
            "tripwire declaration may only update the calling session",
        )));
    }
    Some(hub.resolve(caller).and_then(|session| hub.declare_tripwires(&session, params)))
}
