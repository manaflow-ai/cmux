//! The v2 request origin on a connection (plans/cmux-next/request-origin.md):
//! every `cmux.protocol/2` line is parsed ONCE into a typed request
//! (`resource_router::parse_resource_line`); the origin rules check that
//! value and the dispatcher acts on the same value. A line that does not
//! parse is refused, and a refused line is never dispatched.
//! `origin.confirmation.issue` is answered here. The rules themselves live
//! in `crate::request_origin`.

use super::*;
use crate::Actor;
use crate::request_origin::{
    CONFIRMATION_TTL_MS, HelloRole, RequestOrigin, forbidden, mint_token, needs_user,
    valid_sha256_hex,
};
use crate::resource::RequestEnvelope;

/// Applies the origin rules to one parsed `cmux.protocol/2` line, then
/// validates and dispatches the same parse. The origin rules run before
/// the envelope and catalog validation, so a refused origin learns nothing
/// from validation.
pub(super) fn handle_resource_line(
    mux: &Arc<Mux>,
    client: u64,
    message: &str,
    envelope: Result<RequestEnvelope, ResourceError>,
    writer: &MessageWriter,
) -> bool {
    let envelope = match envelope {
        Ok(envelope) => envelope,
        Err(error) => {
            let response = crate::resource_router::malformed_resource_response(message, error);
            return writer.send_control(&response).is_ok();
        }
    };
    let (id, operation) = (envelope.id.clone(), envelope.operation);
    let admitted = check(mux, client, &envelope)
        .and_then(|actor| crate::resource_router::validate_resource_envelope(envelope, actor));
    match admitted {
        Ok(request) => handle_resource_connection_message(mux, client, request, writer),
        Err(error) => send_resource_response(writer, id, operation, Err(error)),
    }
}

/// The actor of `envelope` on `client` once its origin passes, or why it is
/// refused. A client
/// with no registry record (a connection detached while its reader still
/// held a line) has no known role, so it is refused (fail closed).
fn check(mux: &Mux, client: u64, envelope: &RequestEnvelope) -> Result<Actor, ResourceError> {
    let now_ms = mux.control_clients.origin_clock.monotonic_ms();
    let mut state =
        mux.control_clients.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    let Some(record) = state.clients.get_mut(&client) else {
        return Err(forbidden(
            "the connection is not registered",
            // No record, no role: name the least the connection could be
            // without a hello (the catalog requires `derived`).
            json!({
                "derived": RequestOrigin::Agent.wire_name(),
                "reason": "connection_not_registered",
            }),
        ));
    };
    record.origin.request_origin(
        envelope.operation,
        &envelope.params,
        envelope.origin.as_ref(),
        now_ms,
    )?;
    let (transport, local) = (record.transport, record.origin.actor());
    drop(state);
    Ok(peer_or_local(mux, client, transport, local))
}

/// The actor of a durable mutation that `client` asks for on the legacy
/// control protocol. A client with no record is never the local user.
pub(super) fn connection_actor(mux: &Mux, client: u64) -> Actor {
    let state = mux.control_clients.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    let Some(record) = state.clients.get(&client) else {
        return Actor::Peer { id: "unregistered".to_string() };
    };
    let (transport, local) = (record.transport, record.origin.actor());
    drop(state);
    peer_or_local(mux, client, transport, local)
}

/// A link peer (`peer:link:<install>`), any other WebSocket or remote-entry
/// connection (`peer:websocket`, `peer:remote`), else the local connection's
/// own actor. Read after the clients lock is released: the peers lock is
/// never taken under it.
fn peer_or_local(mux: &Mux, client: u64, transport: ClientTransport, local: Actor) -> Actor {
    match mux.remote_relay().peer_checked(client) {
        Ok(Some(peer)) => return Actor::Peer { id: format!("link:{}", peer.install) },
        // A poisoned peers lock cannot say the client is local: fail closed.
        Err(_) => return Actor::Peer { id: "remote".to_string() },
        Ok(None) => {}
    }
    match transport {
        ClientTransport::Unix => local,
        ClientTransport::WebSocket => Actor::Peer { id: "websocket".to_string() },
        ClientTransport::Remote => Actor::Peer { id: "remote".to_string() },
    }
}

