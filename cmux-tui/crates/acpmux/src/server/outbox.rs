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
use crate::hub::outbox::{Delivery, State};

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
const RETRY_DELAYS_SECS: &[u64] = &[2, 5, 10, 30, 60, 120, 300, 600, 900];
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
    if mux.get("promptId").and_then(Value::as_str).is_none_or(str::is_empty) {
        mux.insert("promptId".into(), json!(uuid::Uuid::now_v7().to_string()));
    }
    let now = crate::store::now_ms();
    let new = Delivery {
        id: uuid::Uuid::now_v7().to_string(),
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
    tokio::spawn(async move { deliver(&hub, &id).await });
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
            d.state = State::Delivering;
            d.attempts = attempt;
        });
        let mut request = delivery.request.clone();
        // A later attempt asks for the first one's outcome when the target took it already.
        if attempt > 1
            && let Some(mux) = request.pointer_mut("/_meta/acpmux").and_then(Value::as_object_mut)
        {
            mux.insert("resend".into(), json!(true));
        }
        match attempt_once(hub, delivery.caller.as_deref(), request, Origin::Local).await {
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
                    d.state = match (next, delay) {
                        (Next::Held, _) => State::Held,
                        (_, Some(_)) => State::Queued,
                        _ => State::Failed,
                    };
                    d.error = Some(error);
                    if d.settled() {
                        crate::attach::strip(&mut d.request);
                    }
                });
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
