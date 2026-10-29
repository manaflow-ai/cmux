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
        return status(hub, params).await;
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
        return Err(RpcError::invalid_params(format!("no session: {target}"))
            .with_data(json!({"reason": "no_session", "session": target})));
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
    let message_id = params
        .pointer("/_meta/acpmux/messageId")
        .and_then(Value::as_str)
        .or(prompt_id)
        .unwrap_or_default();
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
    let intent = &delivery.request["_meta"]["acpmux"]["forwardProjection"];
    let caller = delivery.caller.as_deref().unwrap_or_default();
    let source = hub
        .resolve(caller)
        .ok()
        .filter(|s| s.id == caller)
        .ok_or_else(|| ("the message sender no longer exists".to_owned(), Next::Fail))?;
    if let Some(accepted) = &delivery.accepted {
        if hub.append_sender_message_event(
            &source.id,
            intent["sender"].clone(),
            intent["text"].as_str().unwrap_or_default().to_owned(),
            intent["messageId"].as_str().unwrap_or_default().to_owned(),
            delivery.updated_at,
            delivery.target.split_once('/').map(|(_, target)| target).unwrap_or(&delivery.target),
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
                && msg["sender"]["sessionId"] == caller
            {
                if !hub.append_sender_message_event(
                    &source.id,
                    intent["sender"].clone(),
                    intent["text"].as_str().unwrap_or_default().to_owned(),
                    intent["messageId"].as_str().unwrap_or_default().to_owned(),
                    msg["at"].as_u64().unwrap_or_else(crate::store::now_ms),
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

pub(super) fn forward_refused(hub: &Arc<Hub>, id: &str, error: &RpcError) {
    hub.outbox.update(id, |d| {
        // A turn can fail after its message was accepted. It cannot undo that
        // acceptance or turn a delivered event into a failed delivery.
        if d.settled() || d.accepted.is_some() {
            return;
        }
        d.state = match next(error) {
            Next::Retry => State::Held,
            Next::Held => State::Held,
            Next::Fail => State::Failed,
        };
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

async fn status(hub: &Arc<Hub>, params: &Value) -> Result<Value, RpcError> {
    let id = str_param(params, "deliveryId")
        .ok_or_else(|| RpcError::invalid_params("deliveryId is required"))?;
    if id.starts_with(super::mesh_send::PREFIX)
        && let Some(mesh) = hub.mesh.get()
    {
        return super::mesh_send::status(mesh, id).await;
    }
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
            if d.settled() {
                return;
            }
            d.state = if d.projection_only() { State::Held } else { State::Delivering };
            d.attempts = attempt;
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
        let result = if request.pointer("/_meta/acpmux/forwardProjection").is_some() {
            tokio::time::timeout(ATTEMPT_WAIT, reconcile_forward(hub, &delivery))
                .await
                .unwrap_or_else(|_| Err(("peer message lookup timed out".into(), Next::Retry)))
        } else {
            attempt_once(hub, delivery.caller.as_deref(), request, Origin::Local).await
        };
        match result {
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
                let delay = delays.next().filter(|_| next == Next::Retry);
                hub.outbox.update(id, |d| {
                    if d.settled() {
                        return;
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
                tokio::time::sleep(Duration::from_secs(*secs)).await;
            }
        }
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
        // Reopen the source state as daemon startup does. No original callback survives.
        let restarted = make_hub();
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
        let done =
            status(&restarted, &json!({"deliveryId": intent_id, "waitMs": 10_000})).await.unwrap();
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
            "_acpmuxTarget": receiver.id})
        );
        assert_eq!(
            receiver.meta().event_count,
            before,
            "recovery must never send the prompt again"
        );
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
