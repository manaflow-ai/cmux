#[cfg(target_os = "macos")]
use std::mem::size_of;
use std::sync::Arc;
use std::time::{Duration, Instant};

use base64::Engine;
use ghostty_vt::{
    KeyEncoder, Mods, MouseAction, MouseButton, MouseInput, StyledRun, UnderlineStyle,
    key_input_from_chord, rows_to_runs,
};
use regex::Regex;
use serde_json::{Map, Value, json};

use super::effects::{self, EffectPreparation, PreparedEffect};
use super::{
    ParsedResourceRequest, required_string, resolve_terminal_wait_exit_id,
    resource_operation_error, validation_error,
};
use crate::browser::{BrowserSource, BrowserStatus};
use crate::model::State;
use crate::mux::ResourceEffectProjection;
use crate::resource::{
    BrowserPublicId, ContentPublicId, ResourceError, ResourceOperation, TerminalPublicId,
    WireDecimal,
};
#[cfg(test)]
use crate::resource_api::public_session_snapshot;
use crate::workspace_registry::{
    RegistryBrowserLaunch, RegistryBrowserSource, RegistryBrowserStatus, ResourceChange,
    ResourcePatch, WorkspaceRegistry,
};
use crate::{Mux, ResourceSelectors, ResourceTarget, Surface, SurfaceKind, WorkspaceMutation};

const MAX_TERMINAL_MOUSE_BYTES: usize = crate::resource::MAX_MESSAGE_BYTES;
#[cfg(test)]
pub(super) fn handles(operation: ResourceOperation) -> bool {
    matches!(
        operation,
        ResourceOperation::TerminalInputWrite
            | ResourceOperation::TerminalInputKeys
            | ResourceOperation::TerminalInputMouse
            | ResourceOperation::TerminalInputFocus
            | ResourceOperation::TerminalScreenRead
            | ResourceOperation::TerminalStateRead
            | ResourceOperation::TerminalHistoryRead
            | ResourceOperation::TerminalHistoryClear
            | ResourceOperation::TerminalWait
            | ResourceOperation::TerminalWaitExit
            | ResourceOperation::TerminalCopy
            | ResourceOperation::TerminalProcessGet
            | ResourceOperation::TerminalViewportScroll
            | ResourceOperation::TerminalMove
            | ResourceOperation::TerminalProject
            | ResourceOperation::TerminalClose
            | ResourceOperation::BrowserNavigate
            | ResourceOperation::BrowserBack
            | ResourceOperation::BrowserForward
            | ResourceOperation::BrowserReload
            | ResourceOperation::BrowserActivate
            | ResourceOperation::BrowserInputKey
            | ResourceOperation::BrowserInputText
            | ResourceOperation::BrowserInputMouse
            | ResourceOperation::BrowserInputWheel
            | ResourceOperation::BrowserClose
    )
}

pub(super) fn dispatch(
    mux: &Arc<Mux>,
    request: ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    match request.envelope.operation {
        ResourceOperation::TerminalScreenRead => terminal_screen_read(mux, &request),
        ResourceOperation::TerminalStateRead => terminal_state_read(mux, &request),
        ResourceOperation::TerminalHistoryRead => terminal_history_read(mux, &request),
        ResourceOperation::TerminalWait => terminal_wait(mux, &request),
        ResourceOperation::TerminalWaitExit => terminal_wait_exit(mux, &request),
        ResourceOperation::TerminalCopy => terminal_copy(mux, &request),
        ResourceOperation::TerminalProcessGet => terminal_process_get(mux, &request),
        ResourceOperation::TerminalMove => terminal_move(mux, request),
        ResourceOperation::TerminalProject => terminal_project(mux, request),
        ResourceOperation::TerminalInputWrite
        | ResourceOperation::TerminalInputKeys
        | ResourceOperation::TerminalInputMouse
        | ResourceOperation::TerminalInputFocus
        | ResourceOperation::TerminalHistoryClear
        | ResourceOperation::TerminalViewportScroll
        | ResourceOperation::TerminalClose => terminal_effect(mux, request),
        ResourceOperation::BrowserNavigate
        | ResourceOperation::BrowserBack
        | ResourceOperation::BrowserForward
        | ResourceOperation::BrowserReload
        | ResourceOperation::BrowserActivate
        | ResourceOperation::BrowserInputKey
        | ResourceOperation::BrowserInputText
        | ResourceOperation::BrowserInputMouse
        | ResourceOperation::BrowserInputWheel
        | ResourceOperation::BrowserClose => browser_effect(mux, request),
        operation => Err(ResourceError::operation_failed(
            super::operation_name(operation),
            "content router received an operation it does not own",
            json!({}),
        )),
    }
}

fn terminal_screen_read(
    mux: &Arc<Mux>,
    request: &ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let (_, surface) = resolve_terminal_surface(mux, &request.selectors)?;
    let (text, cols, rows, cursor_col, cursor_row, cursor_visible) = surface
        .try_with_terminal(|terminal| {
            let text = terminal.viewport_text()?;
            let (cursor_col, cursor_row) = terminal.cursor_position().unwrap_or((0, 0));
            Ok::<_, ghostty_vt::Error>((
                text,
                terminal.cols(),
                terminal.rows(),
                cursor_col,
                cursor_row,
                terminal.mode(25, false),
            ))
        })
        .map_err(resource_operation_error)?
        .map_err(|error| resource_operation_error(error.into()))?;
    Ok(json!({
        "text":text,
        "cols":cols,
        "rows":rows,
        "cursor_row":cursor_row,
        "cursor_col":cursor_col,
        "cursor_visible":cursor_visible,
    }))
}

fn terminal_state_read(
    mux: &Arc<Mux>,
    request: &ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let (_, surface) = resolve_terminal_surface(mux, &request.selectors)?;
    let (cols, rows, state) = surface
        .try_with_terminal(|terminal| {
            terminal
                .vt_replay_bounded(crate::surface::VT_REPLAY_MAX_BYTES)
                .map(|state| (terminal.cols(), terminal.rows(), state))
        })
        .map_err(resource_operation_error)?
        .map_err(|error| resource_operation_error(error.into()))?;
    Ok(json!({
        "state_base64":base64::engine::general_purpose::STANDARD.encode(state.bytes),
        "cols":cols,
        "rows":rows,
    }))
}

fn terminal_history_read(
    mux: &Arc<Mux>,
    request: &ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let (_, surface) = resolve_terminal_surface(mux, &request.selectors)?;
    let before = optional_decimal(&request.fields, "before")?;
    let limit = required_u64(&request.fields, "limit")?;
    let limit = u16::try_from(limit).map_err(|_| {
        validation_error(
            "terminal history limit exceeds uint16",
            json!({"field":"limit","value":limit}),
        )
    })?;
    let styled = request.fields.get("styled").and_then(Value::as_bool).unwrap_or(true);
    let (start, next, rows) = surface
        .try_with_terminal(|terminal| {
            let total = u64::from(terminal.history_rows());
            let end = before.unwrap_or(total).min(total);
            let start = end.saturating_sub(u64::from(limit));
            let count = u16::try_from(end.saturating_sub(start))
                .expect("history page is bounded by the uint16 limit");
            let cells = terminal.styled_history_rows(start as u32, count)?;
            Ok::<_, ghostty_vt::Error>((
                start,
                (start > 0).then_some(start),
                history_rows_json(&cells, styled),
            ))
        })
        .map_err(resource_operation_error)?
        .map_err(|error| resource_operation_error(error.into()))?;
    Ok(json!({
        "start":start.to_string(),
        "next":next.map(|value| value.to_string()),
        "rows":rows,
    }))
}

fn terminal_wait(mux: &Arc<Mux>, request: &ParsedResourceRequest) -> Result<Value, ResourceError> {
    let (_, surface) = resolve_terminal_surface(mux, &request.selectors)?;
    let pattern = required_string(&request.fields, "pattern")?;
    let regex = Regex::new(pattern).map_err(|error| {
        validation_error(
            "terminal wait pattern is not a valid regular expression",
            json!({"pattern":pattern,"error":error.to_string()}),
        )
    })?;
    let timeout = optional_decimal(&request.fields, "timeout_ms")?.map(Duration::from_millis);
    let deadline = timeout
        .map(|timeout| {
            Instant::now().checked_add(timeout).ok_or_else(|| {
                validation_error(
                    "terminal wait timeout exceeds the platform deadline range",
                    json!({"field":"timeout_ms"}),
                )
            })
        })
        .transpose()?;
    let check = || -> Result<String, ResourceError> {
        surface
            .try_with_terminal(|terminal| terminal.viewport_text())
            .map_err(resource_operation_error)?
            .map_err(|error| resource_operation_error(error.into()))
    };
    let mut observed = surface
        .terminal_stream_revision()
        .map_err(|error| resource_operation_error(error.into()))?;
    let mut text = check()?;
    if regex.is_match(&text) {
        return Ok(json!({"matched":true,"text":text}));
    }
    if timeout == Some(Duration::ZERO) {
        return Ok(json!({"matched":false,"text":text}));
    }

    loop {
        match surface
            .wait_for_terminal_stream_change(observed, deadline)
            .map_err(|error| resource_operation_error(error.into()))?
        {
            Some(revision) => {
                observed = revision;
                text = check()?;
                if regex.is_match(&text) {
                    return Ok(json!({"matched":true,"text":text}));
                }
            }
            None => {
                // Close the output/deadline race with one final authoritative
                // snapshot. The progress notifier itself is coalesced and
                // cannot disconnect or overflow.
                text = check()?;
                return Ok(json!({"matched":regex.is_match(&text),"text":text}));
            }
        }
    }
}

fn terminal_wait_exit(
    mux: &Arc<Mux>,
    request: &ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let terminal_id = resolve_terminal_wait_exit_id(mux, &request.selectors)?;
    let timeout = optional_decimal(&request.fields, "timeout_ms")?.map(Duration::from_millis);
    mux.wait_for_terminal_exit(&terminal_id, timeout).map_err(resource_operation_error)
}

fn terminal_copy(mux: &Arc<Mux>, request: &ParsedResourceRequest) -> Result<Value, ResourceError> {
    let (_, surface) = resolve_terminal_surface(mux, &request.selectors)?;
    let mode = required_string(&request.fields, "mode")?;
    let text = match mode {
        "screen" => surface
            .try_with_terminal(|terminal| terminal.viewport_text())
            .map_err(resource_operation_error)?
            .map_err(|error| resource_operation_error(error.into()))?,
        "scrollback" => surface
            .try_with_terminal(|terminal| terminal.plain_text())
            .map_err(resource_operation_error)?
            .map_err(|error| resource_operation_error(error.into()))?,
        "selection" => surface.selection_text().ok_or_else(|| {
            ResourceError::operation_failed(
                "terminal.copy",
                "terminal has no active selection",
                json!({}),
            )
        })?,
        _ => {
            return Err(validation_error("terminal copy mode is invalid", json!({"mode":mode})));
        }
    };
    Ok(json!({"mode":mode,"text":text}))
}

fn terminal_process_get(
    mux: &Arc<Mux>,
    request: &ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let (_, surface) = resolve_terminal_surface(mux, &request.selectors)?;
    let pid = surface.process_id().ok_or_else(|| {
        ResourceError::operation_failed(
            "terminal.process.get",
            "terminal has no live child process",
            json!({}),
        )
    })?;
    let argv = surface.spawn_argv().ok_or_else(|| {
        ResourceError::operation_failed(
            "terminal.process.get",
            "terminal launch argv is unavailable",
            json!({"pid":pid}),
        )
    })?;
    let executable = argv.first().cloned();
    let mut children = direct_child_pids(pid);
    children.sort_unstable();
    let mut value = json!({
        "pid":pid,
        "argv":argv,
        "children":children,
    });
    if let Some(executable) = executable {
        value["executable"] = json!(executable);
    }
    if let Some(cwd) = surface.pwd().or_else(|| surface.spawn_cwd()) {
        value["cwd"] = json!(cwd);
    }
    Ok(value)
}

