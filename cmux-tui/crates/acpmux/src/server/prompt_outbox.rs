//! A `session/prompt` to a chat on a peer whose link could not take it waits for the link
//! instead of failing. Part of the request handler (`peer_forward.rs` `forward`).
//!
//! A prompt the link refused before the peer accepted it (`peer_unreachable`: the link is down,
//! or it went down with the prompt still queued here; `peer_disconnected`: it went down while the
//! frame was being written; a frame that reached the socket counts as the peer's, `peer.rs`) is kept in the durable outbox
//! (`hub/outbox.rs`) under its own prompt id, the idempotency key the peer's prompt ledger
//! dedupes on (`hub/turns.rs` `prompt_with`). The outbox sends it again, always as a resend,
//! whenever any of the peer's carriers brings the link back (`Outbox::peer_ready`), so a peer
//! that took the first copy answers with that run and never runs it twice. An accepted prompt
//! never comes here: its caller is rebound to the peer's outcome (`peer.rs` `recover_prompts`).
//!
//! The sender hears `_acpmux/prompt_accepted` with `state: "outbox"` at once (its delivery id,
//! the peer and when it stops waiting), and its `session/prompt` stays open: once the peer
//! accepts it, the peer's own acceptance follows, and the request answers with the turn's
//! outcome, as a prompt sent while the link was up does. At most
//! [`INTERACTIVE_MAX_PER_PEER`] prompts wait for one peer (the next is refused,
//! `outbox.full`), and each waits [`crate::hub::outbox::INTERACTIVE_WAIT_MS`] at most, then
//! fails with `outbox.expired`. A sender that leaves stops waiting; its prompt still goes.
//!
//! Only the unix socket and the app's own pane wait: a peer daemon's forward, a Web client and
//! the outbox's own delivery hear the link's failure as before (the outbox retries on it).

use super::*;
use crate::hub::outbox::{
    Delivery, INTERACTIVE_EXPIRED, INTERACTIVE_EXPIRED_PREFIX, INTERACTIVE_FULL,
    INTERACTIVE_MAX_PER_PEER, INTERACTIVE_WAIT_MS, Interactive, Replay, State,
};

/// `_acpmux/prompt_accepted`'s `state` for a prompt kept to wait for its peer's link.
pub(super) const OUTBOX_STATE: &str = "outbox";

/// Whether the prompt `params` that `conn` sends is for a peer's chat and waits for that peer's
/// link instead of failing.
pub(super) fn may_wait(hub: &Hub, conn: &Conn, params: &Value) -> bool {
    matches!(conn.origin, Origin::Local | Origin::LocalApp)
        && !matches!(conn.socket_peer, SocketPeer::Outbox | SocketPeer::OutboxPerson)
        && !conn.is_trigger()
        && session_key(params)
            .is_ok_and(|key| hub.resolve(key).is_err() && hub.resolve_remote(key).is_some())
}

/// `params` with a prompt id when they have none: the copy kept to wait and the one that may
/// have reached the peer must be one prompt to its ledger.
pub(super) fn with_prompt_id(params: &Value) -> Option<Value> {
    let named = params
        .pointer("/_meta/acpmux/promptId")
        .and_then(Value::as_str)
        .is_some_and(|id| !id.is_empty());
    if named {
        return None;
    }
    let mut params = params.clone();
    crate::hub::merge_mux_meta(&mut params, json!({"promptId": uuid::Uuid::now_v7().to_string()}));
    Some(params)
}

/// The peer whose link failed `e` before the peer accepted the prompt, if that is why it failed.
pub(super) fn link_failed(hub: &Hub, e: &RpcError) -> Option<Arc<crate::peer::Peer>> {
    let data = e.data.as_ref()?;
    let reason = data.get("reason").and_then(Value::as_str)?;
    if !matches!(reason, "peer_unreachable" | "peer_disconnected") {
        return None;
    }
    hub.peer_by_name(data.get("peer").and_then(Value::as_str)?)
}

