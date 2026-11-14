//! Session-scoped resources that are neither workspace topology nor content.

use std::sync::Arc;

use base64::Engine;
use serde_json::{Value, json};

use super::effects::{self, EffectPreparation, PreparedEffect};
use super::{
    ParsedResourceRequest, expected_revision, mutation_result, operation_name, required_string,
    required_u64, resource_operation_error, validation_error,
};
use crate::resource::{
    FrontendProjectionPublicId, PairingRequestPublicId, ResourceError, ResourceOperation, Selector,
    SessionPublicId, SidebarViewPublicId, TerminalPublicId, WireDecimal,
};
use crate::sidebar_resource::{resolve_sidebar_view, sidebar_snapshot, sidebar_view_id};
use crate::{AgentSource, AgentState, Mux, ResourceSelectors, ResourceTarget, WorkspaceMutation};

pub(super) fn handles(operation: ResourceOperation) -> bool {
    matches!(
        operation,
        ResourceOperation::AgentList
            | ResourceOperation::AgentReport
            | ResourceOperation::FrontendProjectionGet
            | ResourceOperation::FrontendProjectionPut
            | ResourceOperation::SidebarViewGet
            | ResourceOperation::SidebarViewEnsure
            | ResourceOperation::SidebarViewInput
            | ResourceOperation::SidebarViewResize
            | ResourceOperation::SidebarViewReload
    )
}

pub(super) fn dispatch(
    mux: &Arc<Mux>,
    request: ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    debug_assert!(handles(request.envelope.operation));
    match request.envelope.operation {
        ResourceOperation::AgentList => list_agents(mux, &request),
        ResourceOperation::AgentReport => report_agent(mux, request),
        ResourceOperation::FrontendProjectionGet => get_frontend_projection(mux, &request),
        ResourceOperation::FrontendProjectionPut => put_frontend_projection(mux, request),
        ResourceOperation::SidebarViewGet => get_sidebar_view(mux, &request),
        ResourceOperation::SidebarViewEnsure => ensure_sidebar_view(mux, request),
        ResourceOperation::SidebarViewInput => input_sidebar_view(mux, request),
        ResourceOperation::SidebarViewResize => resize_sidebar_view(mux, request),
        ResourceOperation::SidebarViewReload => reload_sidebar_view(mux, request),
        operation => Err(ResourceError::operation_failed(
            operation_name(operation),
            "auxiliary router received an operation it does not own",
            json!({}),
        )),
    }
}

pub(super) fn dispatch_trusted_local(
    mux: &Arc<Mux>,
    request: ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    match request.envelope.operation {
        ResourceOperation::PairingRequestList => list_pairing_requests(mux, &request),
        ResourceOperation::PairingRequestResolve => resolve_pairing_request(mux, request),
        operation => Err(ResourceError::operation_failed(
            operation_name(operation),
            "trusted-local auxiliary router received an operation it does not own",
            json!({}),
        )),
    }
}

fn list_agents(mux: &Arc<Mux>, request: &ParsedResourceRequest) -> Result<Value, ResourceError> {
    let session_id = resolve_session(mux, &request.selectors)?;
    let terminal = match request.fields.get("terminal").and_then(Value::as_str) {
        Some(raw) => Some(resolve_terminal_selector(mux, &request.selectors, raw)?),
        None => request.fields.get("terminal_id").map(parse_terminal_id).transpose()?,
    };
    let state = request.fields.get("state").map(parse_agent_state).transpose()?;
    let state_filter = state.map(AgentState::as_str);
    // The kept replies are memory only, read before the projection lock.
    let replies = mux.agent_list_replies(terminal.as_ref());
    let last_sessions = mux.agent_last_sessions();
    // Public agents are durable terminal projections. They remain listable
    // after process exit detaches the runtime and every tab view, until the
    // terminal closes: its tombstone deletes the projection.
    let values = mux
        .with_resource_projection(|registry, _state| {
            Ok(registry
                .public_agent_projections(terminal.as_ref(), state_filter)?
                .into_iter()
                .map(|agent| agent.into_public_snapshot(&session_id))
                .map(|agent| crate::mux::with_agent_list_replies(agent, &replies))
                .map(|agent| crate::mux::with_kept_session(agent, &last_sessions))
                .collect::<Vec<_>>())
        })
        .map_err(resource_operation_error)?;
    Ok(Value::Array(values))
}

