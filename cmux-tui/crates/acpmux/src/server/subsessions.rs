//! The sub-session methods (`hub/subsessions.rs`), routed before peer
//! forwarding (`chats.rs`): a family lives on one daemon.
//!
//! - `_acpmux/subsession/{start,list,get,send,stop}` act for the calling
//!   agent session, which only its caller token proves (`hub/person.rs`
//!   (a)): a unix socket connection whose `initialize` carried a matching
//!   `callerSession`. A request field never names the caller. `send` reaches
//!   a descendant or the caller's own parent; `get` and `stop` a descendant.
//! - `start {parent?, prompt, name?, harness?, model?, effort?, cwd?, worktree?}`: `parent`
//!   (`acpmux new|run --parent`) names the session the child starts under, of any harness
//!   family. A caller names itself or a descendant it may write to
//!   (`Hub::subsession_write_target`, as `send` and `stop`); the person (the app's proof) names
//!   any session here. Left out, it is the caller.
//! - `start`'s `host`: `auto` or `auto-build` weighs this machine with the
//!   placement engine first and refuses when it has no room; the reply's
//!   `placed` says why it went ahead (`server/place.rs` `subsession_host`).
//! - `_acpmux/subsession/retry {sessionId}`: the caller retries a descendant's failed last turn
//!   now, as `_acpmux/retry` does (`hub/auto_resume/retry_turn.rs`); the same ownership as `stop`.
//! - `_acpmux/subsession/answer {sessionId, permissionId, answers}`: the
//!   caller answers a descendant's pending question, never a permission
//!   prompt (`hub/subsession_answer.rs`).
//! - `_acpmux/subsession/limits {sessionId, maxChildren?, maxDepth?, maxRunning?}`
//!   (a number sets, null clears, absent keeps): the person (the app) for any
//!   session, or a calling session for one of its descendants within its own
//!   limits. `{workspaceId, maxRunning?}`: the person only, a workspace's
//!   `maxRunning` (`hub/subsession_runs.rs`).

use super::{Conn, str_param};
use crate::hub::subsessions::{LimitsActor, StartRequest};
use crate::hub::{Hub, Session};
use crate::rpc::{RpcError, method};
use serde_json::{Value, json};
use std::path::PathBuf;
use std::sync::Arc;

/// The reply to a sub-session method, or None for any other method.
pub(super) async fn dispatch(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    params: &Value,
) -> Option<Result<Value, RpcError>> {
    if !m.starts_with("_acpmux/subsession/") {
        return None;
    }
    Some(handle(hub, conn, m, params).await)
}

fn caller_required(hub: &Hub, conn: &Conn) -> RpcError {
    // A token this daemon run did not issue: most often an agent that kept
    // running across a daemon restart under a host that did not record its
    // token (an older build). A new harness process gets a new one.
    if let Some(session) = conn.unproven_caller.get().filter(|id| hub.resolve(id).is_ok()) {
        return RpcError::invalid_params(format!(
            "this session's caller token is not one this acpmux daemon knows: the daemon restarted (a cmux update or restart) after the agent started, so its tools still hold the earlier daemon's token. Restart the agent to get a new one: run `acpmux session restart {session}` (it restarts after the current turn ends, in the same conversation, and keeps its sub-sessions), or ask the person to restart the chat. Until then sub-session tools cannot act for it."
        ))
        .with_data(json!({"reason": "subsessions.caller_not_proven", "sessionId": session}));
    }
    RpcError::invalid_params(
        "sub-session tools act for the agent session that calls them: connect with that session's caller token (its cmux-subsessions MCP server does)",
    )
    .with_data(json!({"reason": "subsessions.caller_required"}))
}

/// The session a start acts for: the proven caller, itself or a descendant it names as
/// `parent`, or the session the person names. Any other connection is refused, as for every
/// sub-session tool: the child runs its parent's policy and mode, so naming a parent widens.
fn start_parent(hub: &Hub, conn: &Conn, params: &Value) -> Result<Arc<Session>, RpcError> {
    let named = str_param(params, "parent").filter(|p| !p.is_empty());
    match (conn.caller(), named) {
        (Some(caller), named) => {
            let caller = hub.resolve(caller)?;
            match named {
                Some(key) if hub.resolve(key)?.id != caller.id => {
                    hub.subsession_write_target(&caller, key, false)
                }
                _ => Ok(caller),
            }
        }
        (None, Some(key)) if conn.is_person() => hub.resolve(key),
        (None, _) => Err(caller_required(hub, conn)),
    }
}

/// A limit field: absent keeps it, null clears it, a number sets it.
fn limit(params: &Value, key: &str) -> Result<Option<Option<u32>>, RpcError> {
    match params.get(key) {
        None => Ok(None),
        Some(Value::Null) => Ok(Some(None)),
        Some(v) => {
            v.as_u64().and_then(|n| u32::try_from(n).ok()).map(|n| Some(Some(n))).ok_or_else(|| {
                RpcError::invalid_params(format!("{key} must be a whole number or null"))
            })
        }
    }
}

