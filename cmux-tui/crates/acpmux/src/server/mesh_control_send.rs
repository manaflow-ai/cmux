//! The local socket's mesh lifecycle enqueue/receipt endpoint. A remote connection may not
//! borrow this daemon's allowlisted identity to control a third daemon.

use super::*;
use crate::mesh::{HubError, Sender};
use crate::mesh_control::{Command, ControlRequest, MeshControlRelay, Recipient};
use std::time::Duration;

fn recipient(value: &Value) -> Result<Recipient, RpcError> {
    let object =
        value.as_object().ok_or_else(|| RpcError::invalid_params("to must be an object"))?;
    let field = |name| object.get(name).and_then(Value::as_str).map(str::to_owned);
    match (field("sessionId"), field("name"), field("host"), field("daemonId"), object.len()) {
        (Some(session_id), None, None, None, 1) => Ok(Recipient::Session { session_id }),
        (None, Some(name), None, None, 1) => Ok(Recipient::Name { name, host: None }),
        (None, Some(name), Some(host), None, 2) => Ok(Recipient::Name { name, host: Some(host) }),
        (None, None, Some(host), None, 1) => Ok(Recipient::Host { host }),
        (None, None, None, Some(daemon_id), 1) => Ok(Recipient::Daemon { daemon_id }),
        _ => Err(RpcError::invalid_params("to must name one exact mesh recipient")),
    }
}

/// A start's `session/new` params, stamped with `answer`, this Mac's answer to cmux's tools: the
/// chat there follows it, never the caller's (`hub/cmux_tools_answer.rs`), as a `session/new`
/// forwarded to a peer does.
fn start_params(params: &Value, answer: &str) -> Result<serde_json::Map<String, Value>, RpcError> {
    let mut start = Value::Object(
        params
            .as_object()
            .cloned()
            .ok_or_else(|| RpcError::invalid_params("start requires params"))?,
    );
    crate::hub::cmux_tools_answer::stamp(&mut start, answer);
    match start {
        Value::Object(params) => Ok(params),
        _ => Err(RpcError::internal("start params are not an object")),
    }
}

fn error(error: HubError) -> RpcError {
    let code = error.code.as_deref().unwrap_or("mesh.unavailable");
    RpcError::new(-32000, error.message.clone()).with_data(json!({
        // A hub's 5xx or 429 passes too, as `mesh_retry::transient` says.
        "reason": code, "candidates": error.candidates,
        "retryable": crate::mesh_retry::transient(&error, false),
    }))
}

/// Mesh controls come from this daemon's own local socket, never from a remote-controlled turn.
fn local_only(hub: &Hub, conn: &Conn) -> Result<(), RpcError> {
    if conn.origin != Origin::Local || conn.auth != ConnAuth::LocalSocket {
        return Err(RpcError::new(-32003, "mesh controls require this daemon's local socket")
            .with_data(json!({"reason": "mesh.local_only"})));
    }
    if let Some(caller) = conn.caller() {
        let caller = hub.resolve(caller)?;
        // This existing check detects both the current and last remote-controlled turn.
        if hub.subsession_attach_check(&caller).is_err() {
            return Err(RpcError::new(
                -32003,
                "a remote-controlled session cannot forward mesh controls",
            )
            .with_data(json!({"reason": "mesh.local_only"})));
        }
    }
    Ok(())
}

pub(super) async fn handle(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    params: &Value,
) -> Result<Value, RpcError> {
    local_only(hub, conn)?;
    let mesh =
        hub.mesh.get().ok_or_else(|| RpcError::new(-32000, "mesh relay is not configured"))?;
    if let Some(id) = params.get("receipt").and_then(Value::as_str) {
        if !crate::mesh::is_message_id(id) {
            return Err(RpcError::invalid_params("invalid mesh receipt id"));
        }
        return serde_json::to_value(mesh.receipt(id).await.map_err(error)?)
            .map_err(|e| RpcError::internal(e.to_string()));
    }
    let to = recipient(&params["to"])?;
    let command = match params["op"].as_str() {
        Some("start") => {
            let start = start_params(
                &params["params"],
                crate::hub::cmux_tools_answer::here_for(
                    crate::user_settings::text().as_deref(),
                    &params["params"],
                ),
            )?;
            // The person's start level, or a full-access caller's, as a start through an ssh
            // peer carries it (`hub/full_access_children.rs`): the machine serves the relay as a
            // peer daemon, so without it every such chat started asking there (hq#11835 row 4).
            let mut start = Value::Object(start);
            // A nested start has the same authority as session/new. The outer mesh method
            // must not let an asking agent name a wider policy on another machine.
            hub.person_check(
                conn.is_person(),
                false,
                conn.caller(),
                true,
                method::SESSION_NEW,
                &start,
            )
            .await?;
            let person = super::requests::person_start(conn, &start);
            hub.forward_start_policy(person, conn.caller(), &mut start).await;
            let Value::Object(params) = start else {
                return Err(RpcError::invalid_params("start requires params"));
            };
            Command::Start { params }
        }
        Some("resume") => Command::Resume,
        Some("stop") => Command::Stop,
        _ => return Err(RpcError::invalid_params("op must be start, resume or stop")),
    };
    let key = params["idempotencyKey"]
        .as_str()
        .ok_or_else(|| RpcError::invalid_params("idempotencyKey is required"))?;
    let request = ControlRequest::new(to, command, key.to_owned())
        .map_err(|e| RpcError::invalid_params(e.to_string()))?;
    let sender = Sender {
        name: conn.caller().map(|id| hub.session_name(id)),
        session_id: conn.caller().map(str::to_owned),
        host: Some(crate::pairing::mesh_host()),
        ..Sender::default()
    };
    let relay = MeshControlRelay::new(mesh.clone(), sender);
    let receipt = crate::mesh_control::submit(&relay, &request).await.map_err(error)?;
    let mut reply = serde_json::to_value(receipt).map_err(|e| RpcError::internal(e.to_string()))?;
    if let Some(reply) = reply.as_object_mut() {
        reply.insert("idempotencyKey".into(), json!(key));
    }
    Ok(reply)
}

