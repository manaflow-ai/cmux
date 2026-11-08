//! Starting a chat on a machine only the mesh hub reaches. Leo, 2026-11-08: "it's about the
//! automaticness of it ... the app [freaking] gets the stuff done."
//!
//! The app's new-chat picker lists the person's hub-joined machines beside the linked ones
//! (`_acpmux/peers`, `hub/mesh_book.rs`). A `session/new` whose `_meta.acpmux.peer` names one that
//! no peer link reaches starts there through the hub's control path, as `acpmux session start NAME
//! --machine HOST` does (`mesh_control.rs`): one `start` control message, its receipt waited on
//! (bounded, [`START_WAIT`]). The machine runs it as a peer's `session/new` and acks with the new
//! session's id. The answer here is that id with `peer: HOST` and `via: "hub"`, as a linked
//! peer's start answers, so the app opens it like any remote chat:
//!
//! - the chat is listed at once (`Hub::mesh_book_started`) until the book lists it, so its bare id
//!   routes to its machine;
//! - a prompt to it goes through the hub (`read::prompt`, `mesh_send.rs`);
//! - its records reach this connection through `follow.rs` (reads through the hub today, the live
//!   hub stream carrier once it lands, with no change to the app).
//!
//! Only this machine's own socket or the app's pane may borrow this daemon's hub identity
//! (`read::may_read`). The machine checks the hub-stamped sender against its own
//! `meshRelay.controlFrom` (`sameUser`), so a machine whose join was revoked, or another person's,
//! refuses; the hub refuses a recipient it does not know.
//!
//! The start is marked as a linked peer's is (`remote_guard::mark_forwarded`): `via: app` for
//! the pane, `web` or `device` for others, and `createdBy` as this daemon decides it. The machine
//! gates a marked start with its folder-trust gate (a folder with no answer, or Don't trust, is
//! refused there: `trust.pending`, `trust.untrusted`), records the mark on the chat
//! (`SessionMeta::hub_via`), and holds every prompt the hub relays to that chat to it, so the
//! pane cannot prompt through the hub what it could not prompt over a peer link. A full-access
//! starter's policy goes on as over a link (`forward_starter_policy`). The VM-boundary opt-out
//! (`hub/vm_boundary.rs`) is not sent: it is a linked peer's setting, and without it the chat
//! keeps the platform sandbox, which fails safe.
//!
//! A marked start goes as control body version 2 (`mesh_control::MARKED_START_VERSION`): a
//! machine takes it only if it keeps that gate. One on an older cmux refuses the version before
//! anything runs, and the pane hears `mesh.trust_unsupported`: update cmux on that machine. The
//! hub's book carries no feature list, so the start itself is the probe.

use super::*;
use crate::mesh::{HubError, Sender};
use crate::mesh_control::{Command, ControlRequest, MeshControlRelay, Recipient};
use std::time::Duration;

/// How long a start waits for its machine's answer. A machine acks within 50 s or keeps the
/// start running and acks it later (`MeshControlHook`); an agent may take most of a minute to
/// start. Past this the start is reported as not answered, with its receipt.
const START_WAIT: Duration = Duration::from_secs(100);

/// One wait on the receipt (the hub holds it at most 25 s).
const ANSWER_WAIT: Duration = Duration::from_secs(25);

/// `session/new` on hub machine `host`, or None when this daemon has no hub, `host` is no machine
/// its book lists, or `conn` may not use the hub; the caller then refuses it as before.
/// `created_by` is the `_meta.acpmux` stamp of who creates it, as the peer-link start sends it.
pub(crate) async fn new_on(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    params: &Value,
    host: &str,
    created_by: Value,
) -> Option<Result<Value, RpcError>> {
    if !read::may_read(conn) || !hub.mesh_book_has_host(host) {
        return None;
    }
    let mesh = hub.mesh.get()?.clone();
    Some(start(hub, conn, mesh, params, host, created_by).await)
}

