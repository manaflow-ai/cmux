//! `_acpmux/send_queue` and `_acpmux/send_status`: the transport `acpmux send --no-wait` uses
//! (`hub/outbox.rs` has the record and the design).
//!
//! `send_queue {request}` takes the `session/prompt` params the CLI would have sent, records them
//! and answers at once with the delivery id; only the unix socket may (the daemon sends them on
//! as the unix socket does). Each delivery then runs here: it opens a connection to this daemon,
//! as the sender's own session when the sender proved one (its caller token, minted again), and
//! sends the prompt there, so every rule of a direct send applies, and a peer's session is
//! forwarded as usual (`peer_forward.rs`). An attempt ends on the target's acceptance (or its
//! answer), on a refusal, or after [`ATTEMPT_WAIT`]. A connection error, a peer that is down
//! and a slow target are tried again after [`RETRY_DELAYS_SECS`], with the same prompt id and
//! `resend`, so a target that took the first attempt answers with it and never runs it twice. A
//! refusal (no such session, the folder's trust, a bad prompt, a full agent pair) fails the
//! delivery at once, and a paused agent pair (`agent_pairs.rs`) leaves it `held` there: the
//! person's resume runs it, so it is never sent again from here.
//!
//! The mesh relay is a transport under this outbox, never a way around it. While a peer's link is
//! down and no attempt has left this daemon, an attempt that fails as not sent hands a text-only
//! delivery to the team hub, addressed to the session id the peer's last list named
//! (`mesh_send.rs` `relay`). The hub's receipt settles the delivery as delivered there; a
//! delivery the relay cannot carry (attachments, `--supersede`, a class) or a hub that refuses it
//! stays here and is tried again as before. A post whose answer was lost may have reached the
//! hub, so that delivery is tried again only through the relay, never on the peer's link too.
//!
//! `send_status {deliveryId, waitMs?}` answers the delivery's state, after waiting up to
//! `waitMs` (at most [`MAX_STATUS_WAIT_MS`]) for it to settle. A target no one here resolves goes
//! to the mesh hub when the relay is on, and its status is the hub's receipt (`mesh_send.rs`).

use crate::no_panic::JsonExt;
use std::time::Duration;

use super::*;
use crate::hub::outbox::{Delivery, RETRY_DELAYS_SECS, State};

/// What an attempt that did not deliver leaves the delivery as.
#[derive(Debug, PartialEq)]
pub(super) enum Next {
    /// Tried again after the next delay.
    Retry,
    /// Tried again too, and known never to have left this daemon (a peer that is down): the
    /// mesh relay may carry it instead.
    Unsent,
    /// A refusal: failed, with its error.
    Fail,
    /// The target holds it for a paused agent pair.
    Held,
}

/// How long one attempt waits for the target's acceptance.
const ATTEMPT_WAIT: Duration = Duration::from_secs(120);
/// The waits before each attempt after the first: about 34 minutes in all, then it fails.
/// The longest a `send_status` waits for a delivery to settle.
const MAX_STATUS_WAIT_MS: u64 = 10_000;

