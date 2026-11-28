//! `_acpmux/bg/rearm`: a session move's wait handoff (`rearm.rs`), versioned. Session rebalance
//! (`cli/run/rebalance.rs`) sends it twice for a session whose every running background task is a
//! re-armable wait:
//!
//! 1. to the destination, once the move landed: `{version: 1, sessionId, waits: [Wait]}`. Each
//!    wait is started again for the chat with the same target and the time its deadline has left
//!    (one already past it is skipped), answered `{version: 1, rearmed: [{from, id}], expired:
//!    [from]}`;
//! 2. to the source, only after every wait was re-armed: `{version: 1, sessionId, release:
//!    [id]}`, which stops those of the chat's tasks that are re-armable waits (any other is
//!    refused and keeps running), answered `{version: 1, released: [id], refused: [{id, why}]}`.
//!
//! Unlike the other `_acpmux/bg/*` methods (`bg_tasks.rs`, this machine's clients only) it is
//! served to a peer too, and forwarded to the host of a peer's chat (`peer_forward.rs`, gated by
//! the [`FEATURE`] its link lists): the destination is another machine. It never runs a command
//! it was sent: each wait's fields are checked and its command written again here
//! (`rearm::Wait`). A message of another version is refused, naming the one this build speaks, so
//! an old daemon and a new one never half-understand each other.

use super::{Conn, Origin, str_param};
use crate::hub::Hub;
use crate::rearm::{VERSION, Wait};
use crate::rpc::RpcError;
use serde_json::{Value, json};
use std::sync::Arc;

/// The peer feature a link lists when its daemon serves `_acpmux/bg/rearm` version 1.
pub const FEATURE: &str = "bgRearm";

/// The message is the version this daemon speaks; any other (an old or a newer sender's) is
/// refused whole, naming this one, never half read.
pub(super) fn speaks(params: &Value) -> Result<(), RpcError> {
    match params.get("version").and_then(Value::as_u64) {
        Some(VERSION) => Ok(()),
        other => Err(RpcError::invalid_params(format!(
            "_acpmux/bg/rearm version {} is not one this daemon speaks ({VERSION})",
            other.map_or("none".to_owned(), |v| v.to_string())
        ))
        .with_data(json!({"reason": "bgRearm.version", "version": VERSION}))),
    }
}

pub(super) async fn handle(hub: &Arc<Hub>, conn: &Conn, params: &Value) -> Result<Value, RpcError> {
    let control = super::remote_guard::control_of(conn.origin, conn.auth, params);
    let peer_owner =
        conn.origin == Origin::Peer && crate::hub::vm_boundary::owner(conn.auth, control, params);
    if conn.origin == Origin::Web || (!conn.is_person() && !peer_owner) {
        return Err(RpcError::invalid_params(
            "_acpmux/bg/rearm is the person's (a session move): their local connection or their peer daemon",
        ));
    }
    speaks(params)?;
    let key = str_param(params, "sessionId")
        .ok_or_else(|| RpcError::invalid_params("sessionId is required"))?;
    let session = hub.resolve(key)?;
    match (params.get("waits"), params.get("release")) {
        (Some(waits), None) => {
            let waits =
                waits.as_array().ok_or_else(|| RpcError::invalid_params("waits must be a list"))?;
            // Every wait is checked before any starts: a bad one arms none.
            let mut checked = Vec::new();
            for w in waits {
                let wait = Wait::from_json(w).map_err(RpcError::invalid_params)?;
                let from = w.get("id").and_then(Value::as_str).unwrap_or_default().to_owned();
                let description = w.get("description").and_then(Value::as_str).map(str::to_owned);
                let notify = w.get("notify").and_then(Value::as_bool).unwrap_or(true);
                let result_line = w.get("resultLine").and_then(Value::as_bool).unwrap_or(false);
                // The call that started it (a list view's `toolCallId`): its registry row keeps
                // naming that call on the new machine (`hub/bg_registry.rs`). A label only.
                let call = w.get("toolCallId").and_then(Value::as_str).map(str::to_owned);
                checked.push((from, wait, description, notify, result_line, call));
            }
            let (mut rearmed, mut expired) = (Vec::new(), Vec::new());
            for (from, wait, description, notify, result_line, call) in checked {
                let Some(command) = wait.command(crate::store::now_ms()) else {
                    expired.push(json!(from));
                    continue;
                };
                let started = hub
                    .bg_start(
                        &session,
                        &command,
                        None,
                        description,
                        notify,
                        result_line,
                        None,
                        false, // A moved wait retains the chat's sandbox.
                        call,
                        crate::session_budget::TaskClass::Task,
                    )
                    .await?;
                // The row of the task it was came with the chat's log: it ends here and gives its
                // call to the new task, so the chat lists the call once (`hub/bg_registry.rs`).
                hub.bg_moved(&session, &from);
                rearmed.push(json!({"from": from, "id": started.get("id")}));
            }
            Ok(json!({"version": VERSION, "rearmed": rearmed, "expired": expired}))
        }
        (None, Some(ids)) => {
            let ids =
                ids.as_array().ok_or_else(|| RpcError::invalid_params("release must be a list"))?;
            let (mut released, mut refused) = (Vec::new(), Vec::new());
            for id in ids {
                let Some(id) = id.as_str() else {
                    return Err(RpcError::invalid_params("release must list task ids"));
                };
                if hub.bg_wait(&session, id).is_none() {
                    refused.push(json!({"id": id, "why": "not a running re-armable wait"}));
                    continue;
                }
                match hub.bg_stop(&session, id).await {
                    Ok(_) => released.push(json!(id)),
                    Err(e) => refused.push(json!({"id": id, "why": e.message})),
                }
            }
            Ok(json!({"version": VERSION, "released": released, "refused": refused}))
        }
        _ => Err(RpcError::invalid_params(
            "give waits (to re-arm) or release (to stop), one of them",
        )),
    }
}

#[cfg(test)]
#[path = "bg_rearm_tests.rs"]
mod tests;