fn report_agent(mux: &Arc<Mux>, request: ParsedResourceRequest) -> Result<Value, ResourceError> {
    let terminal_id = request
        .fields
        .get("terminal_id")
        .map(parse_terminal_id)
        .transpose()?
        .expect("catalog requires terminal_id");
    let state =
        parse_agent_state(request.fields.get("state").expect("catalog requires agent state"))?;
    let source = parse_agent_source(required_string(&request.fields, "source")?)?;
    let source_session =
        request.fields.get("source_session").and_then(Value::as_str).map(str::to_string);
    let mutation = mutation(&request)?;
    let commit = mux
        .resource_report_agent_selected(
            request.selectors,
            &terminal_id,
            state,
            source,
            source_session,
            expected_revision(&request.fields)?,
            &mutation,
        )
        .map_err(resource_operation_error)?;
    mutation_result(mux, commit.result, commit.revision, commit.replayed)
}

fn parse_agent_state(value: &Value) -> Result<AgentState, ResourceError> {
    match value.as_str() {
        Some("working") => Ok(AgentState::Working),
        Some("blocked") => Ok(AgentState::Blocked),
        Some("idle") => Ok(AgentState::Idle),
        Some("done") => Ok(AgentState::Done),
        Some("unknown") => Ok(AgentState::Unknown),
        _ => Err(validation_error("invalid agent state", json!({"state":value}))),
    }
}

fn parse_agent_source(value: &str) -> Result<AgentSource, ResourceError> {
    match value {
        "hook" => Ok(AgentSource::Hook),
        "socket" => Ok(AgentSource::Socket),
        _ => Err(validation_error("invalid agent report source", json!({"source":value}))),
    }
}

fn get_frontend_projection(
    mux: &Arc<Mux>,
    request: &ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let session_id = resolve_session(mux, &request.selectors)?;
    let projection_id = resolve_projection_id(&request.selectors)?;
    let projection = mux
        .get_frontend_projection("resource-api", "session", projection_id.as_str())
        .map_err(resource_operation_error)?
        .ok_or_else(|| ResourceError::not_found("frontend_projection", projection_id.as_str()))?;
    crate::resource_api::public_frontend_projection_snapshot(
        &session_id,
        &projection_id,
        &projection,
    )
}

fn put_frontend_projection(
    mux: &Arc<Mux>,
    request: ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let projection_id = resolve_projection_id(&request.selectors)?;
    let mutation = mutation(&request)?;
    let projection = request.fields.get("projection").expect("catalog requires projection");
    let stored_projection = json!({
        "frontend_id":request.fields["frontend_id"],
        "window_id":request.fields["window_id"],
        "generation":request.fields["generation"],
        "projection":projection,
    });
    let expected_projection_revision =
        request.fields.get("expected_projection_revision").map(|value| {
            serde_json::from_value::<WireDecimal>(value.clone())
                .expect("catalog validates projection revisions")
                .get()
        });
    let commit = mux
        .resource_put_frontend_projection_selected(
            request.selectors,
            &projection_id,
            &stored_projection,
            expected_projection_revision,
            &mutation,
        )
        .map_err(resource_operation_error)?;
    mutation_result(mux, commit.result, commit.revision, commit.replayed)
}

fn resolve_projection_id(
    selectors: &ResourceSelectors,
) -> Result<FrontendProjectionPublicId, ResourceError> {
    let raw = selectors.frontend_projection.as_deref().ok_or_else(|| {
        ResourceError::selector_invalid(
            "frontend_projection",
            "",
            "missing required frontend_projection selector",
        )
    })?;
    match Selector::parse(raw)? {
        Selector::Id(id) => FrontendProjectionPublicId::parse(id),
        Selector::Current | Selector::Name(_) => Err(ResourceError::selector_invalid(
            "frontend_projection",
            raw,
            "frontend projections require an opaque id selector",
        )),
    }
}