pub(super) async fn handle(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    params: &Value,
) -> Result<Value, RpcError> {
    if m == method::MUX_SEND_STATUS {
        return status(hub, conn, params).await;
    }
    if conn.origin != Origin::Local {
        return Err(crate::hub::outbox::local_only());
    }
    let mut request =
        params.get("request").filter(|r| r.is_object()).cloned().ok_or_else(|| {
            RpcError::invalid_params("request (the session/prompt params) is required")
        })?;
    let target = request
        .get("sessionId")
        .and_then(Value::as_str)
        .filter(|t| !t.is_empty())
        .ok_or_else(|| RpcError::invalid_params("request.sessionId is required"))?
        .to_owned();
    // Team-scoped addresses are always hub-routed and are never resolved as
    // local session names. The mesh sender applies the Labs gate and address
    // validation before posting them.
    if target.starts_with('@') {
        if let Some(mesh) = hub.mesh.get() {
            return super::mesh_send::send(hub, conn, mesh, &request, &target).await;
        }
        return Err(RpcError::invalid_params("team messaging requires a configured mesh relay")
            .with_data(json!({"reason": "team_messaging_unavailable", "address": target})));
    }
    // A session here, one a peer lists, or one on a peer that is down now: anything else is no
    // session, said at once.
    if hub.resolve(&target).is_err()
        && hub.resolve_remote(&target).is_none()
        && hub.peer_down_for(&target).is_none()
    {
        // With the mesh relay on, the team hub may know a name nothing here or on a peer matches
        // (`mesh_send.rs`); a name several sessions here or on peers match stays this daemon's
        // refusal (`Hub::mesh_may_route`).
        if let Some(mesh) = hub.mesh.get()
            && hub.mesh_may_route(&target)
        {
            return super::mesh_send::send(hub, conn, mesh, &request, &target).await;
        }
        // The names it nearly matched, so the sender can pick one (`Hub::unknown_session`).
        let close = hub.unknown_session(&target).data.and_then(|d| d.get("candidates").cloned());
        let mut data = json!({"reason": "no_session", "session": target});
        if let Some(close) = close {
            data.set("candidates", close);
        }
        return Err(RpcError::invalid_params(format!("no session: {target}")).with_data(data));
    }
    // Over the caps it is refused now, never kept (`attach.rs`).
    crate::attach::check_wire(&request)?;
    let mux = request
        .as_object_mut()
        .map(|r| r.entry("_meta").or_insert_with(|| json!({})))
        .and_then(Value::as_object_mut)
        .map(|meta| meta.entry("acpmux").or_insert_with(|| json!({})))
        .and_then(Value::as_object_mut)
        .ok_or_else(|| RpcError::invalid_params("request._meta.acpmux must be an object"))?;
    mux.remove("forwardProjection");
    if mux.get("promptId").and_then(Value::as_str).is_none_or(str::is_empty) {
        mux.insert("promptId".into(), json!(uuid::Uuid::now_v7().to_string()));
    }
    let now = crate::store::now_ms();
    let delivery_id = uuid::Uuid::now_v7().to_string();
    if let Some(mux) = request.pointer_mut("/_meta/acpmux").and_then(Value::as_object_mut) {
        mux.insert("messageId".into(), Value::String(delivery_id.clone()));
    }
    let new = Delivery {
        id: delivery_id,
        target,
        request,
        caller: conn.caller().filter(|_| !conn.is_person()).map(str::to_owned),
        state: State::Queued,
        attempts: 0,
        never_sent: true,
        relay_post: None,
        error: None,
        accepted: None,
        created_at: now,
        updated_at: now,
    };
    // Its attachments are kept beside outbox.json, once, not in each rewrite of it.
    let kept = hub.outbox.attachments_path(&new);
    if let Some(path) = kept.clone() {
        let request = new.request.clone();
        tokio::task::spawn_blocking(move || crate::hub::outbox::keep_attachments(&path, &request))
            .await
            .map_err(|e| RpcError::internal(e.to_string()))?
            .map_err(|e| RpcError::internal(format!("cannot keep the attachments: {e:#}")))?;
    }
    let delivery = hub.outbox.add(new.clone());
    // The same prompt id again: the first delivery, already on its way.
    if delivery.id == new.id {
        spawn(hub.clone(), delivery.id.clone());
    } else {
        if let Some(path) = kept {
            forget_attachments(path).await;
        }
        drop_own_uploads(hub, &new, &delivery).await;
    }
    Ok(delivery.status())
}

/// A direct peer send needs a durable projection intent: the peer may accept
/// just before this daemon exits and loses its in-memory acceptance callback.
/// Recovery only reads the target journal; it never retransmits a direct prompt.
/// send_queue entries keep their own delivery/retry semantics; this separate
/// intent stays pending if persisting the sender projection fails after acceptance.
/// The message id a forwarded prompt's receiver keeps (`server/requests.rs` takes a nonempty
/// `messageId`, else the prompt id), so the sender's intent and acceptance check name the same one.
pub(super) fn forwarded_message_id(params: &Value) -> &str {
    let nonempty = |key: &str| {
        params
            .pointer(&format!("/_meta/acpmux/{key}"))
            .and_then(Value::as_str)
            .filter(|id| !id.is_empty())
    };
    nonempty("messageId").or_else(|| nonempty("promptId")).unwrap_or_default()
}

pub(super) async fn remember_forward(
    hub: &Arc<Hub>,
    peer: &str,
    target: &str,
    caller: &str,
    params: &Value,
) -> Result<String, RpcError> {
    let prompt_id = params.pointer("/_meta/acpmux/promptId").and_then(Value::as_str);
    let target = format!("{peer}/{target}");
    let text = params
        .get("prompt")
        .and_then(Value::as_array)
        .map(|blocks| crate::hub::prompt_text(blocks))
        .or_else(|| params.get("text").and_then(Value::as_str).map(str::to_owned))
        .unwrap_or_default();
    let message_id = forwarded_message_id(params);
    let sender = params.pointer("/_meta/acpmux/messageSender").cloned().unwrap_or_else(|| {
        json!({"name": hub.session_name(caller), "sessionId": caller,
                                 "host": crate::hub::host_label()})
    });
    // Store only the projection and its address: recovery needs no attachments,
    // caller tokens, or executable prompt payload.
    let request = json!({"sessionId": target, "_meta": {"acpmux": {
        "promptId": prompt_id,
        "forwardProjection": {"sender": sender, "text": text, "messageId": message_id}
    }}});
    let now = crate::store::now_ms();
    let intent = Delivery {
        id: uuid::Uuid::now_v7().to_string(),
        target,
        request,
        caller: Some(caller.to_owned()),
        // Held is terminal to older daemons: rollback never sends this lookup
        // record as a prompt. New code recognizes the forwardProjection marker.
        state: State::Held,
        attempts: 0,
        never_sent: false,
        relay_post: None,
        error: None,
        accepted: None,
        created_at: now,
        updated_at: now,
    };
    hub.outbox
        .remember_forward(intent)
        .map(|delivery| delivery.id)
        .map_err(|e| RpcError::internal(format!("cannot persist peer message intent: {e:#}")))
}

