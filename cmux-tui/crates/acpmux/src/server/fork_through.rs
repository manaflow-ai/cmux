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
pub const FORK_OPERATIONS: [&str; 2] =
    [method::ACP_SESSION_FORK, "acp.session.fork.beforePromptId"];

/// `acp.session.fork` as the `session/fork` it becomes. Any other method
/// stays as it is, less a `throughSeq`: only `acp.session.fork` names one.
/// A fork of a chat on another computer (a peer's) through a turn or before a
/// prompt stays `acp.session.fork`: it is forwarded whole (`peer_forward.rs`),
/// and the peer's own daemon makes it the `session/fork`, with its own checks
/// of the chat it holds. A live one becomes that machine's `session/fork` here
/// (`to_session_fork`).
pub(super) async fn as_session_fork<'m>(
    hub: &Hub,
    m: &'m str,
    params: &mut Value,
) -> Result<&'m str, RpcError> {
    if m == method::ACP_SESSION_FORK {
        if names_a_peers_chat(hub, params) && !plain_live(params) {
            return Ok(m);
        }
        *params = to_session_fork(hub, params).await?;
        return Ok(method::SESSION_FORK);
    }
    if let Some(meta) = params.pointer_mut("/_meta/acpmux").and_then(Value::as_object_mut) {
        meta.remove("throughSeq");
        meta.remove("beforePromptId");
        meta.remove("requestId");
        meta.remove("startLater");
    }
    Ok(m)
}

/// Whether a `session/fork` came from `acp.session.fork` (Fork Conversation), which answers once
/// the fork's chat is made and starts its agent after (`Hub::fork`'s `start_later`).
pub(super) fn starts_later(params: &Value) -> bool {
    params.pointer("/_meta/acpmux/startLater").and_then(Value::as_bool).unwrap_or(false)
}

/// Listed in `initialize`'s `_meta.acpmux.features`: `session/fork` takes `_meta.acpmux.harness`
/// and `model` (a switch onto another harness, `hub/fork.rs` `Retarget`). A build without it
/// forks on the chat's own harness and ignores them, so a switch goes only to a peer that lists
/// it (`peer_forward.rs`).
pub const RETARGET_FEATURE: &str = "sessionForkRetarget";

/// Why a switch of a peer's chat cannot go to that peer: it did not list [`RETARGET_FEATURE`].
pub(super) fn retarget_unsupported(peer: &str) -> RpcError {
    RpcError::invalid_params(format!(
        "{peer} runs an acpmux that cannot switch a chat onto another harness: update it, then pick the model again"
    ))
    .with_data(serde_json::json!({"reason": "peer.retarget_unsupported", "peer": peer}))
}

/// Whether `session/fork` params ask for a switch onto another harness.
pub(super) fn asks_retarget(params: &Value) -> bool {
    params.pointer("/_meta/acpmux/harness").is_some_and(|v| !v.is_null())
}

/// The harness a `session/fork` forks onto (`_meta.acpmux.harness`, with `model`): a pick of
/// another harness's model in a started chat, at its next send (`hub/fork.rs` `Retarget`).
pub(super) fn retarget(params: &Value) -> Result<Option<crate::hub::Retarget>, RpcError> {
    let text = |key: &str| -> Result<Option<String>, RpcError> {
        match params.pointer(&format!("/_meta/acpmux/{key}")) {
            None | Some(Value::Null) => Ok(None),
            Some(Value::String(s)) if !s.trim().is_empty() && s.len() <= 256 => Ok(Some(s.clone())),
            Some(_) => Err(RpcError::invalid_params(format!(
                "_meta.acpmux.{key} must be a nonempty string of at most 256 bytes"
            ))),
        }
    };
    let model = text("model")?;
    // A model is a spawn parameter (`--model`, `${model}` in a launch command): one model id, never
    // a flag or anything else, as a start's (`cmux-agent-pane-policy` `is_model_id`).
    if let Some(m) = &model
        && !cmux_agent_pane_policy::params::is_model_id(&Value::String(m.clone()))
    {
        return Err(RpcError::invalid_params(
            "_meta.acpmux.model must be one model id: ASCII letters, digits and ._-/:@[]+, not starting with -",
        ));
    }
    Ok(match text("harness")? {
        Some(harness) => Some(crate::hub::Retarget { harness, model, remote: false }),
        None if model.is_some() => {
            return Err(RpcError::invalid_params("_meta.acpmux.model needs _meta.acpmux.harness"));
        }
        None => None,
    })
}

/// The earlier turn a `session/fork` from `acp.session.fork` forks through.
pub(super) fn through(params: &Value) -> Option<u64> {
    params.pointer("/_meta/acpmux/throughSeq").and_then(Value::as_u64)
}

/// A `live` fork with no turn or prompt boundary: the one `to_session_fork` sends to a peer's
/// chat as that machine's `session/fork`.
fn plain_live(params: &Value) -> bool {
    params.get("live").and_then(Value::as_bool).unwrap_or(false)
        && params.get("throughSeq").is_none()
        && params.get("beforePromptId").is_none()
}

/// Whether the request names a chat on a peer, not one on this daemon.
fn names_a_peers_chat(hub: &Hub, params: &Value) -> bool {
    session_key(params)
        .is_ok_and(|key| hub.resolve(key).is_err() && hub.resolve_remote(key).is_some())
}

