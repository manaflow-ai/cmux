//! Shared `cmux.protocol/2` request parsing and dispatch.
//!
//! Unix sockets and WebSockets both call this module. The operation catalog is
//! embedded as the one validation source so transport handlers cannot drift.

use cmux_json::JsonSet as _;

mod auxiliary;
mod browser_engine;
mod close_value;
mod config;
mod content;
mod credential;
mod effects;
mod mouse;
mod open_url;
mod owner;
mod revision_conflict;
mod session;
mod topology;

pub(crate) use open_url::CAPABILITY as OPEN_URL_CAPABILITY;
pub(crate) use open_url::is_web_url;
pub(crate) use open_url::right_pane_beside_focused_dock;
pub(crate) use owner::requires_connection_context;
use owner::{OperationOwner, operation_owner};
pub(crate) use revision_conflict::is_revision_conflict;
use revision_conflict::revision_conflict_values;

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

use base64::Engine;
use serde_json::{Map, Value, json};

use crate::resource::{
    NotificationPublicId, RequestEnvelope, RequestId, ResourceError, ResourceOperation,
    ResponseEnvelope, Selector, TerminalPublicId, WireDecimal, WorkspacePublicId,
};
use crate::resource_api::{
    ResourceMachineRequest, operation_failed, public_session_snapshot, public_terminal_snapshot,
    terminal_tab_ids_in_canonical_order,
};
use crate::workspace_registry::{ResourceEffectOutcome, ResourceEffectPreparation};
use crate::{Mux, ResolvedResourcePath, ResourceSelectors, ResourceTarget};
use mouse::{validate_browser_mouse, validate_terminal_mouse};

mod catalog_validation;
use catalog_validation::*;
pub(crate) use catalog_validation::{validate_operation_error, validate_operation_outcome};

const CATALOG_JSON: &str = include_str!("../../../spec/resource-operations-v2.json");

/// Resolve a live terminal path or an unscoped durable terminal receipt.
/// Nested selectors keep normal topology containment, so a detached receipt
/// cannot satisfy a stale workspace, screen, pane, or tab path.
pub(crate) fn resolve_terminal_wait_exit_id(
    mux: &Mux,
    selectors: &ResourceSelectors,
) -> Result<TerminalPublicId, ResourceError> {
    match mux.resolve_resource_path(ResourceTarget::Terminal, selectors) {
        Ok(path) => path.terminal.ok_or_else(|| ResourceError::not_found("terminal", "<resolved>")),
        Err(error) => {
            if selectors.workspace.is_some()
                || selectors.screen.is_some()
                || selectors.pane.is_some()
                || selectors.tab.is_some()
            {
                return Err(error);
            }
            let Some(raw) = selectors.terminal.as_deref() else {
                return Err(error);
            };
            let Ok(terminal_id) = TerminalPublicId::parse(raw) else {
                return Err(error);
            };
            let session_selectors = ResourceSelectors {
                machine: selectors.machine.clone(),
                session: selectors.session.clone(),
                ..ResourceSelectors::default()
            };
            mux.resolve_resource_path(ResourceTarget::Session, &session_selectors)?;
            match mux.has_durable_terminal_receipt(&terminal_id) {
                Ok(true) => {}
                Ok(false) => return Err(error),
                Err(registry_error) => return Err(resource_operation_error(registry_error)),
            }
            Ok(terminal_id)
        }
    }
}

#[derive(Debug)]
pub(crate) struct ParsedResourceRequest {
    pub envelope: RequestEnvelope,
    pub selectors: ResourceSelectors,
    pub fields: Map<String, Value>,
    /// Who sends it, set by the daemon (never from the envelope).
    pub actor: crate::workspace_registry::Actor,
}

/// The one parse of a connection line (decisions: the origin gate). `None`
/// when the line is not a `cmux.protocol/2` message (it has no `protocol`
/// member); else the typed envelope, or why it is malformed. The origin gate
/// checks this value and [`validate_resource_envelope`] then turns the same
/// value into the dispatched request, so no check reads the line a second
/// time and none can read it differently.
pub(crate) fn parse_resource_line(message: &str) -> Option<Result<RequestEnvelope, ResourceError>> {
    match parse_resource_envelope(message) {
        Ok(envelope) => Some(Ok(envelope)),
        // A typed envelope always has `protocol`; only a line that is not
        // one needs the member probe to choose between v2 and legacy.
        Err(error) => is_resource_protocol_message(message).then_some(Err(error)),
    }
}

fn is_resource_protocol_message(message: &str) -> bool {
    serde_json::from_str::<Value>(message)
        .ok()
        .and_then(|value| value.as_object().cloned())
        .is_some_and(|object| object.contains_key("protocol"))
}