/// Find a receiver projection across every page, including messages still queued
/// there. Only a locally recorded intent can name the source journal to repair.
async fn reconcile_forward(hub: &Arc<Hub>, delivery: &Delivery) -> Result<Value, (String, Next)> {
    let intent =
        delivery.request.pointer("/_meta/acpmux/forwardProjection").unwrap_or(&Value::Null);
    let caller = delivery.caller.as_deref().unwrap_or_default();
    // A restart resumes the outbox before the saved sessions load (`daemon.rs`): the sender is
    // read on demand, or after the load, before its absence counts.
    hub.session_meta(caller).await;
    let source = hub
        .resolve(caller)
        .ok()
        .filter(|s| s.id == caller)
        .ok_or_else(|| ("the message sender no longer exists".to_owned(), Next::Fail))?;
    // The intent's target is `peer/chat` (`remember_forward`).
    let (target_peer, target) =
        delivery.target.split_once('/').unwrap_or(("", delivery.target.as_str()));
    if let Some(accepted) = &delivery.accepted {
        if hub.append_sender_message_event(
            &source.id,
            intent["sender"].clone(),
            intent["text"].as_str().unwrap_or_default().to_owned(),
            intent["messageId"].as_str().unwrap_or_default().to_owned(),
            delivery.updated_at,
            target_peer,
            target,
        ) {
            return Ok(accepted.clone());
        }
        return Err(("cannot persist sender message projection".into(), Next::Retry));
    }
    let (peer, target, _) = hub
        .resolve_remote(&delivery.target)
        .ok_or_else(|| ("the message receiver is not reachable yet".to_owned(), Next::Retry))?;
    let mut after = 0;
    loop {
        let page = peer
            .request(
                method::MUX_EVENTS,
                json!({
                    "sessionId": target, "afterSeq": after, "limit": 256,
                    "kinds": ["_acpmux/message"]
                }),
            )
            .await
            .map_err(|e| (e.message, Next::Retry))?;
        let events = page
            .get("events")
            .and_then(Value::as_array)
            .ok_or_else(|| ("peer returned no message page".to_owned(), Next::Retry))?;
        for event in events {
            let msg = &event["msg"];
            if event["kind"] == "_acpmux/message"
                && msg["messageId"] == intent["messageId"]
                && msg["sessionId"] == target
                && msg.pointer("/sender/sessionId").and_then(Value::as_str) == Some(caller)
            {
                if !hub.append_sender_message_event(
                    &source.id,
                    intent["sender"].clone(),
                    intent["text"].as_str().unwrap_or_default().to_owned(),
                    intent["messageId"].as_str().unwrap_or_default().to_owned(),
                    msg["at"].as_u64().unwrap_or_else(crate::store::now_ms),
                    target_peer,
                    &target,
                ) {
                    return Err((
                        "cannot persist sender message projection".to_owned(),
                        Next::Retry,
                    ));
                }
                return Ok(json!({"sessionId": target, "promptId": delivery.prompt_id(),
                                 "recovered": true}));
            }
        }
        if page.get("hasMore").and_then(Value::as_bool) != Some(true) {
            return Err(("the receiver has not recorded this message".to_owned(), Next::Retry));
        }
        let next = events.iter().filter_map(|e| e["seq"].as_u64()).max().unwrap_or(after);
        if next <= after {
            return Err(("peer message page did not advance".to_owned(), Next::Retry));
        }
        after = next;
    }
}

/// Settle only after the caller has written the sender-side message projection.
pub(super) fn forward_accepted(hub: &Arc<Hub>, id: &str, accepted: Value, stored: bool) {
    hub.outbox.update(id, |d| {
        if d.request.pointer("/_meta/acpmux/forwardProjection").is_none()
            || d.state == State::Delivered
        {
            return;
        }
        d.state = if stored { State::Delivered } else { State::Held };
        d.accepted = Some(accepted);
        d.error = None;
        crate::attach::strip(&mut d.request);
    });
    if !stored {
        spawn(hub.clone(), id.to_owned());
    }
}

/// The peer answered as for a prompt id it took before (`peer_forward.rs` `is_duplicate`): the
/// message it kept may be another one (a direct send, then a `send_queue` retry of its prompt id
/// with its own delivery id). Nothing is recorded from the answer; the intent reads the
/// receiver's journal for its own message id, as after a restart, and records the sender's copy
/// only when the receiver holds it, or fails when its retries run out.
pub(super) fn forward_unconfirmed(hub: &Arc<Hub>, id: &str) {
    hub.outbox.update(id, |d| {
        if d.request.pointer("/_meta/acpmux/forwardProjection").is_none() || d.settled() {
            return;
        }
        d.state = State::Held;
        d.accepted = None;
        d.error = Some("the peer took this prompt id before; reading its journal".into());
    });
    if hub.outbox.get(id).is_some_and(|d| !d.settled()) {
        spawn(hub.clone(), id.to_owned());
    }
}

pub(super) fn forward_refused(hub: &Arc<Hub>, id: &str, error: &RpcError) {
    hub.outbox.update(id, |d| {
        // A turn can fail after its message was accepted. It cannot undo that
        // acceptance or turn a delivered event into a failed delivery.
        if d.settled() || d.accepted.is_some() {
            return;
        }
        // A refusal can come back before the acceptance notice it followed (a steer-only
        // prompt taken, then refused with no turn), and the receiver's copy may still wait on
        // its repair: only the receiver's journal settles it, read on the retry schedule
        // (`reconcile_forward`), as for any unconfirmed intent.
        d.state = State::Held;
        d.error = Some(error.message.clone());
    });
    // The request may have reached the peer before a disconnect. Reconcile its
    // journal without sending the prompt again, even if this daemon stays up.
    if hub.outbox.get(id).is_some_and(|d| !d.settled()) {
        spawn(hub.clone(), id.to_owned());
    }
}