#[cfg(unix)]
/// Gate A2 on the legacy `apps-*` door: `Err` unless `client` derives
/// origin `user` (a verified cmux app connection).
pub(super) fn require_user(mux: &Mux, client: u64) -> Result<(), crate::apps::ApiError> {
    let derived = {
        let state =
            mux.control_clients.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        state.clients.get(&client).map_or(RequestOrigin::Agent, |record| record.origin.derive())
    };
    if derived == RequestOrigin::User {
        return Ok(());
    }
    let refusal = needs_user(derived);
    let mut error = crate::apps::ApiError::new(&refusal.code, refusal.message);
    error.details = Some(refusal.details);
    Err(error)
}

/// Fixes `client`'s hello role (step 1), and `verified_app` when prover A
/// (the app's code signature) passed for a role-main hello. False when the
/// client is gone or already has a role; nothing changes then.
pub(super) fn set_hello(
    mux: &Mux,
    client: u64,
    role: HelloRole,
    peer_key: Option<String>,
    signature_proved: bool,
) -> bool {
    let mut state =
        mux.control_clients.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    let Some(record) = state.clients.get_mut(&client) else { return false };
    if record.origin.role != HelloRole::Legacy {
        return false;
    }
    record.origin.role = role;
    record.origin.peer_key = peer_key;
    record.origin.verified_app = role == HelloRole::Main && signature_proved;
    true
}

/// Step 2 passed (prover B): `client`, a role-main connection, is the
/// verified app. Its `peer_key` stays the audit-token key, so its page
/// relay (same process, same token) still matches it. False when the client
/// is gone or is not role main.
pub(super) fn set_install_proved(mux: &Mux, client: u64, install_id: &str) -> bool {
    let mut state =
        mux.control_clients.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    let Some(record) = state.clients.get_mut(&client) else { return false };
    if record.origin.role != HelloRole::Main {
        return false;
    }
    record.origin.verified_app = true;
    record.origin.install_id = Some(install_id.to_string());
    true
}

/// `origin.confirmation.issue {operation, params_sha256,
/// relay_connection_id}` from the verified app: a token the relay
/// connection of the same peer can present once, within the TTL, for
/// exactly that operation and params.
pub(super) fn handle_issue(
    mux: &Arc<Mux>,
    client: u64,
    request: &crate::resource_router::ParsedResourceRequest,
    id: ResourceRequestId,
    writer: &MessageWriter,
) -> bool {
    let result = issue(mux, client, request);
    send_resource_response(writer, id, ResourceOperation::OriginConfirmationIssue, result)
}

