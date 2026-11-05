//! Reading a session on a machine only the mesh hub reaches: no ssh peer, no tailnet. Leo,
//! 2026-11-05: "I don't want to deal with SSH keys. I just want the app to handle the thing for
//! me."
//!
//! A read is a control message with op `read` (cmux-platform `MeshOp`). Its body names one
//! read-only method and its params: `{"version": 1, "method": "_acpmux/events" | "_acpmux/info"
//! | "_acpmux/attach", "params": {...}}`. An attach there is a hidden one, answered with the
//! chat's detail and newest page; the connection it ran on ends with the read, so it streams
//! nothing (the chat opens as it is then). The receiving daemon runs it on its own session, as a peer daemon's request
//! (`Origin::Peer`), and puts the answer in the ack's `result`. The sender waits on the message's
//! receipt (`MeshHub::answer`), and the hub shows the result to the sender alone. That is
//! Tailscale's DERP shape: the relay forwards over connections both ends already hold, and only
//! the two machines read what it carries.
//!
//! Authority is the person's, twice over. The hub takes a read only between daemons of the same
//! user. The receiver checks the hub-stamped sender against its own `meshRelay.controlFrom`
//! (`sameUser`, the entry `host join` writes) before anything runs (`MeshControlHook::control`).
//!
//! The sending side is [`forward`]. An `_acpmux/info`, `_acpmux/events` or `_acpmux/attach` for
//! `HOST/KEY` that
//! nothing here and no ssh peer resolves (`Hub::mesh_may_route`, the send fallback's own test)
//! goes to the hub when this daemon has one. It is taken only from this machine's own socket or
//! the app's pane, never from a peer daemon's link. Its answer carries `peer: HOST` and
//! `via: "hub"`, so `acpmux last HOST/NAME`, the app's chat for a session there and the next page
//! route back the same way.

use super::*;
use crate::mesh::{
    Ack, HubError, InMessage, Kind, MAX_READ_RESULT_BYTES, Mode, OutMessage, Sender, Target,
};
use std::time::Duration;

/// The methods a read may run: each answers a page of a session and changes nothing.
const READ_METHODS: &[&str] = &[method::MUX_INFO, method::MUX_EVENTS, method::MUX_ATTACH];

/// Whether `m` reads a page of events, so its params cross and its budget halves.
fn pages(m: &str) -> bool {
    matches!(m, method::MUX_EVENTS | method::MUX_ATTACH)
}

/// The params of an events read that go across. The session is the target's; nothing else is
/// taken from the asker.
const EVENT_PARAMS: &[&str] =
    &["afterSeq", "beforeSeq", "limit", "kinds", "maxBytes", "promptIndex", "waitLogs"];

/// The largest events page a read asks for first. The JSON of a page runs past its byte budget
/// (`hub/paging.rs` counts records, not the reply around them), so this leaves the hub's 64 KiB
/// room; a page that still does not fit is asked for again at half the budget.
const READ_PAGE_BYTES: u64 = 40 * 1024;

/// The smallest budget a read halves to before it gives up on a page.
const MIN_READ_PAGE_BYTES: u64 = 4 * 1024;

/// How long a read waits for its answer. The hub expires an unanswered read after a minute.
const READ_WAIT: Duration = Duration::from_secs(50);

/// One wait on the receipt (the hub holds it at most 25 s).
const ANSWER_WAIT: Duration = Duration::from_secs(25);

/// The refusal prefix of a session the receiving daemon does not have.
const NO_SESSION: &str = "mesh.read_no_session";

/// The receiving side: run one authorized read and answer it in the ack.
pub(super) async fn answer(hub: &Arc<Hub>, message: &InMessage) -> Ack {
    match run(hub, message).await {
        Ok(result) => Ack::answered(&message.message_id, result),
        Err(why) => Ack::refused(why),
    }
}