fn terminal_effect(mux: &Arc<Mux>, request: ParsedResourceRequest) -> Result<Value, ResourceError> {
    validate_terminal_effect_fields(&request)?;
    let fields = request.fields.clone();
    let preparation = effects::prepare(mux, &request, || {
        let (terminal_id, _) = resolve_terminal_surface(mux, &request.selectors)?;
        Ok(json!({"terminal_id":terminal_id,"fields":fields}))
    })?;
    match preparation {
        EffectPreparation::Complete(result) => result,
        EffectPreparation::Execute(prepared) => execute_terminal_effect(mux, prepared),
    }
}

fn execute_terminal_effect(
    mux: &Arc<Mux>,
    prepared: PreparedEffect,
) -> Result<Value, ResourceError> {
    let terminal_id = match intent_resource_id::<TerminalPublicId>(
        &prepared.intent,
        "terminal_id",
        "terminal",
        &prepared.operation,
    ) {
        Ok(terminal_id) => terminal_id,
        Err(error) => return effects::commit_known_failure(mux, prepared, error),
    };
    let fields = match intent_fields(&prepared.intent, &prepared.operation) {
        Ok(fields) => fields.clone(),
        Err(error) => return effects::commit_known_failure(mux, prepared, error),
    };
    let Some(surface_id) = mux.resource_surface_for_terminal(&terminal_id) else {
        return effects::commit_known_failure(
            mux,
            prepared,
            ResourceError::not_found("terminal", terminal_id.as_str()),
        );
    };
    let Some(surface) = mux.surface(surface_id) else {
        return effects::commit_known_failure(
            mux,
            prepared,
            ResourceError::not_found("terminal", terminal_id.as_str()),
        );
    };
    if surface.kind() != SurfaceKind::Pty {
        return effects::commit_known_failure(
            mux,
            prepared,
            ResourceError::not_found("terminal", terminal_id.as_str()),
        );
    }

    let action = match prepared.operation.as_str() {
        "terminal.input.write" => terminal_write(&surface, &fields),
        "terminal.input.keys" => terminal_keys(&surface, &fields),
        "terminal.input.mouse" => terminal_mouse(&surface, &fields),
        "terminal.input.focus" => terminal_focus(&surface, &fields),
        "terminal.history.clear" => {
            surface.clear_history().map_err(|error| ActionFailure::Indeterminate(error.to_string()))
        }
        "terminal.viewport.scroll" => terminal_scroll_viewport(mux, &surface, &fields),
        "terminal.close" => Ok(()),
        operation => Err(ActionFailure::Known(ResourceError::operation_failed(
            operation,
            "stored terminal effect operation is invalid",
            json!({}),
        ))),
    };
    if let Err(failure) = action {
        return finish_action_failure(mux, prepared, failure);
    }

    if prepared.operation == "terminal.close" {
        let commit = mux.commit_resource_terminal_close_effect(
            surface_id,
            &prepared.idempotency_key,
            &prepared.operation,
            &prepared.fingerprint,
        );
        return finish_projection_commit(mux, prepared, commit);
    }

    debug_assert!(effects::receipt_only_operation(&prepared.operation));
    effects::commit_success_without_changes(mux, prepared, json!({}))
}

fn browser_effect(mux: &Arc<Mux>, request: ParsedResourceRequest) -> Result<Value, ResourceError> {
    let fields = request.fields.clone();
    let preparation = effects::prepare(mux, &request, || {
        let (browser_id, surface) = resolve_browser_surface(mux, &request.selectors)?;
        if request.envelope.operation != ResourceOperation::BrowserClose
            && surface.browser_source().is_none()
        {
            return Err(browser_not_ready_error(
                &surface,
                super::operation_name(request.envelope.operation),
            ));
        }
        Ok(json!({"browser_id":browser_id,"fields":fields}))
    })?;
    match preparation {
        EffectPreparation::Complete(result) => result,
        EffectPreparation::Execute(prepared) => execute_browser_effect(mux, prepared),
    }
}

fn execute_browser_effect(
    mux: &Arc<Mux>,
    prepared: PreparedEffect,
) -> Result<Value, ResourceError> {
    let browser_id = match intent_resource_id::<BrowserPublicId>(
        &prepared.intent,
        "browser_id",
        "browser",
        &prepared.operation,
    ) {
        Ok(browser_id) => browser_id,
        Err(error) => return effects::commit_known_failure(mux, prepared, error),
    };
    let fields = match intent_fields(&prepared.intent, &prepared.operation) {
        Ok(fields) => fields.clone(),
        Err(error) => return effects::commit_known_failure(mux, prepared, error),
    };
    let Some((surface_id, surface)) = browser_surface_for_id(mux, &browser_id) else {
        return effects::commit_known_failure(
            mux,
            prepared,
            ResourceError::not_found("browser", browser_id.as_str()),
        );
    };

    let action = (|| -> Result<(), ActionFailure> {
        match prepared.operation.as_str() {
            "browser.navigate" => surface
                .browser_navigate_confirmed(required_intent_string(
                    &fields,
                    "url",
                    &prepared.operation,
                )?)
                .map_err(|error| ActionFailure::Indeterminate(error.to_string())),
            "browser.back" => surface
                .browser_back_confirmed()
                .map_err(|error| ActionFailure::Indeterminate(error.to_string())),
            "browser.forward" => surface
                .browser_forward_confirmed()
                .map_err(|error| ActionFailure::Indeterminate(error.to_string())),
            "browser.reload" => surface
                .browser_reload_confirmed()
                .map_err(|error| ActionFailure::Indeterminate(error.to_string())),
            "browser.activate" => surface
                .browser_activate_confirmed()
                .map_err(|error| ActionFailure::Indeterminate(error.to_string())),
            "browser.input.text" => surface
                .browser_insert_text_confirmed(required_intent_string(
                    &fields,
                    "text",
                    &prepared.operation,
                )?)
                .map_err(|error| ActionFailure::Indeterminate(error.to_string())),
            "browser.input.key" => browser_key(&surface, &fields),
            "browser.input.mouse" => browser_mouse(&surface, &fields),
            "browser.input.wheel" => browser_wheel(&surface, &fields),
            "browser.close" => {
                if surface.browser_source().is_some() {
                    surface
                        .browser_close_confirmed()
                        .map_err(|error| ActionFailure::Indeterminate(error.to_string()))?;
                }
                Ok(())
            }
            operation => Err(ActionFailure::Known(ResourceError::operation_failed(
                operation,
                "stored browser effect operation is invalid",
                json!({}),
            ))),
        }
    })();
    if let Err(failure) = action {
        return finish_action_failure(mux, prepared, failure);
    }

    if prepared.operation == "browser.close" {
        let commit = mux.commit_resource_surface_close_effect(
            surface_id,
            &prepared.idempotency_key,
            &prepared.operation,
            &prepared.fingerprint,
        );
        return finish_projection_commit(mux, prepared, commit);
    }

    if effects::receipt_only_operation(&prepared.operation) {
        return effects::commit_success_without_changes(mux, prepared, json!({}));
    }

    let returns_browser = matches!(
        prepared.operation.as_str(),
        "browser.navigate"
            | "browser.back"
            | "browser.forward"
            | "browser.reload"
            | "browser.activate"
    );
    commit_projected_browser_effect(mux, prepared, &browser_id, returns_browser)
}

fn browser_not_ready_error(surface: &Surface, operation: impl Into<String>) -> ResourceError {
    let status = surface.browser_status();
    let state = status.as_ref().map(|status| status.as_str()).unwrap_or("starting");
    ResourceError::operation_failed(
        operation,
        if state == "failed" {
            "browser failed before it acquired a live automation session"
        } else {
            "browser is still starting"
        },
        json!({
            "status":state,
            "error":status.and_then(|status| status.error()),
        }),
    )
}

fn commit_projected_browser_effect(
    mux: &Arc<Mux>,
    prepared: PreparedEffect,
    browser_id: &BrowserPublicId,
    returns_browser: bool,
) -> Result<Value, ResourceError> {
    let browser_id = browser_id.clone();
    let commit = mux.commit_resource_effect_projection(
        &prepared.idempotency_key,
        &prepared.operation,
        &prepared.fingerprint,
        move |registry, state| {
            targeted_browser_effect_projection(registry, state, &browser_id, returns_browser)
        },
    );
    finish_projection_commit(mux, prepared, commit)
}

fn targeted_browser_effect_projection(
    registry: &WorkspaceRegistry,
    state: &State,
    browser_id: &BrowserPublicId,
    returns_browser: bool,
) -> anyhow::Result<ResourceEffectProjection> {
    let topology = registry.resource_topology_snapshot()?;
    let mut browser = topology
        .browsers
        .iter()
        .find(|candidate| &candidate.public_id == browser_id)
        .cloned()
        .ok_or_else(|| anyhow::anyhow!("browser has no durable metadata"))?;
    let mut matching_tabs = topology
        .tabs
        .iter()
        .filter(|tab| tab.content_id == ContentPublicId::Browser(browser_id.clone()));
    let mut tab = matching_tabs
        .next()
        .cloned()
        .ok_or_else(|| anyhow::anyhow!("browser has no durable tab"))?;
    anyhow::ensure!(matching_tabs.next().is_none(), "browser has multiple durable tabs");
    let content_id = ContentPublicId::Browser(browser_id.clone());
    let surface_id = state
        .single_placement_of_content(&content_id)
        .ok_or_else(|| anyhow::anyhow!("browser must have exactly one live surface slot"))?;
    let surface = state
        .surfaces
        .get(&surface_id)
        .filter(|surface| surface.kind() == SurfaceKind::Browser)
        .ok_or_else(|| anyhow::anyhow!("browser has no live browser surface"))?;

    let url = surface.browser_url().unwrap_or_else(|| browser.url.clone());
    let source = surface.browser_source();
    let status =
        surface.browser_status().ok_or_else(|| anyhow::anyhow!("browser surface has no status"))?;
    let (cols, rows) = surface.size();
    browser.url = url.clone();
    browser.cols = cols.max(1);
    browser.rows = rows.max(1);
    if let Some(source) = source {
        browser.source = match source {
            BrowserSource::External => RegistryBrowserSource::External,
            BrowserSource::Launched => RegistryBrowserSource::Launched,
            BrowserSource::Provider => RegistryBrowserSource::External,
        };
    }
    browser.status = match &status {
        BrowserStatus::Starting => RegistryBrowserStatus::Starting,
        BrowserStatus::Live => RegistryBrowserStatus::Live,
        BrowserStatus::Failed(_) => RegistryBrowserStatus::Failed,
    };
    tab.browser_url = Some(url.clone());

    let source_name = source.map(BrowserSource::as_str).unwrap_or_else(|| match browser.source {
        RegistryBrowserSource::External => "external",
        RegistryBrowserSource::Launched => "launched",
        RegistryBrowserSource::Unknown => match browser.launch {
            RegistryBrowserLaunch::Create => "launched",
            RegistryBrowserLaunch::Adopted => "external",
        },
    });
    let status_name = status.as_str();
    let value = json!({
        "id":browser_id,
        "tab_id":tab.public_id,
        "url":url,
        "title":surface.title(),
        "loading":status_name == "starting",
        "source":source_name,
        "status":status_name,
        "error":status.error(),
        "frames_stalled":surface.browser_frames_stalled().unwrap_or(false),
        "size":{
            "cols":cols.max(1),
            "rows":rows.max(1),
        },
    });
    Ok(ResourceEffectProjection {
        patch: ResourcePatch {
            changes: vec![ResourceChange::UpsertBrowser(browser), ResourceChange::UpsertTab(tab)],
        },
        changes: upsert_change("browser", browser_id.as_str(), value.clone()),
        result: if returns_browser { value } else { json!({}) },
    })
}

fn finish_projection_commit(
    mux: &Arc<Mux>,
    prepared: PreparedEffect,
    commit: anyhow::Result<crate::workspace_registry::ResourcePatchCommit>,
) -> Result<Value, ResourceError> {
    let commit = match commit {
        Ok(commit) => commit,
        Err(_) => {
            let _ = mux.mark_resource_effect_indeterminate(&prepared.idempotency_key);
            return Err(effects::indeterminate_error(
                &prepared.idempotency_key,
                &prepared.operation,
            ));
        }
    };
    super::mutation_result(mux, commit.result, commit.revision, commit.replayed)
}