fn list_pairing_requests(
    mux: &Arc<Mux>,
    request: &ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let session_id = resolve_session(mux, &request.selectors)?;
    let mut values = mux
        .pending_pairings()
        .into_iter()
        .map(|challenge| pairing_snapshot(&session_id, &challenge, "pending"))
        .collect::<Result<Vec<_>, _>>()?;
    values.sort_by(|left, right| {
        left["id"].as_str().unwrap_or_default().cmp(right["id"].as_str().unwrap_or_default())
    });
    Ok(Value::Array(values))
}

fn resolve_pairing_request(
    mux: &Arc<Mux>,
    request: ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let pairing_id = resolve_pairing_id(&request.selectors)?;
    let decision = required_string(&request.fields, "decision")?;
    // Approval admits a browser: only the verified app (cx-ehrq). The origin
    // gate refuses earlier; this keeps any other caller from bypassing it.
    if decision == "accept" && !matches!(request.actor, crate::Actor::Frontend { .. }) {
        return Err(crate::request_origin::needs_user(crate::request_origin::RequestOrigin::Agent));
    }
    let mutation = mutation(&request)?;
    let commit = mux
        .resource_resolve_pairing_selected(
            request.selectors,
            &pairing_id,
            decision,
            expected_revision(&request.fields)?,
            &mutation,
        )
        .map_err(resource_operation_error)?;
    mutation_result(mux, commit.result, commit.revision, commit.replayed)
}

fn resolve_pairing_id(
    selectors: &ResourceSelectors,
) -> Result<PairingRequestPublicId, ResourceError> {
    let raw = selectors.pairing_request.as_deref().ok_or_else(|| {
        ResourceError::selector_invalid(
            "pairing_request",
            "",
            "missing required pairing_request selector",
        )
    })?;
    match Selector::parse(raw)? {
        Selector::Id(id) => PairingRequestPublicId::parse(id),
        Selector::Current | Selector::Name(_) => Err(ResourceError::selector_invalid(
            "pairing_request",
            raw,
            "pairing requests require an opaque id selector",
        )),
    }
}

fn pairing_snapshot(
    session_id: &SessionPublicId,
    challenge: &crate::PairingChallenge,
    status: &str,
) -> Result<Value, ResourceError> {
    let id = PairingRequestPublicId::parse(format!("pairing_{:032x}", challenge.id))?;
    Ok(json!({
        "id":id,
        "session_id":session_id,
        "peer":challenge.peer,
        "code":challenge.code,
        "expires_in_seconds":challenge.expires_in.to_string(),
        "status":status,
    }))
}

#[cfg(test)]
fn pairing_numeric_id(id: &PairingRequestPublicId) -> Result<u64, ResourceError> {
    let payload =
        id.as_str().strip_prefix("pairing_").expect("typed pairing ids have their prefix");
    let value = u128::from_str_radix(payload, 16).map_err(|error| {
        validation_error(
            "pairing request id payload is invalid",
            json!({"id":id,"error":error.to_string()}),
        )
    })?;
    u64::try_from(value).map_err(|_| ResourceError::not_found("pairing_request", id.as_str()))
}

fn get_sidebar_view(
    mux: &Arc<Mux>,
    request: &ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let (sidebar_id, session_id) = resolve_sidebar_view(mux, &request.selectors)?;
    current_sidebar_snapshot(mux, &sidebar_id, &session_id)
}

fn ensure_sidebar_view(
    mux: &Arc<Mux>,
    request: ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    match effects::prepare(mux, &request, || {
        let session_id = resolve_session(mux, &request.selectors)?;
        let sidebar_id = sidebar_view_id(&session_id)?;
        let (_, _, configured) = mux.sidebar_plugin_resource_status();
        if !configured {
            return Err(ResourceError::operation_failed(
                "sidebar_view.ensure",
                "no sidebar plugin is configured",
                json!({}),
            ));
        }
        Ok(json!({
            "sidebar_id":sidebar_id,
            "session_id":session_id,
            "cols":required_u64(&request.fields, "cols")?,
            "rows":required_u64(&request.fields, "rows")?,
            "relaunch":request
                .fields
                .get("relaunch")
                .and_then(Value::as_bool)
                .unwrap_or(false),
        }))
    })? {
        EffectPreparation::Complete(result) => result,
        EffectPreparation::Execute(prepared) => execute_sidebar_ensure(mux, prepared),
    }
}

