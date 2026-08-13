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
    let terminal = request.fields.get("terminal_id").map(parse_terminal_id).transpose()?;
    let state = request.fields.get("state").map(parse_agent_state).transpose()?;
    let state_filter = state.map(AgentState::as_str);
    // Public agents are durable terminal projections. They remain listable
    // after process exit detaches the runtime and every tab view.
    let values = mux
        .with_resource_projection(|registry, _state| {
            Ok(registry
                .public_agent_projections(terminal.as_ref(), state_filter)?
                .into_iter()
                .map(|agent| agent.into_public_snapshot(&session_id))
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
    if surface.write_bytes(&data).is_err() {
        return Err(effects::mark_indeterminate(mux, prepared));
    }
    let value = json!({});
    let after = match current_sidebar_snapshot(mux, &sidebar_id, &session_id) {
        Ok(snapshot) => snapshot,
        Err(_) => return Err(effects::mark_indeterminate(mux, prepared)),
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

fn parse_terminal_id(value: &Value) -> Result<TerminalPublicId, ResourceError> {
    TerminalPublicId::parse(
        value
            .as_str()
            .ok_or_else(|| validation_error("terminal id must be a string", json!({})))?
            .to_string(),
    )
}

fn mutation(request: &ParsedResourceRequest) -> Result<WorkspaceMutation, ResourceError> {
    WorkspaceMutation::new(
        request
            .envelope
            .idempotency_key
            .clone()
            .expect("catalog-validated mutations have an idempotency key"),
        "resource-api",
    )
    .map_err(resource_operation_error)
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
mod tests {
    use super::*;
    use crate::resource::{EnvelopeType, PROTOCOL, RequestEnvelope, RequestId};
    use crate::{SidebarPluginOptions, SurfaceOptions};
    use std::time::{Duration, Instant};

    fn public_id(prefix: &str, value: u128) -> String {
        format!("{prefix}_{value:032x}")
    }

    fn request(
        operation: ResourceOperation,
        key: Option<&str>,
        selectors: ResourceSelectors,
        fields: Value,
    ) -> ParsedResourceRequest {
        ParsedResourceRequest {
            envelope: RequestEnvelope {
                protocol: PROTOCOL.to_string(),
                envelope_type: EnvelopeType::Request,
                id: RequestId::parse(format!("aux-{operation:?}")).unwrap(),
                operation,
                params: json!({}),
                idempotency_key: key.map(str::to_string),
            },
            selectors,
            fields: fields.as_object().unwrap().clone(),
        }
    }

    fn session_selectors() -> ResourceSelectors {
        ResourceSelectors {
            machine: Some("current".to_string()),
            session: Some("current".to_string()),
            ..Default::default()
        }
    }

    #[test]
    fn sidebar_input_emits_a_delta_only_when_public_lifecycle_changes() {
        let sidebar_id =
            SidebarViewPublicId::parse(public_id("sidebar_view", 1)).expect("sidebar test id");
        let before = json!({
            "id":sidebar_id,
            "session_id":public_id("session", 1),
            "cols":80,
            "rows":24,
            "running":true,
        });
        assert!(sidebar_input_lifecycle_delta(&sidebar_id, &before, &before).is_none());

        let mut after = before.clone();
        after["running"] = json!(false);
        let changes = sidebar_input_lifecycle_delta(&sidebar_id, &before, &after).unwrap();
        assert_eq!(changes[0]["kind"], "upsert");
        assert_eq!(changes[0]["resource"], "sidebar_view");
        assert_eq!(changes[0]["id"], sidebar_id.as_str());
        assert_eq!(changes[0]["value"], after);
    }

    #[test]
    fn pending_pairing_snapshots_use_public_ids_and_wire_decimals() {
        let mux = Mux::new_for_test("aux-pairing", SurfaceOptions::default());
        let (challenge, _response) = mux.begin_pairing("127.0.0.1".parse().unwrap()).unwrap();
        let session = resolve_session(
            &mux,
            &ResourceSelectors {
                machine: Some("current".to_string()),
                session: Some("current".to_string()),
                ..Default::default()
            },
        )
        .unwrap();
        let snapshot = pairing_snapshot(&session, &challenge, "pending").unwrap();
        assert!(snapshot["id"].as_str().unwrap().starts_with("pairing_"));
        assert_eq!(snapshot["expires_in_seconds"], "60");
        assert_eq!(snapshot["status"], "pending");
        assert_eq!(
            pairing_numeric_id(
                &PairingRequestPublicId::parse(snapshot["id"].as_str().unwrap().to_string())
                    .unwrap()
            )
            .unwrap(),
            challenge.id
        );
    }

    #[test]
    fn agent_report_replays_and_list_filters_by_public_terminal() {
        let mux = Mux::new_for_test("aux-agent", SurfaceOptions::default());
        let created = crate::resource_router::handle_parsed_resource_request(
            &mux,
            request(
                ResourceOperation::WorkspaceCreate,
                Some("aux-agent-create"),
                session_selectors(),
                json!({"initial_content":"terminal"}),
            ),
        )
        .unwrap();
        assert_eq!(created["ok"], true);
        let terminal_id = TerminalPublicId::parse(
            crate::resource_api::public_session_snapshot(&mux).unwrap()["terminals"][0]["id"]
                .as_str()
                .unwrap()
                .to_string(),
        )
        .unwrap();
        let report_request = |key| {
            request(
                ResourceOperation::AgentReport,
                Some(key),
                session_selectors(),
                json!({
                    "terminal_id":terminal_id,
                    "state":"working",
                    "source":"socket",
                    "source_session":"sdk-test",
                }),
            )
        };
        let first = dispatch(&mux, report_request("agent-report-once")).unwrap();
        assert_eq!(first["replayed"], false);
        assert_eq!(first["value"]["terminal_id"], terminal_id.as_str());
        assert_eq!(first["value"]["state"], "working");
        assert_eq!(first["value"]["source_session"], "sdk-test");
        let replay = dispatch(&mux, report_request("agent-report-once")).unwrap();
        assert_eq!(replay["replayed"], true);
        assert_eq!(replay["value"], first["value"]);
        let repeated = dispatch(&mux, report_request("agent-report-twice")).unwrap();
        assert_eq!(repeated["replayed"], false);
        assert_eq!(repeated["value"]["id"], first["value"]["id"]);
        assert!(
            !first["value"]["id"]
                .as_str()
                .unwrap()
                .ends_with(terminal_id.as_str().trim_start_matches("term_")),
            "agent ids must remain stable without revealing the terminal id payload"
        );

        let listed = dispatch(
            &mux,
            request(
                ResourceOperation::AgentList,
                None,
                session_selectors(),
                json!({"terminal_id":terminal_id,"state":"working"}),
            ),
        )
        .unwrap();
        assert_eq!(listed.as_array().unwrap().len(), 1);
        assert_eq!(listed[0]["id"], first["value"]["id"]);
    }

    #[test]
    fn filtered_agent_list_does_not_decode_unrelated_projections() {
        let mux = Mux::new_for_test("filtered-agent-list", SurfaceOptions::default());
        let requested = mux.new_workspace(Some("requested".into()), None).unwrap();
        let unrelated = mux.new_workspace(Some("unrelated".into()), None).unwrap();
        let requested_terminal = requested.terminal_public_id().cloned().unwrap();
        let unrelated_terminal = unrelated.terminal_public_id().cloned().unwrap();

        for (surface, session) in [(requested.id, "requested"), (unrelated.id, "unrelated")] {
            mux.report_agent(surface, AgentState::Working, AgentSource::Hook, Some(session.into()))
                .unwrap();
        }
        mux.corrupt_agent_projection_for_test(&unrelated_terminal);

        let listed = dispatch(
            &mux,
            request(
                ResourceOperation::AgentList,
                None,
                session_selectors(),
                json!({"terminal_id":requested_terminal,"state":"working"}),
            ),
        )
        .expect("the selected query must not decode an unrelated projection");
        assert_eq!(listed.as_array().unwrap().len(), 1);
        assert_eq!(listed[0]["terminal_id"], requested_terminal.as_str());
    }

    #[test]
    fn pairing_resolution_replays_without_resolving_twice() {
        let mux = Mux::new_for_test("aux-pairing-resolve", SurfaceOptions::default());
        let (challenge, response) = mux.begin_pairing("127.0.0.1".parse().unwrap()).unwrap();
        let id = format!("pairing_{:032x}", challenge.id);
        let mut selected = session_selectors();
        selected.pairing_request = Some(id);
        let resolve_request = || {
            request(
                ResourceOperation::PairingRequestResolve,
                Some("pairing-resolve-once"),
                selected.clone(),
                json!({"decision":"accept"}),
            )
        };
        let first = dispatch_trusted_local(&mux, resolve_request()).unwrap();
        assert_eq!(first["replayed"], false);
        assert_eq!(first["value"]["pairing_request"]["status"], "accepted");
        assert!(matches!(
            response.recv_timeout(Duration::from_secs(1)).unwrap(),
            crate::PairingDecision::Approved { .. }
        ));
        let replay = dispatch_trusted_local(&mux, resolve_request()).unwrap();
        assert_eq!(replay["replayed"], true);
        assert_eq!(replay["value"], first["value"]);
        assert!(mux.pending_pairings().is_empty());
    }

    #[test]
    fn frontend_projection_round_trips_exact_json_and_replays() {
        let mux = Mux::new_for_test("aux-projection", SurfaceOptions::default());
        let projection_id = FrontendProjectionPublicId::random().unwrap();
        let mut selected = session_selectors();
        selected.frontend_projection = Some(projection_id.to_string());
        let put_request = || {
            request(
                ResourceOperation::FrontendProjectionPut,
                Some("projection-put-once"),
                selected.clone(),
                json!({
                    "frontend_id":"cmux-test",
                    "window_id":"window-test",
                    "generation":"launch-test",
                    "projection":{"columns":[{"workspace":"α"}]},
                }),
            )
        };
        let first = dispatch(&mux, put_request()).unwrap();
        assert_eq!(first["replayed"], false);
        assert_eq!(first["value"]["projection"], json!({"columns":[{"workspace":"α"}]}));
        let revision = first["revision"].as_str().unwrap().parse::<u64>().unwrap();
        let events = mux.resource_events_after(0).unwrap();
        assert_eq!(events.head_revision, revision);
        assert_eq!(events.batches.len(), 1);
        assert_eq!(events.batches[0].changes[0]["resource"], "frontend_projection");
        assert_eq!(
            crate::resource_api::public_session_snapshot(&mux).unwrap()["cursor"]["revision"],
            first["revision"]
        );
        let replay = dispatch(&mux, put_request()).unwrap();
        assert_eq!(replay["replayed"], true);
        assert_eq!(replay["value"], first["value"]);
        let got = dispatch(
            &mux,
            request(ResourceOperation::FrontendProjectionGet, None, selected, json!({})),
        )
        .unwrap();
        assert_eq!(got, first["value"]);
    }

    #[test]
    fn frontend_projection_cas_is_window_local() {
        let mux = Mux::new_for_test("aux-projection-window-cas", SurfaceOptions::default());
        let first_id = FrontendProjectionPublicId::random().unwrap();
        let second_id = FrontendProjectionPublicId::random().unwrap();
        let fields = |window: &str, generation: &str, selected: &str| {
            json!({
                "frontend_id":"cmux-swift",
                "window_id":window,
                "generation":generation,
                "projection":{"selected_workspace":selected},
            })
        };
        let mut first = session_selectors();
        first.frontend_projection = Some(first_id.to_string());
        let mut second = session_selectors();
        second.frontend_projection = Some(second_id.to_string());

        let initial = dispatch(
            &mux,
            request(
                ResourceOperation::FrontendProjectionPut,
                Some("projection-window-first"),
                first.clone(),
                fields("window-a", "launch-a", "alpha"),
            ),
        )
        .unwrap();
        assert_eq!(initial["value"]["projection_revision"], "1");

        dispatch(
            &mux,
            request(
                ResourceOperation::FrontendProjectionPut,
                Some("projection-window-second"),
                second,
                fields("window-b", "launch-b", "beta"),
            ),
        )
        .unwrap();

        let updated = dispatch(
            &mux,
            request(
                ResourceOperation::FrontendProjectionPut,
                Some("projection-window-first-update"),
                first,
                {
                    let mut fields = fields("window-a", "launch-a", "gamma");
                    fields["expected_projection_revision"] = json!("1");
                    fields
                },
            ),
        )
        .unwrap();
        assert_eq!(updated["value"]["projection_revision"], "2");
        assert_eq!(updated["value"]["projection"]["selected_workspace"], "gamma");
    }

    #[test]
    fn sidebar_resource_lifecycle_uses_the_real_plugin_pty_and_exact_receipts() {
        let mux = Mux::new("aux-sidebar-lifecycle", SurfaceOptions::default());
        mux.configure_sidebar_plugin(Some(SidebarPluginOptions {
            command: vec!["/bin/cat".to_string()],
            cwd: None,
        }));

        let ensure_request = || {
            request(
                ResourceOperation::SidebarViewEnsure,
                Some("sidebar-ensure-once"),
                session_selectors(),
                json!({"cols":24,"rows":5,"relaunch":false}),
            )
        };
        let ensured = dispatch(&mux, ensure_request()).unwrap();
        assert_eq!(ensured["replayed"], false);
        assert_eq!(ensured["value"]["running"], true);
        assert_eq!(ensured["value"]["cols"], 24);
        assert_eq!(ensured["value"]["rows"], 5);
        let sidebar_id = ensured["value"]["id"].as_str().unwrap().to_string();
        let first_surface = mux.sidebar_plugin_status().surface.unwrap();
        let events_before_input = mux.resource_events_after(0).unwrap();

        let replay = dispatch(&mux, ensure_request()).unwrap();
        assert_eq!(replay["replayed"], true);
        assert_eq!(replay["value"], ensured["value"]);
        assert_eq!(mux.sidebar_plugin_status().surface, Some(first_surface));

        let mut selected = session_selectors();
        selected.sidebar_view = Some(sidebar_id.clone());
        let input_request = || {
            request(
                ResourceOperation::SidebarViewInput,
                Some("sidebar-input-once"),
                selected.clone(),
                json!({
                    "data_base64":base64::engine::general_purpose::STANDARD
                        .encode(b"resource-sidebar-input\n"),
                }),
            )
        };
        let input = dispatch(&mux, input_request()).unwrap();
        assert_eq!(input["value"], json!({}));
        assert_eq!(input["revision"], ensured["revision"]);
        let events_after_input = mux.resource_events_after(0).unwrap();
        assert_eq!(events_after_input.head_revision, events_before_input.head_revision);
        assert_eq!(events_after_input.batches.len(), events_before_input.batches.len());
        let replay = dispatch(&mux, input_request()).unwrap();
        assert_eq!(replay["replayed"], true);
        assert_eq!(replay["value"], input["value"]);
        assert_eq!(replay["revision"], input["revision"]);
        let surface = mux.sidebar_plugin_surface().unwrap();
        let deadline = Instant::now() + Duration::from_secs(2);
        loop {
            let text =
                surface.try_with_terminal(|terminal| terminal.viewport_text()).unwrap().unwrap();
            if text.contains("resource-sidebar-input") {
                break;
            }
            assert!(Instant::now() < deadline, "input did not reach the sidebar PTY");
            std::thread::sleep(Duration::from_millis(10));
        }

        let resized = dispatch(
            &mux,
            request(
                ResourceOperation::SidebarViewResize,
                Some("sidebar-resize-once"),
                selected.clone(),
                json!({"cols":31,"rows":7}),
            ),
        )
        .unwrap();
        assert_eq!(resized["value"]["cols"], 31);
        assert_eq!(resized["value"]["rows"], 7);
        assert_eq!(mux.sidebar_plugin_surface().unwrap().size(), (31, 7));

        let got = dispatch(
            &mux,
            request(ResourceOperation::SidebarViewGet, None, selected.clone(), json!({})),
        )
        .unwrap();
        assert_eq!(got["id"], sidebar_id);
        assert_eq!(got["running"], true);
        assert_eq!(got["cols"], 31);
        assert_eq!(got["rows"], 7);

        let reloaded = dispatch(
            &mux,
            request(
                ResourceOperation::SidebarViewReload,
                Some("sidebar-reload-once"),
                selected,
                json!({}),
            ),
        )
        .unwrap();
        assert_eq!(reloaded["value"]["running"], true);
        let second_surface = mux.sidebar_plugin_status().surface.unwrap();
        assert_ne!(second_surface, first_surface);
        mux.sidebar_plugin_surface().unwrap().kill();
    }
}