fn issue(
    mux: &Mux,
    client: u64,
    request: &crate::resource_router::ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    mux.resolve_resource_path(crate::ResourceTarget::Session, &request.selectors)?;
    let operation =
        serde_json::from_value::<ResourceOperation>(json!(string_field(request, "operation")))
            .map_err(|_| {
                ResourceError::validation_invalid(
                    Some("operation"),
                    "operation must be a cmux.protocol/2 catalog operation",
                )
            })?;
    let params_sha256 = string_field(request, "params_sha256").to_string();
    if !valid_sha256_hex(&params_sha256) {
        return Err(ResourceError::validation_invalid(
            Some("params_sha256"),
            "params_sha256 must be 64 lowercase hex digits",
        ));
    }
    let relay = string_field(request, "relay_connection_id").parse::<u64>().map_err(|_| {
        ResourceError::validation_invalid(
            Some("relay_connection_id"),
            "relay_connection_id must be a connection id from client-hello",
        )
    })?;
    let token = mint_token()?;
    // Validity uses the monotonic deadline; expires_at is for display.
    let now_ms = mux.control_clients.origin_clock.monotonic_ms();
    let deadline_ms = now_ms.saturating_add(CONFIRMATION_TTL_MS);
    let expires_at_ms =
        mux.control_clients.origin_clock.wall_ms().saturating_add(CONFIRMATION_TTL_MS);
    let mut state =
        mux.control_clients.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    let caller = state.clients.get(&client).map(|record| &record.origin);
    let Some(caller) = caller else { return Err(needs_user(RequestOrigin::Agent)) };
    let derived = caller.derive();
    if caller.role == HelloRole::PageRelay {
        return Err(forbidden(
            "a page relay connection cannot issue confirmations",
            json!({"derived": derived.wire_name()}),
        ));
    }
    if derived != RequestOrigin::User {
        return Err(needs_user(derived));
    }
    let caller_peer = caller.peer_key.clone();
    let same_peer_relay = state.clients.get_mut(&relay).filter(|record| {
        relay != client
            && record.origin.role == HelloRole::PageRelay
            && caller_peer.is_some()
            && record.origin.peer_key == caller_peer
    });
    let Some(relay_record) = same_peer_relay else {
        return Err(forbidden(
            "the relay connection is not a page relay of the same app",
            json!({"required": "user", "derived": derived.wire_name(), "reason": "relay_mismatch"}),
        ));
    };
    relay_record.origin.store_confirmation(
        token.clone(),
        operation,
        params_sha256,
        deadline_ms,
        now_ms,
    );
    Ok(json!({"token": token, "expires_at": expires_at_ms.to_string()}))
}

/// A string field the catalog already validated ("" if absent).
fn string_field<'a>(
    request: &'a crate::resource_router::ParsedResourceRequest,
    name: &str,
) -> &'a str {
    request.fields.get(name).and_then(Value::as_str).unwrap_or_default()
}

#[cfg(test)]
pub(super) use test_hooks::*;

/// Test hooks: set what client-hello and P8 would set.
#[cfg(test)]
mod test_hooks {
    use super::*;
    use crate::request_origin::ConnectionOrigin;

    fn with_origin(mux: &Arc<Mux>, client: u64, change: impl FnOnce(&mut ConnectionOrigin)) {
        let mut state = mux.control_clients.state.lock().unwrap();
        change(&mut state.clients.get_mut(&client).expect("registered client").origin);
    }

    pub(in crate::server) fn set_role_for_test(mux: &Arc<Mux>, client: u64, role: &str) {
        let role = HelloRole::declared(role).expect("main or page_relay");
        with_origin(mux, client, |origin| origin.role = role);
    }

    pub(in crate::server) fn set_verified_app_for_test(
        mux: &Arc<Mux>,
        client: u64,
        verified: bool,
    ) {
        with_origin(mux, client, |origin| origin.verified_app = verified);
    }

    pub(in crate::server) fn set_peer_key_for_test(mux: &Arc<Mux>, client: u64, peer_key: &str) {
        with_origin(mux, client, |origin| origin.peer_key = Some(peer_key.to_string()));
    }

    pub(in crate::server) fn advance_origin_clock_for_test(mux: &Arc<Mux>, ms: u64) {
        mux.control_clients.origin_clock.advance(ms);
    }

    /// Moves only the wall clock (an NTP step or a user change).
    pub(in crate::server) fn jump_origin_wall_clock_for_test(mux: &Arc<Mux>, delta_ms: i64) {
        mux.control_clients.origin_clock.jump_wall(delta_ms);
    }

    pub(in crate::server) fn role_for_test(mux: &Arc<Mux>, client: u64) -> String {
        let role = {
            let state = mux.control_clients.state.lock().unwrap();
            state.clients.get(&client).map_or(HelloRole::Legacy, |record| record.origin.role)
        };
        match role {
            HelloRole::Legacy => "legacy",
            HelloRole::Main => "main",
            HelloRole::PageRelay => "page_relay",
        }
        .to_string()
    }
}

#[cfg(all(test, unix))]
#[path = "origin_gate_tests.rs"]
mod tests;

#[cfg(all(test, unix))]
#[path = "page_access_tests.rs"]
mod page_access_tests;