#[cfg(test)]
pub(crate) fn handle_resource_message(
    mux: &Arc<Mux>,
    message: &str,
) -> Result<Value, ResourceError> {
    let request = parse_resource_request(message)?;
    handle_parsed_resource_request(mux, request)
}

pub(crate) fn handle_parsed_resource_request(
    mux: &Arc<Mux>,
    request: ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let id = request.envelope.id.clone();
    let operation = request.envelope.operation;
    let result = validate_operation_outcome(operation, dispatch_resource_request(mux, request));
    serde_json::to_value(match result {
        Ok(result) => ResponseEnvelope::success(id, result),
        Err(error) => ResponseEnvelope::failure(id, error),
    })
    .map_err(|error| {
        ResourceError::operation_failed(
            "response.encode",
            "could not encode protocol response",
            json!({"error":error.to_string()}),
        )
    })
}

pub(crate) fn commit_session_shutdown(
    mux: &Arc<Mux>,
    request: ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    debug_assert_eq!(request.envelope.operation, ResourceOperation::SessionShutdown);
    session::commit_shutdown(mux, request)
}

pub(crate) fn handle_trusted_local_auxiliary(
    mux: &Arc<Mux>,
    request: ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    auxiliary::dispatch_trusted_local(mux, request)
}

pub(crate) fn malformed_resource_response(message: &str, error: ResourceError) -> Value {
    let request = serde_json::from_str::<Value>(message).ok();
    let raw_id = request.as_ref().and_then(|value| value.get("id"));
    let id = raw_id
        .and_then(Value::as_str)
        .and_then(|id| RequestId::parse(id).ok())
        .unwrap_or_else(|| RequestId::parse("invalid").expect("static request id"));
    // A v1-style numeric id (a line client that numbers its requests): the
    // refusal names the id, and the response carries it as sent, so the
    // client gets its answer instead of waiting for it (cx-rhf2).
    let numeric_id = raw_id.filter(|id| id.is_i64() || id.is_u64()).cloned();
    let error = if numeric_id.is_some() {
        ResourceError::validation_invalid(
            Some("id"),
            "request id must be a string of 1 to 128 UTF-8 bytes",
        )
    } else {
        error
    };
    let error = request
        .as_ref()
        .and_then(|value| value.get("operation").cloned())
        .and_then(|operation| serde_json::from_value(operation).ok())
        .map_or(error.clone(), |operation| validate_operation_error(operation, error));
    let mut response = serde_json::to_value(ResponseEnvelope::failure(id, error))
        .expect("resource failure envelopes are serializable");
    if let Some(numeric_id) = numeric_id {
        response.set("id", numeric_id);
    }
    response
}

impl ParsedResourceRequest {
    /// The durable mutation of this catalog-validated request, caused by its actor.
    pub(crate) fn mutation(&self) -> anyhow::Result<crate::WorkspaceMutation> {
        let key = self.envelope.idempotency_key.clone();
        let key = key.expect("catalog-validated mutations have an idempotency key");
        crate::WorkspaceMutation::new(key, "resource-api", self.actor.clone())
    }
}

/// One request of `actor`, parsed and validated.
pub(crate) fn parse_resource_request_as(
    message: &str,
    actor: crate::workspace_registry::Actor,
) -> Result<ParsedResourceRequest, ResourceError> {
    validate_resource_envelope(parse_resource_envelope(message)?, actor)
}

/// Tests: a request of the local user.
#[cfg(test)]
pub(crate) fn parse_resource_request(
    message: &str,
) -> Result<ParsedResourceRequest, ResourceError> {
    parse_resource_request_as(message, crate::workspace_registry::Actor::local_user())
}

/// The typed envelope of `message` (size limit, then one serde parse that
/// refuses unknown and duplicate members). Nothing is validated beyond the
/// types.
fn parse_resource_envelope(message: &str) -> Result<RequestEnvelope, ResourceError> {
    if message.len() > crate::resource::MAX_MESSAGE_BYTES {
        return Err(validation_error(
            "request exceeds the protocol message limit",
            json!({"bytes":message.len(),"maximum":crate::resource::MAX_MESSAGE_BYTES}),
        ));
    }
    serde_json::from_str::<RequestEnvelope>(message).map_err(|error| {
        validation_error("invalid request envelope", json!({"error":error.to_string()}))
    })
}

/// Envelope rules and the operation's catalog params, on an envelope that
/// is already parsed (it is moved into the request, never parsed again).
pub(crate) fn validate_resource_envelope(
    envelope: RequestEnvelope,
    actor: crate::workspace_registry::Actor,
) -> Result<ParsedResourceRequest, ResourceError> {
    envelope.validate()?;
    let (selectors, fields) = validate_catalog_params(envelope.operation, &envelope.params)?;
    Ok(ParsedResourceRequest { envelope, selectors, fields, actor })
}

