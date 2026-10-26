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

use super::routes::{OperationRoute, RouteLine};
use super::{FrameStage, MessageWriter, Mux};
use crate::request_origin::page_router_table::{self, Routed};
use crate::request_origin::{HelloRole, OriginClaim, RequestOrigin, forbidden};
use crate::resource::{PROTOCOL, RequestId, ResourceError, ResponseEnvelope};
use cmux_threads::work::{Lane, Priority, Shutdown};
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

/// The v2 operations this module answers (server/routes.rs): every
/// operation a routed namespace of spec/page-router.json names. Each
/// page's allow list is checked in [`run`], by the origin gate.
pub(in crate::server) const OPERATION_ROUTES: &[OperationRoute] = &[OperationRoute {
    names: |operation| page_router_table::routed(operation).is_some(),
    stage: FrameStage::PageRouter,
    entry: handle,
}];

/// Answers a v2 line whose `operation` a routed namespace names (the route
/// found it by name). The line's one decode is its [`Envelope`]; `None`
/// when the line is not exactly one routed request (an unknown or repeated
/// member, an `operation` no namespace names), which the catalog parse then
/// answers.
fn handle(line: &RouteLine<'_>) -> Option<bool> {
    let RouteLine { mux, client, message, writer, .. } = *line;
    if message.len() > crate::resource::MAX_MESSAGE_BYTES {
        return None;
    }
    let envelope: Envelope = crate::line_parses::parse(message).ok()?;
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
    let operation = envelope.operation.clone();
    let job = match run(mux, client, envelope, route) {
        Ok(Answer::Now(result)) => return Some(respond(writer, id, Ok(result))),
        Ok(Answer::Later(job)) => job,
        Err(error) => return Some(respond(writer, id, Err(error))),
    };
    // The owner waits on another process: a work item asks it and answers,
    // so this request thread answers the next line at once (Chrome posts
    // such a wait to a MayBlock task runner, base/task/task_traits.h). A
    // half-done ask is harmless and its connection closes at shutdown, so
    // shutdown never waits for it.
    let (worker_writer, worker_id) = (writer.clone(), id.clone());
    let posted = mux.work.post(
        Priority::UserBlocking,
        Lane::System,
        Shutdown::ContinueOnShutdown,
        move || {
            respond(&worker_writer, worker_id, job());
        },
    );
    Some(match posted {
        Ok(()) => true,
        Err(_) => respond(
            writer,
            id,
            Err(ResourceError::operation_failed(
                &operation,
                "the daemon is shutting down",
                json!({"code": "unavailable"}),
            )),
        ),
    })
}

/// A routed owner's answer: computed on the request thread, or a work item
/// for an owner that waits on another process.
enum Answer {
    Now(Value),
    Later(Box<dyn FnOnce() -> Result<Value, ResourceError> + Send>),
}

fn respond(writer: &MessageWriter, id: RequestId, result: Result<Value, ResourceError>) -> bool {
    let response = match result {
        Ok(result) => ResponseEnvelope::success(id, result),
        Err(error) => ResponseEnvelope::failure(id, error),
    };
    let response = serde_json::to_value(response).unwrap_or_else(|_| json!({}));
    writer.send_control(&response).is_ok()
}

fn run(
    mux: &Arc<Mux>,
    client: u64,
    envelope: Envelope,
    route: Routed,
) -> Result<Answer, ResourceError> {
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
        "apps.store" => {
            apps_store(mux, client, operation, Value::Object(params), origin).map(Answer::Now)
        }
        #[cfg(unix)]
        "agent_session.trust" => {
            super::agent_session_attach::routed_trust(mux, client, operation, params)
                .map(Answer::Later)
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

#[cfg(test)]
#[path = "page_router_tests.rs"]
mod tests;