async fn run(hub: &Arc<Hub>, message: &InMessage) -> Result<String, String> {
    if message.body.len() > MAX_READ_RESULT_BYTES {
        return Err("read body exceeds 64 KiB".into());
    }
    let body: Value =
        serde_json::from_str(&message.body).map_err(|e| format!("invalid read body: {e}"))?;
    if body.get("version").and_then(Value::as_u64) != Some(1) {
        return Err("unsupported read body version".into());
    }
    let m = body.get("method").and_then(Value::as_str).unwrap_or_default();
    if !READ_METHODS.contains(&m) {
        return Err(format!("mesh.read_unsupported: {m:?} is not a read"));
    }
    // Only a session of this daemon, by its exact id or whole name, as a resume or stop does.
    let target = Target {
        session_id: message.to.session_id.clone(),
        name: message.to.name.clone(),
        ..Default::default()
    };
    let session = hub.mesh_target(&target, None).map_err(|why| format!("{NO_SESSION}: {why}"))?;
    let mut params = json!({"sessionId": session.id});
    let asked = body.get("params").and_then(Value::as_object);
    if pages(m) {
        for key in EVENT_PARAMS {
            if let Some(value) = asked.and_then(|p| p.get(*key)) {
                params[*key] = value.clone();
            }
        }
    }
    let mut budget = params
        .get("maxBytes")
        .and_then(Value::as_u64)
        .unwrap_or(READ_PAGE_BYTES)
        .clamp(MIN_READ_PAGE_BYTES, READ_PAGE_BYTES);
    let (tx, mut rx) = super::relay_connection(hub);
    let init = json!({
        "protocolVersion": 1,
        "clientCapabilities": {},
        "clientInfo": {"name": "acpmux-mesh-read", "version": crate::hub::VERSION},
    });
    super::rpc_call(&tx, &mut rx, 1, method::INITIALIZE, init).await.map_err(failure)?;
    if m == method::MUX_ATTACH {
        // Seen by no one here: it neither wakes the agent nor shows as a viewer.
        params["visible"] = json!(false);
    }
    for id in 2.. {
        if pages(m) {
            params["maxBytes"] = json!(budget);
        }
        let reply = super::rpc_call(&tx, &mut rx, id, m, params.clone()).await.map_err(failure)?;
        let text = reply.to_string();
        if text.len() <= MAX_READ_RESULT_BYTES {
            return Ok(text);
        }
        if !pages(m) || budget <= MIN_READ_PAGE_BYTES {
            break;
        }
        budget = (budget / 2).max(MIN_READ_PAGE_BYTES);
    }
    Err("mesh.read_too_large: the answer does not fit the hub's 64 KiB".into())
}

fn failure(failure: super::ControlFailure) -> String {
    match failure {
        super::ControlFailure::Refused(why) => why,
        super::ControlFailure::Unknown => "the read did not finish".into(),
    }
}

/// The sending side: `m` for `HOST/KEY` through the hub, when nothing nearer has the session.
/// None leaves the request to this daemon's own handlers (and their `no session`).
pub(crate) async fn forward(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    params: &Value,
) -> Option<Result<Value, RpcError>> {
    if !(READ_METHODS.contains(&m) || m == method::MUX_DETACH) || !may_read(conn) {
        return None;
    }
    let mesh = hub.mesh.get()?.clone();
    let key = session_key(params).ok()?;
    let (host, rest) = key.split_once('/')?;
    if host.is_empty() || rest.is_empty() || !hub.mesh_may_route(key) {
        return None;
    }
    // A hub attach holds no stream, so there is nothing to detach.
    if m == method::MUX_DETACH {
        return Some(Ok(json!({})));
    }
    Some(read(mesh.as_ref(), host, rest, m, params).await)
}

/// Whether this connection may borrow this daemon's hub identity for a read: its own socket, or
/// the app's pane. A peer daemon's link, a web client or a paired device never may.
fn may_read(conn: &Conn) -> bool {
    match conn.origin {
        Origin::Local => conn.auth == ConnAuth::LocalSocket,
        Origin::LocalApp => true,
        Origin::Web | Origin::Peer => false,
    }
}

