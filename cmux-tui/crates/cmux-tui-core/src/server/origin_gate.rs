//! The v2 request origin on a connection (plans/cmux-next/request-origin.md):
//! every `cmux.protocol/2` line passes `check` before the resource handler
//! parses it, and `origin.confirmation.issue` is answered here. The rules
//! themselves live in `crate::request_origin`.

use super::*;
use crate::request_origin::{
    CONFIRMATION_TTL_MS, HelloRole, OriginClaim, RequestOrigin, forbidden, mint_token, needs_user,
    valid_sha256_hex,
};

/// Applies the origin rules to one `cmux.protocol/2` line, then hands it to
/// the resource connection handler. A refused line is never parsed further
/// or dispatched.
pub(super) fn handle_resource_line(
    mux: &Arc<Mux>,
    client: u64,
    message: &str,
    writer: &MessageWriter,
) -> bool {
    match check(mux, client, message) {
        None => handle_resource_connection_message(mux, client, message, writer),
        Some(refusal) => writer.send_control(&refusal).is_ok(),
    }
}

/// `None` admits the line; `Some(response)` refuses it. A line whose
/// envelope is not readable here is admitted: the resource parser then
/// refuses it, so it can never be dispatched without passing these rules.
fn check(mux: &Mux, client: u64, message: &str) -> Option<Value> {
    // Fast path: a connection that is not a page relay, with no claim and
    // no A2 operation, needs no parse. Each test is a superset of the
    // condition it stands for.
    if role(mux, client) != HelloRole::PageRelay
        && !message.contains("\"origin")
        && !message.contains("\"apps.")
    {
        return None;
    }
    let Ok(Value::Object(envelope)) = serde_json::from_str::<Value>(message) else {
        return None;
    };
    let id = envelope.get("id").and_then(Value::as_str)?;
    let id = ResourceRequestId::parse(id).ok()?;
    let operation = envelope.get("operation").and_then(Value::as_str)?;
    let params = envelope.get("params").unwrap_or(&Value::Null);
    let claim = match envelope
        .get("origin")
        .map(|raw| serde_json::from_value::<OriginClaim>(raw.clone()))
    {
        None => None,
        Some(Ok(claim)) => Some(claim),
        Some(Err(error)) => {
            let error = ResourceError::validation_invalid(
                Some("origin"),
                format!("origin must be {{claim, confirmation?}}: {error}"),
            );
            return Some(refusal(id, operation, error));
        }
    };
    let now_ms = mux.control_clients.origin_clock.monotonic_ms();
    let mut state =
        mux.control_clients.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    let record = state.clients.get_mut(&client)?;
    match record.origin.request_origin(operation, params, claim.as_ref(), now_ms) {
        Ok(_) => None,
        Err(error) => Some(refusal(id, operation, error)),
    }
}

fn refusal(id: ResourceRequestId, operation: &str, error: ResourceError) -> Value {
    // A catalog operation's refusal goes through its error contract; an
    // operation this daemon does not have (apps.* before R62) is answered
    // as is.
    let error = match serde_json::from_value::<ResourceOperation>(json!(operation)) {
        Ok(operation) => crate::resource_router::validate_operation_error(operation, error),
        Err(_) => error,
    };
    serde_json::to_value(ResourceResponseEnvelope::failure(id, error)).unwrap_or(Value::Null)
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

fn role(mux: &Mux, client: u64) -> HelloRole {
    let state = mux.control_clients.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    state.clients.get(&client).map_or(HelloRole::Legacy, |record| record.origin.role)
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
pub(super) fn set_install_proved(mux: &Mux, client: u64) -> bool {
    let mut state =
        mux.control_clients.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    let Some(record) = state.clients.get_mut(&client) else { return false };
    if record.origin.role != HelloRole::Main {
        return false;
    }
    record.origin.verified_app = true;
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
    let operation = string_field(request, "operation").to_string();
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
        match role(mux, client) {
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
