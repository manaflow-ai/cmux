//! A send for a session on another of the person's machines, carried to that machine's daemon
//! directly while the team hub is down (RFD 0086). Off unless the person turns on
//! `meshRelay.directSend` on both machines. Leo, answering TBD d-a6cc56afd2: "Yes, behind a switch,
//! only machines in your mesh book".
//!
//! ```text
//! acpmux send B/NAME  -> A's outbox, kept with its hub post (`Delivery::relay_post`)
//!   hub post fails before it leaves A (no connection, the gate shut): `relay_unreached`
//!   -> `direct_maybe` saved -> a hub carrier MachineCall stream to B (Noise, the book's daemonId)
//!   -> `mesh_send` on B (`machine_call_service.rs`) -> `run_from` -> `mesh_relay::deliver`
//! ```
//!
//! Why each rule holds:
//!
//! - The stream is a [`CircuitService::MachineCall`] one: only that service keeps the dialer's
//!   Noise-proven `daemonId` (`MachineCallGate::open(from)`); the acpmux service splices to a
//!   local socket that cannot tell who dialed. B runs a copy only when its own switch is on and
//!   its own read of the hub's book lists the dialer among the person's machines, re-read for
//!   every request. No control kind, no team address, no op: a prompt for one of the person's
//!   own sessions, as their own machine sends through the hub.
//! - The hub never holds a copy too: a copy goes direct only when every post of it so far
//!   provably never left A (`HubError::never_reached`: no connection made, or the hub's gate kept
//!   it from asking). A timeout, a dropped connection or any answer of the hub's may mean it holds
//!   one, so those wait for the hub as before, and a refusal of the hub's still fails the send.
//!   Once a copy may have gone direct (`Delivery::direct_maybe`, saved before it goes), the hub is
//!   never posted it again: a later hub drain cannot run it twice.
//! - B runs each copy once: its prompt id is `direct:<A's daemonId>:<the post's idempotency key>`,
//!   delivered as a resend, which B's prompt ledger answers from its log when it ran already
//!   (`Hub::knows_prompt`). The hub's own message id is not that key (the hub does not hand the
//!   key to the receiver), so cross-path dedup would need a platform change: hence the rule above
//!   that a copy goes direct only after the hub definitely did not take it.

// Without the hub carrier no copy goes direct (`machine` is None): the rest is kept for its tests.
#![cfg_attr(not(feature = "hub-carrier"), allow(dead_code))]

use serde_json::{Value, json};

#[cfg(test)]
use std::sync::Arc;

use crate::hub::Hub;
use crate::mesh::OutMessage;
use crate::rpc::RpcError;

/// The method B's machine call service answers for a direct copy (`machine_call_service::METHODS`).
pub const METHOD: &str = "mesh_send";

/// Refusal codes (`data.code`) B answers before it runs anything: the copy did not run there.
pub(crate) const OFF: &str = "direct.off";
pub(crate) const UNLISTED: &str = "machine.unlisted";
pub(crate) const BAD_REQUEST: &str = "direct.bad_request";
/// B's session refused it (no such session, an empty message): final, as a hub refusal is.
pub(crate) const REFUSED: &str = "direct.refused";
/// B took it but did not settle it now: it may run, so only a direct copy goes again.
pub(crate) const LATER: &str = "direct.later";

/// What one direct attempt did.
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum Direct {
    /// The far daemon took it: the acceptance the outbox keeps.
    Taken(Value),
    /// The far daemon's session refused it: the send fails with this reason.
    Refused(String),
    /// Provably not run there: no stream, the far daemon refused before it ran anything, or a
    /// build there that has no direct send.
    NotRun(String),
    /// May have run there (no answer, an answer it may still act on): tried again direct only.
    Maybe(String),
}

/// Whether the person turned on direct sends here (`meshRelay.directSend`): read for every attempt and
/// every request, so turning it off stops the next one.
pub(crate) async fn switch_on(hub: &Hub) -> bool {
    hub.config.read().await.mesh_relay.as_ref().is_some_and(|relay| relay.direct_send)
}

/// Whether `key` may name a direct copy: what a sending daemon's idempotency keys look like
/// (`mesh_send::idempotency_key`), bounded, so the prompt id it makes stays a plain token.
fn key_ok(key: &str) -> bool {
    (8..=128).contains(&key.len())
        && key.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b':' | b'-'))
}

/// The prompt id B delivers a direct copy from `from` (A's hub `daemonId`) under: one per post,
/// whatever the attempt, so a copy that comes again is the same prompt.
pub(crate) fn prompt_id(from: &str, key: &str) -> String {
    format!("direct:{from}:{key}")
}