/// A send that the outbox answered with an earlier delivery of the same prompt id: the uploads
/// it named as its own and the earlier one names not at all (`attach::blocks_for` uploaded them
/// for this send) are never read, so they go, on this daemon or on the peer that holds the chat.
/// Each cancel carries its owner token, which the daemon that holds the upload checks.
async fn drop_own_uploads(hub: &Arc<Hub>, new: &Delivery, kept: &Delivery) {
    let blocks = |d: &Delivery| {
        d.request.get("prompt").and_then(Value::as_array).cloned().unwrap_or_default()
    };
    let keep = crate::prompt_uploads::upload_ids(&blocks(kept));
    let own = crate::prompt_uploads::owned_refs(&blocks(new));
    let spelled = |id: &str| uuid::Uuid::try_parse(id).map(|id| id.to_string()).ok();
    for (upload, token) in
        own.into_iter().filter(|(id, _)| spelled(id).is_some_and(|id| !keep.contains(&id)))
    {
        if let Ok(session) = hub.resolve(&new.target) {
            let params = json!({"uploadId": upload, "ownerToken": token});
            let id = session.id.clone();
            let _ =
                tokio::task::spawn_blocking(move || crate::hub::file_uploads::cancel(&id, &params))
                    .await;
        } else if let Some((peer, id, _)) = hub.resolve_remote(&new.target) {
            let params = json!({"sessionId": id, "uploadId": upload, "ownerToken": token});
            let _ = peer.request(method::MUX_FILE_PUT_CANCEL, params).await;
        }
    }
}

async fn status(hub: &Arc<Hub>, conn: &Arc<Conn>, params: &Value) -> Result<Value, RpcError> {
    let id = str_param(params, "deliveryId")
        .ok_or_else(|| RpcError::invalid_params("deliveryId is required"))?;
    if id.starts_with(super::mesh_send::PREFIX)
        && let Some(mesh) = hub.mesh.get()
    {
        return super::mesh_send::status(hub, conn, mesh, id).await;
    }
    let status = outbox_status(hub, id, params).await?;
    match hub.outbox.get(id) {
        Some(delivery) if delivery.settled() => {
            Ok(relayed_status(hub, conn, &delivery, status).await)
        }
        _ => Ok(status),
    }
}

/// `_acpmux/send_status` of an outbox delivery `id`, waiting up to `waitMs` for it to settle.
async fn outbox_status(hub: &Arc<Hub>, id: &str, params: &Value) -> Result<Value, RpcError> {
    let wait = params.get("waitMs").and_then(Value::as_u64).unwrap_or(0).min(MAX_STATUS_WAIT_MS);
    let deadline = tokio::time::Instant::now() + Duration::from_millis(wait);
    loop {
        let changed = hub.outbox.changed.notified();
        let delivery = hub.outbox.get(id).ok_or_else(|| {
            RpcError::invalid_params(format!("no delivery {id}"))
                .with_data(json!({"reason": "outbox.unknown", "deliveryId": id}))
        })?;
        if delivery.settled() || tokio::time::Instant::now() >= deadline {
            return Ok(delivery.status());
        }
        let _ = tokio::time::timeout_at(deadline, changed).await;
    }
}

/// `own`, the status of `delivery`, or, once the mesh relay took it, the hub's message's: `own`
/// when the hub does not answer.
async fn relayed_status(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    delivery: &Delivery,
    own: Value,
) -> Value {
    let relayed = delivery.accepted.as_ref().and_then(|a| a.get("relayDeliveryId"));
    let (Some(relay), Some(mesh)) = (relayed.and_then(Value::as_str), hub.mesh.get()) else {
        return own;
    };
    match super::mesh_send::status(hub, conn, mesh, relay).await {
        Ok(mut status) => {
            // What `acpmux send` reads of an acceptance: whether it steered, and the session.
            if let (Some(accepted), Some(kept)) = (
                status.get_mut("accepted").and_then(Value::as_object_mut),
                delivery.accepted.as_ref(),
            ) {
                for key in ["steer", "sessionId"] {
                    if let Some(v) = kept.get(key).filter(|v| !v.is_null()) {
                        accepted.insert(key.into(), v.clone());
                    }
                }
            }
            status.set("deliveryId", json!(delivery.id));
            status.set("relayDeliveryId", json!(relay));
            status.set("target", json!(delivery.target));
            status
        }
        Err(_) => own,
    }
}

/// Delivers the ones a restart left unsettled (`Hub` `outbox.open`).
pub fn resume(hub: &Arc<Hub>, pending: Vec<Delivery>) {
    for delivery in pending {
        spawn(hub.clone(), delivery.id);
    }
}

fn spawn(hub: Arc<Hub>, id: String) {
    if !hub.outbox.start_delivery(&id) {
        return;
    }
    tokio::spawn(async move {
        struct Running(Arc<Hub>, String);
        impl Drop for Running {
            fn drop(&mut self) {
                self.0.outbox.end_delivery(&self.1);
            }
        }
        let _running = Running(hub.clone(), id.clone());
        deliver(&hub, &id).await;
    });
}

