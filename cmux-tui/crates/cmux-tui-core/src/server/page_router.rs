//! v2 namespace routing (`page-router-v1`, cmux-tui/spec/page-router.md):
//! a `cmux.protocol/2` request whose operation a routed namespace of
//! spec/page-router.json names (`apps.catalog.list`, ...) goes to that
//! namespace's owner, so a page reaches it with the same v2 envelope on
//! every host (the app's page relay, a browser on the WebSocket). These
//! operations are not in the operation catalog; the owner validates its
//! params.
//!
//! The origin rules are the catalog's (request_origin.rs
//! `routed_origin`): the claim may only narrow, a page connection gets its
//! page's allow list, a page relay without a page gets nothing, and a
//! mutation needs origin `user` (the verified app, or a page relay request
//! with a host confirmation for exactly it). Transport: the Unix socket and
//! authenticated WebSocket connections, as for the person's conversations.

use crate::panic_free::JsonFields;
use serde::Deserialize;
use serde_json::{Value, json};

use super::{MessageWriter, Mux};
use crate::request_origin::page_router_table::{self, Routed};
use crate::request_origin::{HelloRole, OriginClaim, RequestOrigin, forbidden};
use crate::resource::{PROTOCOL, RequestId, ResourceError, ResponseEnvelope};
use std::sync::Arc;

/// A routed request's envelope: the catalog envelope's members (no launch
/// credential: a routed owner never acts as a terminal). Like the catalog
/// parse it refuses unknown and duplicate members, so a line that is not
/// exactly one routed request gets the catalog parse's answer.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Envelope {
    protocol: String,
    #[serde(rename = "type")]
    envelope_type: String,
    id: Value,
    operation: String,
    params: Value,
    #[serde(default)]
    idempotency_key: Option<Value>,
    #[serde(default)]
    origin: Option<Value>,
}

/// `Some(keep_open)` when `message`, a v2 line the catalog parse refused,
/// is a request of a routed operation (answered here), else `None`.
pub(super) fn try_handle(
    mux: &Arc<Mux>,
    client: u64,
    message: &str,
    writer: &MessageWriter,
) -> Option<bool> {
    if message.len() > crate::resource::MAX_MESSAGE_BYTES {
        return None;
    }
    let envelope: Envelope = serde_json::from_str(message).ok()?;
    let route = page_router_table::routed(&envelope.operation)?;
    let id = envelope.id.as_str().and_then(|id| RequestId::parse(id).ok());
    let Some(id) = id else {
        let error = ResourceError::validation_invalid(
            Some("id"),
            "request id must be a string of 1 to 128 UTF-8 bytes",
        );
        let response = crate::resource_router::malformed_resource_response(message, error);
        return Some(writer.send_control(&response).is_ok());
    };
    let response = match run(mux, client, envelope, route) {
        Ok(result) => ResponseEnvelope::success(id, result),
        Err(error) => ResponseEnvelope::failure(id, error),
    };
    let response = serde_json::to_value(response).unwrap_or_else(|_| json!({}));
    Some(writer.send_control(&response).is_ok())
}