fn refused(code: &str, message: impl Into<String>) -> RpcError {
    RpcError::invalid_params(message).with_data(json!({"code": code}))
}

/// The message B delivers for `post` from machine `from`: a resend of [`prompt_id`], for the
/// session `post` names by id or name only (the circuit already chose the machine), from the
/// machine the Noise handshake proved, never from the request's own machine or user fields.
pub(crate) fn in_message(
    from: &str,
    post: &OutMessage,
    attempt: u32,
) -> Result<crate::mesh::InMessage, RpcError> {
    post.validate().map_err(|why| refused(BAD_REQUEST, why))?;
    if post.kind != crate::mesh::Kind::Prompt {
        return Err(refused(BAD_REQUEST, "a direct send carries prompts only"));
    }
    if post.to.team_address.is_some() {
        return Err(refused(BAD_REQUEST, "a direct send is for one of the person's own sessions"));
    }
    if !key_ok(&post.idempotency_key) {
        return Err(refused(BAD_REQUEST, "a direct send needs its post's idempotency key"));
    }
    let mut to = post.to.clone();
    to.host = None;
    to.daemon_id = None;
    let mut sender = post.from.clone();
    sender.team_address = None;
    sender.host = None;
    sender.user = None;
    sender.daemon_id = Some(from.to_owned());
    Ok(crate::mesh::InMessage {
        message_id: prompt_id(from, &post.idempotency_key),
        kind: crate::mesh::Kind::Prompt,
        op: None,
        mode: post.mode,
        to,
        from: sender,
        body: post.body.clone(),
        attempt: attempt.max(1),
        start_work: None,
        state: None,
        subject: None,
    })
}

/// B's side: run the direct copy in `params` (`{"message": <post>, "attempt": n}`) from machine
/// `from`, the `daemonId` the carrier's Noise handshake proved. Refused unless the switch is on
/// here and this machine's book lists `from` as one of the person's machines.
#[cfg(feature = "hub-carrier")]
pub(crate) async fn run_from(
    hub: &std::sync::Arc<Hub>,
    from: &str,
    params: &Value,
) -> Result<Value, RpcError> {
    if !switch_on(hub).await {
        return Err(refused(OFF, "direct sends are off on that machine (meshRelay.directSend)"));
    }
    if hub.mesh_book_machine(from).is_none() {
        return Err(refused(UNLISTED, "that machine's hub book does not list the sending machine"));
    }
    let post = params
        .get("message")
        .cloned()
        .and_then(|m| serde_json::from_value::<OutMessage>(m).ok())
        .ok_or_else(|| refused(BAD_REQUEST, "a direct send carries one message"))?;
    let attempt = params.get("attempt").and_then(Value::as_u64).unwrap_or(1);
    let message = in_message(from, &post, u32::try_from(attempt).unwrap_or(u32::MAX))?;
    answer(super::mesh_relay::deliver(hub, &message, &super::mesh_relay::RefuseControl, None).await)
}

/// What B answers for a delivery's ack.
pub(crate) fn answer(ack: Option<crate::mesh::Ack>) -> Result<Value, RpcError> {
    use crate::mesh::AckState;
    match ack {
        Some(ack) if ack.state == AckState::Delivered => {
            Ok(json!({"promptId": ack.prompt_id, "detail": ack.detail}))
        }
        Some(ack) => Err(refused(REFUSED, ack.detail.unwrap_or_else(|| "refused".into()))),
        None => Err(refused(LATER, "that machine did not settle it yet; it is tried again")),
    }
}

/// How A reads B's answer to one request (`machine_call_service::ask`).
pub(crate) fn outcome(
    post: &OutMessage,
    host: &str,
    asked: Result<Value, Option<RpcError>>,
) -> Direct {
    match asked {
        Ok(result) => Direct::Taken(json!({
            "via": "direct",
            "machine": host,
            "promptId": result.get("promptId").cloned().unwrap_or(Value::Null),
            "sessionId": post.to.session_id,
            "steer": post.mode == crate::mesh::Mode::Now,
            "detail": result.get("detail").cloned().unwrap_or(Value::Null),
        })),
        Err(None) => Direct::Maybe(format!("{host} did not answer the direct send")),
        Err(Some(error)) => {
            let code = error.data.as_ref().and_then(|d| d.get("code")).and_then(Value::as_str);
            let why = format!("{host}: {}", error.message);
            match code {
                Some(REFUSED) => Direct::Refused(why),
                Some(OFF | UNLISTED | BAD_REQUEST) => Direct::NotRun(why),
                // A build there with no direct send: nothing ran.
                _ if error.code == RpcError::method_not_found(METHOD).code => Direct::NotRun(why),
                _ => Direct::Maybe(why),
            }
        }
    }
}

