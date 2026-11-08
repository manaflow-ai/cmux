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
pub(crate) async fn new_on(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    params: &Value,
    host: &str,
) -> Option<Result<Value, RpcError>> {
    if !read::may_read(conn) || !hub.mesh_book_has_host(host) {
        return None;
    }
    let mesh = hub.mesh.get()?.clone();
    Some(start(hub, conn, mesh, params, host).await)
}

async fn start(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    mesh: Arc<dyn crate::mesh::MeshHub>,
    params: &Value,
    host: &str,
) -> Result<Value, RpcError> {
    let mut start = params.clone();
    super::super::peer_forward::strip_new_meta(&mut start);
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
                let said = if why == "mesh.control_not_allowed" {
                    "it takes no chats from this machine (its join was removed, or it is not this \
                     person's)"
                        .to_owned()
                } else {
                    why.clone()
                };
                return Err(RpcError::new(-32003, format!("{host} refused the chat: {said}"))
                    .with_data(json!({"reason": "mesh.start_refused", "peer": host, "detail": why})));
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