fn execute_sidebar_ensure(
    mux: &Arc<Mux>,
    prepared: PreparedEffect,
) -> Result<Value, ResourceError> {
    let sidebar_id: SidebarViewPublicId =
        decode_intent("sidebar_view.ensure", &prepared.intent, "sidebar_id", "sidebar view")?;
    let session_id: SessionPublicId =
        decode_intent("sidebar_view.ensure", &prepared.intent, "session_id", "sidebar session")?;
    let cols = intent_u16("sidebar_view.ensure", &prepared.intent, "cols")?;
    let rows = intent_u16("sidebar_view.ensure", &prepared.intent, "rows")?;
    let relaunch = prepared.intent["relaunch"].as_bool().ok_or_else(|| {
        stored_intent_error(
            "sidebar_view.ensure",
            "sidebar ensure intent has an invalid relaunch flag",
        )
    })?;
    let status = mux.ensure_sidebar_plugin(cols, rows, relaunch);
    if status.surface.is_none() {
        let message = status.error.unwrap_or_else(|| "no sidebar plugin is configured".to_string());
        return effects::commit_known_failure(
            mux,
            prepared,
            ResourceError::operation_failed("sidebar_view.ensure", message, json!({})),
        );
    }
    let value = current_sidebar_snapshot(mux, &sidebar_id, &session_id)?;
    effects::commit_success(mux, prepared, value.clone(), sidebar_upsert_delta(&sidebar_id, &value))
}

fn input_sidebar_view(
    mux: &Arc<Mux>,
    request: ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    match effects::prepare(mux, &request, || {
        let (sidebar_id, session_id) = resolve_sidebar_view(mux, &request.selectors)?;
        let (_, _, configured) = mux.sidebar_plugin_resource_status();
        if !configured || mux.sidebar_plugin_surface().is_none() {
            return Err(ResourceError::not_found("sidebar_view", sidebar_id.as_str()));
        }
        Ok(json!({
            "sidebar_id":sidebar_id,
            "session_id":session_id,
            "data_base64":required_string(&request.fields, "data_base64")?,
        }))
    })? {
        EffectPreparation::Complete(result) => result,
        EffectPreparation::Execute(prepared) => execute_sidebar_input(mux, prepared),
    }
}

fn execute_sidebar_input(mux: &Arc<Mux>, prepared: PreparedEffect) -> Result<Value, ResourceError> {
    let sidebar_id: SidebarViewPublicId =
        decode_intent("sidebar_view.input", &prepared.intent, "sidebar_id", "sidebar view")?;
    let session_id: SessionPublicId =
        decode_intent("sidebar_view.input", &prepared.intent, "session_id", "sidebar session")?;
    let data = prepared.intent["data_base64"].as_str().ok_or_else(|| {
        stored_intent_error("sidebar_view.input", "sidebar input intent has invalid base64")
    })?;
    let data = base64::engine::general_purpose::STANDARD.decode(data).map_err(|error| {
        stored_intent_error(
            "sidebar_view.input",
            &format!("sidebar input intent has invalid base64: {error}"),
        )
    })?;
    let Some(surface) = mux.sidebar_plugin_surface().filter(|surface| !surface.is_dead()) else {
        return effects::commit_known_failure(
            mux,
            prepared,
            ResourceError::not_found("sidebar_view", sidebar_id.as_str()),
        );
    };
    let before = match current_sidebar_snapshot(mux, &sidebar_id, &session_id) {
        Ok(snapshot) => snapshot,
        Err(error) => return effects::commit_known_failure(mux, prepared, error),
    };
    if let Err(error) = surface.write_bytes(&data) {
        let cause = format!("sidebar input write failed: {:?}", error.kind());
        return Err(effects::mark_indeterminate(mux, prepared, &cause));
    }
    let value = json!({});
    let after = match current_sidebar_snapshot(mux, &sidebar_id, &session_id) {
        Ok(snapshot) => snapshot,
        Err(error) => {
            let cause = format!("the sidebar snapshot after input failed: {}", error.code);
            return Err(effects::mark_indeterminate(mux, prepared, &cause));
        }
    };
    match sidebar_input_lifecycle_delta(&sidebar_id, &before, &after) {
        Some(changes) => effects::commit_success(mux, prepared, value, changes),
        None => effects::commit_success_without_changes(mux, prepared, value),
    }
}