async fn deliver(hub: &Arc<Hub>, id: &str) {
    let mut delays = RETRY_DELAYS_SECS.iter();
    loop {
        let Some(delivery) = hub.outbox.get(id) else { return };
        if delivery.settled() {
            return;
        }
        let attempt = delivery.attempts + 1;
        hub.outbox.update(id, |d| {
            if !d.settled() {
                start_attempt(d, attempt);
            }
        });
        if hub.outbox.get(id).is_none_or(|d| d.settled()) {
            return;
        }
        let mut request = delivery.request.clone();
        // A later attempt asks for the first one's outcome when the target took it already.
        if attempt > 1
            && let Some(mux) = request.pointer_mut("/_meta/acpmux").and_then(Value::as_object_mut)
        {
            mux.insert("resend".into(), json!(true));
        }
        // Whether the peer's link, if this attempt used it, took nothing (`Delivery::never_sent`).
        let mut link_unsent = true;
        let outcome = if request.pointer("/_meta/acpmux/forwardProjection").is_some() {
            // A projection reconciles with the receiver's log; it never uses the link to send.
            link_unsent = false;
            tokio::time::timeout(ATTEMPT_WAIT, reconcile_forward(hub, &delivery))
                .await
                .unwrap_or_else(|_| Err(("peer message lookup timed out".into(), Next::Retry)))
        } else if delivery.relay_post.is_some() {
            // The hub may hold it already: only the relay tries it again. With the relay off here
            // it may still deliver it (the target's daemon reads it), so it is never sent twice.
            relay_attempt(hub, &delivery).await.unwrap_or_else(|| {
                let key = delivery.relay_post.as_ref().map_or("", |m| m.idempotency_key.as_str());
                let why = format!(
                    "the mesh relay is off here; the team hub may hold it (key {key}), so it is not sent again another way"
                );
                Err((why, Next::Retry))
            })
        } else {
            let outcome =
                attempt_once(hub, delivery.caller.as_deref(), request, Origin::Local).await;
            link_unsent = matches!(outcome, Err((_, Next::Unsent)));
            match outcome {
                // Nothing has reached the target: the mesh relay carries it when it can.
                Err((error, Next::Unsent)) if delivery.never_sent => {
                    match relay_attempt(hub, &delivery).await {
                        Some(Ok(accepted)) => Ok(accepted),
                        Some(Err((why, next))) => Err((format!("{error}; {why}"), next)),
                        None => Err((error, Next::Unsent)),
                    }
                }
                outcome => outcome,
            }
        };
        match outcome {
            Ok(accepted) => {
                hub.outbox.update(id, |d| {
                    d.state = State::Delivered;
                    d.error = None;
                    d.accepted = Some(accepted);
                    // Settled: its record keeps no attachment bytes (`attach.rs`).
                    crate::attach::strip(&mut d.request);
                });
                if let Some(path) = hub.outbox.attachments_path(&delivery) {
                    forget_attachments(path).await;
                }
                return;
            }
            Err((error, next)) => {
                let delay = delays.next().filter(|_| matches!(next, Next::Retry | Next::Unsent));
                hub.outbox.update(id, |d| {
                    if d.settled() {
                        return;
                    }
                    d.never_sent = delivery.never_sent && link_unsent;
                    d.state = match (next, delay) {
                        (Next::Held, _) => State::Held,
                        (_, Some(_)) if d.projection_only() => State::Held,
                        (_, Some(_)) => State::Queued,
                        _ => State::Failed,
                    };
                    d.error = Some(error);
                    if d.settled() {
                        crate::attach::strip(&mut d.request);
                    }
                });
                if hub.outbox.get(id).is_none_or(|d| d.state == State::Delivered) {
                    return;
                }
                let Some(secs) = delay else {
                    if let Some(path) = hub.outbox.attachments_path(&delivery) {
                        forget_attachments(path).await;
                    }
                    return;
                };
                tokio::time::sleep(Duration::from_secs(*secs)).await;
            }
        }
    }
}

/// One attempt through the mesh relay (`mesh_send.rs` `relay`): the hub's acceptance, or why
/// not and what next. The hub answers a key it holds before it checks anything else, so a hub
/// that refused the post outright holds none: the peer's link may try it again (`Next::Unsent`).
/// The two refusals that say it holds an earlier message under the key, and any failure that may
/// have left the post with it, keep it for the relay alone (`Delivery::relay_post`). None when
/// the relay cannot carry it.
async fn relay_attempt(
    hub: &Arc<Hub>,
    delivery: &Delivery,
) -> Option<Result<Value, (String, Next)>> {
    let outcome = super::mesh_send::relay(hub, delivery).await?;
    Some(outcome.map_err(|e| {
        let held =
            matches!(e.code.as_deref(), Some("mesh.idempotency_conflict" | "mesh.not_found"));
        let next = if e.refused && !held {
            hub.outbox.update(&delivery.id, |d| d.relay_post = None);
            Next::Unsent
        } else {
            Next::Retry
        };
        (format!("the mesh relay did not take it: {e}"), next)
    }))
}