fn dispatch_resource_request(
    mux: &Arc<Mux>,
    mut request: ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let operation = request.envelope.operation;
    crate::debug_spans::mark("router.dispatch");
    browser_engine::route_to_frontend(mux, &mut request)?;
    browser_engine::refuse_without_provider(mux, &request)?;
    crate::debug_spans::mark("router.provider_checked");
    match operation_owner(operation) {
        OperationOwner::Session => session::dispatch(mux, request),
        OperationOwner::Content => content::dispatch(mux, request),
        OperationOwner::Topology => topology::dispatch(mux, request),
        OperationOwner::Auxiliary => auxiliary::dispatch(mux, request),
        OperationOwner::State => crate::state::router::dispatch(mux, request),
        OperationOwner::Git => crate::git_ops::dispatch(mux, request),
        OperationOwner::History => crate::history_ops::dispatch(mux, request),
        OperationOwner::BrowserProfile => crate::browser_profile_ops::dispatch(mux, request),
        OperationOwner::Credential => credential::dispatch(mux, request),
        OperationOwner::Config => config::dispatch(mux, request),
        OperationOwner::OpenUrl => open_url::dispatch(mux, request),
        OperationOwner::Stash => crate::state::stash_router::dispatch(mux, request),
        OperationOwner::Machine => {
            mux.resource_machine_service().dispatch(&ResourceMachineRequest {
                operation,
                selectors: request.selectors,
                fields: request.fields,
                idempotency_key: request.envelope.idempotency_key,
                actor: request.actor,
            })
        }
        OperationOwner::Snapshot => match operation {
            ResourceOperation::SessionSnapshot => {
                ensure_session_route(mux, &request.selectors)?;
                public_session_snapshot(mux)
            }
            ResourceOperation::SessionPing => {
                ensure_session_route(mux, &request.selectors)?;
                // The cursor alone: a ping reads the topology frame, not the
                // whole session snapshot.
                let cursor = crate::resource_api::public_session_cursor(mux)?;
                Ok(json!({"alive":true,"cursor":cursor}))
            }
            ResourceOperation::TerminalList => list_resources(mux, &request.selectors, "terminals"),
            // A conversation tab's content is not a browser (`conversation-tabs-v1`).
            ResourceOperation::BrowserList => list_resources(mux, &request.selectors, "browsers")
                .map(|mut browsers| {
                    mux.retain_browser_pages(&mut browsers);
                    browsers
                }),
            ResourceOperation::TerminalGet => get_terminal(mux, &request.selectors),
            ResourceOperation::BrowserGet => {
                let browser =
                    get_resource(mux, &request.selectors, ResourceTarget::Browser, "browsers")?;
                mux.refuse_conversation_content(&browser)?;
                Ok(browser)
            }
            ResourceOperation::NotificationList => {
                ensure_session_route(mux, &request.selectors)?;
                let limit =
                    request.fields.get("limit").and_then(Value::as_u64).unwrap_or(100) as usize;
                let snapshot = public_session_snapshot(mux)?;
                Ok(Value::Array(
                    snapshot["notifications"]
                        .as_array()
                        .expect("public snapshot notifications are an array")
                        .iter()
                        .take(limit)
                        .cloned()
                        .collect(),
                ))
            }
            ResourceOperation::NotificationCreate => create_notification(mux, request),
            ResourceOperation::NotificationAck => ack_notifications(mux, request),
            ResourceOperation::NotificationClear => clear_notifications(mux, request),
            _ => unreachable!("operation_owner classifies snapshot operations exhaustively"),
        },
        OperationOwner::Connection => Err(ResourceError::operation_failed(
            operation_name(operation),
            "the operation requires a live control-connection context",
            json!({"required_context":"control_connection"}),
        )),
    }
}

fn ensure_session_route(
    mux: &Mux,
    selectors: &ResourceSelectors,
) -> Result<ResolvedResourcePath, ResourceError> {
    mux.resolve_resource_path(ResourceTarget::Session, selectors)
}

fn list_resources(
    mux: &Mux,
    selectors: &ResourceSelectors,
    collection: &str,
) -> Result<Value, ResourceError> {
    let path = resolve_list_scope(mux, selectors)?;
    let snapshot = public_session_snapshot(mux)?;
    let values = snapshot[collection]
        .as_array()
        .ok_or_else(|| {
            ResourceError::operation_failed(
                "session.snapshot",
                "public snapshot collection is malformed",
                json!({"collection":collection}),
            )
        })?
        .iter()
        .filter(|value| resource_is_in_path(&snapshot, collection, value, &path))
        .cloned()
        .collect();
    Ok(Value::Array(values))
}

