//! `_acpmux/send_queue` and `_acpmux/send_status`: the transport `acpmux send --no-wait` uses
//! (`hub/outbox.rs` has the record and the design).
//!
//! `send_queue {request}` takes the `session/prompt` params the CLI would have sent, records them
//! and answers at once with the delivery id; only the unix socket may (the daemon sends them on
//! as the unix socket does). Each delivery then runs here: it opens a connection to this daemon,
//! as the sender's own session when the sender proved one (its caller token, minted again), and
//! sends the prompt there, so every rule of a direct send applies, and a peer's session is
//! forwarded as usual (`peer_forward.rs`). An attempt ends on the target's acceptance (or its
//! answer), on a refusal, or after [`ATTEMPT_WAIT`] with nothing heard. A connection error, a
//! peer that is down and a slow target are tried again after [`RETRY_DELAYS_SECS`], with the same
//! prompt id and `resend`, so a target that took the first attempt answers with it and never runs
//! it twice. A
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
//! An `ssh://` peer's machine is also reached by a plain ssh login while its link is down
//! (`ssh_carry.rs`): from the second attempt that finds the link down, the far CLI's own
//! `send --no-wait` takes the message under the delivery's prompt id. Taken there, the delivery
//! is delivered, pinned to no link, so a reconnect never sends it again.
//!
//! `send_status {deliveryId, waitMs?}` answers the delivery's state, after waiting up to
//! `waitMs` (at most [`MAX_STATUS_WAIT_MS`]) for it to settle. A target no one here resolves goes
//! to the mesh hub when the relay is on, and its status is the hub's receipt (`mesh_send.rs`).

use crate::no_panic::JsonExt;
use std::collections::HashMap;
use std::time::Duration;

use super::*;
use crate::hub::no_session::NO_SESSION_PREFIX;
use crate::hub::outbox::{Delivery, RETRY_DELAYS_SECS, RETRY_FOR_MS, State};

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
    /// The target's machine answered that it has no such session: failed at once, never tried
    /// again (a name that is no session's stays so; `hub/no_session.rs`).
    NoSession,
    /// The session the attempt named (`sessionCreatedAt`) is not the one under that id now (it
    /// was purged and made again): a first delivery reads the session again and tries again; a
    /// delivery again of a prompt that session took fails (`hub/open_delivery.rs`).
    Stale,
    /// The chat moved to another daemon (`transfer.moved`, its `movedTo`): nothing ran here, and
    /// the delivery follows it to this `HOST/SESSION` at once (`follow_move`).
    Moved(String),
    /// The chat moved to a sibling daemon on this machine (`session transfer --to SOCKET`:
    /// `movedTo {socket, sessionId}`, no host), which no `HOST/SESSION` reaches: the delivery is
    /// handed to that daemon's own outbox (`hand_to_socket`).
    MovedToSocket { socket: String, session: String },
    /// The chat is being moved right now (`transfer.moving`): tried again after
    /// [`MOVING_RETRY`], without spending a retry delay, until the move commits (then
    /// [`Next::Moved`]) or aborts (then it runs here).
    Moving,
}

/// How long a delivery to a chat in the middle of a move waits before it tries again. A move
/// freezes the chat only while its bundle is copied, so a short fixed wait keeps the message
/// right behind the chat instead of minutes behind it on the back-off.
const MOVING_RETRY: Duration = Duration::from_millis(250);

/// How long a delivery tries a chat mid-move every [`MOVING_RETRY`]. A move that takes longer
/// (a large bundle on a slow link, a stuck client its watch has not ended yet) is tried on the
/// usual back-off from then on.
const MOVING_FAST_FOR: Duration = Duration::from_secs(120);

/// How many moves one delivery follows in a row before it fails: a chat moving in a loop
/// (`movedTo` chains that point back) must not keep a message bouncing for its whole day.
const MAX_MOVES_FOLLOWED: u32 = 16;

/// How long one attempt waits for the target's acceptance with nothing heard from it: each line
/// the connection answers (a forward's progress, an update) starts it again, so an attempt that is
/// moving is never cut off. Leo, 2026-11-24: "if it's making good progress, it shiukd be allowed
/// to keep going?"
const ATTEMPT_WAIT: Duration = Duration::from_secs(120);
/// How often a delivery held behind another (`Delivery::waits_behind`) looks again when no
/// outbox change woke it.
const AFTER_RECHECK: Duration = Duration::from_secs(5);
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
    queue(hub, conn, params, false).await
}