fn resize_sidebar_view(
    mux: &Arc<Mux>,
    request: ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    // The core method performs replay lookup before it resolves any selector.
    // Deriving the singleton ID from durable context does not select a view.
    let context = mux.local_resource_context().map_err(resource_operation_error)?;
    let sidebar_id = sidebar_view_id(&context.session_id)?;
    let mutation = mutation(&request)?;
    let cols = u16::try_from(required_u64(&request.fields, "cols")?)
        .map_err(|_| validation_error("sidebar cols exceed uint16", json!({"field":"cols"})))?;
    let rows = u16::try_from(required_u64(&request.fields, "rows")?)
        .map_err(|_| validation_error("sidebar rows exceed uint16", json!({"field":"rows"})))?;
    let commit = mux
        .resource_resize_sidebar_selected(
            request.selectors,
            &sidebar_id,
            cols,
            rows,
            expected_revision(&request.fields)?,
            &mutation,
        )
        .map_err(resource_operation_error)?;
    mutation_result(mux, commit.result, commit.revision, commit.replayed)
}

fn reload_sidebar_view(
    mux: &Arc<Mux>,
    request: ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    match effects::prepare(mux, &request, || {
        let (sidebar_id, session_id) = resolve_sidebar_view(mux, &request.selectors)?;
        let (_, last_size, configured) = mux.sidebar_plugin_resource_status();
        if !configured {
            return Err(ResourceError::not_found("sidebar_view", sidebar_id.as_str()));
        }
        let (cols, rows) = last_size.ok_or_else(|| {
            ResourceError::operation_failed(
                "sidebar_view.reload",
                "sidebar view has not been sized yet",
                json!({}),
            )
        })?;
        Ok(json!({
            "sidebar_id":sidebar_id,
            "session_id":session_id,
            "cols":cols,
            "rows":rows,
        }))
    })? {
        EffectPreparation::Complete(result) => result,
        EffectPreparation::Execute(prepared) => execute_sidebar_reload(mux, prepared),
    }
}

fn execute_sidebar_reload(
    mux: &Arc<Mux>,
    prepared: PreparedEffect,
) -> Result<Value, ResourceError> {
    let sidebar_id: SidebarViewPublicId =
        decode_intent("sidebar_view.reload", &prepared.intent, "sidebar_id", "sidebar view")?;
    let session_id: SessionPublicId =
        decode_intent("sidebar_view.reload", &prepared.intent, "session_id", "sidebar session")?;
    let cols = intent_u16("sidebar_view.reload", &prepared.intent, "cols")?;
    let rows = intent_u16("sidebar_view.reload", &prepared.intent, "rows")?;
    let status = mux.reload_sidebar_plugin(cols, rows);
    if status.surface.is_none() {
        let message = status.error.unwrap_or_else(|| "sidebar plugin did not restart".to_string());
        return effects::commit_known_failure(
            mux,
            prepared,
            ResourceError::operation_failed("sidebar_view.reload", message, json!({})),
        );
    }
    let value = current_sidebar_snapshot(mux, &sidebar_id, &session_id)?;
    effects::commit_success(mux, prepared, value.clone(), sidebar_upsert_delta(&sidebar_id, &value))
}