fn resolve_list_scope(
    mux: &Mux,
    selectors: &ResourceSelectors,
) -> Result<ResolvedResourcePath, ResourceError> {
    let target = if selectors.tab.is_some() {
        ResourceTarget::Tab
    } else if selectors.pane.is_some() {
        ResourceTarget::Pane
    } else if selectors.screen.is_some() {
        ResourceTarget::Screen
    } else if selectors.workspace.is_some() {
        ResourceTarget::Workspace
    } else {
        ResourceTarget::Session
    };
    mux.resolve_resource_path(target, selectors)
}

fn resource_is_in_path(
    snapshot: &Value,
    collection: &str,
    value: &Value,
    path: &ResolvedResourcePath,
) -> bool {
    let workspaces = snapshot["screens"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|screen| Some((screen["id"].as_str()?, screen["workspace_id"].as_str()?)))
        .collect::<HashMap<_, _>>();
    let screens = snapshot["panes"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|pane| Some((pane["id"].as_str()?, pane["screen_id"].as_str()?)))
        .collect::<HashMap<_, _>>();
    let panes = snapshot["tabs"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|tab| Some((tab["id"].as_str()?, tab["pane_id"].as_str()?)))
        .collect::<HashMap<_, _>>();
    let id = value["id"].as_str();
    let (workspace, screen, pane, tab) = match collection {
        "workspaces" => (id, None, None, None),
        "screens" => (value["workspace_id"].as_str(), id, None, None),
        "panes" => {
            let screen = value["screen_id"].as_str();
            (screen.and_then(|id| workspaces.get(id).copied()), screen, id, None)
        }
        "tabs" => {
            let pane = value["pane_id"].as_str();
            let screen = pane.and_then(|id| screens.get(id).copied());
            (screen.and_then(|id| workspaces.get(id).copied()), screen, pane, id)
        }
        "terminals" | "browsers" => {
            let tab = value["tab_id"].as_str();
            let pane = tab.and_then(|id| panes.get(id).copied());
            let screen = pane.and_then(|id| screens.get(id).copied());
            (screen.and_then(|id| workspaces.get(id).copied()), screen, pane, tab)
        }
        _ => return false,
    };
    path.workspace.as_ref().is_none_or(|id| workspace == Some(id.as_str()))
        && path.screen.as_ref().is_none_or(|id| screen == Some(id.as_str()))
        && path.pane.as_ref().is_none_or(|id| pane == Some(id.as_str()))
        && path.tab.as_ref().is_none_or(|id| tab == Some(id.as_str()))
        && match collection {
            "terminals" => path.terminal.as_ref().is_none_or(|target| id == Some(target.as_str())),
            "browsers" => path.browser.as_ref().is_none_or(|target| id == Some(target.as_str())),
            _ => true,
        }
}

/// `terminal.get`: the value `session.snapshot` lists for the terminal, read
/// from its own rows (its host, its durable record, the tabs that show it,
/// its live surface). Never the whole session snapshot: the bundled screen
/// detector reads one terminal per output burst, and a snapshot of every
/// workspace, screen and tab (each decorated from SQLite) per read held the
/// projection lock that every command of the session waits on, so a large
/// session's commands slowed with its size (a classic migration of 512
/// workspaces went O(n²)).
fn get_terminal(mux: &Mux, selectors: &ResourceSelectors) -> Result<Value, ResourceError> {
    let path = mux.resolve_resource_path(ResourceTarget::Terminal, selectors)?;
    let terminal_id =
        path.terminal.ok_or_else(|| ResourceError::not_found("terminals", "<resolved>"))?;
    // The snapshot publishes every terminal's pending directory before it
    // reads; this one's is enough. Outside the projection lock, as there:
    // publishing takes the state lock itself.
    if let Some(surface) = mux.with_state(|state| state.terminal_catalog.get(&terminal_id).cloned())
    {
        surface.publish_pending_directory();
    }
    mux.with_resource_projection(|registry, state| {
        let Some(host_id) = registry.live_terminal_host_id(&terminal_id)? else {
            return Ok(None);
        };
        // A resource row whose durable host is gone or tombstoned is not
        // listed by the snapshot either.
        let Some(durable) = registry.live_terminal_record(&host_id)? else {
            return Ok(None);
        };
        let surface = state.terminal_catalog.get(&terminal_id);
        if let Some(surface) = surface {
            let runtime_host = mux.resource_terminal_host_identity(surface).ok_or_else(|| {
                anyhow::anyhow!("terminal {terminal_id} runtime omitted its durable identity")
            })?;
            anyhow::ensure!(
                runtime_host.terminal_id == host_id,
                "terminal {terminal_id} runtime references a mismatched durable host"
            );
        }
        let tabs = registry.resource_tabs_of_content(terminal_id.as_str())?;
        for tab in &tabs {
            if let Some(tab_host_id) = &tab.terminal_id {
                anyhow::ensure!(
                    *tab_host_id == host_id,
                    "terminal {terminal_id} references a mismatched durable host"
                );
            }
        }
        let tab_ids = terminal_tab_ids_in_canonical_order(
            tabs.into_iter()
                .map(|tab| (terminal_id.clone(), tab.pane_id, tab.position, tab.public_id)),
        )
        .remove(&terminal_id)
        .unwrap_or_default();
        public_terminal_snapshot(&terminal_id, &durable, surface.map(Arc::as_ref), tab_ids)
            .map(Some)
    })
    .map_err(operation_failed)?
    .ok_or_else(|| ResourceError::not_found("terminal", terminal_id.as_str()))
}