/// What delivery `d` is saved as while its attempt `attempt` runs: the record a restart resumes.
/// An attempt on the peer's link may put the frame on the wire before a crash, so it is saved as
/// maybe sent (`never_sent` false) and marked never sent again only once the link refuses it as
/// not sent. A relay-only attempt never touches the link and leaves it.
fn start_attempt(d: &mut Delivery, attempt: u32) {
    d.state = if d.projection_only() { State::Held } else { State::Delivering };
    d.attempts = attempt;
    if d.relay_post.is_none() {
        d.never_sent = false;
    }
}

/// Deletes a settled delivery's kept attachments.
async fn forget_attachments(path: std::path::PathBuf) {
    let _ = tokio::task::spawn_blocking(move || std::fs::remove_file(path)).await;
}

/// One attempt: the target's acceptance, or the error and whether to try again. It runs on a
/// connection of `origin`: the unix socket's for a send here, a peer's for a message the mesh
/// relay delivers (`mesh_relay.rs`), so each is held to its origin's rules.
pub(super) async fn attempt_once(
    hub: &Arc<Hub>,
    caller: Option<&str>,
    request: Value,
    origin: Origin,
) -> Result<Value, (String, Next)> {
    let target = request.get("sessionId").and_then(Value::as_str).unwrap_or_default();
    let summary = hub
        .resolve(target)
        .ok()
        .map(|session| hub.session_summary(&session))
        .or_else(|| hub.resolve_remote(target).map(|(_, _, summary)| summary));
    if let Some(summary) = summary {
        let config = hub.config.read().await.machine_wake.clone();
        if let Some(config) = config
            && let Err(error) = crate::machine_wake::wake(&config, &summary).await
        {
            return Err((format!("machine wake failed: {error}"), Next::Retry));
        }
    }
    let prompt_id = request
        .pointer("/_meta/acpmux/promptId")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_owned();
    let (in_tx, in_rx) = mpsc::channel(16);
    let (out_tx, mut out_rx) = mpsc::channel(1024);
    tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, origin));
    let mut hello = json!({
        "protocolVersion": 1,
        "clientCapabilities": {},
        "clientInfo": {"name": "acpmux-outbox", "version": crate::hub::VERSION},
    });
    if let Some(id) = caller {
        let mut mux = serde_json::Map::new();
        mux.insert(
            crate::hub::person::CALLER_FIELD.to_owned(),
            json!({"sessionId": id, "token": crate::hub::person::caller_token(id)}),
        );
        hello.set("_meta", json!({"acpmux": mux}));
    }
    let lines = [
        Message::request(1, method::INITIALIZE, hello).to_line(),
        Message::request(2, method::SESSION_PROMPT, request).to_line(),
    ];
    for line in lines {
        if in_tx.send(line).await.is_err() {
            return Err(("this daemon's connection closed".into(), Next::Retry));
        }
    }
    let deadline = tokio::time::sleep(ATTEMPT_WAIT);
    tokio::pin!(deadline);
    loop {
        let line = tokio::select! {
            line = out_rx.recv() => line,
            () = &mut deadline => {
                return Err((
                    format!("no answer within {} s", ATTEMPT_WAIT.as_secs()),
                    Next::Retry,
                ));
            }
        };
        let Some(line) = line else {
            return Err(("this daemon's connection closed".into(), Next::Retry));
        };
        match Message::parse(&line) {
            // A duplicate with no turn is a run of this id still in flight, which may yet be
            // held or refused: its answer says.
            Ok(Message::Notification { method: m, params: Some(p) })
                if m == method::MUX_PROMPT_ACCEPTED
                    && p.get("promptId").and_then(Value::as_str) == Some(prompt_id.as_str())
                    && !(p.get("duplicate") == Some(&Value::Bool(true))
                        && p.get("turnId").is_none_or(Value::is_null)) =>
            {
                return Ok(p);
            }
            Ok(Message::Response { id, result, error }) if id == 2 => {
                return match error {
                    None => Ok(result.unwrap_or(Value::Null)),
                    Some(e) => Err((e.message.clone(), next(&e))),
                };
            }
            Ok(Message::Response { id, error: Some(e), .. }) if id == 1 => {
                return Err((e.message, Next::Retry));
            }
            _ => {}
        }
    }
}

/// A paused pair holds it; any other refusal (a full pair among them) is final; a connection, a
/// peer or a timeout is tried again.
fn next(e: &RpcError) -> Next {
    let data = e.data.as_ref();
    if data.and_then(|d| d.get("held")).and_then(Value::as_bool) == Some(true) {
        return Next::Held;
    }
    let reason = data.and_then(|d| d.get("reason")).and_then(Value::as_str).unwrap_or_default();
    // The peer's link took nothing (`peer_link::unreachable_error`): the request was not sent.
    if reason == "peer_unreachable" {
        return Next::Unsent;
    }
    let flagged = data.and_then(|d| d.get("retryable")).and_then(Value::as_bool);
    match flagged {
        _ if reason.starts_with("agent_pair.") => Next::Fail,
        Some(true) => Next::Retry,
        Some(false) => Next::Fail,
        None if e.code != RpcError::invalid_params("").code => Next::Retry,
        None => Next::Fail,
    }
}

#[cfg(test)]
mod forward_projection_tests {
    use super::*;
    use crate::config::{Config, StoreMode};
    use crate::hub::{EventFilter, NewRequest};