fn terminal_move(mux: &Arc<Mux>, request: ParsedResourceRequest) -> Result<Value, ResourceError> {
    let mutation = resource_mutation(&request)?;
    let destination = destination_selectors(mux, &request)?;
    let index = required_u64(&request.fields, "index")?;
    let commit = mux
        .resource_move_terminal_selected(
            request.selectors,
            destination,
            usize::try_from(index).map_err(|_| {
                validation_error("terminal move index exceeds usize", json!({"index":index}))
            })?,
            super::expected_revision(&request.fields)?,
            &mutation,
        )
        .map_err(resource_operation_error)?;
    commit.result["terminal"].as_str().ok_or_else(|| {
        ResourceError::operation_failed(
            "terminal.move",
            "terminal move commit omitted its public identity",
            json!({}),
        )
    })?;
    let value =
        commit.result.get("value").filter(|value| value.is_object()).cloned().ok_or_else(|| {
            ResourceError::operation_failed(
                "terminal.move",
                "terminal move commit omitted its captured terminal snapshot",
                json!({}),
            )
        })?;
    super::mutation_result(mux, value, commit.revision, commit.replayed)
}

fn terminal_project(
    mux: &Arc<Mux>,
    request: ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let mutation = resource_mutation(&request)?;
    let destination = destination_selectors(mux, &request)?;
    let index = required_u64(&request.fields, "index")?;
    let name = request.fields.get("name").and_then(Value::as_str).map(str::to_string);
    let commit = mux
        .resource_project_terminal_selected(
            request.selectors,
            destination,
            usize::try_from(index).map_err(|_| {
                validation_error("terminal projection index exceeds usize", json!({"index":index}))
            })?,
            name,
            super::expected_revision(&request.fields)?,
            &mutation,
        )
        .map_err(resource_operation_error)?;
    let value =
        commit.result.get("value").filter(|value| value.is_object()).cloned().ok_or_else(|| {
            ResourceError::operation_failed(
                "terminal.project",
                "terminal could not be added to the destination; refresh the session and try again",
                json!({}),
            )
        })?;
    super::mutation_result(mux, value, commit.revision, commit.replayed)
}

fn terminal_write(surface: &Surface, fields: &Map<String, Value>) -> Result<(), ActionFailure> {
    let bytes = match (fields.get("text"), fields.get("bytes_base64")) {
        (Some(Value::String(text)), None) => text.as_bytes().to_vec(),
        (None, Some(Value::String(encoded))) => {
            base64::engine::general_purpose::STANDARD.decode(encoded).map_err(|error| {
                ActionFailure::Known(validation_error(
                    "stored terminal input is not valid base64",
                    json!({"error":error.to_string()}),
                ))
            })?
        }
        _ => {
            return Err(ActionFailure::Known(validation_error(
                "stored terminal input must contain exactly one payload",
                json!({}),
            )));
        }
    };
    surface.write_bytes(&bytes).map_err(|error| ActionFailure::Indeterminate(error.to_string()))
}

fn terminal_scroll_viewport(
    mux: &Mux,
    surface: &Surface,
    fields: &Map<String, Value>,
) -> Result<(), ActionFailure> {
    let delta_rows = required_i64_action(fields, "delta_rows")?;
    let delta_rows = isize::try_from(delta_rows).map_err(|_| {
        ActionFailure::Known(validation_error(
            "terminal scroll delta exceeds platform isize",
            json!({"delta_rows":delta_rows}),
        ))
    })?;
    mux.scroll_surface_viewport(surface, delta_rows)
        .map_err(|error| ActionFailure::Indeterminate(error.to_string()))
}

fn terminal_keys(surface: &Surface, fields: &Map<String, Value>) -> Result<(), ActionFailure> {
    let keys = intent_string_array(fields, "keys", "terminal.input.keys")?;
    let mut encoder = KeyEncoder::new().map_err(|error| {
        ActionFailure::Known(ResourceError::operation_failed(
            "terminal.input.keys",
            "terminal key encoder could not be created",
            json!({"error":error.to_string()}),
        ))
    })?;
    let mut encoded = Vec::new();
    surface
        .try_with_terminal(|terminal| {
            encoder.sync_from_terminal(terminal);
            for key in &keys {
                let input = key_input_from_chord(key).ok_or_else(|| {
                    validation_error("terminal key chord is invalid", json!({"key":key}))
                })?;
                encoder.encode(&input, &mut encoded).map_err(|error| {
                    ResourceError::operation_failed(
                        "terminal.input.keys",
                        "terminal key could not be encoded",
                        json!({"key":key,"error":error.to_string()}),
                    )
                })?;
            }
            Ok::<(), ResourceError>(())
        })
        .map_err(|error| ActionFailure::Known(resource_operation_error(error)))?
        .map_err(ActionFailure::Known)?;
    surface.scroll_to_bottom().map_err(|error| ActionFailure::Indeterminate(error.to_string()))?;
    surface.write_bytes(&encoded).map_err(|error| ActionFailure::Indeterminate(error.to_string()))
}

fn terminal_mouse(surface: &Surface, fields: &Map<String, Value>) -> Result<(), ActionFailure> {
    let kind = required_intent_string(fields, "kind", "terminal.input.mouse")?;
    let row = required_u64_action(fields, "row")? as u16;
    let column = required_u64_action(fields, "column")? as u16;
    let mods = terminal_modifiers(fields)?;
    let (cols, rows) = surface.size();
    let button =
        fields.get("button").and_then(Value::as_str).map(terminal_mouse_button).transpose()?;
    let mut output = Vec::new();
    match kind {
        "down" | "up" | "move" => {
            let action = match kind {
                "down" => MouseAction::Press,
                "up" => MouseAction::Release,
                _ => MouseAction::Motion,
            };
            let input = MouseInput {
                action,
                button,
                mods,
                position: (f32::from(column) + 0.5, f32::from(row) + 0.5),
                screen_size: (u32::from(cols), u32::from(rows)),
                cell_size: (1, 1),
                any_button_pressed: kind == "down",
            };
            let encoded = if kind == "up" {
                surface.encode_mouse_release(input, &mut output)
            } else {
                surface.encode_mouse(input, &mut output)
            };
            encoded
                .ok_or_else(|| {
                    ActionFailure::Known(ResourceError::operation_failed(
                        "terminal.input.mouse",
                        "terminal mouse encoder is busy",
                        json!({}),
                    ))
                })?
                .map_err(|error| {
                    ActionFailure::Known(ResourceError::operation_failed(
                        "terminal.input.mouse",
                        "terminal mouse input could not be encoded",
                        json!({"error":error.to_string()}),
                    ))
                })?;
        }
        "wheel" => {
            let delta = required_i64_action(fields, "delta_rows")?;
            let wheel = if delta < 0 { MouseButton::WheelUp } else { MouseButton::WheelDown };
            let count = delta.unsigned_abs();
            if count > 100_000 {
                return Err(ActionFailure::Known(ResourceError::operation_failed(
                    "terminal.input.mouse",
                    "terminal wheel input exceeds the bounded event count",
                    json!({"events":count,"maximum_events":100000}),
                )));
            }
            for _ in 0..count {
                let before = output.len();
                let encoded = surface
                    .encode_mouse(
                        MouseInput {
                            action: MouseAction::Press,
                            button: Some(wheel),
                            mods,
                            position: (f32::from(column) + 0.5, f32::from(row) + 0.5),
                            screen_size: (u32::from(cols), u32::from(rows)),
                            cell_size: (1, 1),
                            any_button_pressed: false,
                        },
                        &mut output,
                    )
                    .ok_or_else(|| {
                        ActionFailure::Known(ResourceError::operation_failed(
                            "terminal.input.mouse",
                            "terminal mouse encoder is busy",
                            json!({}),
                        ))
                    })?;
                encoded.map_err(|error| {
                    ActionFailure::Known(ResourceError::operation_failed(
                        "terminal.input.mouse",
                        "terminal wheel input could not be encoded",
                        json!({"error":error.to_string()}),
                    ))
                })?;
                if output.len() > MAX_TERMINAL_MOUSE_BYTES {
                    return Err(ActionFailure::Known(ResourceError::operation_failed(
                        "terminal.input.mouse",
                        "terminal wheel input exceeds the bounded encoded size",
                        json!({
                            "encoded_bytes":output.len(),
                            "maximum_bytes":MAX_TERMINAL_MOUSE_BYTES,
                        }),
                    )));
                }
                if output.len() == before {
                    break;
                }
            }
        }
        _ => {
            return Err(ActionFailure::Known(validation_error(
                "stored terminal mouse kind is invalid",
                json!({"kind":kind}),
            )));
        }
    }
    if output.is_empty() {
        return Ok(());
    }
    surface.write_bytes(&output).map_err(|error| ActionFailure::Indeterminate(error.to_string()))
}

fn terminal_focus(surface: &Surface, fields: &Map<String, Value>) -> Result<(), ActionFailure> {
    let focused = fields.get("focused").and_then(Value::as_bool).ok_or_else(|| {
        ActionFailure::Known(validation_error("stored terminal focus input is invalid", json!({})))
    })?;
    let reports_focus = surface
        .try_with_terminal(|terminal| terminal.mode(1004, false))
        .map_err(|error| ActionFailure::Known(resource_operation_error(error)))?;
    if !reports_focus {
        return Ok(());
    }
    let bytes: &[u8] = if focused { b"\x1b[I" } else { b"\x1b[O" };
    surface.write_bytes(bytes).map_err(|error| ActionFailure::Indeterminate(error.to_string()))
}

fn browser_key(surface: &Surface, fields: &Map<String, Value>) -> Result<(), ActionFailure> {
    let key = required_intent_string(fields, "key", "browser.input.key")?;
    let kind = required_intent_string(fields, "kind", "browser.input.key")?;
    let key = browser_key_description(key);
    let modifiers = browser_modifiers(fields)?;
    let (event_key, text) = browser_key_event_values(&key, modifiers);
    let send = |event_type: &str, text: Option<&str>| {
        surface
            .browser_key_event_confirmed(
                event_type,
                &event_key,
                &key.code,
                key.windows_virtual_key_code,
                modifiers,
                text,
            )
            .map_err(|error| ActionFailure::Indeterminate(error.to_string()))
    };
    match kind {
        "down" => send("keyDown", text.as_deref()),
        "up" => send("keyUp", None),
        "press" => {
            send("keyDown", text.as_deref())?;
            send("keyUp", None)
        }
        _ => Err(ActionFailure::Known(validation_error(
            "stored browser key kind is invalid",
            json!({"kind":kind}),
        ))),
    }
}

fn browser_mouse(surface: &Surface, fields: &Map<String, Value>) -> Result<(), ActionFailure> {
    let kind = required_intent_string(fields, "kind", "browser.input.mouse")?;
    let event_type = match kind {
        "down" => "mousePressed",
        "up" => "mouseReleased",
        "move" => "mouseMoved",
        _ => {
            return Err(ActionFailure::Known(validation_error(
                "stored browser mouse kind is invalid",
                json!({"kind":kind}),
            )));
        }
    };
    let x = required_f64(fields, "x_px")?;
    let y = required_f64(fields, "y_px")?;
    let button = fields.get("button").and_then(Value::as_str);
    let click_count = fields.get("click_count").and_then(Value::as_u64).map(|value| value as u32);
    let pointer_frame_seq = required_decimal_action(fields, "pointer_frame_seq")?;
    surface
        .browser_mouse_event_confirmed(event_type, x, y, button, click_count, pointer_frame_seq)
        .map_err(|error| ActionFailure::Indeterminate(error.to_string()))
}

fn browser_wheel(surface: &Surface, fields: &Map<String, Value>) -> Result<(), ActionFailure> {
    surface
        .browser_wheel_confirmed(
            required_f64(fields, "x_px")?,
            required_f64(fields, "y_px")?,
            required_f64(fields, "delta_x")?,
            required_f64(fields, "delta_y")?,
            required_decimal_action(fields, "pointer_frame_seq")?,
        )
        .map_err(|error| ActionFailure::Indeterminate(error.to_string()))
}