fn get_resource(
    mux: &Mux,
    selectors: &ResourceSelectors,
    target: ResourceTarget,
    collection: &str,
) -> Result<Value, ResourceError> {
    let path = mux.resolve_resource_path(target, selectors)?;
    let public_id = match target {
        ResourceTarget::Workspace => path.workspace.as_ref().map(ToString::to_string),
        ResourceTarget::Screen => path.screen.as_ref().map(ToString::to_string),
        ResourceTarget::Pane => path.pane.as_ref().map(ToString::to_string),
        ResourceTarget::Tab => path.tab.as_ref().map(ToString::to_string),
        ResourceTarget::Terminal => path.terminal.as_ref().map(ToString::to_string),
        ResourceTarget::Browser => path.browser.as_ref().map(ToString::to_string),
        ResourceTarget::Machine | ResourceTarget::Session => None,
    }
    .ok_or_else(|| ResourceError::not_found(collection, "<resolved>"))?;
    public_session_snapshot(mux)?[collection]
        .as_array()
        .and_then(|values| values.iter().find(|value| value["id"] == public_id))
        .cloned()
        .ok_or_else(|| ResourceError::not_found(collection.trim_end_matches('s'), &public_id))
}

fn create_notification(mux: &Mux, request: ParsedResourceRequest) -> Result<Value, ResourceError> {
    let operation = "notification.create";
    let idempotency_key = request
        .envelope
        .idempotency_key
        .as_deref()
        .expect("validated mutations have an idempotency key");
    let fingerprint = json!({
        "operation": operation,
        "selectors": request.selectors,
        "fields": request.fields,
    });
    if let Some(preparation) = mux
        .lookup_resource_effect(idempotency_key, operation, &fingerprint)
        .map_err(resource_operation_error)?
    {
        return finish_notification_effect(
            mux,
            &request.actor,
            idempotency_key,
            &fingerprint,
            preparation,
        );
    }

    ensure_session_route(mux, &request.selectors)?;
    let terminal_id = request
        .fields
        .get("terminal_id")
        .map(|value| {
            TerminalPublicId::parse(
                value.as_str().expect("catalog resource-id validation").to_string(),
            )
        })
        .transpose()?;
    if let Some(terminal_id) = &terminal_id
        && mux.resource_surface_for_terminal(terminal_id).is_none()
    {
        return Err(ResourceError::not_found("terminal", terminal_id.as_str()));
    }
    let workspace_id = notification_workspace(mux, &request.fields)?;
    if terminal_id.is_some() && workspace_id.is_some() {
        return Err(validation_error(
            "give terminal_id or workspace_id, not both: a terminal's notification already belongs to its workspace",
            json!({}),
        ));
    }
    let notification_id = NotificationPublicId::random()?;
    let created_at_ms: u64 = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|error| {
            ResourceError::operation_failed(
                "notification.create",
                "system clock is before the Unix epoch",
                json!({"error":error.to_string()}),
            )
        })?
        .as_millis()
        .try_into()
        .map_err(|_| {
            ResourceError::operation_failed(
                "notification.create",
                "notification timestamp exceeds uint64",
                json!({}),
            )
        })?;
    let intent = json!({
        "notification_id": notification_id,
        "title": required_string(&request.fields, "title")?,
        "subtitle": request.fields.get("subtitle").and_then(Value::as_str),
        "body": required_string(&request.fields, "body")?,
        "level": required_string(&request.fields, "level")?,
        "terminal_id": terminal_id,
        "workspace_id": workspace_id,
        "created_at_ms": created_at_ms,
        "source": crate::NotificationSource::Cli.as_str(),
        "desktop": request.fields.get("desktop").and_then(Value::as_bool).unwrap_or(true),
        "reply": request.fields.get("reply").and_then(Value::as_bool).unwrap_or(false),
    });
    let preparation = mux
        .prepare_resource_effect(
            &request.mutation().map_err(resource_operation_error)?,
            operation,
            &fingerprint,
            &intent,
            None,
            expected_revision(&request.fields)?,
        )
        .map_err(resource_operation_error)?;
    finish_notification_effect(mux, &request.actor, idempotency_key, &fingerprint, preparation)
}