/// A send's queueing, after its caller was checked: a local `send_queue`, or a peer's one-hop
/// relay (`hop_in`, `send_hop.rs`), which never hops again.
pub(super) async fn queue(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    params: &Value,
    hop_in: bool,
) -> Result<Value, RpcError> {
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
    // A name nothing live here answers to goes to the session that took it over or claimed it,
    // and a session on a peer that is down is looked up on the mesh hub first (`send_check.rs`).
    let asked = target.clone();
    let (target, unchecked) = super::send_check::route(hub, &mut request, target).await?;
    // A waiting CLI has already attached to a resolved session. If it disappeared while the
    // queue request was in flight, refuse before the hub/hop fast paths can send without a
    // local durable receipt. A normal queued send keeps its existing hub-routing behavior.
    if params.get("waitForTurn").and_then(Value::as_bool) == Some(true)
        && (target.starts_with('@')
            || (hub.resolve(&target).is_err()
                && hub.resolve_remote(&target).is_none()
                && hub.peer_down_for(&target).is_none()
                && hub.no_session_is_final(&target)))
    {
        return Err(RpcError::invalid_params(format!("no session to follow: {target}")));
    }
    // Team-scoped addresses are always hub-routed and are never resolved as
    // local session names. The mesh sender applies the team-messaging gate and address
    // validation before posting them.
    if target.starts_with('@') {
        if let Some(mesh) = hub.mesh.get() {
            return super::mesh_send::send(hub, conn, &mesh, &request, &target).await;
        }
        return Err(RpcError::invalid_params("team messaging requires a configured mesh relay")
            .with_data(json!({"reason": "team_messaging_unavailable", "address": target})));
    }
    // Its prompt id, fixed before anything is sent: the hub's key for it (`mesh_send.rs`) and
    // the outbox's are the same, so a post the outbox sends again is the same message.
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
    // A post the hub did not take in a way that passes, kept for the outbox's retry, and why.
    let mut hub_post: Option<(crate::mesh::OutMessage, String)> = None;
    // The hub provably holds no copy of `hub_post` (`Posted::Queue::unreached`).
    let mut hub_unreached = false;
    // A session here, one a peer lists, or one on a peer that is down now: anything else is no
    // session, said at once.
    if hub.resolve(&target).is_err()
        && hub.resolve_remote(&target).is_none()
        && hub.peer_down_for(&target).is_none()
        && hub.no_session_is_final(&target)
    {
        // With the mesh relay on, the team hub may know a name nothing here or on a peer matches
        // (`mesh_send.rs`); a name several sessions here or on peers match stays this daemon's
        // refusal (`Hub::mesh_may_route`).
        // A hub that fails in a way that passes (a 503 from overload, no answer) never fails the
        // send: it is kept here and the outbox posts it again (RFD 0049 R1).
        // HOST/NAME on a host this daemon does not peer: one hop through a peer that does and
        // takes hops (`send_hop.rs`); the refusal names the route it tried.
        let mut hop_tried: Vec<Value> = vec![];
        if !hop_in {
            match super::send_hop::try_hop(hub, conn, &request, &target).await {
                super::send_hop::Hop::Sent(answer) => return Ok(answer),
                super::send_hop::Hop::Failed(e) => return Err(e),
                super::send_hop::Hop::NoRoute(tried) => hop_tried = tried,
            }
        }
        if let Some(mesh) = hub.mesh.get()
            && hub.mesh_may_route(&target)
        {
            match super::mesh_send::post_or_queue(hub, conn, &mesh, &request, &target).await {
                super::mesh_send::Posted::Answered(answer) => return answer,
                super::mesh_send::Posted::Queue { post, why, unreached } => {
                    hub_post = Some((post, why));
                    hub_unreached = unreached;
                }
            }
        } else {
            // The machine is reachable and has no such session: refused now, never queued,
            // with the closest names there so the sender can pick one (`hub/no_session.rs`).
            let (mut text, mut data) = hub.no_session_text(&target);
            super::send_hop::note_route(&mut text, &mut data, &hop_tried);
            return Err(
                RpcError::invalid_params(format!("no session: {target} ({text})")).with_data(data)
            );
        }
    }
    // The hub did not answer the post, or the book could not tell: the name was not checked.
    let unchecked = unchecked.or_else(|| hub_post.as_ref().map(|(_, why)| why.clone()));
    // A peer that is down now: queued and tried again, and the answer says so.
    let host_unreachable = hub.host_unreachable_for(&target);
    // Over the caps it is refused now, never kept (`attach.rs`).
    crate::attach::check_wire(&request)?;
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
        // A token it could not prove keeps the replay off the owner too (#38260 F1).
        unproven_caller: conn.unproven_caller.get().filter(|_| !conn.is_person()).cloned(),
        not_terminal: !conn.is_person() && !conn.may_be_owner_terminal(),
        state: State::Queued,
        attempts: 0,
        // The hub may hold a post that did not answer in time: only the relay sends it again.
        never_sent: hub_post.is_none(),
        resends: 0,
        resent_at: 0,
        relay_post: hub_post.as_ref().map(|(post, _)| post.clone()),
        relay_unreached: hub_post.is_some() && hub_unreached,
        direct_maybe: false,
        open_on_peer: false,
        pin: None,
        proof: None,
        error: hub_post.map(|(_, why)| why),
        accepted: None,
        created_at: now,
        updated_at: now,
    };
    // Its attachments are kept beside outbox.json, once, never in its snapshot or journal.
    let kept = hub.outbox.attachments_path(&new);
    if let Some(path) = kept.clone() {
        let request = new.request.clone();
        tokio::task::spawn_blocking(move || crate::hub::outbox::keep_attachments(&path, &request))
            .await
            .map_err(|e| RpcError::internal(e.to_string()))?
            .map_err(|e| crate::recovery::write_error("cannot keep the attachments", e, None))?;
    }
    // The send's one durable write (its line in outbox.journal, a group commit with other
    // changes): on the blocking pool at the on-screen CPU tier (`qos.rs`), so a loaded machine or
    // a slow disk never holds an async worker that serves other connections, and agent work at
    // its clamped priority never starves the write the sender waits on.
    let added = {
        let (hub, new) = (hub.clone(), new.clone());
        tokio::task::spawn_blocking(move || crate::qos::on_screen(|| hub.outbox.add(new)))
            .await
            .map_err(|e| RpcError::internal(e.to_string()))?
    };
    // Not on disk, so not kept: the sender is told to send it again, and its attachments go.
    let delivery = match added {
        Ok(delivery) => delivery,
        Err(e) => {
            if let Some(path) = kept {
                forget_attachments(path).await;
            }
            return Err(crate::recovery::write_error(
                "cannot keep the message",
                e,
                Some("outbox.not_saved"),
            ));
        }
    };
    // The same prompt id again: the first delivery, already on its way.
    if delivery.id == new.id {
        spawn(hub.clone(), delivery.id.clone());
    } else if handed_away(&delivery) {
        // A sibling daemon hands back a message this one handed it (`hand_to_socket`): its chat
        // moved back here before the sibling delivered it. Nothing ran it on either side (each
        // refused it as moved), so it opens again and is delivered here, where the chat is now.
        // Before, the hand-back read the first delivery's `delivered` and the message was lost.
        if let Some(path) = kept {
            forget_attachments(path).await;
        }
        hub.outbox.update_saved(&delivery.id, |d| {
            d.state = State::Queued;
            d.accepted = None;
            d.pin = None;
            d.error = Some("handed back here: its chat moved back".into());
        });
        spawn(hub.clone(), delivery.id.clone());
        let delivery = hub.outbox.get(&delivery.id).unwrap_or(delivery);
        return Ok(delivery.status());
    } else {
        if let Some(path) = kept {
            forget_attachments(path).await;
        }
        drop_own_uploads(hub, &new, &delivery).await;
    }
    let mut status = delivery.status();
    if host_unreachable {
        status.set("hostUnreachable", json!(true));
    }
    super::send_check::note(&mut status, &asked, &delivery.target, unchecked);
    Ok(status)
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
        unproven_caller: None,
        not_terminal: false,
        // Held is terminal to older daemons: rollback never sends this lookup
        // record as a prompt. New code recognizes the forwardProjection marker.
        state: State::Held,
        attempts: 0,
        never_sent: false,
        resends: 0,
        resent_at: 0,
        relay_post: None,
        relay_unreached: false,
        direct_maybe: false,
        open_on_peer: false,
        pin: None,
        proof: None,
        error: None,
        accepted: None,
        created_at: now,
        updated_at: now,
    };
    hub.outbox
        .remember_forward(intent)
        .map(|delivery| delivery.id)
        .map_err(|e| crate::recovery::write_error("cannot persist peer message intent", e, None))
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

/// The most `send_status {list: true}` answers.
const LIST_LIMIT: usize = 200;