async fn handle(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    params: &Value,
) -> Result<Value, RpcError> {
    if m == method::MUX_SUBSESSION_LIMITS {
        if params.get("workspaceId").is_some() && params.get("sessionId").is_some() {
            return Err(RpcError::invalid_params("name a sessionId or a workspaceId, not both"));
        }
        if let Some(workspace) = str_param(params, "workspaceId") {
            if !conn.is_person() {
                return Err(crate::hub::person::person_required("changing a workspace's limits"));
            }
            return hub.set_workspace_run_limit(workspace, limit(params, "maxRunning")?);
        }
        let key = str_param(params, "sessionId")
            .ok_or_else(|| RpcError::invalid_params("sessionId is required"))?;
        let target = hub.resolve(key)?;
        let actor = if conn.is_person() {
            LimitsActor::Person
        } else if let Some(caller) = conn.caller() {
            LimitsActor::Session(caller)
        } else {
            return Err(crate::hub::person::person_required("changing sub-session limits"));
        };
        return hub.set_subsession_limits(
            actor,
            &target,
            limit(params, "maxChildren")?,
            limit(params, "maxDepth")?,
            limit(params, "maxRunning")?,
        );
    }
    if m == method::MUX_SUBSESSION_START {
        let parent = start_parent(hub, conn, params)?;
        // Weighed before anything starts: a refused placement makes no child.
        let placed = super::place::subsession_host(hub, str_param(params, "host")).await?;
        let text = |k: &str| str_param(params, k).map(str::to_owned);
        let req = StartRequest {
            prompt: text("prompt").unwrap_or_default(),
            name: text("name"),
            harness: text("harness"),
            model: text("model"),
            effort: text("effort"),
            cwd: text("cwd").map(PathBuf::from),
            worktree: params.get("worktree").and_then(Value::as_bool).unwrap_or(false),
        };
        let mut started = hub.start_subsession(&parent, req).await?;
        if let Some(placed) = placed {
            started["placed"] = json!(placed);
        }
        return Ok(started);
    }
    // The caller token is read only on the unix socket (`server/mod.rs`).
    let caller = conn.caller().ok_or_else(|| caller_required(hub, conn))?;
    let caller = hub.resolve(caller)?;
    match m {
        method::MUX_SUBSESSION_LIST => {
            let all = str_param(params, "scope") == Some("descendants");
            Ok(hub.subsession_list(&caller, all))
        }
        method::MUX_SUBSESSION_GET => {
            let key = str_param(params, "sessionId")
                .ok_or_else(|| RpcError::invalid_params("sessionId is required"))?;
            let target = hub.subsession_target(&caller, key, true)?;
            Ok(hub.subsession_row(&target, true))
        }
        method::MUX_SUBSESSION_SEND => {
            let key = str_param(params, "sessionId")
                .ok_or_else(|| RpcError::invalid_params("sessionId is required"))?;
            let target = hub.subsession_write_target(&caller, key, true)?;
            let text = str_param(params, "text").unwrap_or_default();
            let interrupt = params.get("interrupt").and_then(Value::as_bool).unwrap_or(false);
            let deliver = crate::hub::Delivery::parse(str_param(params, "deliver"), interrupt)?;
            let prompt_id = str_param(params, "promptId").map(str::to_owned);
            // Files sent with it, as `send_message` reads them (`attach.rs`).
            let attachments = match params.get("attachments") {
                None | Some(Value::Null) => Vec::new(),
                Some(Value::Array(blocks)) if crate::attach::all(blocks) => blocks.clone(),
                Some(_) => {
                    return Err(RpcError::invalid_params(
                        "attachments must be attachment blocks (send_message reads the files)",
                    ));
                }
            };
            hub.subsession_send(&caller, &target, text, attachments, deliver, prompt_id).await
        }
        method::MUX_SUBSESSION_ANSWER => {
            let key = str_param(params, "sessionId")
                .ok_or_else(|| RpcError::invalid_params("sessionId is required"))?;
            let target = hub.subsession_write_target(&caller, key, false)?;
            let permission_id = str_param(params, "permissionId")
                .ok_or_else(|| RpcError::invalid_params("permissionId is required"))?;
            let answers = params
                .get("answers")
                .cloned()
                .ok_or_else(|| RpcError::invalid_params("answers is required"))?;
            hub.subsession_answer(&caller, &target, permission_id, answers).await
        }
        method::MUX_SUBSESSION_STOP => {
            let key = str_param(params, "sessionId")
                .ok_or_else(|| RpcError::invalid_params("sessionId is required"))?;
            let target = hub.subsession_write_target(&caller, key, false)?;
            let close = params.get("close").and_then(Value::as_bool).unwrap_or(false);
            hub.subsession_stop(&target, close).await
        }
        method::MUX_SUBSESSION_RETRY => {
            let key = str_param(params, "sessionId")
                .ok_or_else(|| RpcError::invalid_params("sessionId is required"))?;
            let target = hub.subsession_write_target(&caller, key, false)?;
            hub.subsession_retry(&caller, &target, str_param(params, "subagentId")).await
        }
        other => Err(RpcError::method_not_found(other)),
    }
}