fn validate_terminal_effect_fields(request: &ParsedResourceRequest) -> Result<(), ResourceError> {
    if request.envelope.operation == ResourceOperation::TerminalInputKeys {
        for key in intent_string_array(&request.fields, "keys", "terminal.input.keys").map_err(
            |failure| match failure {
                ActionFailure::Known(error) => error,
                ActionFailure::Indeterminate(_) => unreachable!("validation has no effects"),
            },
        )? {
            if key_input_from_chord(&key).is_none() {
                return Err(validation_error("terminal key chord is invalid", json!({"key":key})));
            }
        }
    }
    Ok(())
}

fn resolve_terminal_surface(
    mux: &Arc<Mux>,
    selectors: &ResourceSelectors,
) -> Result<(TerminalPublicId, Arc<Surface>), ResourceError> {
    let path = mux.resolve_resource_path(ResourceTarget::Terminal, selectors)?;
    let terminal_id =
        path.terminal.ok_or_else(|| ResourceError::not_found("terminal", "<resolved>"))?;
    let surface_id = mux
        .resource_surface_for_terminal(&terminal_id)
        .ok_or_else(|| ResourceError::not_found("terminal", terminal_id.as_str()))?;
    let surface = mux
        .surface(surface_id)
        .filter(|surface| surface.kind() == SurfaceKind::Pty)
        .ok_or_else(|| ResourceError::not_found("terminal", terminal_id.as_str()))?;
    Ok((terminal_id, surface))
}

fn resolve_browser_surface(
    mux: &Arc<Mux>,
    selectors: &ResourceSelectors,
) -> Result<(BrowserPublicId, Arc<Surface>), ResourceError> {
    let path = mux.resolve_resource_path(ResourceTarget::Browser, selectors)?;
    let browser_id =
        path.browser.ok_or_else(|| ResourceError::not_found("browser", "<resolved>"))?;
    let (_, surface) = browser_surface_for_id(mux, &browser_id)
        .ok_or_else(|| ResourceError::not_found("browser", browser_id.as_str()))?;
    Ok((browser_id, surface))
}

fn browser_surface_for_id(
    mux: &Mux,
    browser_id: &BrowserPublicId,
) -> Option<(crate::SurfaceId, Arc<Surface>)> {
    mux.with_state(|state| {
        let surface_id =
            state.single_placement_of_content(&ContentPublicId::Browser(browser_id.clone()))?;
        let surface = state.surfaces.get(&surface_id)?.clone();
        (surface.kind() == SurfaceKind::Browser).then_some((surface_id, surface))
    })
}

fn history_rows_json(rows: &[Vec<ghostty_vt::Cell>], styled: bool) -> Vec<Value> {
    let runs = rows_to_runs(rows);
    runs.iter()
        .enumerate()
        .map(|(row, runs)| {
            let runs = if styled {
                runs.iter().map(styled_run_json).collect()
            } else {
                vec![json!({
                    "text":runs.iter().map(|run| run.text.as_str()).collect::<String>(),
                    "fg":null,
                    "bg":null,
                    "attrs":0,
                })]
            };
            json!({"row":row as u16,"runs":runs})
        })
        .collect()
}

fn styled_run_json(run: &StyledRun) -> Value {
    let mut value = json!({
        "text":run.text,
        "fg":run.fg.map(rgb_hex),
        "bg":run.bg.map(rgb_hex),
        "attrs":u32::from(run.attrs),
    });
    if let Some(underline) = run.underline {
        value["underline"] = json!(match underline {
            UnderlineStyle::Single => "single",
            UnderlineStyle::Double => "double",
            UnderlineStyle::Curly => "curly",
            UnderlineStyle::Dotted => "dotted",
            UnderlineStyle::Dashed => "dashed",
        });
    }
    if let Some(width_hint) = run.width_hint {
        value["width_hint"] = json!(width_hint);
    }
    value
}

fn rgb_hex(color: ghostty_vt::Rgb) -> String {
    format!("#{:02x}{:02x}{:02x}", color.r, color.g, color.b)
}

fn upsert_change(resource: &str, id: &str, value: Value) -> Value {
    json!([{
        "kind":"upsert",
        "sequence":0,
        "resource":resource,
        "id":id,
        "value":value,
    }])
}

#[cfg(test)]
fn find_upsert_change(changes: &Value, resource: &str, id: &str) -> Option<Value> {
    changes.as_array()?.iter().find_map(|change| {
        (change["kind"] == "upsert"
            && change["resource"] == resource
            && change["id"].as_str() == Some(id))
        .then(|| change["value"].clone())
    })
}

fn destination_selectors(
    mux: &Arc<Mux>,
    request: &ParsedResourceRequest,
) -> Result<ResourceSelectors, ResourceError> {
    let mut selectors = ResourceSelectors {
        machine: request.selectors.machine.clone(),
        session: request.selectors.session.clone(),
        workspace: Some(required_string(&request.fields, "destination_workspace")?.to_string()),
        screen: Some(required_string(&request.fields, "destination_screen")?.to_string()),
        pane: Some(required_string(&request.fields, "destination_pane")?.to_string()),
        ..ResourceSelectors::default()
    };
    let path = mux.resolve_resource_path(ResourceTarget::Pane, &selectors)?;
    selectors.workspace = path.workspace.map(|id| id.into_string());
    selectors.screen = path.screen.map(|id| id.into_string());
    selectors.pane = path.pane.map(|id| id.into_string());
    Ok(selectors)
}

fn resource_mutation(request: &ParsedResourceRequest) -> Result<WorkspaceMutation, ResourceError> {
    WorkspaceMutation::new(
        request
            .envelope
            .idempotency_key
            .clone()
            .expect("catalog-validated mutations have an idempotency key"),
        "resource-api",
    )
    .map_err(super::operation_failed)
}

fn intent_fields<'a>(
    intent: &'a Value,
    operation: &str,
) -> Result<&'a Map<String, Value>, ResourceError> {
    intent.get("fields").and_then(Value::as_object).ok_or_else(|| {
        ResourceError::operation_failed(
            operation,
            "stored content effect fields are malformed",
            json!({}),
        )
    })
}

fn intent_resource_id<T>(
    intent: &Value,
    field: &str,
    resource: &str,
    operation: &str,
) -> Result<T, ResourceError>
where
    T: serde::de::DeserializeOwned,
{
    serde_json::from_value(intent.get(field).cloned().unwrap_or(Value::Null)).map_err(|error| {
        ResourceError::operation_failed(
            operation,
            "stored content effect target is malformed",
            json!({"resource":resource,"error":error.to_string()}),
        )
    })
}

fn optional_decimal(
    fields: &Map<String, Value>,
    field: &str,
) -> Result<Option<u64>, ResourceError> {
    fields
        .get(field)
        .map(|value| {
            serde_json::from_value::<WireDecimal>(value.clone()).map(WireDecimal::get).map_err(
                |error| {
                    validation_error(
                        "field must be an unsigned decimal string",
                        json!({"field":field,"error":error.to_string()}),
                    )
                },
            )
        })
        .transpose()
}

fn required_u64(fields: &Map<String, Value>, field: &str) -> Result<u64, ResourceError> {
    fields.get(field).and_then(Value::as_u64).ok_or_else(|| {
        validation_error("required unsigned integer field is missing", json!({"field":field}))
    })
}

fn required_i64(fields: &Map<String, Value>, field: &str) -> Result<i64, ResourceError> {
    fields.get(field).and_then(Value::as_i64).ok_or_else(|| {
        validation_error("required signed integer field is missing", json!({"field":field}))
    })
}

fn required_u64_action(fields: &Map<String, Value>, field: &str) -> Result<u64, ActionFailure> {
    required_u64(fields, field).map_err(ActionFailure::Known)
}

fn required_decimal_action(fields: &Map<String, Value>, field: &str) -> Result<u64, ActionFailure> {
    optional_decimal(fields, field).map_err(ActionFailure::Known)?.ok_or_else(|| {
        ActionFailure::Known(validation_error(
            "required unsigned decimal field is missing",
            json!({"field":field}),
        ))
    })
}

fn required_i64_action(fields: &Map<String, Value>, field: &str) -> Result<i64, ActionFailure> {
    required_i64(fields, field).map_err(ActionFailure::Known)
}

fn required_intent_string<'a>(
    fields: &'a Map<String, Value>,
    field: &str,
    operation: &str,
) -> Result<&'a str, ActionFailure> {
    fields.get(field).and_then(Value::as_str).ok_or_else(|| {
        ActionFailure::Known(ResourceError::operation_failed(
            operation,
            "stored content effect string is malformed",
            json!({"field":field}),
        ))
    })
}

fn intent_string_array(
    fields: &Map<String, Value>,
    field: &str,
    operation: &str,
) -> Result<Vec<String>, ActionFailure> {
    fields
        .get(field)
        .and_then(Value::as_array)
        .ok_or_else(|| {
            ActionFailure::Known(ResourceError::operation_failed(
                operation,
                "stored content effect array is malformed",
                json!({"field":field}),
            ))
        })?
        .iter()
        .map(|value| {
            value.as_str().map(str::to_string).ok_or_else(|| {
                ActionFailure::Known(ResourceError::operation_failed(
                    operation,
                    "stored content effect array item is malformed",
                    json!({"field":field}),
                ))
            })
        })
        .collect()
}

fn required_f64(fields: &Map<String, Value>, field: &str) -> Result<f64, ActionFailure> {
    fields.get(field).and_then(Value::as_f64).filter(|value| value.is_finite()).ok_or_else(|| {
        ActionFailure::Known(validation_error(
            "stored browser coordinate is invalid",
            json!({"field":field}),
        ))
    })
}

fn terminal_modifiers(fields: &Map<String, Value>) -> Result<Mods, ActionFailure> {
    let mut mods = Mods::default();
    for modifier in optional_modifier_array(fields)? {
        mods = mods
            | match modifier {
                "shift" => Mods::SHIFT,
                "control" => Mods::CTRL,
                "alt" => Mods::ALT,
                "meta" => Mods::SUPER,
                _ => {
                    return Err(ActionFailure::Known(validation_error(
                        "stored input modifier is invalid",
                        json!({"modifier":modifier}),
                    )));
                }
            };
    }
    Ok(mods)
}

fn browser_modifiers(fields: &Map<String, Value>) -> Result<u32, ActionFailure> {
    let mut modifiers = 0;
    for modifier in optional_modifier_array(fields)? {
        modifiers |= match modifier {
            "alt" => 1,
            "control" => 2,
            "meta" => 4,
            "shift" => 8,
            _ => {
                return Err(ActionFailure::Known(validation_error(
                    "stored input modifier is invalid",
                    json!({"modifier":modifier}),
                )));
            }
        };
    }
    Ok(modifiers)
}

fn optional_modifier_array(fields: &Map<String, Value>) -> Result<Vec<&str>, ActionFailure> {
    fields
        .get("modifiers")
        .map(|value| {
            value
                .as_array()
                .ok_or_else(|| {
                    ActionFailure::Known(validation_error(
                        "stored input modifiers are invalid",
                        json!({}),
                    ))
                })?
                .iter()
                .map(|value| {
                    value.as_str().ok_or_else(|| {
                        ActionFailure::Known(validation_error(
                            "stored input modifier is invalid",
                            json!({}),
                        ))
                    })
                })
                .collect()
        })
        .transpose()
        .map(|modifiers| modifiers.unwrap_or_default())
}

fn terminal_mouse_button(value: &str) -> Result<MouseButton, ActionFailure> {
    match value {
        "left" => Ok(MouseButton::Left),
        "middle" => Ok(MouseButton::Middle),
        "right" => Ok(MouseButton::Right),
        _ => Err(ActionFailure::Known(validation_error(
            "stored terminal mouse button is invalid",
            json!({"button":value}),
        ))),
    }
}

struct BrowserKeyDescription {
    key: String,
    code: String,
    windows_virtual_key_code: u32,
    text: Option<String>,
}