/// Whom `HOST/KEY` names at the hub: a session id when KEY is one (session ids are UUIDs), else
/// a name, on host HOST either way.
fn recipient(host: &str, key: &str) -> Target {
    let host = Some(host.to_owned());
    if uuid::Uuid::try_parse(key).is_ok() {
        Target { session_id: Some(key.to_owned()), host, ..Target::default() }
    } else {
        Target { name: Some(key.to_owned()), host, ..Target::default() }
    }
}

/// The request body a read carries: the method and only the params the receiver takes.
fn body(m: &str, params: &Value) -> String {
    let mut picked = serde_json::Map::new();
    if pages(m) {
        for key in EVENT_PARAMS {
            if let Some(value) = params.get(*key) {
                picked.insert((*key).to_owned(), value.clone());
            }
        }
    }
    json!({"version": 1, "method": m, "params": picked}).to_string()
}

pub(crate) async fn read(
    mesh: &dyn crate::mesh::MeshHub,
    host: &str,
    key: &str,
    m: &str,
    params: &Value,
) -> Result<Value, RpcError> {
    let message = OutMessage {
        to: recipient(host, key),
        from: Sender { host: Some(crate::pairing::machine_name()), ..Sender::default() },
        kind: Kind::Control,
        op: Some("read".into()),
        body: body(m, params),
        mode: Mode::Now,
        idempotency_key: format!("read-{}", uuid::Uuid::now_v7()),
    };
    let mut receipt = mesh.send(&message).await.map_err(|e| hub_error(host, key, e))?;
    let deadline = tokio::time::Instant::now() + READ_WAIT;
    loop {
        match receipt.state.as_str() {
            "delivered" => break,
            "refused" => {
                let why = receipt.detail.unwrap_or_else(|| "the machine refused the read".into());
                return Err(if why.starts_with(NO_SESSION) {
                    RpcError::not_found(format!("no session matches \"{host}/{key}\""))
                } else {
                    RpcError::new(-32003, why).with_data(json!({"reason": "mesh.read_refused"}))
                });
            }
            "expired" => return Err(unanswered(host)),
            _ => {}
        }
        let left = deadline.saturating_duration_since(tokio::time::Instant::now());
        if left.is_zero() {
            return Err(unanswered(host));
        }
        receipt = mesh
            .answer(&receipt.message_id, left.min(ANSWER_WAIT))
            .await
            .map_err(|e| hub_error(host, key, e))?;
    }
    let text = receipt.result.ok_or_else(|| {
        RpcError::internal(format!("{host} answered the read with no result; is it on a build that reads?"))
    })?;
    let mut reply: Value = serde_json::from_str(&text)
        .map_err(|_| RpcError::internal(format!("{host}'s answer to the read is not JSON")))?;
    if let Some(object) = reply.as_object_mut() {
        object.insert("peer".into(), json!(host));
        object.insert("via".into(), json!("hub"));
    }
    Ok(reply)
}

fn unanswered(host: &str) -> RpcError {
    RpcError::new(-32000, format!("{host} did not answer the read through the mesh hub"))
        .with_data(json!({"reason": "mesh.read_unanswered", "retryable": true}))
}

/// The hub's refusal as this daemon's: a session it does not know is `no session`, as a send's.
fn hub_error(host: &str, key: &str, e: HubError) -> RpcError {
    match e.code.as_deref() {
        Some("mesh.unknown_recipient") => {
            RpcError::not_found(format!("no session matches \"{host}/{key}\""))
        }
        code => RpcError::new(-32000, e.message.clone()).with_data(json!({
            "reason": code.unwrap_or("mesh.unavailable"),
            "candidates": e.candidates,
            "retryable": !e.refused,
        })),
    }
}

#[cfg(test)]
#[path = "mesh_read_tests.rs"]
mod tests;
