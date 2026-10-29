//! `acp.session.fork` (the agent pane's "Fork from Here"): `{ sessionId,
//! throughSeq }` -> `{ sessionId }` of a new session holding the source's
//! conversation through the turn whose `turn_result` is `throughSeq`.
//!
//! The hub forks a chat at its end (`session/fork`; Claude's
//! `--resume --fork-session`, the agent's own `session/fork` otherwise). A
//! Claude chat can also fork through an earlier turn (session replay's
//! Continue from here): the fork resumes a copy of Claude's transcript cut
//! at that turn (`hub/fork_at.rs`). Any other agent can fork only through
//! the latest completed turn; an earlier one is refused with a clear error.
//! The request becomes a plain `session/fork` (with `_meta.acpmux.throughSeq`
//! for an earlier turn) before any guard runs, so it gets exactly
//! session/fork's checks. `live: true` (Fork Conversation) forks the whole chat
//! as it is now, also while its turn runs, and needs no `throughSeq`; a working
//! chat is never refused (`hub/fork.rs`).

use super::*;
use crate::no_panic::JsonExt;
use crate::store::SessionStatus;

/// Advertised in `initialize` as `_meta.acpmux.operations`.
pub const FORK_OPERATIONS: [&str; 1] = [method::ACP_SESSION_FORK];

/// `acp.session.fork` as the `session/fork` it becomes. Any other method
/// stays as it is, less a `throughSeq`: only `acp.session.fork` names one.
pub(super) async fn as_session_fork<'m>(
    hub: &Hub,
    m: &'m str,
    params: &mut Value,
) -> Result<&'m str, RpcError> {
    if m == method::ACP_SESSION_FORK {
        *params = to_session_fork(hub, params).await?;
        return Ok(method::SESSION_FORK);
    }
    if let Some(meta) = params.pointer_mut("/_meta/acpmux").and_then(Value::as_object_mut) {
        meta.remove("throughSeq");
    }
    Ok(m)
}

/// The earlier turn a `session/fork` from `acp.session.fork` forks through.
pub(super) fn through(params: &Value) -> Option<u64> {
    params.pointer("/_meta/acpmux/throughSeq").and_then(Value::as_u64)
}

/// The `session/fork` params for an `acp.session.fork` request, or why the
/// fork cannot happen at that turn.
async fn to_session_fork(hub: &Hub, params: &Value) -> Result<Value, RpcError> {
    let key = session_key(params)?;
    let session = hub.resolve(key).map_err(|e| {
        if hub.resolve_remote(key).is_some() {
            RpcError::invalid_params(
                "forking a chat on another computer through a turn is not supported yet",
            )
        } else {
            e
        }
    })?;
    let working = matches!(session.meta().status, SessionStatus::Running | SessionStatus::Waiting);
    // `live`: the whole chat as it is now (Fork Conversation), its running turn cut off
    // there (`hub/fork.rs`).
    let live = params.get("live").and_then(Value::as_bool).unwrap_or(false);
    let can_cut = {
        let harness = session.meta().harness;
        let cfg = hub.config.read().await;
        cfg.profile(&harness).and_then(|p| crate::config::turn_cut(&harness, p)).is_some()
    };
    // A working chat of an agent that forks only at its end forks as it is now.
    if live || (working && !can_cut) {
        let mut out = json!({"sessionId": session.id});
        if let Some(via) = params.pointer("/_meta/acpmux/via") {
            out.set("_meta", json!({"acpmux": {"via": via}}));
        }
        return Ok(out);
    }
    let through = params
        .get("throughSeq")
        .and_then(Value::as_u64)
        .ok_or_else(|| RpcError::invalid_params("throughSeq is required"))?;
    let mut at_through = false;
    let mut earlier = false;
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
                earlier = true;
            }
        }
    }
    if !at_through {
        return Err(RpcError::invalid_params(format!("no completed turn ends at seq {through}")));
    }
    // The resolved id, so the fork's own resolution cannot pick another
    // session; a forward mark (`_meta.acpmux.via`) keeps its guard.
    if earlier && !can_cut {
        return Err(RpcError::invalid_params(
            "only the latest turn of this agent's chat can be forked; an earlier turn needs a Claude or Codex chat",
        ));
    }
    // A working chat moved past its latest finished turn: a fork through it cuts there too.
    let earlier = earlier || working;
    let mut mux = serde_json::Map::new();
    if let Some(via) = params.pointer("/_meta/acpmux/via") {
        mux.insert("via".into(), via.clone());
    }
    if earlier {
        mux.insert("throughSeq".into(), json!(through));
    }
    let mut out = json!({"sessionId": session.id});
    if !mux.is_empty() {
        out.set("_meta", json!({"acpmux": mux}));
    }
    Ok(out)
}