fn finish_notification_effect(
    mux: &Mux,
    actor: &crate::Actor,
    idempotency_key: &str,
    fingerprint: &Value,
    preparation: ResourceEffectPreparation,
) -> Result<Value, ResourceError> {
    match preparation {
        ResourceEffectPreparation::Committed { outcome, revision } => match outcome {
            ResourceEffectOutcome::Success(value) => mutation_result(mux, value, revision, true),
            ResourceEffectOutcome::Failure(error) => Err(error),
        },
        ResourceEffectPreparation::Indeterminate => {
            Err(indeterminate_error(idempotency_key, "notification.create"))
        }
        ResourceEffectPreparation::Execute { .. } => {
            let intent = mux
                .mark_resource_effect_executing(idempotency_key, "notification.create", fingerprint)
                .map_err(resource_operation_error)?;
            execute_notification_effect(mux, actor, idempotency_key, fingerprint, &intent)
        }
    }
}

fn execute_notification_effect(
    mux: &Mux,
    actor: &crate::Actor,
    idempotency_key: &str,
    fingerprint: &Value,
    intent: &Value,
) -> Result<Value, ResourceError> {
    let notification_id: NotificationPublicId =
        serde_json::from_value(intent["notification_id"].clone()).map_err(|error| {
            ResourceError::operation_failed(
                "notification.create",
                "stored notification intent has an invalid identity",
                json!({"error":error.to_string()}),
            )
        })?;
    let terminal_id = intent
        .get("terminal_id")
        .filter(|value| !value.is_null())
        .map(|value| serde_json::from_value::<TerminalPublicId>(value.clone()))
        .transpose()
        .map_err(|error| {
            ResourceError::operation_failed(
                "notification.create",
                "stored notification intent has an invalid terminal identity",
                json!({"error":error.to_string()}),
            )
        })?;
    let surface =
        terminal_id.as_ref().and_then(|terminal_id| mux.resource_surface_for_terminal(terminal_id));
    let workspace_id = intent
        .get("workspace_id")
        .filter(|value| !value.is_null())
        .map(|value| serde_json::from_value::<WorkspacePublicId>(value.clone()))
        .transpose()
        .map_err(|error| {
            ResourceError::operation_failed(
                "notification.create",
                "stored notification intent has an invalid workspace identity",
                json!({"error":error.to_string()}),
            )
        })?;
    let missing = match (&terminal_id, &workspace_id) {
        (Some(terminal_id), _) if surface.is_none() => {
            Some(ResourceError::not_found("terminal", terminal_id.as_str()))
        }
        (_, Some(workspace_id)) if !workspace_exists(mux, workspace_id) => {
            Some(ResourceError::not_found("workspace", workspace_id.as_str()))
        }
        _ => None,
    };
    if let Some(error) = missing {
        let outcome = ResourceEffectOutcome::Failure(error.clone());
        if mux
            .commit_resource_effect(
                idempotency_key,
                "notification.create",
                fingerprint,
                &outcome,
                None,
            )
            .is_err()
        {
            let _ = mux.mark_resource_effect_indeterminate(idempotency_key);
            return Err(indeterminate_error(idempotency_key, "notification.create"));
        }
        return Err(error);
    }
    let level = match required_string(
        intent
            .as_object()
            .ok_or_else(|| validation_error("stored effect intent is not an object", json!({})))?,
        "level",
    )? {
        "info" => crate::NotificationLevel::Info,
        "warning" => crate::NotificationLevel::Warning,
        "error" => crate::NotificationLevel::Error,
        other => {
            return Err(ResourceError::operation_failed(
                "notification.create",
                "stored notification intent has an invalid level",
                json!({"level":other}),
            ));
        }
    };
    let title = intent.get("title").and_then(Value::as_str).ok_or_else(|| {
        ResourceError::operation_failed(
            "notification.create",
            "stored notification intent has an invalid title",
            json!({}),
        )
    })?;
    let body = intent.get("body").and_then(Value::as_str).ok_or_else(|| {
        ResourceError::operation_failed(
            "notification.create",
            "stored notification intent has an invalid body",
            json!({}),
        )
    })?;
    let created_at_ms = intent.get("created_at_ms").and_then(Value::as_u64).ok_or_else(|| {
        ResourceError::operation_failed(
            "notification.create",
            "stored notification intent has an invalid timestamp",
            json!({}),
        )
    })?;
    let session_id = mux.local_resource_context().map_err(resource_operation_error)?.session_id;
    let subtitle = intent.get("subtitle").and_then(Value::as_str).map(str::to_string);
    let source = intent
        .get("source")
        .and_then(Value::as_str)
        .and_then(crate::NotificationSource::parse)
        .unwrap_or(crate::NotificationSource::Cli);
    // Intents written before the field existed post a banner.
    let desktop = intent.get("desktop").and_then(Value::as_bool).unwrap_or(true);
    let reply = intent.get("reply").and_then(Value::as_bool).unwrap_or(false);
    let numeric_id = mux.post_resource_notification(
        notification_id.clone(),
        title.to_string(),
        subtitle.clone(),
        body.to_string(),
        level,
        surface,
        terminal_id.clone(),
        workspace_id.clone(),
        created_at_ms,
        source,
        desktop,
        reply,
    );
    let notification = crate::ResourceNotification {
        id: notification_id.clone(),
        title: title.to_string(),
        subtitle,
        body: body.to_string(),
        level,
        terminal_id,
        workspace_id,
        created_at_ms,
        source,
        surface,
        desktop,
        reply,
    };
    let value = mux.created_notification_value(&notification, &session_id);
    let outcome = ResourceEffectOutcome::Success(value.clone());
    let deltas = json!([{
        "kind":"upsert",
        "sequence":0,
        "resource":"notification",
        "id":notification_id,
        "value":value,
    }]);
    let revision = match mux.commit_notification_effect(
        actor,
        idempotency_key,
        fingerprint,
        &outcome,
        &deltas,
        &notification,
        numeric_id,
    ) {
        Ok(revision) => revision,
        Err(_) => {
            let _ = mux.mark_resource_effect_indeterminate(idempotency_key);
            return Err(indeterminate_error(idempotency_key, "notification.create"));
        }
    };
    mux.prune_evicted_notification_reads();
    mutation_result(mux, value, revision, false)
}