fn current_sidebar_snapshot(
    mux: &Mux,
    sidebar_id: &SidebarViewPublicId,
    session_id: &SessionPublicId,
) -> Result<Value, ResourceError> {
    let (status, last_size, configured) = mux.sidebar_plugin_resource_status();
    if !configured && last_size.is_none() {
        return Err(ResourceError::not_found("sidebar_view", sidebar_id.as_str()));
    }
    let surface = status.surface.and_then(|surface| mux.surface(surface));
    Ok(sidebar_snapshot(sidebar_id, session_id, last_size.unwrap_or((1, 1)), surface.as_ref()))
}

fn sidebar_upsert_delta(id: &SidebarViewPublicId, value: &Value) -> Value {
    json!([{
        "kind":"upsert",
        "sequence":0,
        "resource":"sidebar_view",
        "id":id,
        "value":value,
    }])
}

fn sidebar_input_lifecycle_delta(
    id: &SidebarViewPublicId,
    before: &Value,
    after: &Value,
) -> Option<Value> {
    (before != after).then(|| sidebar_upsert_delta(id, after))
}

fn intent_u16(operation: &str, intent: &Value, field: &str) -> Result<u16, ResourceError> {
    let value = intent[field].as_u64().ok_or_else(|| {
        stored_intent_error(operation, &format!("sidebar intent omitted {field}"))
    })?;
    u16::try_from(value).map_err(|_| {
        stored_intent_error(operation, &format!("sidebar intent {field} exceeds uint16"))
    })
}

fn resolve_session(
    mux: &Mux,
    selectors: &ResourceSelectors,
) -> Result<SessionPublicId, ResourceError> {
    let mut session_selectors = selectors.clone();
    session_selectors.client = None;
    session_selectors.split = None;
    session_selectors.stream = None;
    session_selectors.notification = None;
    session_selectors.agent = None;
    session_selectors.frontend_projection = None;
    session_selectors.pairing_request = None;
    session_selectors.sidebar_view = None;
    mux.resolve_resource_path(ResourceTarget::Session, &session_selectors)?
        .session
        .ok_or_else(|| ResourceError::not_found("session", "<resolved>"))
}

/// The terminal a `terminal` selector field names (W5-P): every form a
/// terminal selector takes (a full id, a unique prefix, a bare or host id, a
/// tab or pane id, a name, `current`), resolved by the one resolver. A name
/// or `current` gets `current` parents, as the CLI sends a terminal target,
/// so a name the focused tab lacks is looked up in the whole session.
fn resolve_terminal_selector(
    mux: &Mux,
    routing: &ResourceSelectors,
    raw: &str,
) -> Result<TerminalPublicId, ResourceError> {
    let implicit =
        (!matches!(Selector::parse(raw)?, Selector::Id(_))).then(|| "current".to_owned());
    let selectors = ResourceSelectors {
        machine: routing.machine.clone(),
        session: routing.session.clone(),
        workspace: implicit.clone(),
        screen: implicit.clone(),
        pane: implicit.clone(),
        tab: implicit,
        terminal: Some(raw.to_owned()),
        ..Default::default()
    };
    mux.resolve_resource_path(ResourceTarget::Terminal, &selectors)?
        .terminal
        .ok_or_else(|| ResourceError::not_found("terminal", raw))
}

fn parse_terminal_id(value: &Value) -> Result<TerminalPublicId, ResourceError> {
    TerminalPublicId::parse(
        value
            .as_str()
            .ok_or_else(|| validation_error("terminal id must be a string", json!({})))?
            .to_string(),
    )
}

fn mutation(request: &ParsedResourceRequest) -> Result<WorkspaceMutation, ResourceError> {
    request.mutation().map_err(resource_operation_error)
}

fn decode_intent<T: serde::de::DeserializeOwned>(
    operation: &str,
    intent: &Value,
    field: &str,
    description: &str,
) -> Result<T, ResourceError> {
    serde_json::from_value(intent[field].clone()).map_err(|error| {
        stored_intent_error(operation, &format!("stored {description} intent is invalid: {error}"))
    })
}

fn stored_intent_error(operation: &str, message: &str) -> ResourceError {
    ResourceError::operation_failed(operation, message, json!({}))
}

#[cfg(test)]
mod tests;