    fn config(mode: StoreMode) -> Config {
        let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
        let mut config: Config = serde_json::from_value(json!({
            "harnesses": {"fake": {"argv": ["python3", fake]}},
            "defaultHarness": "fake", "permissionPolicy": "approve-all"
        }))
        .unwrap();
        config.store.mode = mode;
        config
    }

    #[tokio::test]
    async fn forward_intent_requires_successful_persistence_even_on_retry() {
        let dir = std::env::temp_dir().join(format!("forward-write-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(&dir).unwrap();
        // A regular file in the parent path injects a deterministic write failure,
        // including when the tests run as a user that can bypass file permissions.
        let blocked_parent = dir.join("blocked");
        std::fs::write(&blocked_parent, b"block").unwrap();
        let path = blocked_parent.join("outbox.json");
        let config = config(StoreMode::Memory);
        let hub = Hub::new(config.clone(), crate::store::open(&config.store, &dir).unwrap());
        hub.outbox.open(&path);
        let request = json!({"sessionId": "receiver", "text": "hello", "_meta": {"acpmux": {
            "promptId": "write-failure", "messageId": "message-write-failure",
            "messageSender": {"name": "sender", "sessionId": "sender"}
        }}});
        let error = remember_forward(&hub, "remote", "receiver", "sender", &request)
            .await
            .expect_err("a peer request must not proceed without its durable intent");
        assert!(error.message.contains("cannot persist peer message intent"));
        assert!(
            remember_forward(&hub, "remote", "receiver", "sender", &request).await.is_err(),
            "an existing in-memory intent must not bypass the failed write"
        );
        std::fs::remove_file(&blocked_parent).unwrap();
        std::fs::create_dir(&blocked_parent).unwrap();
        let id = remember_forward(&hub, "remote", "receiver", "sender", &request)
            .await
            .expect("retry succeeds once the intent can be persisted");
        let reopened = crate::hub::outbox::Outbox::default();
        let pending = reopened.open(&path);
        assert_eq!(pending.len(), 1, "retries preserve one durable intent");
        assert_eq!(pending[0].id, id);
        assert_eq!(pending[0].prompt_id(), "write-failure");
        assert!(pending[0].projection_only());
        std::fs::remove_dir_all(dir).unwrap();
    }

    /// A refusal that came back before its acceptance notice: the receiver's journal says
    /// whether the message was taken, also when its copy lands only later (a repair after a
    /// failed append). Until then the intent stays open, reading on the retry schedule.
    #[tokio::test]
    async fn a_refused_forward_reads_the_receiver_journal_once() {
        let dir = std::env::temp_dir().join(format!("forward-refused-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(&dir).unwrap();
        let config = config(StoreMode::Memory);
        let local = Hub::new(config.clone(), crate::store::open(&config.store, &dir).unwrap());
        let remote = Hub::new(config.clone(), crate::store::open(&config.store, &dir).unwrap());
        let new = |name: &str| NewRequest {
            name: Some(name.into()),
            cwd: Some(std::env::temp_dir()),
            ..NewRequest::default()
        };
        let sender = local.new_session(new("sender")).await.unwrap();
        let receiver = remote.new_session(new("receiver")).await.unwrap();
        let auth_dir = dir.join("peer-auth");
        let auth = crate::server::peer_auth::PeerAuth::create(&auth_dir).unwrap();
        let token =
            std::fs::read_to_string(crate::server::peer_auth::token_path(&auth_dir)).unwrap();
        let listener = bind_ws("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        tokio::spawn(serve_ws_with(
            remote.clone(),
            listener,
            "test".into(),
            WsAuth { local_app: None, peer: Some(Arc::new(auth)) },
        ));
        local
            .add_peer(
                "remote",
                &format!("ws://127.0.0.1:{port}"),
                Some("test".into()),
                Some(token),
                true,
            )
            .await
            .unwrap();
        let sender_meta = json!({"name": "sender", "sessionId": sender.id, "host": "local"});
        let intent = async |prompt_id: &str| {
            let request = json!({"sessionId": receiver.id,
                "prompt": [{"type": "text", "text": "steer only"}], "_meta": {"acpmux": {
                "promptId": prompt_id, "messageSender": sender_meta
            }}});
            remember_forward(&local, "remote", &receiver.id, &sender.id, &request).await.unwrap()
        };
        let refusal = RpcError::invalid_params("no turn to steer");
        assert_eq!(next(&refusal), Next::Fail);

        let taken = intent("p-taken").await;
        assert!(remote.append_message_event(
            &receiver,
            sender_meta.clone(),
            "steer only".into(),
            "p-taken".into(),
            1234
        ));
        forward_refused(&local, &taken, &refusal);
        let done = outbox_status(&local, &taken, &json!({"waitMs": 10_000})).await.unwrap();
        assert_eq!(done["status"], "delivered", "{done}");

        // The receiver's copy is not there at the first read: the intent stays open, and the
        // copy a repair appends later still gains the sender's.
        let repaired = intent("p-repaired").await;
        forward_refused(&local, &repaired, &refusal);
        let open = outbox_status(&local, &repaired, &json!({"waitMs": 1_000})).await.unwrap();
        assert_eq!(open["status"], "held", "{open}");
        assert!(remote.append_message_event(
            &receiver,
            sender_meta.clone(),
            "steer only".into(),
            "p-repaired".into(),
            1234
        ));
        let done = outbox_status(&local, &repaired, &json!({"waitMs": 10_000})).await.unwrap();
        assert_eq!(done["status"], "delivered", "{done}");

        let page = local
            .events_page(&sender.id, 0, None, 500, None, false, &EventFilter::parse(None).unwrap())
            .unwrap();
        let ids: Vec<_> = page
            .events
            .iter()
            .filter(|r| r.kind == "_acpmux/message")
            .map(|r| r.msg["messageId"].clone())
            .collect();
        assert_eq!(ids, vec![json!("p-taken"), json!("p-repaired")]);
        std::fs::remove_dir_all(&dir).ok();
    }

    #[tokio::test]
    async fn restarted_forward_recovers_sender_projection_without_resending_prompt() {
        let dir = std::env::temp_dir().join(format!("forward-projection-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(&dir).unwrap();
        let config = config(StoreMode::Local);
        let make_hub = || {
            let store = crate::store::open(&config.store, &dir).unwrap();
            Hub::new(config.clone(), store)
        };
        let original = make_hub();
        let outbox_path = dir.join("outbox.json");
        original.outbox.open(&outbox_path);
        let sender = original
            .new_session(NewRequest {
                name: Some("sender".into()),
                cwd: Some(std::env::temp_dir()),
                ..NewRequest::default()
            })
            .await
            .unwrap();
        let remote_config = self::config(StoreMode::Memory);
        let remote = Hub::new(
            remote_config.clone(),
            crate::store::open(&remote_config.store, &dir).unwrap(),
        );
        let receiver = remote
            .new_session(NewRequest {
                name: Some("receiver".into()),
                cwd: Some(std::env::temp_dir()),
                ..NewRequest::default()
            })
            .await
            .unwrap();
        let sender_meta = json!({"name": "sender", "sessionId": sender.id, "host": "local"});
        let request = json!({"sessionId": receiver.id,
            "prompt": [{"type": "text", "text": "already accepted"}], "_meta": {"acpmux": {
            "promptId": "p-restart", "messageId": "d-restart", "messageSender": sender_meta
        }}});
        let intent_id = remember_forward(&original, "remote", &receiver.id, &sender.id, &request)
            .await
            .unwrap();
        // The receiver accepted before the source recorded its outgoing projection.
        // Fill a first page to ensure recovery advances beyond the first 256 records.
        for n in 0..257 {
            assert!(remote.append_message_event(
                &receiver,
                json!({"name": "other", "sessionId": "other"}),
                "earlier".into(),
                format!("prior-{n}"),
                1
            ));
        }
        assert!(remote.append_message_event(
            &receiver,
            sender_meta.clone(),
            "already accepted".into(),
            "d-restart".into(),
            1234
        ));
        let before = receiver.meta().event_count;
        original.detach_child(&sender).await;
        original.store.flush().unwrap();
        // Reopen the source state as daemon startup does: the outbox resumes before the saved
        // sessions load (`daemon.rs`). No original callback survives.
        let restarted = Hub::new_loading(
            config.clone(),
            crate::store::open(&config.store, &dir).unwrap(),
            crate::mailbox::Mailbox::open(dir.join("mailbox")).unwrap(),
        );
        let pending = restarted.outbox.open(&outbox_path);
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].state, State::Held, "older daemons must never execute the lookup");
        assert!(pending[0].request.get("prompt").is_none(), "lookup keeps no executable prompt");
        let auth_dir = dir.join("peer-auth");
        let auth = crate::server::peer_auth::PeerAuth::create(&auth_dir).unwrap();
        let token =
            std::fs::read_to_string(crate::server::peer_auth::token_path(&auth_dir)).unwrap();
        let listener = bind_ws("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        tokio::spawn(serve_ws_with(
            remote.clone(),
            listener,
            "test".into(),
            WsAuth { local_app: None, peer: Some(Arc::new(auth)) },
        ));
        restarted
            .add_peer(
                "remote",
                &format!("ws://127.0.0.1:{port}"),
                Some("test".into()),
                Some(token),
                true,
            )
            .await
            .unwrap();
        resume(&restarted, pending);
        let loading = restarted.clone();
        tokio::spawn(async move { loading.load_store_async().await });
        let done = outbox_status(&restarted, &intent_id, &json!({"waitMs": 10_000})).await.unwrap();
        assert_eq!(done["status"], "delivered", "{done}");
        let page = restarted
            .events_page(&sender.id, 0, None, 500, None, false, &EventFilter::parse(None).unwrap())
            .unwrap();
        let messages: Vec<_> = page.events.iter().filter(|r| r.kind == "_acpmux/message").collect();
        assert_eq!(messages.len(), 1);
        assert_eq!(
            messages[0].msg,
            json!({"sessionId": sender.id, "sender": sender_meta,
            "text": "already accepted", "messageId": "d-restart", "at": 1234,
            "_acpmuxTarget": receiver.id, "_acpmuxTargetPeer": "remote"})
        );
        assert_eq!(
            receiver.meta().event_count,
            before,
            "recovery must never send the prompt again"
        );
        std::fs::remove_dir_all(&dir).unwrap();
    }
}

#[cfg(test)]
#[path = "outbox_relay_tests.rs"]
mod relay_tests;