fn ack_notifications(mux: &Mux, request: ParsedResourceRequest) -> Result<Value, ResourceError> {
    ensure_session_route(mux, &request.selectors)?;
    let client_id = required_string(&request.fields, "client_id")?.to_string();
    crate::mux::validate_client_id(&client_id)
        .map_err(|error| validation_error(&error.to_string(), json!({"client_id":client_id})))?;
    let notifications = request
        .fields
        .get("notifications")
        .and_then(Value::as_array)
        .ok_or_else(|| validation_error("notifications must be an array", json!({})))?
        .iter()
        .map(|value| {
            NotificationPublicId::parse(
                value
                    .as_str()
                    .ok_or_else(|| validation_error("notification id must be a string", json!({})))?
                    .to_string(),
            )
        })
        .collect::<Result<Vec<_>, ResourceError>>()?;
    let mutation = request.mutation().map_err(resource_operation_error)?;
    let ack = mux
        .ack_notifications(
            &mutation,
            expected_revision(&request.fields)?,
            &client_id,
            &notifications,
        )
        .map_err(resource_operation_error)?;
    mutation_result(mux, ack.result, ack.revision, ack.replayed)
}

fn clear_notifications(mux: &Mux, request: ParsedResourceRequest) -> Result<Value, ResourceError> {
    ensure_session_route(mux, &request.selectors)?;
    let terminal_id = request
        .fields
        .get("terminal_id")
        .map(|value| {
            TerminalPublicId::parse(
                value.as_str().expect("catalog resource-id validation").to_string(),
            )
        })
        .transpose()?;
    let workspace_id = notification_workspace(mux, &request.fields)?;
    let scope = match (&terminal_id, &workspace_id) {
        (Some(_), Some(_)) => {
            return Err(validation_error("give terminal_id or workspace_id, not both", json!({})));
        }
        (Some(terminal), None) => crate::mux::NotificationClearScope::Terminal(terminal),
        (None, Some(workspace)) => crate::mux::NotificationClearScope::Workspace(workspace),
        (None, None) => crate::mux::NotificationClearScope::Session,
    };
    let mutation = request.mutation().map_err(resource_operation_error)?;
    let commit = mux
        .clear_notifications_in(&mutation, expected_revision(&request.fields)?, scope)
        .map_err(|error| {
            // Revision conflicts keep their typed error; anything else is an
            // internal failure whose raw cause stays in the daemon log.
            let mapped = resource_operation_error(error);
            if mapped.code == "revision.conflict" {
                return mapped;
            }
            mux.report_internal_diagnostic(format!(
                "notification.clear failed: {}",
                mapped.message
            ));
            ResourceError::operation_failed(
                "notification.clear",
                "the machine could not clear notifications; retry after the next state refresh",
                json!({}),
            )
        })?;
    mutation_result(mux, commit.result, commit.revision, commit.replayed)
}

/// The `workspace_id` field of a notification create or clear: a workspace of
/// this session, else `selector.not_found`.
fn notification_workspace(
    mux: &Mux,
    fields: &Map<String, Value>,
) -> Result<Option<WorkspacePublicId>, ResourceError> {
    let Some(value) = fields.get("workspace_id") else { return Ok(None) };
    let workspace = WorkspacePublicId::parse(
        value
            .as_str()
            .ok_or_else(|| validation_error("workspace_id must be a string", json!({})))?
            .to_string(),
    )?;
    if !workspace_exists(mux, &workspace) {
        return Err(ResourceError::not_found("workspace", workspace.as_str()));
    }
    Ok(Some(workspace))
}

