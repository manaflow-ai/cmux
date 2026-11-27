//! The scheduled-prompt methods (`hub/prompt_schedule.rs`): `_acpmux/schedule/set {sessionId,
//! prompt, everyMinutes | at | idle, maxRuns?, until?}`, `_acpmux/schedule/pause {sessionId,
//! paused}`, `_acpmux/schedule/clear {sessionId}` and `_acpmux/schedule/get {sessionId}`, each
//! answering the schedule (`PromptSchedule::to_value`, null for none; clear answers `{cleared}`).
//!
//! Like the goal methods (`goal.rs`) they belong to the person and the chat's own agent; a remote
//! WebSocket device and a peer are refused, since a schedule sends prompts on its own later.

use super::{Conn, str_param};
use crate::hub::Hub;
use crate::rpc::{RpcError, method};
use serde_json::{Value, json};
use std::sync::Arc;

/// The reply to a schedule method, or None for any other method.
pub(super) async fn dispatch(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    params: &Value,
) -> Option<Result<Value, RpcError>> {
    if !matches!(
        m,
        method::MUX_SCHEDULE_SET
            | method::MUX_SCHEDULE_PAUSE
            | method::MUX_SCHEDULE_CLEAR
            | method::MUX_SCHEDULE_GET
    ) {
        return None;
    }
    if conn.origin.web_class() {
        return Some(Err(RpcError::method_not_found(&format!(
            "{m} (not served to a remote WebSocket connection or a peer)"
        ))));
    }
    Some(handle(hub, conn, m, params).await)
}

async fn handle(hub: &Arc<Hub>, conn: &Conn, m: &str, params: &Value) -> Result<Value, RpcError> {
    let key = str_param(params, "sessionId")
        .ok_or_else(|| RpcError::invalid_params("sessionId is required"))?;
    let session = hub.resolve(key)?;
    if conn.caller() != Some(session.id.as_str()) && !conn.is_person() {
        return Err(RpcError::invalid_params("a chat reaches only its own schedule"));
    }
    match m {
        method::MUX_SCHEDULE_SET => {
            let req =
                crate::prompt_schedule::request_of(params).map_err(RpcError::invalid_params)?;
            // A schedule sends prompts: it passes the folder-trust gate a prompt from this
            // connection would (`trust_gate.rs`), and each run is checked again when it goes.
            super::trust_gate::check(
                hub,
                conn.origin,
                method::SESSION_PROMPT,
                params,
                Some(&session),
            )
            .await?;
            hub.schedule_set(&session, req, super::trust_gate::gated(conn.origin, params))
        }
        method::MUX_SCHEDULE_PAUSE => {
            let paused = params
                .get("paused")
                .and_then(Value::as_bool)
                .ok_or_else(|| RpcError::invalid_params("paused must be true or false"))?;
            hub.schedule_pause(&session, paused)
        }
        method::MUX_SCHEDULE_CLEAR => Ok(json!({"cleared": hub.schedule_clear(&session)?})),
        _ => Ok(hub.schedule_get(&session)),
    }
}
