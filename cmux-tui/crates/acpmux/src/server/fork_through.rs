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
        meta.remove("startLater");
    }
    Ok(m)
}

/// Whether a `session/fork` came from `acp.session.fork` (Fork Conversation), which answers once
/// the fork's chat is made and starts its agent after (`Hub::fork`'s `start_later`).
pub(super) fn starts_later(params: &Value) -> bool {
    params.pointer("/_meta/acpmux/startLater").and_then(Value::as_bool).unwrap_or(false)
}

/// The earlier turn a `session/fork` from `acp.session.fork` forks through.
pub(super) fn through(params: &Value) -> Option<u64> {
    params.pointer("/_meta/acpmux/throughSeq").and_then(Value::as_u64)
}

/// Why a chat on another computer (a peer's) cannot be forked here: a `live`
/// fork names no turn. Daemon error text, in English as acpmux's other
/// errors; the pane never sends a fork of a peer's chat (webviews
/// `messageMenu.ts` `forkServed`), so only a raw client reads it.
fn remote_refusal(live: bool) -> &'static str {
    if live {
        "forking a chat on another computer is not supported yet"
    } else {
        "forking a chat on another computer through a turn is not supported yet"
    }
}

/// The `session/fork` params for an `acp.session.fork` request, or why the
/// fork cannot happen at that turn.
async fn to_session_fork(hub: &Hub, params: &Value) -> Result<Value, RpcError> {
    let key = session_key(params)?;
    // `live`: the whole chat as it is now (Fork Conversation), its running turn cut off
    // there (`hub/fork.rs`).
    let live = params.get("live").and_then(Value::as_bool).unwrap_or(false);
    let session = hub.resolve(key).map_err(|e| {
        if hub.resolve_remote(key).is_some() {
            RpcError::invalid_params(remote_refusal(live))
        } else {
            e
        }
    })?;
    let working = matches!(session.meta().status, SessionStatus::Running | SessionStatus::Waiting);
    let can_cut = {
        let harness = session.meta().harness;
        let cfg = hub.config.read().await;
        cfg.profile(&harness).and_then(|p| crate::config::turn_cut(&harness, p)).is_some()
    };
    // A working chat of an agent that forks only at its end forks as it is now.
    if live || (working && !can_cut) {
        let mut out = json!({"sessionId": session.id});
        let mut mux = serde_json::Map::new();
        for key in ["via", "requireFullAccess"] {
            if let Some(value) = params.pointer(&format!("/_meta/acpmux/{key}")) {
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
    let mut mux = serde_json::Map::new();
    for key in ["via", "requireFullAccess"] {
        if let Some(value) = params.pointer(&format!("/_meta/acpmux/{key}")) {
            mux.insert(key.into(), value.clone());
        }
    }
    if earlier {
        mux.insert("throughSeq".into(), json!(through));
    }
    mux.insert("startLater".into(), json!(true));
    let mut out = json!({"sessionId": session.id});
    out.set("_meta", json!({"acpmux": mux}));
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{Config, StoreMode};
    use crate::session_identity::SessionReceipt;

    /// A hub with no chat of its own, and peer hb (listed, never run) listing a working chat:
    /// `Hub::resolve_remote` needs the peer as well as its row (`hub/own_host.rs` `add_peer`).
    fn hub_with_a_peer_chat() -> Arc<Hub> {
        let mut config: Config = serde_json::from_value(json!({})).unwrap();
        config.store.mode = StoreMode::Memory;
        let store =
            crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
        let hub = Hub::new(config, store);
        let row = crate::hub::RemoteSession {
            peer: "hb".into(),
            summary: json!({"sessionId": "peer-chat-1", "name": "hb/chat", "status": "running"}),
            receipt: SessionReceipt {
                host_id: "hb".into(),
                mux_session_id: "peer-chat-1".into(),
                agent_session_id: None,
                generation: 1,
            },
        };
        hub.remote_sessions.lock().unwrap().insert("hb/peer-chat-1".into(), row);
        let (tx, _rx) = tokio::sync::mpsc::channel(8);
        let peer = crate::peer::Peer::new("hb", "ws://127.0.0.1:9", None, None, tx);
        hub.peers.lock().unwrap().insert("hb".to_owned(), peer);
        hub
    }

    /// Review of #28332: a `live` fork (Fork Conversation of a working chat) names no turn, so
    /// its refusal for a peer's chat does not say "through a turn"; a fork through a turn does.
    #[tokio::test]
    async fn a_peer_chats_fork_is_refused_with_what_it_asked_for() {
        let hub = hub_with_a_peer_chat();
        assert!(
            hub.resolve_remote("hb/peer-chat-1").is_some(),
            "the fixture lists the peer's chat"
        );
        let live = to_session_fork(&hub, &json!({"sessionId": "hb/peer-chat-1", "live": true}))
            .await
            .unwrap_err();
        assert_eq!(live.message, "forking a chat on another computer is not supported yet");
        let through =
            to_session_fork(&hub, &json!({"sessionId": "hb/peer-chat-1", "throughSeq": 3}))
                .await
                .unwrap_err();
        assert_eq!(
            through.message,
            "forking a chat on another computer through a turn is not supported yet"
        );
    }
}