async fn status(hub: &Arc<Hub>, conn: &Arc<Conn>, params: &Value) -> Result<Value, RpcError> {
    // `{stats: true}`: this daemon's send counters and gauges (`hub/outbox_stats.rs`), the
    // `/proc/net/snmp` of agent sends. Counts only, no targets: any connection may read them.
    if params.get("stats").and_then(Value::as_bool) == Some(true) {
        return Ok(json!({"stats": hub.outbox.stats()}));
    }
    // `{list: true, caller?, limit?}`: this daemon's messages to deliver, newest first, each as
    // its status (`acpmux send --status` with no id, `acpmux session inbox`). Only the unix
    // socket reads the list: it names other sessions' targets.
    if params.get("list").and_then(Value::as_bool) == Some(true) {
        if conn.origin != Origin::Local {
            return Err(crate::hub::outbox::local_only());
        }
        let caller = str_param(params, "caller");
        let limit = params
            .get("limit")
            .and_then(Value::as_u64)
            .map_or(LIST_LIMIT, |n| usize::try_from(n).unwrap_or(LIST_LIMIT).min(LIST_LIMIT));
        let (deliveries, pending) = hub.outbox.list(caller, limit);
        let deliveries: Vec<Value> = deliveries.iter().map(Delivery::status).collect();
        return Ok(
            json!({"deliveries": deliveries, "pending": pending, "stats": hub.outbox.stats()}),
        );
    }
    let id = str_param(params, "deliveryId")
        .ok_or_else(|| RpcError::invalid_params("deliveryId is required"))?;
    if id.starts_with(super::mesh_send::PREFIX)
        && let Some(reply) = super::mesh_relay::read::mesh_status(hub, conn, id).await
    {
        return reply;
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
    // `firstAttempt`: also end once an attempt failed and the delivery waits for its retry (a
    // peer that is down): the sender learns nothing more by waiting (`acpmux send`'s quick wait).
    let first = params.get("firstAttempt").and_then(Value::as_bool) == Some(true);
    let deadline = tokio::time::Instant::now() + Duration::from_millis(wait);
    loop {
        let changed = hub.outbox.changed.notified();
        let delivery = hub.outbox.get(id).ok_or_else(|| {
            RpcError::invalid_params(format!("no delivery {id}"))
                .with_data(json!({"reason": "outbox.unknown", "deliveryId": id}))
        })?;
        let retrying = first && delivery.state == State::Queued && delivery.attempts > 0;
        if delivery.settled() || retrying || tokio::time::Instant::now() >= deadline {
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
    match super::mesh_send::status(hub, conn, &mesh, relay).await {
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
    // The wait after the schedule ran out, doubled each time (`retry_delay`).
    let mut tail = 0u64;
    // How many moves of its chat this delivery followed (`Next::Moved`).
    let mut moves_followed = 0u32;
    // When it first found its chat mid-move (`Next::Moving`).
    let mut moving_since: Option<std::time::Instant> = None;
    loop {
        let Ok(permit) = hub.outbox_attempts.acquire().await else { return };
        let Some(delivery) = hub.outbox.get(id) else { return };
        if delivery.settled() {
            return;
        }
        // The owner's copy wrote its prompt's records: the peer took it, and it is never sent
        // again (a resend could run it twice); it stays open on them (`hub/open_delivery.rs`).
        if delivery.proof.is_some() && delivery.pin.is_some() {
            hub.outbox.update(id, |d| {
                if !d.settled() {
                    let (pin, answer) = (d.pin.clone(), json!({"proven": true}));
                    crate::hub::open_delivery::accepted(d, pin, answer);
                }
            });
            return;
        }
        // Past its day (a restart resumes old ones too): failed, never sent this late.
        if expired(&delivery, crate::store::now_ms()) {
            let saved = hub.outbox.update_saved(id, |d| {
                if !d.settled() {
                    d.state = State::Failed;
                    let last =
                        d.error.take().map(|e| format!("; last error: {e}")).unwrap_or_default();
                    d.error = Some(format!("not delivered within a day of being sent{last}"));
                    crate::attach::strip(&mut d.request);
                }
            });
            // Its bytes go once the file says it failed: a restart reads it open otherwise.
            if saved && let Some(path) = hub.outbox.attachments_path(&delivery) {
                forget_attachments(path).await;
            }
            return;
        }
        // Behind an earlier message to the same session (`AFTER_KEY`): it waits for that one to
        // settle, woken by every outbox change and looking again at least every few seconds.
        let changed = hub.outbox.changed.notified();
        tokio::pin!(changed);
        changed.as_mut().enable();
        if delivery.waits_behind(&hub.outbox).is_some() {
            drop(permit);
            let _ = tokio::time::timeout(AFTER_RECHECK, changed).await;
            continue;
        }
        // Armed before the attempt: `notify_waiters` wakes only waits that exist, so a peer
        // ready while the attempt runs or its failure is saved still ends the retry wait.
        let ready = hub.outbox.peer_ready.notified();
        tokio::pin!(ready);
        ready.as_mut().enable();
        // `peer_ready` is one signal for every peer: this delivery's own peer's count, read
        // with it armed, tells whether a ready was this peer's (`Outbox::note_peer_ready`). A
        // target that names no peer (no `/`) never wakes on one.
        let ready_seen = own_ready_count(&hub.outbox, &delivery.target);
        // The same for the hub's gate opening (`mesh_gate.rs` `Gate::opened`): a delivery the
        // hub carries is tried the moment the hub takes a post again (RFD 0086 item 2).
        let opened = hub.mesh.gate().opened.notified();
        tokio::pin!(opened);
        opened.as_mut().enable();
        // This attempt asked the team hub (or its gate kept it from asking).
        let mut relayed = false;
        let attempt = delivery.attempts + 1;
        // Saved as maybe sent, and with its pin, before the attempt may reach the peer
        // (below): an attempt whose state is not on disk does not go (review of #37284 at
        // a088585e: a failed save was logged, and the attempt went).
        let mut saved = hub.outbox.update_saved(id, |d| {
            if !d.settled() {
                start_attempt(d, attempt);
            }
        });
        if hub.outbox.get(id).is_none_or(|d| d.settled()) {
            return;
        }
        let mut request = delivery.request.clone();
        // Ordering for this outbox alone: the receiver never sees it.
        if let Some(mux) = request.pointer_mut("/_meta/acpmux").and_then(Value::as_object_mut) {
            mux.remove(crate::hub::outbox::AFTER_KEY);
        }
        // A later attempt asks for the first one's outcome when the target took it already.
        if attempt > 1
            && let Some(mux) = request.pointer_mut("/_meta/acpmux").and_then(Value::as_object_mut)
        {
            mux.insert("resend".into(), json!(true));
        }
        // Whether the peer's link, if this attempt used it, took nothing (`Delivery::never_sent`).
        let mut link_unsent = true;
        // The ssh carrier took it (`ssh_carry.rs`): delivered on no link, so open on none.
        let mut by_ssh = false;
        // The peer's session the delivery goes to: read before its first attempt, kept on the
        // delivery before the attempt goes (a crash mid-attempt keeps it), and the same for every
        // later one once an attempt may have reached the peer, so nothing read after that (a link
        // replaced, the session purged and made again) changes where it goes or what is recorded
        // (`open_delivery.rs`). An attempt that reached nothing lets it go (below).
        let projection = request.pointer("/_meta/acpmux/forwardProjection").is_some();
        let fresh_pin = delivery.pin.is_none();
        let pin = if projection {
            None
        } else {
            delivery.pin.clone().or_else(|| crate::hub::open_delivery::pin(hub, &delivery.target))
        };
        if fresh_pin && pin.is_some() {
            saved &= hub.outbox.update_saved(id, |d| d.pin.clone_from(&pin));
        }
        let outcome = if !saved {
            // Nothing went on the link.
            Err(("the outbox could not be saved; tried again".to_owned(), Next::Retry))
        } else if request.pointer("/_meta/acpmux/forwardProjection").is_some() {
            // A projection reconciles with the receiver's log; it never uses the link to send.
            link_unsent = false;
            tokio::time::timeout(ATTEMPT_WAIT, reconcile_forward(hub, &delivery))
                .await
                .unwrap_or_else(|_| Err(("peer message lookup timed out".into(), Next::Retry)))
        } else if delivery.relay_post.is_some() {
            // The hub may hold it already: only the relay tries it again. With the relay off here
            // it may still deliver it (the target's daemon reads it), so it is never sent twice.
            relayed = true;
            relay_or_direct(hub, &delivery).await.unwrap_or_else(|| {
                let key = delivery.relay_post.as_ref().map_or("", |m| m.idempotency_key.as_str());
                let why = format!(
                    "the mesh relay is off here; the team hub may hold it (key {key}), so it is not sent again another way"
                );
                Err((why, Next::Retry))
            })
        } else {
            crate::hub::open_delivery::name_generation(&mut request, pin.as_ref());
            let caller = Caller::of(&delivery);
            let mut outcome = attempt_once(hub, caller, request, Origin::Local).await;
            link_unsent = matches!(outcome, Err((_, Next::Unsent)));
            // The link is still down on a later attempt: an ssh peer's machine is tried over a
            // plain ssh login (`ssh_carry.rs`). Taken there, it is delivered and never sent
            // again; one that may have reached it is tried again only as a resend of the same
            // prompt id, never through the mesh relay.
            if link_unsent
                && attempt >= super::ssh_carry::CARRY_FROM_ATTEMPT
                && let Some(carry) = super::ssh_carry::carry(hub, &delivery).await
            {
                let error = outcome.err().map(|(e, _)| e).unwrap_or_default();
                outcome = match carry {
                    super::ssh_carry::Carry::Taken(answer) => {
                        by_ssh = true;
                        Ok(answer)
                    }
                    super::ssh_carry::Carry::Maybe(why) => {
                        link_unsent = false;
                        Err((format!("{error}; ssh carry: {why}"), Next::Retry))
                    }
                    super::ssh_carry::Carry::NotTaken(why) => {
                        Err((format!("{error}; ssh carry: {why}"), Next::Unsent))
                    }
                };
            }
            match outcome {
                // Nothing has reached the target: the mesh relay carries it when it can.
                Err((error, Next::Unsent)) if delivery.never_sent => {
                    relayed = true;
                    match relay_or_direct(hub, &delivery).await {
                        Some(Ok(accepted)) => Ok(accepted),
                        Some(Err((why, next))) => Err((format!("{error}; {why}"), next)),
                        None => Err((error, Next::Unsent)),
                    }
                }
                // `HOST/ID` on a machine only the hub reaches, as a followed hub move names it
                // (`follow_move`): this daemon's lookup reaches nothing there, so the hub carries
                // it, never a "no session HOST/ID on" this machine.
                Err((error, Next::NoSession)) if hub.mesh_only_host(&delivery.target) => {
                    relayed = true;
                    match relay_or_direct(hub, &delivery).await {
                        Some(outcome) => outcome,
                        None => Err((error, Next::NoSession)),
                    }
                }
                outcome => outcome,
            }
        };
        match outcome {
            Ok(accepted) => {
                // A peer's session may lose it with the machine's disk until the owner's copy of
                // that session holds it (`hub/open_delivery.rs`): open until then. One the ssh
                // carrier took is the far daemon's own delivery now: no link sends it again.
                // One its machine took directly is that daemon's own delivery too.
                let direct = accepted.get("via").and_then(Value::as_str) == Some("direct");
                let pin = if by_ssh || direct { None } else { pin };
                let open = pin.is_some();
                let saved = hub.outbox.update_saved(id, |d| {
                    crate::hub::open_delivery::accepted(d, pin, accepted);
                    // Settled: its record keeps no attachment bytes (`attach.rs`). One open on
                    // its peer keeps them until it closes: a delivery again sends them too.
                    if !open {
                        crate::attach::strip(&mut d.request);
                    }
                });
                if saved
                    && !open
                    && let Some(path) = hub.outbox.attachments_path(&delivery)
                {
                    forget_attachments(path).await;
                }
                return;
            }
            Err((error, next)) => {
                // Whether a peer's link that is ready again may end this delivery's wait: only
                // when this attempt never left the daemon (the peer was down) or the peer had not
                // listed its sessions yet. One the link took and nobody answered waits its whole
                // delay: a link that comes back every few minutes under load must not send it
                // again on each one.
                let mut wake_on_ready = link_unsent;
                // No such session there: failed now, naming the closest names, unless its
                // machine is down or has not listed its sessions since it came back (then the
                // answer proves nothing; tried again).
                let (error, next) = match next {
                    Next::NoSession if hub.peer_down_for(&delivery.target).is_some() => {
                        wake_on_ready = true;
                        (error, Next::Unsent)
                    }
                    Next::NoSession if !hub.no_session_is_final(&delivery.target) => {
                        wake_on_ready = true;
                        (error, Next::Retry)
                    }
                    Next::NoSession => {
                        let (text, _) = hub.no_session_text(&delivery.target);
                        (format!("{NO_SESSION_PREFIX}{text}"), Next::NoSession)
                    }
                    // Purged and made again since the attempt read it. A first attempt reached
                    // nothing: read again, and tried. A later one may have been taken by the
                    // session that is gone: it never runs in the new one; failed, saying why.
                    Next::Stale if fresh_pin => {
                        hub.outbox.update(id, |d| d.pin = None);
                        (error, Next::Retry)
                    }
                    Next::Stale => (error, Next::Fail),
                    // The chat moved away before this prompt ran: it goes where the chat went,
                    // now, under the same prompt id (the new daemon runs it once). One that
                    // followed too many moves fails, saying where it last went.
                    Next::Moved(to) => {
                        if follow_move(hub, id, &to, moves_followed) {
                            moves_followed += 1;
                            continue;
                        }
                        let why = format!("{error}; followed {moves_followed} moves, last to {to}");
                        (why, Next::Fail)
                    }
                    // Moved to a sibling daemon here: its outbox takes the delivery over. A
                    // daemon that does not answer is tried again on the back-off.
                    Next::MovedToSocket { socket, session } => {
                        let handoff = hand_to_socket(&delivery, &socket, &session);
                        match tokio::time::timeout(ATTEMPT_WAIT, handoff).await.unwrap_or_else(
                            |_| {
                                Err(format!(
                                    "the daemon at {socket} did not answer within {} s",
                                    ATTEMPT_WAIT.as_secs()
                                ))
                            },
                        ) {
                            // Its attachment files stay: the request the sibling took may name
                            // them, and the settled sweep removes them with the record.
                            Ok(accepted) => {
                                hub.outbox.update_saved(id, |d| {
                                    crate::hub::open_delivery::accepted(d, None, accepted);
                                });
                                return;
                            }
                            Err(why) => (format!("{error}; {why}"), Next::Retry),
                        }
                    }
                    // Mid-move: tried again shortly, on no back-off, while the delivery's day
                    // lasts (`expired`, above).
                    Next::Moving
                        if moving_since.get_or_insert_with(std::time::Instant::now).elapsed()
                            > MOVING_FAST_FOR =>
                    {
                        (error, Next::Retry)
                    }
                    Next::Moving => {
                        hub.outbox.update(id, |d| {
                            if !d.settled() {
                                d.state = State::Queued;
                                d.error = Some(error.clone());
                            }
                        });
                        drop(permit);
                        tokio::time::sleep(MOVING_RETRY).await;
                        continue;
                    }
                    next => (error, next),
                };
                wake_on_ready |= next == Next::Unsent;
                let delay = matches!(next, Next::Retry | Next::Unsent)
                    .then(|| retry_delay(&mut delays, &mut tail, &delivery, crate::store::now_ms()))
                    .flatten();
                // A pin is the generation an attempt may have reached. While none reached the
                // peer (nothing went on its link, no relay holds it), none is kept: the next
                // attempt reads the session as the peer lists it then, so a session the peer made
                // again meanwhile is not failed as stale for an attempt it never saw (review of
                // #37284 at c4a6f4e7, F3).
                let drop_pin = !hub.at_c4a6();
                hub.outbox.update(id, |d| {
                    if d.settled() {
                        return;
                    }
                    d.never_sent = delivery.never_sent && link_unsent;
                    if drop_pin && d.never_sent && d.relay_post.is_none() {
                        d.pin = None;
                    }
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
                // A peer whose link is ready again ends the wait (`Outbox::peer_ready`): a message
                // to a machine that was down goes the moment it is reachable. A projection intent
                // keeps its bounded schedule: another peer's reconnects must not use it up. A
                // message's wait never runs past its day; an intent's delays are never cut, so an
                // intent older than a day after a restart does not spend its retries at once.
                //
                // A delivery the hub carries (its post is kept) ends its wait when the hub's gate
                // opens: the outbox drains as soon as the hub is back, not on each send's own
                // schedule. Its key makes the post again the same message. One the hub's shut gate
                // held waits for the gate, not its own schedule: until the gate lets its next probe
                // go (with a little jitter, so the queue does not race for it) or the hub takes any
                // post, whichever comes first. Twenty sends refused in one window go together once
                // it opens, in their order (`waits_behind`), rather than one per window as each own
                // back-off ran out (RFD 0049 R1).
                let own = retry_sleep(&delivery, secs, crate::store::now_ms());
                let by_hub = hub.outbox.get(id).is_some_and(|d| d.relay_post.is_some());
                let behind_gate = !delivery.projection_only() && relayed && hub.mesh.gate().shut();
                let wait = match hub.mesh.gate().reopens_at().filter(|_| behind_gate) {
                    Some(at) => own.min(gate_wait(at, crate::peer_link::jitter())),
                    None => own,
                };
                drop(permit);
                let sleep = tokio::time::sleep(wait);
                tokio::pin!(sleep);
                let on_ready = !delivery.projection_only() && wake_on_ready;
                // A name the hub does not list yet waits its own back-off: the hub taking some
                // other post says nothing about this name, and waking on it would spend the
                // bounded attempts ([`UNKNOWN_RECIPIENT_ATTEMPTS`]) in a burst.
                let unlisted = hub
                    .outbox
                    .get(id)
                    .is_some_and(|d| d.error.as_deref().is_some_and(|e| e.contains(UNLISTED)));
                let on_open = !delivery.projection_only() && (by_hub || behind_gate) && !unlisted;
                loop {
                    tokio::select! {
                        () = &mut sleep => break,
                        () = &mut opened, if on_open => break,
                        () = &mut ready, if on_ready => {
                            // `peer_ready` is one signal for every peer. Another peer's link
                            // coming back leaves this one's as it was: waking for it retried
                            // (and ssh-carried, and journaled) every queued delivery at once on
                            // each link flap anywhere. Only this target's own peer, ready or
                            // listed since the wait was armed and up now, ends it; a target
                            // naming an unknown peer or none, or one whose peer was up all along
                            // (`Next::Unsent` without an outage), waits its own delay (review of
                            // #53719, F1). Re-armed before the look, so a ready in between is not
                            // missed.
                            ready.set(hub.outbox.peer_ready.notified());
                            ready.as_mut().enable();
                            if !own_ready_since(&hub.outbox, ready_seen.as_ref()) {
                                continue;
                            }
                            let Ok(_permit) = hub.outbox_attempts.acquire().await else { return };
                            if hub.peer_down_for(&delivery.target).is_none() {
                                break;
                            }
                        }
                    }
                }
            }
        }
    }
}

/// `target`'s own peer and how many times its link was ready or listed so far
/// (`Outbox::note_peer_ready`), read as a delivery arms its `peer_ready` wait. None for a target
/// that names no peer (no `/`): no peer's ready is its own.
fn own_ready_count(outbox: &crate::hub::outbox::Outbox, target: &str) -> Option<(String, u64)> {
    let (peer, rest) = target.split_once('/')?;
    (!peer.is_empty() && !rest.is_empty()).then(|| (peer.to_owned(), outbox.peer_ready_count(peer)))
}

/// Whether the peer [`own_ready_count`] read was ready or listed again since: a `peer_ready`
/// that was another peer's leaves it false.
fn own_ready_since(outbox: &crate::hub::outbox::Outbox, seen: Option<&(String, u64)>) -> bool {
    seen.is_some_and(|(peer, count)| outbox.peer_ready_count(peer) != *count)
}

/// Peer `peer`'s link `link` is ready, and its journals took back what this daemon kept of them
/// (`hub/peer_snapshot/restore.rs`; `ends`: where each journal ends now, session: generation and
/// `lastSeq`). Every delivery to it that is still open (`hub/open_delivery.rs` `step`) is, oldest
/// first: failed when it lapsed or its session is another generation there; closed when its
/// proof is held there; left open when proven and not seen held yet (never sent again); else
/// sent again as a resend of its own prompt id to its pinned generation (a machine that kept it
/// answers with its first outcome; one that lost it with its disk runs it now, once; a refused
/// one fails it, saying why). All of them go on this link, in batches of [`REDELIVER_BATCH`],
/// while it is up; the next link goes on after the last one reached, so none waits behind the
/// others for good. One task per call; each resend waits [`ATTEMPT_WAIT`] of silence at most.
/// `since`: where each kept copy's open deliveries' proofs begin, as the link's restore read it (`Store::ahead`);
/// a proven delivery whose copy is not kept is sent again (`od::unproven`).
pub(crate) fn redeliver_open(
    hub: &Arc<Hub>,
    peer: &str,
    link: (u64, u64),
    ends: HashMap<String, (u64, u64)>,
    since: crate::hub::open_delivery::Since,
) {
    let open: Vec<Delivery> = hub
        .outbox
        .open_on_peers()
        .into_iter()
        .filter(|d| d.pin.as_ref().is_some_and(|p| p.peer == peer))
        .collect();
    let open = one_per_prompt(open);
    if open.is_empty() {
        return;
    }
    let scope = &hub.scope;
    let (hub, peer) = (hub.clone(), peer.to_owned());
    scope.spawn_until_cancelled("peer-redeliver-open", async move {
        let on_link = || hub.peer_on_link(&peer, link);
        let from = cursor(&hub).get(&peer).cloned();
        let one = |d: Delivery| {
            let (hub, peer, ends, since) = (hub.clone(), peer.clone(), &ends, &since);
            async move {
                let Ok(_permit) = hub.outbox_attempts.acquire().await else { return };
                if !hub.peer_on_link(&peer, link) {
                    return;
                }
                if let Some(live) = hub.outbox.get(&d.id)
                    && live.open_on_peer
                    && live.pin == d.pin
                {
                    redeliver_one(&hub, &live, link, (ends, since)).await;
                }
                cursor(&hub).insert(peer, (d.created_at, d.id.clone()));
            }
        };
        redeliver_all(open, from, on_link, one).await;
    });
}

/// `open` with one delivery per prompt id and pinned session (the oldest): a resend runs under
/// its own prompt id, and the machine answers every copy of that id with its first outcome, so a
/// second copy on the same link is a send for nothing. One with no prompt id is kept as it is.
fn one_per_prompt(mut open: Vec<Delivery>) -> Vec<Delivery> {
    open.sort_by(|a, b| (a.created_at, &a.id).cmp(&(b.created_at, &b.id)));
    let mut seen = std::collections::HashSet::new();
    open.retain(|d| {
        let session = d.pin.as_ref().map(|p| p.session.clone()).unwrap_or_default();
        d.prompt_id().is_empty() || seen.insert((d.prompt_id().to_owned(), session))
    });
    open
}

fn cursor(hub: &Hub) -> std::sync::MutexGuard<'_, HashMap<String, (u64, String)>> {
    hub.outbox.redelivered_to.lock().unwrap_or_else(|e| e.into_inner())
}

/// The open deliveries of one link go in batches of this many; between batches the link is read
/// again and the runtime gets the thread.
const REDELIVER_BATCH: usize = 256;

/// Runs `one` on each of `open` (oldest first), starting after `from` (the one a link before
/// reached last, by sent time and id) and coming round to it, in batches of
/// [`REDELIVER_BATCH`], while `on_link` holds. Answers how many it ran.
async fn redeliver_all<F, Fut>(
    mut open: Vec<Delivery>,
    from: Option<(u64, String)>,
    on_link: impl Fn() -> bool,
    mut one: F,
) -> usize
where
    F: FnMut(Delivery) -> Fut,
    Fut: std::future::Future<Output = ()>,
{
    open.sort_by(|a, b| (a.created_at, &a.id).cmp(&(b.created_at, &b.id)));
    let after = from.map_or(0, |(at, id)| {
        open.iter().position(|d| (d.created_at, d.id.as_str()) > (at, id.as_str())).unwrap_or(0)
    });
    open.rotate_left(after);
    let mut ran = 0;
    for batch in open.chunks(REDELIVER_BATCH) {
        for d in batch {
            if !on_link() {
                return ran;
            }
            one(d.clone()).await;
            ran += 1;
        }
        tokio::task::yield_now().await;
    }
    ran
}

/// One open delivery of a link's redelivery (`redeliver_open`).
async fn redeliver_one(
    hub: &Arc<Hub>,
    d: &Delivery,
    link: (u64, u64),
    (ends, since): (&HashMap<String, (u64, u64)>, &crate::hub::open_delivery::Since),
) {
    use crate::hub::open_delivery::{self as od, Again, Step};
    let now = crate::store::now_ms();
    let Some(pin) = d.pin.clone() else { return };
    let mut step = od::step_after_restore(d, (now, link), (ends, since), hub.at_27f3());
    if step == Step::Check {
        let held = tokio::time::timeout(ATTEMPT_WAIT, hub.proof_held(d, link)).await;
        step = od::checked(held.unwrap_or(None));
    }
    match step {
        Step::Lapse => {
            let lapsed = crate::hub::outbox::OPEN_LAPSED.to_owned();
            close_open(hub, d, |d| d.fail_open(lapsed)).await;
        }
        Step::Stale => {
            tracing::warn!(delivery = %d.id, "a proven delivery's session is another generation now");
            close_open(hub, d, |d| d.fail_open(od::STALE.to_owned())).await;
        }
        Step::Lost => {
            tracing::warn!(delivery = %d.id, "a proven delivery's machine holds another history");
            close_open(hub, d, |d| d.fail_open(od::LOST.to_owned())).await;
        }
        Step::Release => close_open(hub, d, od::release).await,
        Step::Wait | Step::Check => {}
        // Answered a duplicate with its final outcome already: closed, not sent again (`done_on_peer`).
        Step::Again if od::done_on_peer(d) => close_open(hub, d, od::release).await,
        Step::Again | Step::Unproven => {
            if step == Step::Unproven {
                // Proven by records no restore gave back and no journal holds (review of #37284
                // at 27f3761b, F1): delivered again, as one never proven.
                tracing::warn!(delivery = %d.id, "a proof no machine holds; delivered again");
                hub.outbox.update(&d.id, od::unprove);
            }
            // At most one resend per backoff step (`od::resend_due`), claimed on the record
            // before it goes so two links' redeliveries of the same peer send it once. Read
            // first: a delivery the backoff holds back costs no outbox write.
            if !hub.outbox.get(&d.id).is_some_and(|live| od::resend_due(&live, now)) {
                return;
            }
            let mut claimed = false;
            hub.outbox.update(&d.id, |live| claimed = od::claim_resend(live, now));
            if !claimed {
                return;
            }
            // To the pinned session, by its id, never by the name it was sent to (review of
            // #37284 at 4bce04df, F2).
            let request = od::again_request(d, &pin);
            let again = match attempt_once(hub, Caller::of(d), request, Origin::Local).await {
                Ok(answer) => Again::Taken(answer),
                Err((error, Next::Fail | Next::NoSession | Next::Stale)) => Again::Refused(error),
                Err(_) => Again::Unknown,
            };
            if let Again::Refused(error) = &again {
                tracing::warn!(delivery = %d.id, "a delivery again was refused: {error}");
            }
            let mut settled = false;
            hub.outbox.update(&d.id, |d| settled = od::after_again(d, again));
            if settled {
                close_open(hub, d, |_| {}).await;
            }
        }
    }
}

/// Closes open delivery `d` with `f`: settled now, its record keeps no attachment bytes, and
/// the ones kept beside the outbox go.
async fn close_open(hub: &Arc<Hub>, d: &Delivery, f: impl FnOnce(&mut Delivery)) {
    let saved = hub.outbox.update_saved(&d.id, |d| {
        f(d);
        crate::attach::strip(&mut d.request);
    });
    // The bytes go only once the file says it closed (review of #37284 at a088585e): a restart
    // that reads it open sends it again, or checks its proof again, with them. A file left
    // without its delivery's bytes' owner is swept at the next open (`Outbox::open`).
    if saved && let Some(path) = hub.outbox.attachments_path(d) {
        forget_attachments(path).await;
    }
}

/// How long `delivery` sleeps before its next attempt, given the schedule's `secs`: a message
/// no longer than what is left of its day ([`RETRY_FOR_MS`]), a projection intent the whole delay.
fn retry_sleep(delivery: &Delivery, secs: u64, now: u64) -> Duration {
    let delay = Duration::from_secs(secs);
    if delivery.projection_only() {
        return delay;
    }
    let left = delivery.created_at.saturating_add(RETRY_FOR_MS).saturating_sub(now);
    delay.min(Duration::from_millis(left))
}

/// The most a send behind the hub's gate adds to the gate's reopening, spread by `jitter`
/// (0..1) so the queue's wakes do not all land on the same instant.
const GATE_JITTER: Duration = Duration::from_millis(250);

/// How long a send behind the hub's shut gate sleeps: until `reopens_at`, plus its jitter.
fn gate_wait(reopens_at: tokio::time::Instant, jitter: f64) -> Duration {
    let left = reopens_at.saturating_duration_since(tokio::time::Instant::now());
    left + GATE_JITTER.mul_f64(jitter.clamp(0.0, 1.0))
}

/// Whether `delivery`, a message (not a projection intent, which keeps its own schedule), is
/// past [`RETRY_FOR_MS`] since it was handed over and still not delivered.
fn expired(delivery: &Delivery, now: u64) -> bool {
    delivery.past_retry_window(now)
}

/// The wait before the next attempt of `delivery`: the next of [`RETRY_DELAYS_SECS`], then
/// twice the wait before (`tail`, the last one used) until [`RETRY_FOR_MS`] after the message was
/// handed over: a message whose target never answers costs about log2 of its day in attempts,
/// not one every 15 minutes (`retry_sleep` cuts the last wait at the end of its day). A
/// projection intent keeps the bounded schedule alone. None: it fails.
fn retry_delay(
    delays: &mut std::slice::Iter<'_, u64>,
    tail: &mut u64,
    delivery: &Delivery,
    now: u64,
) -> Option<u64> {
    if let Some(secs) = delays.next() {
        *tail = *secs;
        return Some(*secs);
    }
    let within = now < delivery.created_at.saturating_add(RETRY_FOR_MS);
    if !within || delivery.projection_only() {
        return None;
    }
    let last = RETRY_DELAYS_SECS.last().copied().unwrap_or(1);
    *tail = (*tail).max(last).saturating_mul(2);
    Some(*tail)
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
        let passes = crate::mesh_retry::transient(&e, true);
        if hub_only(hub, &delivery.target) {
            // Only the hub routes it: its refusal is final, said with its reason, and anything
            // else is tried again through it on the outbox's back-off.
            return if e.code.as_deref() == Some(super::mesh_send::BACKING_OFF) {
                // Not asked: the reason it waits is still the hub's last answer.
                let why = delivery.error.clone();
                (why.unwrap_or_else(|| super::mesh_send::waiting_reason(&e)), Next::Retry)
            } else if passes || held {
                (super::mesh_send::waiting_reason(&e), Next::Retry)
            } else if unknown_recipient_waits(&e, delivery.attempts + 1) {
                // Not listed is not gone: the hub's address book is fed by heartbeats, so a
                // paused or restarting machine reads as unknown for a while (EAGAIN, not ENOENT).
                (format!("{UNLISTED}: {e}"), Next::Retry)
            } else {
                (format!("the mesh hub refused it: {e}"), Next::Fail)
            };
        }
        let next = if e.refused && !held {
            hub.outbox.update(&delivery.id, |d| d.relay_post = None);
            Next::Unsent
        } else {
            Next::Retry
        };
        (format!("the mesh relay did not take it: {e}"), next)
    }))
}

/// [`relay_attempt`], and while the team hub is down a copy to the target's machine directly
/// (`mesh_direct.rs`, RFD 0086): only with `meshRelay.directSend` on, for a target only the hub
/// routes, on a machine this daemon's book lists, and only once every hub post of it provably
/// never left here (`Delivery::relay_unreached`). A refusal of the hub's still fails it; a
/// timeout or an answer still waits for the hub. Once a copy may have gone direct
/// (`Delivery::direct_maybe`, saved first), only the direct path tries it again, under the same
/// key, so the hub never holds a second copy.
async fn relay_or_direct(
    hub: &Arc<Hub>,
    delivery: &Delivery,
) -> Option<Result<Value, (String, Next)>> {
    use super::mesh_direct::{self, Direct};
    if hub.outbox.get(&delivery.id).is_some_and(|d| d.direct_maybe) {
        return Some(direct_again(hub, delivery).await);
    }
    let outcome = relay_attempt(hub, delivery).await;
    let Some(Err((why, next))) = &outcome else { return outcome };
    if *next == Next::Fail {
        return outcome;
    }
    // Read after the post: a first one recorded its message and whether it left.
    let Some(fresh) = hub.outbox.get(&delivery.id) else { return outcome };
    let Some(post) = fresh.relay_post.as_ref().filter(|_| fresh.relay_unreached) else {
        return outcome;
    };
    if !hub_only(hub, &delivery.target) || !mesh_direct::switch_on(hub).await {
        return outcome;
    }
    let Some(machine) = mesh_direct::machine(hub, post) else { return outcome };
    // Saved before it goes: a crash mid-attempt leaves it for the direct path alone.
    if !hub.outbox.update_saved(&delivery.id, |d| d.direct_maybe = true) {
        return outcome;
    }
    let host = machine.1.clone();
    Some(match mesh_direct::attempt(hub, &machine, post, fresh.attempts.max(1)).await {
        Direct::Taken(accepted) => Ok(accepted),
        Direct::Refused(reason) => Err((format!("{host} refused it: {reason}"), Next::Fail)),
        Direct::NotRun(reason) => {
            // The first direct copy ran nothing: the hub may carry it after all.
            hub.outbox.update(&delivery.id, |d| d.direct_maybe = false);
            Err((format!("{why}; not sent directly either: {reason}"), Next::Retry))
        }
        Direct::Maybe(reason) => {
            Err((format!("{why}; sent to {host} directly, not settled yet: {reason}"), Next::Retry))
        }
    })
}

/// A delivery whose copy may have gone to its machine directly: tried again that way only, never
/// posted to the hub, since only the direct prompt id dedups it there.
async fn direct_again(hub: &Arc<Hub>, delivery: &Delivery) -> Result<Value, (String, Next)> {
    use super::mesh_direct::{self, Direct};
    let wait = |why: String| {
        Err((
            format!(
                "sent to its machine directly before; {why}, so it waits, never sent another way"
            ),
            Next::Retry,
        ))
    };
    let fresh = hub.outbox.get(&delivery.id);
    let Some(post) = fresh.as_ref().and_then(|d| d.relay_post.as_ref()) else {
        return wait("its message is gone".into());
    };
    if !mesh_direct::switch_on(hub).await {
        return wait("direct sends are off here now (meshRelay.directSend)".into());
    }
    let Some(machine) = mesh_direct::machine(hub, post) else {
        return wait("this machine's book does not list its machine now".into());
    };
    let attempt = fresh.as_ref().map_or(1, |d| d.attempts.max(1));
    match mesh_direct::attempt(hub, &machine, post, attempt).await {
        Direct::Taken(accepted) => Ok(accepted),
        Direct::Refused(reason) => Err((format!("{} refused it: {reason}", machine.1), Next::Fail)),
        // An earlier copy may have run there: this one running nothing proves nothing of it.
        Direct::NotRun(reason) | Direct::Maybe(reason) => wait(reason),
    }
}

/// The reason a kept delivery waits while the hub lists no session by its name.
const UNLISTED: &str = "the hub lists no session by that name yet (its machine may be paused, \
     restarting or between heartbeats); tried again before it fails";

/// How many attempts a kept delivery makes while the hub answers `mesh.unknown_recipient`: on the
/// outbox's back-off ([`RETRY_DELAYS_SECS`]: 2, 5, 10, 30, 60, 120, 300 s) eight attempts span
/// about nine minutes, about three of the hub's 90 s heartbeat leases. The hub lists a session
/// only once its daemon heartbeats it, so a paused, waking or restarting machine reads as unknown
/// for a while: a not-yet-listed name is EAGAIN, not ENOENT. On one lane VM (2026-11-23 to
/// 11-25) all 3 of 69 failed deliveries were this answer, on their second attempt. A send the
/// hub refuses this way at once is still `no session` to its sender (`mesh_send.rs`): only a
/// delivery the outbox already keeps waits, so a typo is never kept.
const UNKNOWN_RECIPIENT_ATTEMPTS: u32 = 8;

/// Whether the hub's answer `e` to attempt `attempt` is a name it does not list yet, with
/// attempts left in [`UNKNOWN_RECIPIENT_ATTEMPTS`].
fn unknown_recipient_waits(e: &crate::mesh::HubError, attempt: u32) -> bool {
    e.code.as_deref() == Some("mesh.unknown_recipient") && attempt < UNKNOWN_RECIPIENT_ATTEMPTS
}

/// Whether only the hub routes `target`: no session here, none a peer lists, no peer of it down.
fn hub_only(hub: &Hub, target: &str) -> bool {
    hub.resolve(target).is_err()
        && hub.resolve_remote(target).is_none()
        && hub.peer_down_for(target).is_none()
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
    let _ = tokio::task::spawn_blocking(move || crate::home_fs::remove_file(path)).await;
}

/// The session a kept send is delivered as (`Delivery::caller`, `Delivery::unproven_caller`): one
/// the sender's connection proved, or one it named with a token this daemon could not prove.
#[derive(Clone, Copy, Debug)]
pub(super) enum Caller<'a> {
    Proven(&'a str),
    Unproven(&'a str),
    /// No session, from a connection that declared no terminal (`Delivery::not_terminal`).
    NotTerminal,
}

impl<'a> Caller<'a> {
    fn of(delivery: &'a Delivery) -> Option<Self> {
        delivery
            .caller
            .as_deref()
            .map(Caller::Proven)
            .or_else(|| delivery.unproven_caller.as_deref().map(Caller::Unproven))
            .or_else(|| delivery.not_terminal.then_some(Caller::NotTerminal))
    }
}

/// Whether acceptance `p`, a duplicate with no turn, is a receipt: the chat's inbox, its surge or
/// a hold took the message, which no turn of its own ever runs (`hub/turns.rs` `first_acceptance`).
pub(crate) fn taken_without_turn(p: &Value) -> bool {
    ["inbox", "surgeHeld", "sessionHeld", "held"]
        .iter()
        .any(|k| p.get(*k) == Some(&Value::Bool(true)))
}

/// One attempt: the target's acceptance, or the error and whether to try again. It runs on a
/// connection of `origin`: the unix socket's for a send here, a peer's for a message the mesh
/// relay delivers (`mesh_relay.rs`), so each is held to its origin's rules.
pub(super) async fn attempt_once(
    hub: &Arc<Hub>,
    caller: Option<Caller<'_>>,
    request: Value,
    origin: Origin,
) -> Result<Value, (String, Next)> {
    attempt(hub, caller, request, origin).await
}

/// Waking the machine is bounded by ATTEMPT_WAIT on the wall clock; the answer after it ends on
/// silence (`IdleDeadline`), not a wall clock (#55012), so a long answer that keeps arriving runs.
async fn attempt(
    hub: &Arc<Hub>,
    caller: Option<Caller<'_>>,
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
        if let Some(config) = config {
            match tokio::time::timeout(ATTEMPT_WAIT, crate::machine_wake::wake(&config, &summary))
                .await
            {
                Ok(Ok(_)) => {}
                Ok(Err(error)) => {
                    return Err((format!("machine wake failed: {error}"), Next::Retry));
                }
                Err(_) => {
                    return Err((
                        format!("machine wake did not finish within {} s", ATTEMPT_WAIT.as_secs()),
                        Next::Retry,
                    ));
                }
            }
        }
    }
    let prompt_id = request
        .pointer("/_meta/acpmux/promptId")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_owned();
    let (in_tx, in_rx) = mpsc::channel(16);
    let (out_tx, mut out_rx) = mpsc::channel(1024);
    tokio::spawn(super::serve_outbox_connection(hub.clone(), in_rx, out_tx, origin));
    let mut hello = json!({
        "protocolVersion": 1,
        "clientCapabilities": {},
        "clientInfo": {"name": "acpmux-outbox", "version": crate::hub::VERSION},
    });
    if let Some(caller) = caller {
        // An unproven one goes with no token, which proves nothing: the fresh connection binds it
        // unproven, as the sender's own did (`Conn::bind_person`).
        let (id, token) = match caller {
            Caller::Proven(id) => (Some(id), crate::hub::person::caller_token(id)),
            Caller::Unproven(id) => (Some(id), String::new()),
            Caller::NotTerminal => (None, String::new()),
        };
        // Never a terminal's declaration: a send that names a session or declared none is no
        // owner's terminal send (`cli_caller.rs`).
        let mut mux = crate::cli_caller::agent_declaration();
        if let Some(id) = id {
            mux.insert(
                crate::hub::person::CALLER_FIELD.to_owned(),
                json!({"sessionId": id, "token": token}),
            );
        }
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
    let mut quiet = cmux_deadline::IdleDeadline::<tokio::time::Instant>::new(ATTEMPT_WAIT, None);
    loop {
        let line = tokio::select! {
            line = out_rx.recv() => line,
            () = tokio::time::sleep_until(quiet.end()) => {
                return Err((
                    format!("nothing heard for {} s", ATTEMPT_WAIT.as_secs()),
                    Next::Retry,
                ));
            }
        };
        quiet.progressed();
        let Some(line) = line else {
            return Err(("this daemon's connection closed".into(), Next::Retry));
        };
        match Message::parse(&line) {
            // A duplicate with no turn and no receipt is a run of this id still in flight, which
            // may yet be held or refused: its answer says. One the chat's inbox (or a hold)
            // took has no turn of its own and is taken: before, each redelivery of it waited
            // for the message's answer and timed out, every 120 s, forever (2026-11-25).
            Ok(Message::Notification { method: m, params: Some(p) })
                if m == method::MUX_PROMPT_ACCEPTED
                    && p.get("promptId").and_then(Value::as_str) == Some(prompt_id.as_str())
                    && !(p.get("duplicate") == Some(&Value::Bool(true))
                        && p.get("turnId").is_none_or(Value::is_null)
                        && !taken_without_turn(&p)) =>
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
    if let Some(to) = data.and_then(|d| d.get("movedTo")).filter(|to| to.is_object()) {
        let session = to.get("sessionId").and_then(Value::as_str).filter(|s| !s.is_empty());
        let socket = to.get("socket").and_then(Value::as_str).filter(|s| s.starts_with('/'));
        let host = to.get("host").and_then(Value::as_str).filter(|h| !h.is_empty());
        match (session, host, socket) {
            (Some(session), Some(host), _) => return Next::Moved(format!("{host}/{session}")),
            (Some(session), None, Some(socket)) => {
                let (socket, session) = (socket.to_owned(), session.to_owned());
                return Next::MovedToSocket { socket, session };
            }
            (Some(session), None, None) => return Next::Moved(session.to_owned()),
            _ => {}
        }
    }
    if e.message.starts_with("transfer.moving") {
        return Next::Moving;
    }
    if data.and_then(|d| d.get("held")).and_then(Value::as_bool) == Some(true) {
        return Next::Held;
    }
    let reason = data.and_then(|d| d.get("reason")).and_then(Value::as_str).unwrap_or_default();
    // The peer's link took nothing (`peer_link::unreachable_error`): the request was not sent.
    if reason == "peer_unreachable" {
        return Next::Unsent;
    }
    if reason == "stale_generation" {
        return Next::Stale;
    }
    // No such session on the target's machine: a not-found answer (this daemon's for a peer
    // that lists none, or the peer's own), which every later attempt would give again.
    if reason == "no_session"
        || (e.code == RpcError::not_found("").code && e.message.starts_with("no session matches"))
    {
        return Next::NoSession;
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

/// Hands delivery `delivery` to the sibling daemon at `socket` that its chat moved to (as
/// `session`): that daemon's own `send_queue`, under the same prompt id, so its outbox owns it
/// from here (a second hand-off of the same prompt id is the first delivery there, never a
/// second run). Its answer, the delivery's status there, is this delivery's acceptance. Never
/// this daemon's own socket: a chat that moved here is no move away.
async fn hand_to_socket(delivery: &Delivery, socket: &str, session: &str) -> Result<Value, String> {
    let path = std::path::Path::new(socket);
    let own = crate::config::socket_path();
    let canonical = |p: &std::path::Path| std::fs::canonicalize(p).unwrap_or_else(|_| p.to_owned());
    if crate::qos::off_worker(|| canonical(path) == canonical(&own)) {
        return Err("the chat's move names this daemon's own socket".into());
    }
    let client = crate::client::Client::connect_without_caller(path)
        .await
        .map_err(|e| format!("the daemon at {socket} does not answer: {e}"))?;
    let init = json!({"protocolVersion": 1, "clientInfo": {"name": "acpmux-outbox"}});
    client.request(method::INITIALIZE, init).await.map_err(|e| e.to_string())?;
    let mut request = delivery.request.clone();
    request.set("sessionId", json!(session));
    let status = client
        .request(method::MUX_SEND_QUEUE, json!({"request": request}))
        .await
        .map_err(|e| format!("the daemon at {socket} did not take it: {e}"))?;
    Ok(json!({"handedTo": {"socket": socket, "sessionId": session}, "status": status}))
}

/// Points delivery `id` at where its chat moved (`to`, `HOST/SESSION`): its target and its
/// request's `sessionId`, with its pin dropped (the pin named the copy that moved away). The
/// moved-away copy refused the prompt before it ran, so the delivery has reached no one and the
/// mesh relay may carry it if the new machine's link is down. False when the delivery already
/// followed [`MAX_MOVES_FOLLOWED`] moves, or could not be saved.
fn follow_move(hub: &Hub, id: &str, to: &str, followed: u32) -> bool {
    if followed >= MAX_MOVES_FOLLOWED {
        return false;
    }
    hub.outbox.update_saved(id, |d| {
        if d.settled() {
            return;
        }
        tracing::info!(delivery = %d.id, from = %d.target, to, "outbox: following a moved chat");
        d.target = to.to_owned();
        d.request.set("sessionId", json!(to));
        d.pin = None;
        d.never_sent = true;
        d.state = State::Queued;
        d.error = Some(format!("the chat moved; following it to {to}"));
    })
}

/// Whether `d` settled by handing its message to a sibling daemon its chat moved to
/// (`hand_to_socket`), so a hand-back of the same prompt id reopens it rather than reading it as
/// delivered.
fn handed_away(d: &Delivery) -> bool {
    d.state == State::Delivered && d.accepted.as_ref().is_some_and(|a| a.get("handedTo").is_some())
}

#[cfg(test)]
#[path = "outbox_moved_next_tests.rs"]
mod moved_next_tests;

#[cfg(test)]
#[path = "outbox_no_session_next_tests.rs"]
mod no_session_next_tests;

#[cfg(test)]
#[path = "outbox_retry_delay_tests.rs"]
mod retry_delay_tests;

#[cfg(test)]
#[path = "outbox_redeliver_tests.rs"]
mod redeliver_tests;

#[cfg(test)]
#[path = "outbox_forward_projection_tests.rs"]
mod forward_projection_tests;

#[cfg(test)]
#[path = "outbox_relay_tests.rs"]
mod relay_tests;

#[cfg(test)]
#[path = "outbox_hub_queue_tests.rs"]
mod hub_queue_tests;

#[cfg(test)]
#[path = "outbox_direct_tests.rs"]
mod direct_tests;
#[cfg(test)]
#[path = "lost_message_tests.rs"]
mod lost_message_tests;
