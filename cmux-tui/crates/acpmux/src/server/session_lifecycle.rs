//! Explicit completion and wake intent. Kept local, like the goal controls.
use super::*;

pub(super) fn dispatch(
    hub: &Arc<Hub>,
    conn: &Conn,
    method: &str,
    params: &Value,
) -> Option<Result<Value, RpcError>> {
    if method != crate::hub::finished::METHOD {
        return None;
    }
    Some(handle(hub, conn, params))
}

fn handle(hub: &Arc<Hub>, conn: &Conn, params: &Value) -> Result<Value, RpcError> {
    if conn.origin.web_class() || (!conn.is_person() && conn.caller().is_none()) {
        return Err(RpcError::invalid_params("session lifecycle requires a local proven caller"));
    }
    if let Some(op @ ("pause" | "resume")) = str_param(params, "op") {
        let reason = str_param(params, "reason").unwrap_or("");
        return hub.set_fleet_pause(op == "pause", reason);
    }
    let key = str_param(params, "sessionId")
        .ok_or_else(|| RpcError::invalid_params("sessionId is required"))?;
    let session = hub.resolve(key)?;
    match str_param(params, "op") {
        Some("finish") => {
            if !conn.is_person() && conn.caller() != Some(session.id.as_str()) {
                return Err(RpcError::invalid_params("an agent may finish only its own session"));
            }
            let handoff = str_param(params, "handoff")
                .filter(|s| !s.trim().is_empty())
                .ok_or_else(|| RpcError::invalid_params("finish requires a handoff"))?;
            hub.finish_session(&session, handoff)
        }
        Some("wake") => {
            let reason = str_param(params, "reason")
                .ok_or_else(|| RpcError::invalid_params("wake requires a reason"))?;
            hub.wake_finished(&session, reason)
        }
        _ => Err(RpcError::invalid_params("op must be finish or wake")),
    }
}