/// The error a waiting prompt fails with once its peer stayed away past its wait.
pub(super) fn expired_error(peer: &str, last: &str) -> String {
    format!(
        "{INTERACTIVE_EXPIRED_PREFIX}{peer} stayed unreachable for {} minutes after the prompt was sent{last}",
        INTERACTIVE_WAIT_MS / 60_000
    )
}

/// Keeps `params`, which the link to `peer` failed with `error`, to send once the link is back,
/// tells the sender it waits, and answers with the turn's outcome once the peer ran it.
pub(super) async fn queue_unaccepted(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    params: &Value,
    peer: &crate::peer::Peer,
    error: &RpcError,
) -> Result<Value, RpcError> {
    let delivery = keep(hub, conn, params, peer, error).await?;
    let prompt_id = delivery.prompt_id().to_owned();
    let remote = hub.resolve_remote(&delivery.target).map(|(_, id, _)| id);
    conn.send(&Message::notification(
        method::MUX_PROMPT_ACCEPTED,
        json!({
            "sessionId": remote.as_deref().unwrap_or(&delivery.target),
            "promptId": prompt_id,
            "peer": peer.name,
            "state": OUTBOX_STATE,
            "queued": true,
            "turnId": null,
            "deliveryId": delivery.id,
            "expiresAt": delivery.interactive.as_ref().map(|i| i.expires_at),
        }),
    ));
    let accepted = tokio::select! {
        settled = settled(hub, &delivery.id) => settled?,
        () = conn.closed() => return Err(RpcError::internal("the client closed the connection")),
    };
    // A resend of a prompt the peer ran already answers with that run's outcome.
    if accepted.get("stopReason").is_some() {
        return Ok(accepted);
    }
    let mut notice = accepted.clone();
    notice.set("peer", json!(peer.name));
    conn.send(&Message::notification(method::MUX_PROMPT_ACCEPTED, notice));
    tokio::select! {
        outcome = outcome(hub, &delivery.target, &prompt_id) => outcome,
        () = conn.closed() => Err(RpcError::internal("the client closed the connection")),
    }
}

/// Records the waiting prompt (or finds the one already waiting under its prompt id) and starts
/// its delivery.
async fn keep(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    params: &Value,
    peer: &crate::peer::Peer,
    error: &RpcError,
) -> Result<Delivery, RpcError> {
    let target = session_key(params)?.to_owned();
    let mut request = params.clone();
    request.set("sessionId", json!(target));
    if let Some(mux) = request.pointer_mut("/_meta/acpmux").and_then(Value::as_object_mut) {
        mux.remove("forwardProjection");
    }
    let now = crate::store::now_ms();
    let agent = !conn.is_person();
    let new = Delivery {
        id: uuid::Uuid::now_v7().to_string(),
        target,
        request,
        caller: conn.caller().filter(|_| agent).map(str::to_owned),
        unproven_caller: conn.unproven_caller.get().filter(|_| agent).cloned(),
        state: State::Queued,
        attempts: 0,
        // A frame that left may have reached the peer: never through the mesh relay either way.
        never_sent: false,
        relay_post: None,
        interactive: Some(Interactive {
            peer: peer.name.clone(),
            expires_at: now.saturating_add(INTERACTIVE_WAIT_MS),
            replay: Replay { app: conn.origin == Origin::LocalApp, person: conn.is_person() },
        }),
        error: Some(error.message.clone()),
        accepted: None,
        created_at: now,
        updated_at: now,
    };
    // Its attachments are kept beside outbox.json, as a `send_queue` message's are.
    let kept = hub.outbox.attachments_path(&new);
    if let Some(path) = kept.clone() {
        let request = new.request.clone();
        tokio::task::spawn_blocking(move || crate::hub::outbox::keep_attachments(&path, &request))
            .await
            .map_err(|e| RpcError::internal(e.to_string()))?
            .map_err(|e| RpcError::internal(format!("cannot keep the attachments: {e:#}")))?;
    }
    let added = {
        let (hub, new) = (hub.clone(), new.clone());
        tokio::task::spawn_blocking(move || {
            crate::qos::on_screen(|| hub.outbox.add_interactive(new, INTERACTIVE_MAX_PER_PEER))
        })
        .await
        .map_err(|e| RpcError::internal(e.to_string()))?
    };
    let forget = |path: Option<std::path::PathBuf>| async move {
        if let Some(path) = path {
            let _ = tokio::task::spawn_blocking(move || std::fs::remove_file(path)).await;
        }
    };
    match added {
        Ok(delivery) if delivery.id == new.id => {
            super::outbox::spawn(hub.clone(), delivery.id.clone());
            Ok(delivery)
        }
        // The same prompt id waits already (a Retry of it): this send waits on that one.
        Ok(delivery) => {
            forget(kept).await;
            Ok(delivery)
        }
        Err(waiting) => {
            forget(kept).await;
            Err(full(&peer.name, waiting, error))
        }
    }
}

