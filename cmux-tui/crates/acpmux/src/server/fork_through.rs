//! `acp.session.fork` (the agent pane's "Fork from Here"): `{ sessionId,
//! throughSeq }` -> `{ sessionId }` of a new session holding the source's
//! conversation through the turn whose `turn_result` is `throughSeq`.
//!
//! The hub forks a chat at its end (`session/fork`; Claude's
//! `--resume --fork-session`, the agent's own `session/fork` otherwise), so
//! only the latest completed turn of an idle chat can be the fork point; an
//! earlier turn is refused with a clear error. The request becomes a plain
//! `session/fork` before any guard runs, so it gets exactly session/fork's
//! checks.

use super::*;
use crate::store::SessionStatus;

/// Advertised in `initialize` as `_meta.acpmux.operations`.
pub const FORK_OPERATIONS: [&str; 1] = [method::ACP_SESSION_FORK];

const CONFLICT: i64 = -32000;

/// The `session/fork` params for an `acp.session.fork` request, or why the
/// fork cannot happen at that turn.
pub(super) fn to_session_fork(hub: &Hub, params: &Value) -> Result<Value, RpcError> {
    let key = session_key(params)?;
    let through = params
        .get("throughSeq")
        .and_then(Value::as_u64)
        .ok_or_else(|| RpcError::invalid_params("throughSeq is required"))?;
    let session = hub.resolve(key).map_err(|e| {
        if hub.resolve_remote(key).is_some() {
            RpcError::invalid_params(
                "forking a chat on another computer through a turn is not supported yet",
            )
        } else {
            e
        }
    })?;
    if matches!(session.meta().status, SessionStatus::Running | SessionStatus::Waiting) {
        return Err(RpcError::new(CONFLICT, "the chat is working; fork it when the turn ends"));
    }
    let mut at_through = false;
    let mut after = through.saturating_sub(1);
    loop {
        let page =
            hub.events(&session.id, after, 1000).map_err(|e| RpcError::internal(e.to_string()))?;
        let Some(last) = page.last() else { break };
        after = last.seq;
        for event in &page {
            if event.kind != "turn_result" {
                continue;
            }
            if event.seq == through {
                at_through = true;
            } else if event.seq > through {
                return Err(RpcError::invalid_params(
                    "only the latest turn can be forked; forking from an earlier turn is not supported yet",
                ));
            }
        }
    }
    if !at_through {
        return Err(RpcError::invalid_params(format!("no completed turn ends at seq {through}")));
    }
    // The resolved id, so the fork's own resolution cannot pick another
    // session; a forward mark (`_meta.acpmux.via`) keeps its guard.
    let mut out = json!({"sessionId": session.id});
    if let Some(via) = params.pointer("/_meta/acpmux/via") {
        out["_meta"] = json!({"acpmux": {"via": via}});
    }
    Ok(out)
}