fn workspace_exists(mux: &Mux, workspace: &WorkspacePublicId) -> bool {
    mux.with_state(|state| {
        state.workspaces.iter().any(|candidate| candidate.public_id == *workspace)
    })
}

fn indeterminate_error(idempotency_key: &str, operation: &str) -> ResourceError {
    ResourceError::new(
        "mutation.indeterminate",
        "the external effect may have run before its outcome was recorded",
        json!({
            "idempotency_key":idempotency_key,
            "operation":operation,
            "recovery":"inspect_state_then_retry_with_new_key",
        }),
        false,
    )
}

pub(super) fn mutation_result(
    mux: &Mux,
    value: Value,
    revision: u64,
    replayed: bool,
) -> Result<Value, ResourceError> {
    let (_, generation) = mux.registry_identity();
    Ok(json!({
        "value": value,
        "generation": generation,
        "revision": revision.to_string(),
        "replayed": replayed,
    }))
}

pub(super) fn find_snapshot(
    snapshot: &Value,
    collection: &str,
    id: &str,
) -> Result<Value, ResourceError> {
    snapshot[collection]
        .as_array()
        .and_then(|values| values.iter().find(|value| value["id"] == id))
        .cloned()
        .ok_or_else(|| ResourceError::not_found(collection.trim_end_matches('s'), id))
}

pub(super) fn expected_revision(fields: &Map<String, Value>) -> Result<Option<u64>, ResourceError> {
    fields
        .get("expected_revision")
        .map(|value| {
            serde_json::from_value::<WireDecimal>(value.clone()).map(WireDecimal::get).map_err(
                |error| {
                    validation_error(
                        "expected_revision must be an unsigned decimal string",
                        json!({"error":error.to_string()}),
                    )
                },
            )
        })
        .transpose()
}

pub(super) fn required_string<'a>(
    fields: &'a Map<String, Value>,
    field: &str,
) -> Result<&'a str, ResourceError> {
    fields
        .get(field)
        .and_then(Value::as_str)
        .ok_or_else(|| validation_error("required string field is missing", json!({"field":field})))
}

pub(super) fn optional_string(
    fields: &Map<String, Value>,
    field: &str,
) -> Result<Option<String>, ResourceError> {
    fields
        .get(field)
        .map(|value| {
            value
                .as_str()
                .map(str::to_string)
                .ok_or_else(|| validation_error("field must be a string", json!({"field":field})))
        })
        .transpose()
}

pub(super) fn required_u64(fields: &Map<String, Value>, field: &str) -> Result<u64, ResourceError> {
    fields.get(field).and_then(Value::as_u64).ok_or_else(|| {
        validation_error("required unsigned integer field is missing", json!({"field":field}))
    })
}

pub(super) fn resource_operation_error(error: anyhow::Error) -> ResourceError {
    if let Some(resource) = error.downcast_ref::<ResourceError>() {
        return resource.clone();
    }
    if let Some(home) = crate::state::home_store::resource_error(&error) {
        return home;
    }
    if let Some(failure) = error.downcast_ref::<crate::terminal_host_protocol::HostLaunchFailure>()
    {
        return ResourceError::operation_failed(
            "terminal.launch",
            failure.message.clone(),
            json!({"reason_code":failure.kind.reason_code()}),
        );
    }
    let message = error.to_string();
    if message.starts_with("idempotency.conflict:") {
        let fields = message.split_whitespace().collect::<Vec<_>>();
        if let (Some(key), Some(operation)) = (fields.get(2), fields.get(4)) {
            return ResourceError::idempotency_conflict(key, operation);
        }
    }
    if let Some((expected, actual)) = revision_conflict_values(&message) {
        return ResourceError::revision_conflict(expected, actual);
    }
    ResourceError::operation_failed("resource.runtime", message, json!({}))
}

pub(super) fn operation_name(operation: ResourceOperation) -> String {
    operation.wire_name().to_owned()
}

pub(super) fn validation_error(message: &str, details: Value) -> ResourceError {
    let field = details
        .get("field")
        .or_else(|| details.get("path"))
        .or_else(|| details.get("parameter"))
        .and_then(Value::as_str);
    ResourceError::validation_invalid(field, message)
}

#[cfg(test)]
mod browser_engine_tests;
#[cfg(test)]
mod closed_content_tests;
#[cfg(test)]
mod create_argv_tests;
#[cfg(test)]
mod frontend_browser_effect_tests;
#[cfg(test)]
mod partial_create_tests;
#[cfg(test)]
mod split_focus_tests;
#[cfg(test)]
mod terminal_get_tests;
#[cfg(test)]
mod tests;