async fn start(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    mesh: Arc<dyn crate::mesh::MeshHub>,
    params: &Value,
    host: &str,
    created_by: Value,
) -> Result<Value, RpcError> {
    let mut start = params.clone();
    super::super::peer_forward::strip_new_meta(&mut start);
    // As a linked peer's start is marked: whom it is for (the machine gates `app` and `web`
    // there), a full-access starter's policy, and who creates it.
    super::super::remote_guard::mark_forwarded(conn.origin, conn.auth, params, &mut start);
    hub.forward_starter_policy(conn.caller(), &mut start);
    crate::hub::merge_mux_meta(&mut start, created_by);
    let start = start
        .as_object()
        .cloned()
        .ok_or_else(|| RpcError::invalid_params("session/new params must be an object"))?;
    let meta = |key: &str| {
        params.pointer(&format!("/_meta/acpmux/{key}")).and_then(Value::as_str).map(str::to_owned)
    };
    let key = format!("new-{}", uuid::Uuid::now_v7());
    let request = ControlRequest::new(
        Recipient::Host { host: host.to_owned() },
        Command::Start { params: start },
        key.clone(),
    )
    .map_err(|e| RpcError::invalid_params(e.to_string()))?;
    let sender = Sender {
        name: conn.caller().map(|id| hub.session_name(id)),
        session_id: conn.caller().map(str::to_owned),
        host: Some(crate::pairing::machine_name()),
        ..Sender::default()
    };
    let relay = MeshControlRelay::new(mesh.clone(), sender);
    let mut receipt =
        crate::mesh_control::submit(&relay, &request).await.map_err(|e| refusal(host, e))?;
    let deadline = tokio::time::Instant::now() + START_WAIT;
    loop {
        match receipt.state.as_str() {
            "delivered" => break,
            "refused" => {
                let why = receipt.detail.unwrap_or_else(|| "no reason given".into());
                // The machine's folder-trust gate keeps its reason, so the pane says it as a
                // linked peer's refusal.
                let reason = ["trust.pending", "trust.untrusted", "mesh.start_unsaved"]
                    .into_iter()
                    .find(|r| why.contains(r))
                    .unwrap_or("mesh.start_refused");
                if why == "unsupported control body version" {
                    return Err(RpcError::new(
                        -32003,
                        format!(
                            "{host} runs an older cmux that cannot keep this chat behind its \
                             folder-trust gate: update cmux on {host}"
                        ),
                    )
                    .with_data(json!({"reason": "mesh.trust_unsupported", "peer": host})));
                }
                let said = if why == "mesh.control_not_allowed" {
                    "it takes no chats from this machine (its join was removed, or it is not this \
                     person's)"
                        .to_owned()
                } else {
                    why.clone()
                };
                return Err(RpcError::new(-32003, format!("{host} refused the chat: {said}"))
                    .with_data(json!({"reason": reason, "peer": host, "detail": why})));
            }
            "expired" => return Err(unanswered(host, &receipt.message_id)),
            _ => {}
        }
        let left = deadline.saturating_duration_since(tokio::time::Instant::now());
        if left.is_zero() {
            return Err(unanswered(host, &receipt.message_id));
        }
        receipt = mesh
            .answer(&receipt.message_id, left.min(ANSWER_WAIT))
            .await
            .map_err(|e| refusal(host, e))?;
    }
    let id = receipt.detail.filter(|id| !id.is_empty() && !id.contains('/')).ok_or_else(|| {
        RpcError::internal(format!("{host} started the chat but did not say its session id"))
    })?;
    let name = meta("name").unwrap_or_else(|| id.clone());
    hub.mesh_book_started(host, &id, &name, &meta("harness").unwrap_or_default());
    follow::follow(
        hub,
        conn,
        follow::Chat { host: host.to_owned(), remote: id.clone(), key: id.clone() },
        0,
    );
    Ok(json!({
        "sessionId": id,
        "peer": host,
        "via": "hub",
        "qualifiedSessionId": format!("{host}/{id}"),
        "receipt": receipt.message_id,
    }))
}

fn unanswered(host: &str, receipt: &str) -> RpcError {
    RpcError::new(
        -32000,
        format!(
            "{host} did not answer the start through the mesh hub; it may still start (receipt {receipt}: `acpmux session receipt {receipt}`)"
        ),
    )
    .with_data(json!({"reason": "mesh.start_unanswered", "peer": host, "receipt": receipt}))
}

/// The hub's refusal of the start, said for the machine.
fn refusal(host: &str, e: HubError) -> RpcError {
    let code = e.code.as_deref().unwrap_or("mesh.unavailable");
    let message = match code {
        "mesh.unknown_recipient" => {
            format!("no machine {host:?} through the mesh hub: it left or its join was removed")
        }
        "machine.revoked" | "mesh.unauthorized" => {
            format!("the mesh hub refused the chat on {host}: {}", e.message)
        }
        _ => format!("could not start the chat on {host} through the mesh hub: {}", e.message),
    };
    let error = if code == "mesh.unknown_recipient" {
        RpcError::not_found(message)
    } else {
        RpcError::new(-32000, message)
    };
    error.with_data(json!({
        "reason": code, "peer": host, "candidates": e.candidates, "retryable": !e.refused,
    }))
}

#[cfg(test)]
#[path = "mesh_start_tests.rs"]
mod tests;