fn browser_key_event_values(
    key: &BrowserKeyDescription,
    modifiers: u32,
) -> (String, Option<String>) {
    // CDP treats `text` as the characters to insert, bypassing shortcut
    // interpretation. Alt, control, and meta chords must omit it so browser
    // accelerators such as Meta-C are dispatched instead of typing "c".
    if modifiers & (1 | 2 | 4) != 0 {
        return (key.key.clone(), None);
    }
    let mut event_key = key.key.clone();
    let mut text = key.text.clone();
    if modifiers & 8 != 0
        && let Some(character) = text
            .as_deref()
            .filter(|text| text.len() == 1)
            .and_then(|text| text.as_bytes().first())
            .copied()
            .filter(u8::is_ascii_lowercase)
    {
        let uppercase = char::from(character.to_ascii_uppercase()).to_string();
        event_key.clone_from(&uppercase);
        text = Some(uppercase);
    }
    (event_key, text)
}

fn browser_key_description(value: &str) -> BrowserKeyDescription {
    let lowercase = value.to_ascii_lowercase();
    let canonical = match lowercase.as_str() {
        "enter" | "return" => "Enter",
        "tab" => "Tab",
        "backspace" => "Backspace",
        "esc" | "escape" => "Escape",
        "delete" => "Delete",
        "insert" => "Insert",
        "home" => "Home",
        "end" => "End",
        "pageup" | "page-up" => "PageUp",
        "pagedown" | "page-down" => "PageDown",
        "left" | "arrow-left" | "arrowleft" => "ArrowLeft",
        "up" | "arrow-up" | "arrowup" => "ArrowUp",
        "right" | "arrow-right" | "arrowright" => "ArrowRight",
        "down" | "arrow-down" | "arrowdown" => "ArrowDown",
        "space" | "spacebar" => " ",
        _ => value,
    };
    let named = match canonical {
        "Enter" => Some(("Enter", 13)),
        "Tab" => Some(("Tab", 9)),
        "Backspace" => Some(("Backspace", 8)),
        "Escape" => Some(("Escape", 27)),
        "Delete" => Some(("Delete", 46)),
        "Insert" => Some(("Insert", 45)),
        "Home" => Some(("Home", 36)),
        "End" => Some(("End", 35)),
        "PageUp" => Some(("PageUp", 33)),
        "PageDown" => Some(("PageDown", 34)),
        "ArrowLeft" => Some(("ArrowLeft", 37)),
        "ArrowUp" => Some(("ArrowUp", 38)),
        "ArrowRight" => Some(("ArrowRight", 39)),
        "ArrowDown" => Some(("ArrowDown", 40)),
        " " => Some(("Space", 32)),
        _ => None,
    };
    if let Some((code, vkey)) = named {
        return BrowserKeyDescription {
            key: canonical.to_string(),
            code: code.to_string(),
            windows_virtual_key_code: vkey,
            text: (canonical == " ").then(|| " ".to_string()),
        };
    }
    if let Some(number) = canonical
        .strip_prefix('F')
        .or_else(|| canonical.strip_prefix('f'))
        .and_then(|value| value.parse::<u32>().ok())
        && (1..=24).contains(&number)
    {
        let name = format!("F{number}");
        return BrowserKeyDescription {
            key: name.clone(),
            code: name,
            windows_virtual_key_code: 111 + number,
            text: None,
        };
    }
    if canonical.chars().count() == 1 {
        let character = canonical.chars().next().expect("counted one character");
        let (code, vkey) = if character.is_ascii_alphabetic() {
            (
                format!("Key{}", character.to_ascii_uppercase()),
                u32::from(character.to_ascii_uppercase()),
            )
        } else if character.is_ascii_digit() {
            (format!("Digit{character}"), u32::from(character))
        } else {
            (String::new(), u32::from(character))
        };
        return BrowserKeyDescription {
            key: canonical.to_string(),
            code,
            windows_virtual_key_code: vkey,
            text: Some(canonical.to_string()),
        };
    }
    BrowserKeyDescription {
        key: canonical.to_string(),
        code: canonical.to_string(),
        windows_virtual_key_code: 0,
        text: None,
    }
}

#[cfg(target_os = "macos")]
fn direct_child_pids(pid: u32) -> Vec<u32> {
    let Ok(pid) = libc::pid_t::try_from(pid) else {
        return Vec::new();
    };
    // SAFETY: the discovery call receives a null buffer as required by
    // libproc. The second call writes at most `children.len()` pid_t values
    // into an initialized, correctly aligned allocation.
    let count = unsafe { libc::proc_listchildpids(pid, std::ptr::null_mut(), 0) };
    let Ok(count) = usize::try_from(count) else {
        return Vec::new();
    };
    if count == 0 {
        return Vec::new();
    }
    let mut children = vec![0 as libc::pid_t; count];
    let Ok(bytes) = libc::c_int::try_from(children.len().saturating_mul(size_of::<libc::pid_t>()))
    else {
        return Vec::new();
    };
    // SAFETY: `children` owns a writable buffer of exactly `bytes` bytes.
    let written = unsafe { libc::proc_listchildpids(pid, children.as_mut_ptr().cast(), bytes) };
    let Ok(written) = usize::try_from(written) else {
        return Vec::new();
    };
    children
        .into_iter()
        .take(written.min(count))
        .filter(|child| *child > 0)
        .filter_map(|child| u32::try_from(child).ok())
        .collect()
}