fn run(
    mux: &Arc<Mux>,
    client: u64,
    envelope: Envelope,
    route: Routed,
) -> Result<Value, ResourceError> {
    let operation = envelope.operation.as_str();
    if envelope.protocol != PROTOCOL {
        return Err(ResourceError::validation_invalid(Some("protocol"), "unsupported protocol"));
    }
    if envelope.envelope_type != "request" {
        return Err(ResourceError::validation_invalid(Some("type"), "type must be request"));
    }
    let Value::Object(mut params) = envelope.params else {
        return Err(ResourceError::validation_invalid(Some("params"), "params must be an object"));
    };
    let claim = match envelope.origin {
        None => None,
        Some(origin) => Some(serde_json::from_value::<OriginClaim>(origin).map_err(|_| {
            ResourceError::validation_invalid(
                Some("origin"),
                "origin must be {claim, confirmation?}",
            )
        })?),
    };
    let key = match envelope.idempotency_key {
        None => None,
        Some(Value::String(key)) if (1..=128).contains(&key.len()) => Some(key),
        Some(_) => {
            return Err(ResourceError::validation_invalid(
                Some("idempotency_key"),
                "idempotency_key must be a string of 1 to 128 bytes",
            ));
        }
    };
    // The origin gate before any validation, as for catalog operations.
    let origin = {
        let now_ms = mux.control_clients.origin_clock.monotonic_ms();
        let mut state =
            mux.control_clients.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let Some(record) = state.clients.get_mut(&client) else {
            return Err(forbidden(
                "the connection is not registered",
                json!({"derived": RequestOrigin::Agent.wire_name(), "reason": "connection_not_registered"}),
            ));
        };
        let origin = record.origin.routed_origin(
            operation,
            route.mutation,
            &Value::Object(params.clone()),
            claim.as_ref(),
            now_ms,
        )?;
        (origin, record.origin.role == HelloRole::PageRelay)
    };
    let (origin, relay) = origin;
    // Origin user on the connection itself (the verified app, not a page
    // relay's confirmed request) also needs a connection that is not bound
    // to an agent, as on the raw `apps-store` door.
    if origin == RequestOrigin::User && !relay {
        let facts = super::origin_gate::app_connection(mux, client);
        if facts.agent || !facts.verified_app {
            return Err(forbidden(
                "an agent connection cannot act with origin user",
                json!({"derived": origin.wire_name(), "reason": "agent_bound"}),
            ));
        }
    }
    if !mux.control_clients.is_owner_client(client) {
        return Err(ResourceError::operation_failed(
            operation,
            "operation requires a local or authenticated connection",
            json!({"required_authority": "trusted_local"}),
        ));
    }
    // Every page sends its host's selectors (`machine`, `session`): the
    // routed owners are this daemon's own.
    for selector in ["machine", "session"] {
        match params.remove(selector) {
            None => {}
            Some(Value::String(value)) if value == "current" || value == "local" => {}
            Some(_) => {
                return Err(ResourceError::validation_invalid(
                    Some(selector),
                    "a routed operation runs on this daemon: the selector must be current",
                ));
            }
        }
    }
    if route.mutation {
        let Some(key) = key else {
            return Err(ResourceError::validation_invalid(
                Some("idempotency_key"),
                "a routed mutation needs an idempotency_key",
            ));
        };
        params.insert("idempotency_key".to_owned(), Value::String(key));
    }
    match route.owner {
        "apps.store" => apps_store(mux, client, operation, Value::Object(params), origin),
        #[cfg(unix)]
        "agent_session.trust" => {
            super::agent_session_attach::routed_trust(mux, client, operation, params)
        }
        owner => Err(ResourceError::operation_failed(
            operation,
            "this daemon has no owner for the routed namespace",
            json!({"owner": owner}),
        )),
    }
}

/// The App Store owner (apps/store.rs `store_call`).
#[cfg(unix)]
fn apps_store(
    mux: &Arc<Mux>,
    client: u64,
    operation: &str,
    params: Value,
    origin: RequestOrigin,
) -> Result<Value, ResourceError> {
    if crate::apps::advertised().is_none() {
        return Err(ResourceError::operation_failed(
            operation,
            "this daemon has no app host",
            json!({"code": "apps.unavailable"}),
        ));
    }
    let supervisor = mux.control_clients.apps.get_or_init(mux);
    let origin = if origin == RequestOrigin::User {
        crate::apps::Origin::User
    } else {
        crate::apps::Origin::Cli
    };
    supervisor.store_call(client, operation, params, origin).map_err(|error| {
        if error.code == "bad-request" {
            return ResourceError::validation_invalid(Some("params"), error.message);
        }
        let mut extra = json!({"code": error.code});
        if let Some(details) = error.details {
            extra.insert("details", details);
        }
        ResourceError::operation_failed(operation, error.message, extra)
    })
}

#[cfg(not(unix))]
fn apps_store(
    _mux: &Arc<Mux>,
    _client: u64,
    operation: &str,
    _params: Value,
    _origin: RequestOrigin,
) -> Result<Value, ResourceError> {
    Err(ResourceError::operation_failed(
        operation,
        "this daemon has no app host",
        json!({"code": "apps.unavailable"}),
    ))
}