/// What a turn fork keeps of the caller's request: the forward mark and full-access guard, and the
/// child's `name` (`_meta.acpmux.name`, else the top-level `name`, as `session/fork` reads it).
/// Without the name the child took the default `<parent>-fork` (cmux Try another approach labels
/// its sibling).
fn carried_meta(params: &Value) -> serde_json::Map<String, Value> {
    let mut mux = serde_json::Map::new();
    for key in ["via", "requireFullAccess", "name"] {
        if let Some(value) = params.pointer(&format!("/_meta/acpmux/{key}")) {
            mux.insert(key.into(), value.clone());
        }
    }
    if let Some(name) = params.get("name").filter(|name| name.is_string()) {
        mux.entry("name").or_insert_with(|| name.clone());
    }
    mux
}

/// The `session/fork` params for an `acp.session.fork` request, or why the
/// fork cannot happen at that turn.
async fn to_session_fork(hub: &Hub, params: &Value) -> Result<Value, RpcError> {
    let key = session_key(params)?;
    // `live`: the whole chat as it is now (Fork Conversation), its running turn cut off
    // there (`hub/fork.rs`).
    let live = params.get("live").and_then(Value::as_bool).unwrap_or(false);
    // A switch (`harness`, `model`) forks the chat as it is now: with `live` only, never at a turn
    // or before a prompt, which would drop the target and make an ordinary fork.
    let switch =
        ["harness", "model"].iter().any(|key| params.get(*key).is_some_and(|v| !v.is_null()));
    if switch
        && (!live || params.get("throughSeq").is_some() || params.get("beforePromptId").is_some())
    {
        return Err(RpcError::invalid_params(
            "harness and model fork the chat as it is now: send them with live, without throughSeq or beforePromptId",
        ));
    }
    // A chat on another computer (a peer's, a Cloud machine's) forks there as it is now: the
    // `session/fork` goes to that machine (`peer_forward.rs`), onto another harness too (a pick
    // of another harness's model, sent; Leo 2026-11-11: "across any and all conditions of
    // workspaces/folders/models/provides/harnesses").
    if live
        && hub.resolve(key).is_err()
        && hub.resolve_remote(key).is_some()
        && params.get("throughSeq").is_none()
        && params.get("beforePromptId").is_none()
    {
        let mut mux = cancel_token(params);
        for key in ["via", "requireFullAccess"] {
            if let Some(value) = params.pointer(&format!("/_meta/acpmux/{key}")) {
                mux.insert(key.into(), value.clone());
            }
        }
        for key in ["harness", "model"] {
            if let Some(value) = params.get(key).filter(|v| v.is_string()) {
                mux.insert(key.into(), value.clone());
            }
        }
        mux.insert("startLater".into(), json!(true));
        return Ok(json!({"sessionId": key, "_meta": {"acpmux": mux}}));
    }
    let session = hub.resolve(key)?;
    if params.get("beforePromptId").is_some() {
        use crate::hub::fork_before::refused;
        if params.get("throughSeq").is_some() || params.get("live").is_some() {
            return Err(refused(
                "fork.invalid_boundary",
                "beforePromptId excludes throughSeq and live",
            ));
        }
        let field = |key| {
            params.get(key).and_then(Value::as_str)
            .filter(|s| !s.trim().is_empty() && s.len() <= 512)
            .ok_or_else(|| refused("fork.invalid_boundary", "beforePromptId and requestId must be nonempty strings of at most 512 bytes"))
        };
        let prompt = field("beforePromptId")?;
        let request = field("requestId")?;
        let mut mux = json!({"beforePromptId": prompt, "requestId": request});
        for key in ["via", "requireFullAccess"] {
            if let Some(value) = params.pointer(&format!("/_meta/acpmux/{key}")) {
                mux.set(key, value.clone());
            }
        }
        // Only this canonical operation may mint the internal boundary. All guards still run.
        return Ok(json!({"sessionId": session.id, "_meta": {"acpmux": mux}}));
    }
    if params.get("requestId").is_some() {
        return Err(crate::hub::fork_before::refused(
            "fork.invalid_boundary",
            "requestId requires beforePromptId",
        ));
    }
    let working = matches!(session.meta().status, SessionStatus::Running | SessionStatus::Waiting);
    let can_cut = {
        let harness = session.meta().harness;
        let cfg = hub.config.read().await;
        cfg.profile(&harness).and_then(|p| crate::config::turn_cut(&harness, p)).is_some()
    };
    // A working chat of an agent that forks only at its end forks as it is now.
    if live || (working && !can_cut) {
        let mut out = json!({"sessionId": session.id});
        let mut mux = cancel_token(params);
        for key in ["via", "requireFullAccess"] {
            if let Some(value) = params.pointer(&format!("/_meta/acpmux/{key}")) {
                mux.insert(key.into(), value.clone());
            }
        }
        // A pick of another harness's model, sent (`hub/fork.rs` `Retarget`).
        for key in ["harness", "model"] {
            if let Some(value) = params.get(key).filter(|v| v.is_string()) {
                mux.insert(key.into(), value.clone());
            }
        }
        mux.insert("startLater".into(), json!(true));
        out.set("_meta", json!({"acpmux": mux}));
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
    let mut mux = carried_meta(params);
    mux.extend(cancel_token(params));
    if earlier {
        mux.insert("throughSeq".into(), json!(through));
    }
    mux.insert("startLater".into(), json!(true));
    let mut out = json!({"sessionId": session.id});
    out.set("_meta", json!({"acpmux": mux}));
    Ok(out)
}

/// The `_meta.acpmux` a Fork Conversation's `session/fork` starts from: its `cancelToken`, which
/// Cancel names it by (`hub/fork_cancel.rs`).
fn cancel_token(params: &Value) -> serde_json::Map<String, Value> {
    let mut mux = serde_json::Map::new();
    if let Some(token) = params.get("cancelToken").filter(|t| t.is_string()) {
        mux.insert("cancelToken".into(), token.clone());
    }
    mux
}

#[cfg(test)]
mod tests;