#[cfg(target_os = "linux")]
fn direct_child_pids(pid: u32) -> Vec<u32> {
    std::fs::read_to_string(format!("/proc/{pid}/task/{pid}/children"))
        .ok()
        .into_iter()
        .flat_map(|children| {
            children
                .split_whitespace()
                .filter_map(|child| child.parse::<u32>().ok())
                .collect::<Vec<_>>()
        })
        .collect()
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn direct_child_pids(_pid: u32) -> Vec<u32> {
    Vec::new()
}

enum ActionFailure {
    Known(ResourceError),
    Indeterminate(String),
}

fn finish_action_failure(
    mux: &Arc<Mux>,
    prepared: PreparedEffect,
    failure: ActionFailure,
) -> Result<Value, ResourceError> {
    match failure {
        ActionFailure::Known(error) => effects::commit_known_failure(mux, prepared, error),
        ActionFailure::Indeterminate(_message) => Err(effects::mark_indeterminate(mux, prepared)),
    }
}

#[cfg(test)]
mod tests {
    use std::sync::mpsc;

    use super::*;
    use crate::SurfaceOptions;

    fn terminal_fixture(
        command: Option<Vec<String>>,
    ) -> (Arc<Mux>, Arc<Surface>, ResourceSelectors) {
        let mux = Mux::new_for_test(
            "content-router",
            SurfaceOptions { command, cols: 12, rows: 4, ..SurfaceOptions::default() },
        );
        let session = ResourceSelectors {
            machine: Some("current".to_string()),
            session: Some("current".to_string()),
            ..ResourceSelectors::default()
        };
        let created = super::super::topology::dispatch(
            &mux,
            parsed_request(
                "workspace.create",
                &session,
                json!({"initial_content":"terminal","name":"content"}),
                Some("create-terminal-content-fixture"),
            ),
        )
        .unwrap();
        let terminal_id =
            TerminalPublicId::parse(created["value"]["terminal_id"].as_str().unwrap()).unwrap();
        let surface_id =
            mux.resource_surface_for_terminal(&terminal_id).expect("created terminal is live");
        let surface = mux.surface(surface_id).expect("created terminal surface is live");
        let selectors = ResourceSelectors {
            machine: Some("current".to_string()),
            session: Some("current".to_string()),
            terminal: Some(terminal_id.to_string()),
            ..ResourceSelectors::default()
        };
        (mux, surface, selectors)
    }

    fn parsed_request(
        operation: &str,
        selectors: &ResourceSelectors,
        fields: Value,
        idempotency_key: Option<&str>,
    ) -> ParsedResourceRequest {
        let mut params = serde_json::to_value(selectors).unwrap().as_object().unwrap().clone();
        params.extend(fields.as_object().unwrap().clone());
        let mut envelope = json!({
            "protocol":"cmux.protocol/2",
            "type":"request",
            "id":format!("test-{operation}"),
            "operation":operation,
            "params":params,
        });
        if let Some(key) = idempotency_key {
            envelope["idempotency_key"] = json!(key);
        }
        super::super::parse_resource_request(&serde_json::to_string(&envelope).unwrap()).unwrap()
    }

    #[test]
    fn owns_every_non_stream_terminal_and_browser_content_operation() {
        let owned = [
            ResourceOperation::TerminalInputWrite,
            ResourceOperation::TerminalInputKeys,
            ResourceOperation::TerminalInputMouse,
            ResourceOperation::TerminalInputFocus,
            ResourceOperation::TerminalScreenRead,
            ResourceOperation::TerminalStateRead,
            ResourceOperation::TerminalHistoryRead,
            ResourceOperation::TerminalHistoryClear,
            ResourceOperation::TerminalWait,
            ResourceOperation::TerminalWaitExit,
            ResourceOperation::TerminalCopy,
            ResourceOperation::TerminalProcessGet,
            ResourceOperation::TerminalViewportScroll,
            ResourceOperation::TerminalMove,
            ResourceOperation::TerminalProject,
            ResourceOperation::TerminalClose,
            ResourceOperation::BrowserNavigate,
            ResourceOperation::BrowserBack,
            ResourceOperation::BrowserForward,
            ResourceOperation::BrowserReload,
            ResourceOperation::BrowserActivate,
            ResourceOperation::BrowserInputKey,
            ResourceOperation::BrowserInputText,
            ResourceOperation::BrowserInputMouse,
            ResourceOperation::BrowserInputWheel,
            ResourceOperation::BrowserClose,
        ];
        assert!(owned.into_iter().all(handles));
        assert!(!handles(ResourceOperation::TerminalAttach));
        assert!(!handles(ResourceOperation::BrowserAttach));
        assert!(!handles(ResourceOperation::TerminalViewerResize));
        assert!(!handles(ResourceOperation::BrowserViewerResize));
    }

    #[test]
    fn one_terminal_can_be_detached_reprojected_and_closed_explicitly() {
        let (mux, original, selectors) = terminal_fixture(None);
        let terminal_id = TerminalPublicId::parse(selectors.terminal.as_deref().unwrap()).unwrap();
        let initial = public_session_snapshot(&mux).unwrap();
        let terminal = initial["terminals"]
            .as_array()
            .unwrap()
            .iter()
            .find(|terminal| terminal["id"] == terminal_id.as_str())
            .unwrap();
        let original_tab = terminal["tab_ids"][0].as_str().unwrap().to_string();
        let pane_id = initial["tabs"]
            .as_array()
            .unwrap()
            .iter()
            .find(|tab| tab["id"] == original_tab)
            .unwrap()["pane_id"]
            .as_str()
            .unwrap()
            .to_string();
        let pane = ResourceSelectors {
            machine: Some("current".into()),
            session: Some("current".into()),
            pane: Some(pane_id.clone()),
            ..ResourceSelectors::default()
        };
        super::super::topology::dispatch(
            &mux,
            parsed_request(
                "tab.create_terminal",
                &pane,
                json!({}),
                Some("terminal-multiview-keeper"),
            ),
        )
        .unwrap();

        let destination = public_session_snapshot(&mux).unwrap();
        let workspace_id = destination["workspaces"][0]["id"].as_str().unwrap();
        let screen_id = destination["screens"][0]["id"].as_str().unwrap();
        let active_before_projection = mux.active_surface();
        let projected = dispatch(
            &mux,
            parsed_request(
                "terminal.project",
                &selectors,
                json!({
                    "destination_workspace":workspace_id,
                    "destination_screen":screen_id,
                    "destination_pane":pane_id,
                    "index":1,
                    "name":"mirror",
                }),
                Some("terminal-multiview-project"),
            ),
        )
        .unwrap();
        assert_eq!(projected["value"]["focused"], false);
        assert_eq!(mux.active_surface(), active_before_projection);
        let projected_tab = projected["value"]["id"].as_str().unwrap().to_string();
        let placements = mux.with_state(|state| {
            state.placements_of_content(&ContentPublicId::Terminal(terminal_id.clone())).to_vec()
        });
        assert_eq!(placements.len(), 2);
        let mirror = mux.surface(placements[1]).unwrap();
        assert!(original.shares_terminal_runtime(&mirror));
        let terminal = public_session_snapshot(&mux).unwrap()["terminals"]
            .as_array()
            .unwrap()
            .iter()
            .find(|terminal| terminal["id"] == terminal_id.as_str())
            .unwrap()
            .clone();
        assert_eq!(terminal["tab_ids"].as_array().unwrap().len(), 2);

        for (index, tab) in [original_tab, projected_tab].into_iter().enumerate() {
            let tab_selectors = ResourceSelectors {
                machine: Some("current".into()),
                session: Some("current".into()),
                tab: Some(tab),
                ..ResourceSelectors::default()
            };
            super::super::topology::dispatch(
                &mux,
                parsed_request(
                    "tab.close",
                    &tab_selectors,
                    json!({}),
                    Some(&format!("terminal-multiview-detach-{index}")),
                ),
            )
            .unwrap();
        }

        let detached = public_session_snapshot(&mux).unwrap();
        let terminal = detached["terminals"]
            .as_array()
            .unwrap()
            .iter()
            .find(|terminal| terminal["id"] == terminal_id.as_str())
            .unwrap();
        assert!(terminal["tab_id"].is_null());
        assert_eq!(terminal["tab_ids"], json!([]));
        assert!(mux.surface(original.id).is_some());
        assert!(
            dispatch(&mux, parsed_request("terminal.screen.read", &selectors, json!({}), None),)
                .is_ok()
        );

        let reprojected = dispatch(
            &mux,
            parsed_request(
                "terminal.project",
                &selectors,
                json!({
                    "destination_workspace":workspace_id,
                    "destination_screen":screen_id,
                    "destination_pane":pane_id,
                    "index":1,
                }),
                Some("terminal-multiview-reproject"),
            ),
        )
        .unwrap();
        assert_eq!(reprojected["value"]["content_id"], terminal_id.as_str());
        dispatch(
            &mux,
            parsed_request(
                "terminal.project",
                &selectors,
                json!({
                    "destination_workspace":workspace_id,
                    "destination_screen":screen_id,
                    "destination_pane":pane_id,
                    "index":2,
                    "name":"second mirror",
                }),
                Some("terminal-multiview-second-reproject"),
            ),
        )
        .unwrap();
        assert_eq!(
            mux.with_state(|state| state
                .placements_of_content(&ContentPublicId::Terminal(terminal_id.clone()))
                .len()),
            2
        );

        let before_close = mux.with_state(|state| state.resource_revision);
        dispatch(
            &mux,
            parsed_request(
                "terminal.close",
                &selectors,
                json!({}),
                Some("terminal-multiview-explicit-close"),
            ),
        )
        .unwrap();
        let close_events = mux.resource_events_after(before_close).unwrap();
        assert_eq!(close_events.batches.len(), 1);
        let close_changes = close_events.batches[0].changes.as_array().unwrap();
        assert_eq!(
            close_changes
                .iter()
                .filter(|change| {
                    change["kind"] == "delete"
                        && change["resource"] == "terminal"
                        && change["id"] == terminal_id.as_str()
                })
                .count(),
            1
        );
        assert_eq!(
            close_changes
                .iter()
                .filter(|change| change["kind"] == "delete" && change["resource"] == "tab")
                .count(),
            2
        );
        assert!(
            public_session_snapshot(&mux).unwrap()["terminals"]
                .as_array()
                .unwrap()
                .iter()
                .all(|terminal| terminal["id"] != terminal_id.as_str())
        );
        assert!(mux.surface(original.id).is_none());
    }

    #[test]
    fn terminal_wait_coalesces_more_than_attach_capacity_without_losing_a_later_match() {
        let (mux, surface, selectors) = terminal_fixture(Some(vec!["fake-shell".into()]));
        let request = parsed_request(
            "terminal.wait",
            &selectors,
            json!({"pattern":"READY","timeout_ms":"2000"}),
            None,
        );
        let waiting_mux = mux;
        let waiter = std::thread::spawn(move || dispatch(&waiting_mux, request));

        let waiting_deadline = Instant::now() + Duration::from_secs(1);
        while surface.terminal_stream_waiter_count_for_test() != Some(1) {
            assert!(Instant::now() < waiting_deadline, "terminal wait did not subscribe");
            std::thread::yield_now();
        }
        for _ in 0..300 {
            surface.apply_stream_output_for_test(b"\r").unwrap();
        }
        surface.apply_stream_output_for_test(b"READY").unwrap();

        let result = waiter.join().unwrap().unwrap();
        assert_eq!(result["matched"], true, "wait lost the post-burst match: {result}");
        assert!(result["text"].as_str().unwrap().contains("READY"));
    }

    #[test]
    fn terminal_wait_rechecks_after_resize_reflows_visible_text() {
        let (mux, surface, selectors) = terminal_fixture(Some(vec!["fake-shell".into()]));
        surface.apply_stream_output_for_test(b"abcdefghij").unwrap();
        let request = parsed_request(
            "terminal.wait",
            &selectors,
            json!({"pattern":"abcde\\nfghij","timeout_ms":"2000"}),
            None,
        );
        let waiting_mux = mux;
        let waiter = std::thread::spawn(move || dispatch(&waiting_mux, request));

        let waiting_deadline = Instant::now() + Duration::from_secs(1);
        while surface.terminal_stream_waiter_count_for_test() != Some(1) {
            assert!(Instant::now() < waiting_deadline, "terminal wait did not subscribe");
            std::thread::yield_now();
        }
        assert!(surface.resize(5, 4).unwrap(), "fixture resize was unexpectedly unchanged");

        let result = waiter.join().unwrap().unwrap();
        assert_eq!(result["matched"], true, "wait ignored resize reflow: {result}");
    }

    #[test]
    fn terminal_wait_exit_wakes_on_its_durable_terminal_event() {
        let (mux, _surface, selectors) = terminal_fixture(Some(vec!["fake-shell".into()]));
        let public_id = TerminalPublicId::parse(selectors.terminal.as_deref().unwrap()).unwrap();
        mux.reset_terminal_exit_state_query_count_for_test();
        let request =
            parsed_request("terminal.wait_exit", &selectors, json!({"timeout_ms":"2000"}), None);
        let waiting_mux = mux.clone();
        let waiter = std::thread::spawn(move || dispatch(&waiting_mux, request));

        let waiting_deadline = Instant::now() + Duration::from_secs(1);
        while mux.terminal_exit_waiter_count_for_test(&public_id) != 1
            || mux.terminal_exit_state_query_count_for_test() != 1
        {
            assert!(Instant::now() < waiting_deadline, "exit wait did not subscribe");
            std::thread::yield_now();
        }
        let exit = crate::terminal_host_protocol::TerminalExit {
            outcome: crate::terminal_host_protocol::TerminalExitOutcome::Exit { code: 23 },
            exited_at_ms: 2_345_678,
        };
        assert!(mux.persist_terminal_exit_for_test(&public_id, &exit).unwrap());

        let result = waiter.join().unwrap().unwrap();
        assert_eq!(result["state"], "exited", "exit notification did not settle wait: {result}");
        assert_eq!(result["outcome"], json!({"kind":"exit","code":23}));
        assert_eq!(mux.terminal_exit_state_query_count_for_test(), 2);
        assert_eq!(mux.terminal_exit_waiter_count_for_test(&public_id), 0);
    }

    #[test]
    fn terminal_wait_exit_wakes_when_a_concurrent_terminal_close_tombstones_it() {
        let (mux, _surface, selectors) = terminal_fixture(Some(vec!["fake-shell".into()]));
        let public_id = TerminalPublicId::parse(selectors.terminal.as_deref().unwrap()).unwrap();
        mux.reset_terminal_exit_state_query_count_for_test();
        let request = parsed_request("terminal.wait_exit", &selectors, json!({}), None);
        let waiting_mux = mux.clone();
        let (settled_tx, settled_rx) = mpsc::sync_channel(1);
        std::thread::spawn(move || {
            let _ = settled_tx.send(dispatch(&waiting_mux, request));
        });

        let waiting_deadline = Instant::now() + Duration::from_secs(1);
        while mux.terminal_exit_waiter_count_for_test(&public_id) != 1
            || mux.terminal_exit_state_query_count_for_test() != 1
        {
            assert!(Instant::now() < waiting_deadline, "exit wait did not subscribe");
            std::thread::yield_now();
        }
        let closed = dispatch(
            &mux,
            parsed_request("terminal.close", &selectors, json!({}), Some("close-waited-terminal")),
        )
        .unwrap();
        assert_eq!(closed["replayed"], false);

        let error = settled_rx
            .recv_timeout(Duration::from_secs(1))
            .expect("terminal close stranded an unbounded exit wait")
            .unwrap_err();
        assert_eq!(error.code, "terminal.closed");
        assert_eq!(error.details["terminal_id"], public_id.as_str());
        assert_eq!(mux.terminal_exit_state_query_count_for_test(), 2);
        assert_eq!(mux.terminal_exit_waiter_count_for_test(&public_id), 0);
    }

    #[test]
    fn terminal_wait_exit_latches_one_public_event_without_host_identity() {
        let (mux, surface, selectors) = terminal_fixture(Some(vec!["fake-shell".into()]));
        let public_id = TerminalPublicId::parse(selectors.terminal.as_deref().unwrap()).unwrap();
        let tab_id = mux.with_state(|state| state.resource_indexes.tab_ids[&surface.id].clone());
        let durable = mux.terminal_registry_snapshot().unwrap();
        let internal = durable.terminals.first().expect("fixture has one durable terminal");
        let internal_id = internal.terminal_id.as_str();
        let incarnation = internal.incarnation.as_deref().unwrap_or_default();
        let pending = dispatch(
            &mux,
            parsed_request("terminal.wait_exit", &selectors, json!({"timeout_ms":"0"}), None),
        )
        .unwrap();
        assert_eq!(pending["state"], "pending");
        assert_eq!(pending["terminal_id"], public_id.as_str());
        assert!(pending.get("incarnation").is_none());
        let before = pending["revision"].as_str().unwrap().parse::<u64>().unwrap();

        let exit = crate::terminal_host_protocol::TerminalExit {
            outcome: crate::terminal_host_protocol::TerminalExitOutcome::Signal {
                signal: libc::SIGTERM,
                core_dumped: false,
            },
            exited_at_ms: 1_234_567,
        };
        assert!(mux.persist_terminal_exit_for_test(&public_id, &exit).unwrap());
        assert!(
            !mux.persist_terminal_exit_for_test(&public_id, &exit).unwrap(),
            "duplicate observations must not mint another revision"
        );

        let exited = dispatch(
            &mux,
            parsed_request("terminal.wait_exit", &selectors, json!({"timeout_ms":"1000"}), None),
        )
        .unwrap();
        assert_eq!(
            exited,
            json!({
                "state":"exited",
                "terminal_id":public_id,
                "lifecycle":"exited",
                "outcome":{"kind":"signal","signal":libc::SIGTERM,"core_dumped":false},
                "exited_at":"1234567",
                "revision":(before + 1).to_string(),
            })
        );

        let events = mux.resource_events_after(before).unwrap();
        assert_eq!(events.batches.len(), 1);
        let changes = events.batches[0].changes.as_array().unwrap();
        assert_eq!(changes[0]["kind"], "upsert");
        assert_eq!(changes[0]["sequence"], 0);
        assert_eq!(changes[0]["resource"], "terminal");
        assert_eq!(changes[0]["id"], public_id.as_str());
        assert_eq!(changes[0]["value"]["lifecycle"], "exited");
        assert_eq!(changes[0]["value"]["exit"]["outcome"], exited["outcome"]);
        assert!(changes.iter().enumerate().all(|(sequence, change)| {
            change["sequence"].as_u64() == u64::try_from(sequence).ok()
        }));
        assert!(changes.iter().any(|change| {
            change["kind"] == "delete"
                && change["resource"] == "tab"
                && change["id"] == tab_id.as_str()
        }));
        assert!(!changes.iter().any(|change| {
            change["kind"] == "delete"
                && change["resource"] == "terminal"
                && change["id"] == public_id.as_str()
        }));
        let public_json = serde_json::to_string(changes).unwrap();
        assert!(!public_json.contains("\"incarnation\""));
        assert!(!public_json.contains(internal_id));
        assert!(incarnation.is_empty() || !public_json.contains(incarnation));

        let snapshot = public_session_snapshot(&mux).unwrap();
        let terminal = snapshot["terminals"]
            .as_array()
            .unwrap()
            .iter()
            .find(|terminal| terminal["id"] == public_id.as_str())
            .expect("exited terminal receipt remains publicly addressable");
        assert_eq!(terminal["lifecycle"], "exited");
        assert_eq!(terminal["tab_id"], Value::Null);
        assert_eq!(terminal["tab_ids"], json!([]));
        assert_eq!(terminal["exit"]["outcome"], exited["outcome"]);
        assert!(mux.surface(surface.id).is_none());
    }

    #[cfg(unix)]
    #[test]
    fn terminal_wait_exit_resolves_detached_id_after_exit_upsert() {
        let (mux, _surface, selectors) = terminal_fixture(Some(vec!["fake-shell".into()]));
        let public_id = TerminalPublicId::parse(selectors.terminal.as_deref().unwrap()).unwrap();
        let before = public_session_snapshot(&mux).unwrap()["cursor"]["revision"]
            .as_str()
            .unwrap()
            .parse::<u64>()
            .unwrap();
        let exit = crate::terminal_host_protocol::TerminalExit {
            outcome: crate::terminal_host_protocol::TerminalExitOutcome::Signal {
                signal: libc::SIGTERM,
                core_dumped: true,
            },
            exited_at_ms: 3_456_789,
        };
        assert!(mux.persist_terminal_exit_for_test(&public_id, &exit).unwrap());

        let exited = dispatch(
            &mux,
            parsed_request("terminal.wait_exit", &selectors, json!({"timeout_ms":"0"}), None),
        )
        .unwrap();
        assert_eq!(exited["state"], "exited");
        assert_eq!(
            exited["outcome"],
            json!({"kind":"signal","signal":libc::SIGTERM,"core_dumped":true})
        );
        assert_eq!(exited["exited_at"], "3456789");

        let snapshot = public_session_snapshot(&mux).unwrap();
        let terminals = snapshot["terminals"].as_array().unwrap();
        assert_eq!(terminals.len(), 1);
        let terminal = &terminals[0];
        assert_eq!(terminal["id"], public_id.as_str());
        assert_eq!(terminal["lifecycle"], "exited");
        assert_eq!(terminal["running"], false);
        assert_eq!(terminal["tab_id"], Value::Null);
        assert_eq!(terminal["tab_ids"], json!([]));
        assert_eq!(terminal["exit"]["outcome"], exited["outcome"]);
        assert_eq!(terminal["exit"]["exited_at"], exited["exited_at"]);
        let events = mux.resource_events_after(before).unwrap();
        assert_eq!(events.batches.len(), 1);
        let exit_changes = events.batches[0].changes.as_array().unwrap();
        let exit_upsert = exit_changes
            .iter()
            .find(|change| {
                change["resource"] == "terminal"
                    && change["id"] == public_id.as_str()
                    && change["kind"] == "upsert"
            })
            .expect("exit batch omitted the terminal upsert");
        assert_eq!(exit_upsert["value"]["lifecycle"], "exited");
        assert_eq!(exit_upsert["value"]["exit"]["outcome"], exited["outcome"]);
        assert_eq!(exit_upsert["sequence"], 0);
        assert!(!exit_changes.iter().any(|change| {
            change["resource"] == "terminal"
                && change["id"] == public_id.as_str()
                && change["kind"] == "delete"
        }));

        let mut stale_nested = selectors.clone();
        stale_nested.pane = Some("pane_00000000000000000000000000000001".into());
        let error = dispatch(
            &mux,
            parsed_request("terminal.wait_exit", &stale_nested, json!({"timeout_ms":"0"}), None),
        )
        .unwrap_err();
        assert_eq!(error.code, "selector.not_found");

        let mut unknown = selectors;
        unknown.terminal = Some("term_ffffffffffffffffffffffffffffffff".into());
        let error = dispatch(
            &mux,
            parsed_request("terminal.wait_exit", &unknown, json!({"timeout_ms":"0"}), None),
        )
        .unwrap_err();
        assert_eq!(error.code, "selector.not_found");
    }

    #[test]
    fn browser_key_mapping_preserves_text_and_named_key_identity() {
        let letter = browser_key_description("a");
        assert_eq!(letter.key, "a");
        assert_eq!(letter.code, "KeyA");
        assert_eq!(letter.windows_virtual_key_code, 65);
        assert_eq!(letter.text.as_deref(), Some("a"));

        let arrow = browser_key_description("ArrowLeft");
        assert_eq!(arrow.key, "ArrowLeft");
        assert_eq!(arrow.code, "ArrowLeft");
        assert_eq!(arrow.windows_virtual_key_code, 37);
        assert_eq!(arrow.text, None);

        let space = browser_key_description("Space");
        assert_eq!(space.key, " ");
        assert_eq!(space.code, "Space");
        assert_eq!(space.windows_virtual_key_code, 32);
        assert_eq!(space.text.as_deref(), Some(" "));

        let function = browser_key_description("F12");
        assert_eq!(function.key, "F12");
        assert_eq!(function.code, "F12");
        assert_eq!(function.windows_virtual_key_code, 123);
        assert_eq!(function.text, None);

        assert_eq!(browser_key_event_values(&letter, 0), ("a".into(), Some("a".into())));
        assert_eq!(browser_key_event_values(&letter, 8), ("A".into(), Some("A".into())));
        assert_eq!(browser_key_event_values(&letter, 1), ("a".into(), None));
        assert_eq!(browser_key_event_values(&letter, 2), ("a".into(), None));
        assert_eq!(browser_key_event_values(&letter, 4), ("a".into(), None));
    }

    #[test]
    fn finds_the_exact_browser_upsert_in_a_typed_delta_batch() {
        let expected = json!({
            "id":"browser_00000000000000000000000000000001",
            "url":"https://example.test",
        });
        let changes = json!([
            {
                "kind":"upsert",
                "sequence":0,
                "resource":"terminal",
                "id":"term_00000000000000000000000000000002",
                "value":{"id":"term_00000000000000000000000000000002"},
            },
            {
                "kind":"upsert",
                "sequence":1,
                "resource":"browser",
                "id":"browser_00000000000000000000000000000001",
                "value":expected,
            },
        ]);
        assert_eq!(
            find_upsert_change(&changes, "browser", "browser_00000000000000000000000000000001"),
            Some(expected)
        );
        assert_eq!(
            find_upsert_change(&changes, "browser", "browser_00000000000000000000000000000003"),
            None
        );
    }

    #[test]
    fn targeted_browser_projection_emits_only_the_browser_delta() {
        let mux = Mux::new_for_test("browser-effect-projection", SurfaceOptions::default());
        let session = ResourceSelectors {
            machine: Some("current".to_string()),
            session: Some("current".to_string()),
            ..ResourceSelectors::default()
        };
        let created = super::super::topology::dispatch(
            &mux,
            parsed_request(
                "tab.create_browser",
                &session,
                json!({"url":"about:blank"}),
                Some("create-browser-content-fixture"),
            ),
        )
        .unwrap();
        let browser_id =
            BrowserPublicId::parse(created["value"]["browser_id"].as_str().unwrap()).unwrap();
        let (_, surface) =
            browser_surface_for_id(&mux, &browser_id).expect("created browser is live");
        let durable = mux
            .with_resource_projection(|registry, _| registry.resource_topology_snapshot())
            .unwrap();
        let durable_browser = durable
            .browsers
            .iter()
            .find(|browser| browser.public_id == browser_id)
            .expect("created browser is durable");
        assert_eq!(durable_browser.status, RegistryBrowserStatus::Starting);

        let projection = mux
            .with_resource_projection(|registry, state| {
                targeted_browser_effect_projection(registry, state, &browser_id, true)
            })
            .unwrap();
        let deltas = projection.changes.as_array().unwrap();
        assert_eq!(deltas.len(), 1);
        assert_eq!(deltas[0]["kind"], "upsert");
        assert_eq!(deltas[0]["resource"], "browser");
        assert_eq!(deltas[0]["id"], browser_id.as_str());
        assert_eq!(projection.patch.changes.len(), 2);
        assert!(matches!(
            &projection.patch.changes[0],
            ResourceChange::UpsertBrowser(browser) if browser.public_id == browser_id
        ));
        assert!(matches!(
            &projection.patch.changes[1],
            ResourceChange::UpsertTab(tab)
                if tab.content_id == ContentPublicId::Browser(browser_id.clone())
        ));
        surface.kill();
    }

    #[test]
    fn starting_browser_error_matches_catalog_contract() {
        let surface = crate::browser::new_surface(
            1,
            "about:blank".into(),
            (80, 24),
            (8, 16),
            &SurfaceOptions::default(),
            std::sync::Weak::new(),
        )
        .unwrap();
        let error = browser_not_ready_error(&surface, "browser.navigate");
        assert_eq!(error.code, "operation.failed");
        assert_eq!(error.details["operation"], "browser.navigate");
        assert_eq!(error.details["extra"]["status"], "starting");
        assert!(!error.retryable);
        surface.kill();
    }

    #[test]
    fn terminal_reads_match_catalog_shapes_and_preserve_argv_boundaries() {
        {
            let reserved =
                Mux::new_for_test("ordinary-terminal-projection", SurfaceOptions::default());
            let surface = reserved.new_workspace(Some("ordinary".into()), Some((12, 4))).unwrap();
            let projection = reserved.resource_effect_projection().unwrap();
            assert!(!projection.patch.changes.is_empty());
            surface.kill();
        }

        let (mux, surface, selectors) =
            terminal_fixture(Some(vec!["fake-shell".into(), "argument with spaces".into()]));
        surface
            .try_with_terminal(|terminal| terminal.vt_write(b"one\r\ntwo\r\nthree\r\nfour\r\nfive"))
            .unwrap();

        let screen =
            dispatch(&mux, parsed_request("terminal.screen.read", &selectors, json!({}), None))
                .unwrap();
        assert!(screen["text"].as_str().unwrap().contains("five"));
        assert_eq!(screen["cols"], 12);
        assert_eq!(screen["rows"], 4);
        assert!(screen["cursor_row"].is_u64());
        assert!(screen["cursor_col"].is_u64());
        assert!(screen["cursor_visible"].is_boolean());

        let state =
            dispatch(&mux, parsed_request("terminal.state.read", &selectors, json!({}), None))
                .unwrap();
        assert!(
            !base64::engine::general_purpose::STANDARD
                .decode(state["state_base64"].as_str().unwrap())
                .unwrap()
                .is_empty()
        );

        let history = dispatch(
            &mux,
            parsed_request(
                "terminal.history.read",
                &selectors,
                json!({"limit":2,"styled":true}),
                None,
            ),
        )
        .unwrap();
        assert!(history["start"].is_string());
        assert!(history["rows"].as_array().unwrap().len() <= 2);
        for row in history["rows"].as_array().unwrap() {
            assert!(row["row"].is_u64());
            for run in row["runs"].as_array().unwrap() {
                assert!(run["text"].is_string());
                assert!(run["attrs"].is_u64());
                assert!(run.get("fg").is_some());
                assert!(run.get("bg").is_some());
            }
        }

        let process =
            dispatch(&mux, parsed_request("terminal.process.get", &selectors, json!({}), None))
                .unwrap();
        assert_eq!(process["executable"], "fake-shell");
        assert_eq!(process["argv"], json!(["fake-shell", "argument with spaces"]));
        assert!(process["pid"].is_u64());
        assert!(process["children"].is_array());
        assert!(process.get("cwd").is_none_or(Value::is_string));
    }

    #[test]
    fn terminal_external_effect_replays_before_selector_resolution() {
        let (mux, _surface, selectors) = terminal_fixture(None);
        let input_revision = mux.with_state(|state| state.resource_revision);
        let input_terminal_revision = mux.terminal_registry_snapshot().unwrap().revision;
        let first = dispatch(
            &mux,
            parsed_request(
                "terminal.input.write",
                &selectors,
                json!({"text":"echo safe\n"}),
                Some("terminal-write-replay"),
            ),
        )
        .unwrap();
        assert_eq!(first["value"], json!({}));
        assert_eq!(first["replayed"], false);
        assert_eq!(first["revision"], input_revision.to_string());
        assert_eq!(mux.with_state(|state| state.resource_revision), input_revision);
        assert!(mux.resource_events_after(input_revision).unwrap().batches.is_empty());
        assert_eq!(mux.terminal_registry_snapshot().unwrap().revision, input_terminal_revision);

        let second = dispatch(
            &mux,
            parsed_request(
                "terminal.input.write",
                &selectors,
                json!({"text":"echo safe\n"}),
                Some("terminal-write-replay"),
            ),
        )
        .unwrap();
        assert_eq!(second["replayed"], true);
        assert_eq!(second["revision"], first["revision"]);
        assert_eq!(mux.with_state(|state| state.resource_revision), input_revision);
        assert!(mux.resource_events_after(input_revision).unwrap().batches.is_empty());

        let conflict = dispatch(
            &mux,
            parsed_request(
                "terminal.input.write",
                &selectors,
                json!({"text":"different payload\n"}),
                Some("terminal-write-replay"),
            ),
        )
        .unwrap_err();
        assert_eq!(conflict.code, "idempotency.conflict");
        assert_eq!(mux.with_state(|state| state.resource_revision), input_revision);

        let before_resource = first["revision"].as_str().unwrap().parse::<u64>().unwrap();
        let before_terminal = mux.terminal_registry_snapshot().unwrap().revision;
        let closed = dispatch(
            &mux,
            parsed_request("terminal.close", &selectors, json!({}), Some("terminal-close-replay")),
        )
        .unwrap();
        assert_eq!(closed["replayed"], false);
        assert_eq!(public_session_snapshot(&mux).unwrap()["terminals"], json!([]));
        assert_eq!(mux.with_state(|state| state.resource_revision), before_resource + 1);
        assert_eq!(mux.resource_events_after(before_resource).unwrap().batches.len(), 1);
        let (terminal_snapshot, terminal_events) =
            mux.terminal_registry_events_page(before_terminal).unwrap();
        assert_eq!(terminal_snapshot.revision, before_terminal + 1);
        assert_eq!(terminal_events.len(), 1);
        assert_eq!(terminal_events[0].kind, "terminal-closed");

        let replay = dispatch(
            &mux,
            parsed_request("terminal.close", &selectors, json!({}), Some("terminal-close-replay")),
        )
        .unwrap();
        assert_eq!(replay["replayed"], true);
        assert_eq!(replay["revision"], closed["revision"]);
        assert_eq!(mux.resource_events_after(before_resource).unwrap().batches.len(), 1);
        assert_eq!(mux.terminal_registry_snapshot().unwrap().revision, before_terminal + 1);
    }

    #[test]
    fn terminal_viewport_scroll_uses_one_bounded_receipt_and_one_journal_outcome() {
        let (mux, surface, selectors) = terminal_fixture(None);
        surface
            .try_with_terminal(|terminal| {
                for index in 0..20 {
                    terminal.vt_write(format!("line-{index}\r\n").as_bytes());
                }
            })
            .unwrap();
        let bottom = surface.view_scrollbar().expect("fixture has scrollback");
        assert!(!bottom.scrolled_back());

        let revision = mux.with_state(|state| state.resource_revision);
        let terminal_revision = mux.terminal_registry_snapshot().unwrap().revision;
        let event_epoch = mux.resource_event_epoch();
        let journal_head = mux.session_journal_after(0, 1).unwrap().head_sequence;
        let mutation_count = mux.resource_mutation_count_for_test().unwrap();
        let request = || {
            parsed_request(
                "terminal.viewport.scroll",
                &selectors,
                json!({
                    "delta_rows":-2,
                    "expected_revision":revision.to_string(),
                }),
                Some("terminal-scroll-receipt"),
            )
        };

        let first = dispatch(&mux, request()).unwrap();
        assert_eq!(first["value"], json!({}));
        assert_eq!(first["revision"], revision.to_string());
        assert_eq!(first["replayed"], false);
        let after_first = surface.view_scrollbar().expect("fixture has scrollback");
        assert!(after_first.scrolled_back());
        assert!(after_first.offset < bottom.offset);
        assert_eq!(
            surface
                .try_with_terminal(|terminal| {
                    terminal.scrollbar().expect("fixture has scrollback")
                })
                .unwrap(),
            bottom,
            "a backend projection must not change the shared compatibility viewport"
        );
        assert_eq!(mux.with_state(|state| state.resource_revision), revision);
        assert_eq!(mux.terminal_registry_snapshot().unwrap().revision, terminal_revision);
        assert_eq!(mux.resource_event_epoch(), event_epoch + 1);
        assert!(mux.resource_events_after(revision).unwrap().batches.is_empty());
        assert_eq!(mux.resource_mutation_count_for_test().unwrap(), mutation_count);
        let journal = mux.session_journal_after(journal_head, 2).unwrap();
        assert_eq!(journal.records.len(), 1);
        assert_eq!(journal.records[0].kind, "terminal.viewport.scroll.effect.succeeded");
        let effect_sequence = journal.records[0].sequence;

        let replay = dispatch(&mux, request()).unwrap();
        assert_eq!(replay["value"], first["value"]);
        assert_eq!(replay["generation"], first["generation"]);
        assert_eq!(replay["revision"], first["revision"]);
        assert_eq!(replay["replayed"], true);
        assert_eq!(
            surface.view_scrollbar().expect("fixture has scrollback"),
            after_first,
            "receipt replay must not apply the viewport delta twice"
        );
        assert_eq!(mux.with_state(|state| state.resource_revision), revision);
        assert_eq!(mux.resource_event_epoch(), event_epoch + 1);
        assert!(mux.session_journal_after(effect_sequence, 1).unwrap().records.is_empty());
        assert_eq!(mux.resource_mutation_count_for_test().unwrap(), mutation_count);

        let closed = dispatch(
            &mux,
            parsed_request(
                "terminal.close",
                &selectors,
                json!({}),
                Some("terminal-scroll-close-target"),
            ),
        )
        .unwrap();
        assert_eq!(closed["revision"], (revision + 1).to_string());

        let replay_after_close = dispatch(&mux, request()).unwrap();
        assert_eq!(replay_after_close["value"], first["value"]);
        assert_eq!(replay_after_close["generation"], first["generation"]);
        assert_eq!(replay_after_close["revision"], first["revision"]);
        assert_eq!(replay_after_close["replayed"], true);

        let conflict = dispatch(
            &mux,
            parsed_request(
                "terminal.viewport.scroll",
                &selectors,
                json!({
                    "delta_rows":-3,
                    "expected_revision":revision.to_string(),
                }),
                Some("terminal-scroll-receipt"),
            ),
        )
        .unwrap_err();
        assert_eq!(conflict.code, "idempotency.conflict");

        let missing_before_stale_revision = dispatch(
            &mux,
            parsed_request(
                "terminal.viewport.scroll",
                &selectors,
                json!({
                    "delta_rows":-2,
                    "expected_revision":revision.to_string(),
                }),
                Some("terminal-scroll-new-receipt"),
            ),
        )
        .unwrap_err();
        assert_eq!(missing_before_stale_revision.code, "selector.not_found");
    }

    #[test]
    fn browser_close_commits_the_tab_and_browser_tombstones_once() {
        let mux = Mux::new_for_test("content-browser-close", SurfaceOptions::default());
        let session = ResourceSelectors {
            machine: Some("current".to_string()),
            session: Some("current".to_string()),
            ..ResourceSelectors::default()
        };
        let created = super::super::topology::dispatch(
            &mux,
            parsed_request(
                "tab.create_browser",
                &session,
                json!({"url":"about:blank#atomic-browser-close"}),
                Some("content-browser-create"),
            ),
        )
        .unwrap();
        let browser_id = created["value"]["browser_id"].as_str().unwrap().to_string();
        let selectors = ResourceSelectors {
            machine: Some("current".to_string()),
            session: Some("current".to_string()),
            browser: Some(browser_id),
            ..ResourceSelectors::default()
        };
        let before_resource = mux.with_state(|state| state.resource_revision);
        let before_terminal = mux.terminal_registry_snapshot().unwrap().revision;
        let request = || {
            parsed_request(
                "browser.close",
                &selectors,
                json!({}),
                Some("content-browser-close-effect"),
            )
        };

        let closed = dispatch(&mux, request()).unwrap();
        assert_eq!(closed["replayed"], false);
        assert_eq!(mux.with_state(|state| state.resource_revision), before_resource + 1);
        assert_eq!(mux.resource_events_after(before_resource).unwrap().batches.len(), 1);
        assert_eq!(mux.terminal_registry_snapshot().unwrap().revision, before_terminal);
        let snapshot = public_session_snapshot(&mux).unwrap();
        assert!(snapshot["browsers"].as_array().unwrap().is_empty());
        assert!(snapshot["tabs"].as_array().unwrap().is_empty());

        let replay = dispatch(&mux, request()).unwrap();
        assert_eq!(replay["replayed"], true);
        assert_eq!(replay["revision"], closed["revision"]);
        assert_eq!(mux.resource_events_after(before_resource).unwrap().batches.len(), 1);
        mux.shutdown();
    }

    #[test]
    fn terminal_move_of_a_panes_final_tab_collapses_the_source_pane() {
        let mux = Mux::new_for_test("content-terminal-move", SurfaceOptions::default());
        let session = ResourceSelectors {
            machine: Some("current".to_string()),
            session: Some("current".to_string()),
            ..ResourceSelectors::default()
        };
        let created = super::super::topology::dispatch(
            &mux,
            parsed_request(
                "workspace.create",
                &session,
                json!({"initial_content":"terminal","name":"move"}),
                Some("create-terminal-move-fixture"),
            ),
        )
        .unwrap();
        let destination_workspace = created["value"]["workspace_id"].as_str().unwrap().to_string();
        let destination_screen = created["value"]["screen_id"].as_str().unwrap().to_string();
        let destination_pane = created["value"]["pane_id"].as_str().unwrap().to_string();
        let destination_selectors = ResourceSelectors {
            machine: Some("current".to_string()),
            session: Some("current".to_string()),
            pane: Some(destination_pane.clone()),
            ..ResourceSelectors::default()
        };
        let source = super::super::topology::dispatch(
            &mux,
            parsed_request(
                "pane.split",
                &destination_selectors,
                json!({"direction":"right","ratio":0.5}),
                Some("split-terminal-move-fixture"),
            ),
        )
        .unwrap();
        let source_terminal =
            TerminalPublicId::parse(source["value"]["terminal_id"].as_str().unwrap()).unwrap();
        let source_selectors = ResourceSelectors {
            machine: Some("current".to_string()),
            session: Some("current".to_string()),
            terminal: Some(source_terminal.to_string()),
            ..ResourceSelectors::default()
        };

        let move_request = || {
            parsed_request(
                "terminal.move",
                &source_selectors,
                json!({
                    "destination_workspace":&destination_workspace,
                    "destination_screen":&destination_screen,
                    "destination_pane":&destination_pane,
                    "index":1,
                }),
                Some("terminal-final-tab-move"),
            )
        };
        let moved = dispatch(&mux, move_request()).unwrap();
        assert_eq!(moved["value"]["id"], source_terminal.as_str());
        assert_eq!(moved["replayed"], false);

        let after = public_session_snapshot(&mux).unwrap();
        assert_eq!(after["panes"].as_array().unwrap().len(), 1);
        assert_eq!(after["tabs"].as_array().unwrap().len(), 2);
        assert!(after["panes"][0]["focused"].as_bool().unwrap());

        dispatch(
            &mux,
            parsed_request(
                "terminal.close",
                &source_selectors,
                json!({}),
                Some("close-moved-terminal"),
            ),
        )
        .unwrap();
        let replay = dispatch(&mux, move_request()).unwrap();
        assert_eq!(replay["value"], moved["value"]);
        assert_eq!(replay["revision"], moved["revision"]);
        assert_eq!(replay["replayed"], true);
    }
}