/// The refusal once [`INTERACTIVE_MAX_PER_PEER`] prompts already wait for `peer`.
fn full(peer: &str, waiting: usize, error: &RpcError) -> RpcError {
    RpcError::internal(format!(
        "{INTERACTIVE_FULL}: {waiting} prompts already wait for {peer} to come back; this one was not sent ({})",
        error.message
    ))
    .with_data(json!({
        "reason": INTERACTIVE_FULL,
        "peer": peer,
        "waiting": waiting,
        "retryable": true,
    }))
}

/// The peer's acceptance of delivery `id` once the outbox delivered it, or why it did not.
async fn settled(hub: &Hub, id: &str) -> Result<Value, RpcError> {
    loop {
        let changed = hub.outbox.changed.notified();
        let delivery = hub
            .outbox
            .get(id)
            .ok_or_else(|| RpcError::internal(format!("delivery {id} is gone")))?;
        match delivery.state {
            State::Delivered => return Ok(delivery.accepted.unwrap_or(Value::Null)),
            State::Failed | State::Held => return Err(not_delivered(&delivery)),
            State::Queued | State::Delivering => changed.await,
        }
    }
}

/// Why a waiting prompt was not delivered: its peer stayed away past its wait, or the peer
/// refused it when the link was back (its words).
fn not_delivered(delivery: &Delivery) -> RpcError {
    let error = delivery.error.clone().unwrap_or_else(|| "not delivered".to_owned());
    let reason = if delivery.expired_waiting() {
        INTERACTIVE_EXPIRED
    } else if delivery.state == State::Held {
        "outbox.held"
    } else {
        "outbox.failed"
    };
    RpcError::internal(error).with_data(json!({
        "reason": reason,
        "deliveryId": delivery.id,
        "peer": delivery.interactive.as_ref().map(|i| &i.peer),
        "held": delivery.state == State::Held,
    }))
}

/// The outcome of prompt `prompt_id`, which the peer of `target` accepted: the peer's ledger
/// answers it once the turn ends (`wait.rs` `promptOutcome`), asked again on each link while the
/// link drops, never sending the prompt again.
async fn outcome(hub: &Arc<Hub>, target: &str, prompt_id: &str) -> Result<Value, RpcError> {
    loop {
        let (peer, id, _) = hub
            .resolve_remote(target)
            .ok_or_else(|| RpcError::not_found(format!("no session matches {target}")))?;
        let mut settled = peer.settled();
        let asked = peer
            .request(
                method::MUX_WAIT,
                json!({"sessionId": id, "promptId": prompt_id, "until": ["promptOutcome"]}),
            )
            .await;
        match asked {
            Err(e) if link_failed(hub, &e).is_some() => {
                peer.want();
                // A peer removed or stopped settles no more: its failure is the answer.
                if settled.changed().await.is_err() {
                    return Err(e);
                }
            }
            answer => return answer,
        }
    }
}

#[cfg(test)]
#[path = "prompt_outbox_tests.rs"]
mod tests;