/// How long a `new` started through the hub waits for the machine there to say it started.
// timeout: the start's receipt is kept; the caller reads it with `acpmux session receipt ID`.
const START_WAIT: Duration = Duration::from_secs(120);

/// A `session/new` for `host`, a machine only the mesh hub reaches (`hub/mesh_book.rs`): sent as
/// the hub's start control, as `acpmux session start NAME --machine HOST` sends it, and answered
/// as a peer's start is (`sessionId`, `peer`), with `via: "hub"`, once that machine started it.
/// Before, a placed `new` there was refused as no peer (a lane VM, 2026-11-24: every
/// fleet host was hub-only). Its prompts then go through the hub (`mesh_read.rs` `prompt`).
pub(super) async fn start_through_hub(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    params: &Value,
    host: &str,
) -> Result<Value, RpcError> {
    let started = start_through(hub, conn, params, host).await;
    // A host that refuses starts leaves `machine pick` for a while (`placement/reach.rs`).
    crate::placement::reach::note_start_outcome(host, started.as_ref().err());
    started
}

async fn start_through(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    params: &Value,
    host: &str,
) -> Result<Value, RpcError> {
    local_only(hub, conn)?;
    let mesh =
        hub.mesh.get().ok_or_else(|| RpcError::new(-32000, "mesh relay is not configured"))?;
    let mut p = params.clone();
    super::peer_forward::strip_new_meta(&mut p);
    let meta = p.pointer("/_meta/acpmux");
    // A create key that fits the hub's key keeps a resent `new` from starting a second chat.
    let name = meta.and_then(|m| m.get("name")).and_then(Value::as_str).map(str::to_owned);
    // A named start that last failed in a way that may pass is resent with its key, so the hub
    // answers with that start's message and session, not a second chat (`unsettled`).
    let slot = name.as_deref().map(|n| unsettled::Slot::new(conn.caller(), host, n));
    let key = slot
        .as_ref()
        .and_then(unsettled::Slot::key)
        .or_else(|| {
            crate::hub::create_key::requested(meta)
                .ok()
                .flatten()
                .filter(|k| k.len() >= 8)
                .map(|k| format!("new:{k}"))
        })
        .unwrap_or_else(|| uuid::Uuid::now_v7().to_string());
    let answer =
        crate::hub::cmux_tools_answer::here_for(crate::user_settings::text().as_deref(), &p);
    let mut start = Value::Object(start_params(&p, answer)?);
    let person = super::requests::person_start(conn, params);
    hub.forward_start_policy(person, conn.caller(), &mut start).await;
    let Value::Object(start) = start else {
        return Err(RpcError::invalid_params("start requires params"));
    };
    let to = Recipient::Host { host: host.to_owned() };
    let request = ControlRequest::new(to, Command::Start { params: start }, key.clone())
        .map_err(|e| RpcError::invalid_params(e.to_string()))?;
    let sender = Sender {
        name: conn.caller().map(|id| hub.session_name(id)),
        session_id: conn.caller().map(str::to_owned),
        host: Some(crate::pairing::mesh_host()),
        ..Sender::default()
    };
    let relay = MeshControlRelay::new(mesh.clone(), sender);
    let until = tokio::time::Instant::now() + START_WAIT;
    let started = async {
        // The keyed send is safe to post again: the hub answers a resend with the same message.
        let receipt = crate::mesh_retry::ride_out(false, until, || {
            crate::mesh_control::submit(&relay, &request)
        })
        .await
        .map_err(error)?;
        let receipt = settled(mesh.as_ref(), receipt, until).await?;
        started(receipt, host, name.as_deref(), &key)
    }
    .await;
    if let Some(slot) = &slot {
        slot.note(&key, &started);
    }
    let started = started?;
    if let Some(id) = started.get("sessionId").and_then(Value::as_str) {
        hub.note_created_remote(host, id, name.as_deref());
    }
    Ok(started)
}