/// The book's machine for `post`: by the post's
/// `daemonId`, else by its host name. None when the book names none, or more than one.
#[cfg(feature = "hub-carrier")]
fn book_machine(hub: &Hub, post: &OutMessage) -> Option<(String, String)> {
    let machines = hub.mesh_book_machines();
    let by = |key: &str| {
        let key = crate::machine_call_service::machine_key(&machines, key)?;
        machines.iter().find(|(k, _)| *k == key).cloned()
    };
    post.to
        .daemon_id
        .as_deref()
        .filter(|d| !d.is_empty())
        .and_then(|d| machines.iter().find(|(k, _)| k == d).cloned())
        .or_else(|| post.to.host.as_deref().filter(|h| !h.is_empty()).and_then(by))
}

#[cfg(not(feature = "hub-carrier"))]
fn book_machine(_hub: &Hub, _post: &OutMessage) -> Option<(String, String)> {
    None
}

/// How long A waits for B's answer to one direct copy.
#[cfg(feature = "hub-carrier")]
const WAIT: std::time::Duration = std::time::Duration::from_secs(60);

/// Send `post` to machine `(key, host)` over the hub carrier, once. The stream is open (B's gate let it in)
/// before a byte of the request is written, so a dial that fails ran nothing there.
#[cfg(feature = "hub-carrier")]
async fn dial(
    hub: &Hub,
    (key, host): &(String, String),
    post: &OutMessage,
    attempt: u32,
) -> Direct {
    use crate::hub_carrier::CircuitService;
    let Some(carrier) = hub.hub_carrier.get() else {
        return Direct::NotRun("this machine's hub carrier is off".into());
    };
    let stream = match carrier.dial_service(key, CircuitService::MachineCall).await {
        Ok(stream) => stream,
        Err(e) => return Direct::NotRun(format!("{host} could not be reached directly: {e}")),
    };
    let params = json!({"message": post, "attempt": attempt});
    let asked = crate::machine_call_service::ask(stream, METHOD, params, WAIT).await;
    outcome(post, host, asked)
}

#[cfg(not(feature = "hub-carrier"))]
async fn dial(
    _hub: &Hub,
    _machine: &(String, String),
    _post: &OutMessage,
    _attempt: u32,
) -> Direct {
    Direct::NotRun("this build has no hub carrier".into())
}

/// The machine `post` is for, as `(daemonId, host)` this machine's book lists (`book_machine`).
pub(crate) fn machine(hub: &Hub, post: &OutMessage) -> Option<(String, String)> {
    #[cfg(test)]
    if let Some((machine, _)) = stubbed(hub) {
        return Some(machine);
    }
    book_machine(hub, post)
}

/// Send `post` to `machine` directly, once (`dial`).
pub(crate) async fn attempt(
    hub: &Hub,
    machine: &(String, String),
    post: &OutMessage,
    attempt: u32,
) -> Direct {
    #[cfg(test)]
    if let Some((_, far)) = stubbed(hub) {
        return far(post, attempt).await;
    }
    dial(hub, machine, post, attempt).await
}

/// A far machine a test stands in for one hub: what its daemon does with each direct copy.
#[cfg(test)]
pub(crate) type FarStub =
    Arc<dyn Fn(&OutMessage, u32) -> futures::future::BoxFuture<'static, Direct> + Send + Sync>;

#[cfg(test)]
type Stubs = Vec<(std::sync::Weak<Hub>, (String, String), FarStub)>;

#[cfg(test)]
static STUBS: std::sync::Mutex<Stubs> = std::sync::Mutex::new(Vec::new());

/// Route `hub`'s direct copies to `far`, as machine `machine`, for as long as `hub` lives.
#[cfg(test)]
pub(crate) fn stub_far(hub: &Arc<Hub>, machine: (String, String), far: FarStub) {
    let mut stubs = STUBS.lock().unwrap_or_else(|e| e.into_inner());
    stubs.retain(|(h, _, _)| h.strong_count() > 0);
    stubs.push((Arc::downgrade(hub), machine, far));
}

#[cfg(test)]
fn stubbed(hub: &Hub) -> Option<((String, String), FarStub)> {
    let stubs = STUBS.lock().unwrap_or_else(|e| e.into_inner());
    stubs
        .iter()
        .find(|(h, _, _)| h.strong_count() > 0 && std::ptr::eq(h.as_ptr(), hub))
        .map(|(_, machine, far)| (machine.clone(), far.clone()))
}

#[cfg(test)]
#[path = "mesh_direct_tests.rs"]
mod tests;
