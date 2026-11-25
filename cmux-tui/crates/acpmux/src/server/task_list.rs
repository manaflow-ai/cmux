//! The task-list methods (`hub/task_list.rs`, `crate::task_list`): `_acpmux/task_list/set
//! {sessionId, items: [{content, status}]}` keeps a chat's list for a harness that writes no plan of
//! its own (an empty `items` clears it), and `_acpmux/task_list/get {sessionId}` reads it. Each
//! answers the list's summary (`TaskListSummary`), null for none.
//!
//! Set by the chat's own agent (its proven caller token: source `agent`), by the session that
//! started it with `start_session`, or by a local client that runs in no chat: the person, the
//! Chief host (optchat-chief's socket client proves neither a caller nor the person) and the app
//! (source `chief`). A connection that proved it runs in another chat is refused, and so are a
//! remote WebSocket device and a peer, as for the goal methods (`goal.rs`). The list is display
//! data, and an unproven local client can already prompt any chat, so this rule gives it nothing
//! it lacks.

use super::{Conn, str_param};
use crate::hub::Hub;
use crate::rpc::{RpcError, method};
use crate::task_list::{self, TaskListSource};
use serde_json::Value;
use std::sync::Arc;

/// The reply to a task-list method, or None for any other method.
pub(super) fn dispatch(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    params: &Value,
) -> Option<Result<Value, RpcError>> {
    if !matches!(m, method::MUX_TASK_LIST_SET | method::MUX_TASK_LIST_GET) {
        return None;
    }
    if conn.origin.web_class() {
        return Some(Err(RpcError::method_not_found(&format!(
            "{m} (not served to a remote WebSocket connection or a peer)"
        ))));
    }
    Some(handle(hub, conn, m, params))
}

fn handle(hub: &Arc<Hub>, conn: &Conn, m: &str, params: &Value) -> Result<Value, RpcError> {
    let key = str_param(params, "sessionId")
        .ok_or_else(|| RpcError::invalid_params("sessionId is required"))?;
    let session = hub.resolve(key)?;
    let caller = conn.caller();
    let own = caller == Some(session.id.as_str());
    let starter = caller.is_some_and(|c| {
        session.read_meta(|m| m.subsession.as_ref().is_some_and(|s| s.started_by == c))
    });
    let source = if own {
        TaskListSource::Agent
    } else if starter || caller.is_none() || conn.is_person() {
        TaskListSource::Chief
    } else {
        return Err(RpcError::invalid_params(
            "a chat's task list is kept by its own agent, the chat that started it, the Chief or the person",
        ));
    };
    if m == method::MUX_TASK_LIST_GET {
        return Ok(hub.task_list_get(&session));
    }
    let items = params
        .get("items")
        .ok_or_else(|| RpcError::invalid_params("items is required"))
        .and_then(|items| task_list::set_items(items).map_err(RpcError::invalid_params))?;
    hub.task_list_set(&session, source, items)
}