/// `receipt`, waited on through the hub until it is delivered, refused or expired, or `wait`
/// passes.
/// A hub that fails to answer for a while (a 503 `mesh.unavailable`) is asked again until
/// `until`: the start may already be running there, so one failed read is not its answer.
/// Before, the first failed read failed the `new` although the session started (fs-agent-lane-47,
/// 2026-11-28: a caller's retries left 8 idle duplicates).
async fn settled(
    mesh: &dyn crate::mesh::MeshHub,
    mut receipt: crate::mesh::Receipt,
    until: tokio::time::Instant,
) -> Result<crate::mesh::Receipt, RpcError> {
    while !matches!(receipt.state.as_str(), "delivered" | "refused" | "expired") {
        let left = until.saturating_duration_since(tokio::time::Instant::now());
        if left.is_zero() {
            break;
        }
        let id = receipt.message_id.clone();
        let read = crate::mesh_retry::ride_out(false, until, || {
            let left = until.saturating_duration_since(tokio::time::Instant::now());
            mesh.answer(&id, left.min(Duration::from_secs(25)))
        })
        .await;
        match read {
            Ok(next) => receipt = next,
            // Out of time with the start unanswered: say it is pending, with its message id.
            Err(e) if crate::mesh_retry::transient(&e, false) => break,
            Err(e) => return Err(error(e)),
        }
    }
    Ok(receipt)
}

/// The keys of named starts through the hub that did not settle, so a `new` sent again for the
/// same caller, machine and name resends that start rather than starting another chat. A start
/// that settled (started or refused) leaves; a key is kept [`unsettled::KEPT`] at most.
mod unsettled {
    use super::*;
    use std::collections::HashMap;
    use std::sync::{Mutex, OnceLock};
    use std::time::Instant;

    /// How long a start that did not settle is resent rather than started again.
    // timeout: past it a `new` is a new start; the hub keeps the old one's receipt.
    pub(super) const KEPT: Duration = Duration::from_secs(15 * 60);
    /// At most this many unsettled starts are kept; the oldest leaves first.
    const MOST: usize = 256;

    type Book = HashMap<(String, String, String), (String, Instant)>;

    fn book() -> &'static Mutex<Book> {
        static BOOK: OnceLock<Mutex<Book>> = OnceLock::new();
        BOOK.get_or_init(Default::default)
    }

    pub(super) struct Slot((String, String, String));

    impl Slot {
        pub(super) fn new(caller: Option<&str>, host: &str, name: &str) -> Self {
            Self((caller.unwrap_or_default().to_owned(), host.to_owned(), name.to_owned()))
        }

        /// The key of this start's last unsettled send, if it is recent.
        pub(super) fn key(&self) -> Option<String> {
            let mut book = book().lock().unwrap_or_else(|e| e.into_inner());
            book.retain(|_, (_, at)| at.elapsed() < KEPT);
            book.get(&self.0).map(|(key, _)| key.clone())
        }

        /// Keep `key` when `outcome` may pass on a resend; forget it once the start settled.
        pub(super) fn note(&self, key: &str, outcome: &Result<Value, RpcError>) {
            let mut book = book().lock().unwrap_or_else(|e| e.into_inner());
            let unsettled = match outcome {
                Ok(_) => false,
                Err(e) => {
                    e.data.as_ref().and_then(|d| d.get("retryable")).and_then(Value::as_bool)
                        == Some(true)
                }
            };
            if !unsettled {
                book.remove(&self.0);
                return;
            }
            if book.len() >= MOST && !book.contains_key(&self.0) {
                if let Some(oldest) =
                    book.iter().min_by_key(|(_, (_, at))| *at).map(|(k, _)| k.clone())
                {
                    book.remove(&oldest);
                }
            }
            book.insert(self.0.clone(), (key.to_owned(), Instant::now()));
        }
    }
}

/// The answer to a `session/new` started through the hub, from its start's `receipt`.
fn started(
    receipt: crate::mesh::Receipt,
    host: &str,
    name: Option<&str>,
    key: &str,
) -> Result<Value, RpcError> {
    let detail = receipt.detail.clone().unwrap_or_default();
    match receipt.state.as_str() {
        "delivered" if !detail.is_empty() => {
            let mut v = json!({"sessionId": detail, "peer": host, "via": "hub"});
            if let (Some(name), Some(fields)) = (name, v.as_object_mut()) {
                fields.insert("_meta".into(), json!({"acpmux": {"name": name}}));
            }
            Ok(v)
        }
        "refused" | "expired" => Err(RpcError::new(
            -32000,
            format!("{host} did not start it through the mesh hub ({}): {detail}", receipt.state),
        )
        .with_data(json!({"reason": "mesh.start_refused", "peer": host, "via": "hub"}))),
        state => Err(RpcError::new(
            -32000,
            format!(
                "{host} has not said it started the session through the mesh hub ({state}); \
                 read it with `acpmux session receipt {}` (idempotency key {key})",
                receipt.message_id
            ),
        )
        .with_data(json!({"reason": "mesh.start_pending", "peer": host, "via": "hub",
            "messageId": receipt.message_id, "retryable": true}))),
    }
}

#[cfg(test)]
#[path = "mesh_control_send_tests.rs"]
mod tests;
