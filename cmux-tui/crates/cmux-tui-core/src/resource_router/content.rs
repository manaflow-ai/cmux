#[cfg(target_os = "macos")]
use std::mem::size_of;
use std::sync::Arc;
use std::time::{Duration, Instant};

use base64::Engine;
use cmux_json::JsonSet as _;
use ghostty_vt::{
    KeyEncoder, Mods, MouseAction, MouseButton, MouseInput, StyledRun, UnderlineStyle,
    key_input_from_chord, rows_to_runs,
};
use regex::Regex;
use serde_json::{Map, Value, json};

mod targeted_browser;
use targeted_browser::targeted_browser_effect_projection;

use super::effects::{self, EffectPreparation, PreparedEffect};
use super::{
    ParsedResourceRequest, required_string, resolve_terminal_wait_exit_id,
    resource_operation_error, validation_error,
};
use crate::browser::{BrowserSource, BrowserStatus};
use crate::model::State;
use crate::mux::{ResourceEffectProjection, TerminalCloseGuard, TerminalCloseGuardFailed};
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
            | ResourceOperation::TerminalOutputRead
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
        ResourceOperation::TerminalOutputRead => terminal_output_read(mux, &request),
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
    let snapshot = surface
        .terminal_screen_snapshot_with(screen_text(&request.fields)?)
        .map_err(resource_operation_error)?;
    Ok(json!({
        "text":snapshot.text,
        "cols":snapshot.cols,
        "rows":snapshot.rows,
        "cursor_row":snapshot.cursor_row,
        "cursor_col":snapshot.cursor_col,
        "cursor_visible":snapshot.cursor_visible,
        "revision":snapshot.revision.to_string(),
        "osc_progress":snapshot.osc_progress,
    }))
}

/// The text a `terminal.screen.read` asks for: `unwrap` joins soft wraps,
/// `lines` reads the last N lines of scrollback and screen instead of the
/// screen (`terminal-read-unwrap-v1`).
fn screen_text(fields: &Map<String, Value>) -> Result<crate::surface::ScreenText, ResourceError> {
    let unwrap = fields.get("unwrap").and_then(Value::as_bool).unwrap_or(false);
    let lines = fields.get("lines").and_then(Value::as_u64);
    Ok(match lines {
        Some(count) => crate::surface::ScreenText::LastLines {
            count: usize::try_from(count).map_err(|_| {
                validation_error("lines is too large", json!({"field":"lines","value":count}))
            })?,
            unwrap,
        },
        None if unwrap => crate::surface::ScreenText::Unwrapped,
        None => crate::surface::ScreenText::Rows,
    })
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
        "state_base64":base64::engine::general_purpose::STANDARD.encode(state.self_contained_bytes()),
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
            // start is at most `limit` rows before end, so the page fits in a u16.
            let count = u16::try_from(end.saturating_sub(start)).unwrap_or(limit);
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

/// Bounded plain-text window over one terminal's journaled output stream.
/// Unlike the other content reads it does not require a live surface: like
/// `terminal.wait_exit` it resolves through the durable exit receipt, so it
/// answers for exited terminals under both exit policies (kept views and detached ones).
fn terminal_output_read(
    mux: &Arc<Mux>,
    request: &ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let terminal_id = resolve_terminal_wait_exit_id(mux, &request.selectors)?;
    let after = optional_decimal(&request.fields, "after")?;
    // The catalog injects the default and enforces the 1..=4 MiB bounds.
    let max_bytes = required_u64(&request.fields, "max_bytes")?;
    mux.terminal_output_read(&terminal_id, after, max_bytes).map_err(|error| {
        // Journal failures can contain SQLite paths, trigger text, and other
        // host diagnostics. Keep those details in daemon logs; this resource
        // is user-facing and must return a stable, non-sensitive error.
        eprintln!("cmux-tui: terminal output read failed for {terminal_id}: {error:#}");
        ResourceError::operation_failed(
            "terminal.output_read",
            "could not read terminal output",
            json!({}),
        )
    })
}

fn terminal_wait(mux: &Arc<Mux>, request: &ParsedResourceRequest) -> Result<Value, ResourceError> {
    let (_, surface) = resolve_terminal_surface(mux, &request.selectors)?;
    let pattern = required_string(&request.fields, "pattern")?;
    let regex = crate::wait_pattern::compile(pattern).map_err(|error| {
        validation_error(
            &crate::wait_pattern::invalid_message(pattern, &error),
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
    // `new`: only text printed below the cursor's line as the wait starts
    // counts (`terminal-wait-new-v1`).
    let text = super::WaitText::start(&surface, &request.fields)?;
    wait_for_match(&surface, &regex, timeout, deadline, || text.read())
}

/// Re-reads `check` on every output change until `regex` matches it or
/// `deadline` passes; the `terminal.wait` result.
fn wait_for_match(
    surface: &Surface,
    regex: &Regex,
    timeout: Option<Duration>,
    deadline: Option<Instant>,
    check: impl Fn() -> Result<String, ResourceError>,
) -> Result<Value, ResourceError> {
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
    // `unwrap` joins soft-wrapped rows into the lines the program printed
    // (`terminal-read-unwrap-v1`); a selection keeps the app's own rules.
    let unwrap = request.fields.get("unwrap").and_then(Value::as_bool).unwrap_or(false);
    let text = match mode {
        "screen" => surface
            .try_with_terminal(|terminal| {
                if unwrap { terminal.active_text_unwrapped() } else { terminal.active_text() }
            })
            .map_err(resource_operation_error)?
            .map_err(|error| resource_operation_error(error.into()))?,
        "scrollback" => surface
            .try_with_terminal(|terminal| {
                if unwrap { terminal.plain_text_unwrapped() } else { terminal.plain_text() }
            })
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
        "foreground_cwd":crate::platform::foreground_cwd(pid),
        "foreground_executable":crate::platform::foreground_process_name(pid),
    });
    if let Some(executable) = executable {
        value.set("executable", json!(executable));
    }
    if let Some(cwd) = surface.local_cwd() {
        value.set("cwd", json!(cwd));
    }
    Ok(value)
}

fn terminal_effect(mux: &Arc<Mux>, request: ParsedResourceRequest) -> Result<Value, ResourceError> {
    validate_terminal_effect_fields(&request)?;
    let fields = request.fields.clone();
    let preparation = effects::prepare(mux, &request, || {
        // Explicit close is the only terminal effect that must keep working
        // after the runtime is gone: an exited terminal survives as a durable
        // receipt with zero views, and close is the one operation that
        // retires that receipt. Resolve it like `terminal.wait_exit` instead
        // of demanding a live surface.
        let terminal_id = if request.envelope.operation == ResourceOperation::TerminalClose {
            resolve_terminal_wait_exit_id(mux, &request.selectors)?
        } else {
            resolve_terminal_surface(mux, &request.selectors)?.0
        };
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
    if prepared.operation == "terminal.close" {
        // `if_unplaced`: end the terminal only when nothing shows it (no tab,
        // no `keep` mark, no attach stream), the reaper's rule without the
        // grace. A retained terminal is a stored known failure, so a retry
        // with the key answers the same.
        let guard = if fields.get("if_unplaced").and_then(Value::as_bool) == Some(true) {
            TerminalCloseGuard::UnplacedAndNotKept
        } else {
            TerminalCloseGuard::None
        };
        if guard == TerminalCloseGuard::UnplacedAndNotKept && mux.terminal_attached(&terminal_id) {
            return effects::commit_known_failure(mux, prepared, terminal_retained(&terminal_id));
        }
        let commit = mux.commit_resource_terminal_close_effect(
            &terminal_id,
            &prepared.idempotency_key,
            &prepared.operation,
            &prepared.fingerprint,
            guard,
        );
        if let Err(error) = &commit
            && error.downcast_ref::<TerminalCloseGuardFailed>().is_some()
        {
            return effects::commit_known_failure(mux, prepared, terminal_retained(&terminal_id));
        }
        return finish_projection_commit(mux, prepared, commit);
    }

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

    // Bytes queued for this terminal while it was being created go first.
    mux.wait_for_creating_input_flush(&surface);
    let action = match prepared.operation.as_str() {
        "terminal.input.write" => terminal_write(&surface, &fields),
        "terminal.input.keys" => terminal_keys(&surface, &fields),
        "terminal.input.mouse" => terminal_mouse(&surface, &fields),
        "terminal.input.focus" => terminal_focus(&surface, &fields),
        "terminal.history.clear" => {
            surface.clear_history().map_err(|error| ActionFailure::Indeterminate(error.to_string()))
        }
        "terminal.viewport.scroll" => terminal_scroll_viewport(mux, &surface, &fields),
        operation => Err(ActionFailure::Known(ResourceError::operation_failed(
            operation,
            "stored terminal effect operation is invalid",
            json!({}),
        ))),
    };
    if let Err(failure) = action {
        return finish_action_failure(mux, prepared, failure);
    }
    // The input's sequence point for `terminal wait --until idle`.
    if matches!(prepared.operation.as_str(), "terminal.input.write" | "terminal.input.keys") {
        surface.note_terminal_input();
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
            let operation = super::operation_name(request.envelope.operation);
            if mux.is_frontend_browser_surface(&surface) {
                return Err(browser_rendered_by_app_error(&surface, &browser_id, operation));
            }
            return Err(browser_not_ready_error(&surface, operation));
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
                .map_err(unconfirmed_browser_action),
            "browser.back" => surface.browser_back_confirmed().map_err(unconfirmed_browser_action),
            "browser.forward" => {
                surface.browser_forward_confirmed().map_err(unconfirmed_browser_action)
            }
            "browser.reload" => {
                surface.browser_reload_confirmed().map_err(unconfirmed_browser_action)
            }
            "browser.activate" => {
                surface.browser_activate_confirmed().map_err(unconfirmed_browser_action)
            }
            "browser.input.text" => surface
                .browser_insert_text_confirmed(required_intent_string(
                    &fields,
                    "text",
                    &prepared.operation,
                )?)
                .map_err(unconfirmed_browser_action),
            "browser.input.key" => browser_key(&surface, &fields),
            "browser.input.mouse" => browser_mouse(&surface, &fields),
            "browser.input.wheel" => browser_wheel(&surface, &fields),
            "browser.close" => {
                if surface.browser_source().is_some() {
                    surface.browser_close_confirmed().map_err(unconfirmed_browser_action)?;
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

/// The refusal of a browser effect on a browser the cmux app draws itself
/// (WebKit or CEF): the daemon has no automation session for that page. The
/// `extra.code` is `browser_rendered_by_app` and `extra.tab_id` names the
/// tab the app knows the page by, so the CLI and MCP run the verb through the
/// app's `browser.page.*` methods (`cli/app_browser_route.rs`).
fn browser_rendered_by_app_error(
    surface: &Surface,
    browser_id: &BrowserPublicId,
    operation: impl Into<String>,
) -> ResourceError {
    let tab_id = surface.resource_identity().map(|identity| identity.tab_id.as_str().to_string());
    ResourceError::operation_failed(
        operation,
        "the cmux app draws this browser, so the daemon cannot drive it; \
         run the command through the app (`cmux browser <tab_id> <verb>`)",
        json!({
            "code":"browser_rendered_by_app",
            "browser_id":browser_id.as_str(),
            "tab_id":tab_id,
            "status":surface.browser_status().as_ref().map(|status| status.as_str()),
        }),
    )
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

/// The `if_unplaced` close of a terminal that has a tab, is kept or is
/// attached: nothing changed.
fn terminal_retained(terminal_id: &TerminalPublicId) -> ResourceError {
    ResourceError::operation_failed(
        "terminal.close",
        "the terminal has a tab, is marked keep or is attached, so it was left running",
        json!({"terminal_retained":true,"terminal_id":terminal_id}),
    )
}

fn finish_projection_commit(
    mux: &Arc<Mux>,
    prepared: PreparedEffect,
    commit: anyhow::Result<crate::workspace_registry::ResourcePatchCommit>,
) -> Result<Value, ResourceError> {
    let commit = match commit {
        Ok(commit) => commit,
        Err(error) => {
            return Err(effects::mark_indeterminate(
                mux,
                prepared,
                &format!("the projection commit failed: {error:#}"),
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

fn confirmed_terminal_write(
    surface: &Surface,
    bytes: &[u8],
    operation: &str,
) -> Result<(), ActionFailure> {
    surface.write_bytes_confirmed(bytes).map_err(|error| confirmed_input_error(operation, error))
}

fn confirmed_input_error(
    operation: &str,
    error: crate::surface::ConfirmedInputFailure,
) -> ActionFailure {
    match error {
        crate::surface::ConfirmedInputFailure::Known(error) => {
            let message = match error.kind() {
                std::io::ErrorKind::InvalidInput => "terminal_input_too_large",
                std::io::ErrorKind::WouldBlock => "terminal_input_unavailable",
                std::io::ErrorKind::Unsupported => "terminal_input_confirmation_unsupported",
                _ => "terminal_input_delivery_failed",
            };
            ActionFailure::Known(ResourceError::operation_failed(operation, message, json!({})))
        }
        crate::surface::ConfirmedInputFailure::Indeterminate(error) => {
            // Raw transport text can name private sockets, so neither the
            // durable API response nor the daemon log gets it: the log gets
            // the error kind and OS code, which tell a missed InputAck
            // (TimedOut, ConnectionAborted) from a failed frame write.
            let cause = match error.raw_os_error() {
                Some(code) => {
                    format!("input delivery failed: {:?} (os error {code})", error.kind())
                }
                None => format!("input delivery failed: {:?}", error.kind()),
            };
            ActionFailure::Indeterminate(cause)
        }
    }
}

#[cfg(test)]
#[path = "confirmed_input_error_tests.rs"]
mod confirmed_input_error_tests;

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
    confirmed_terminal_write(surface, &bytes, "terminal.input.write")
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
                let input = key_input_from_chord(key)
                    .ok_or_else(|| validation_error(INVALID_CHORD, json!({"key":key})))?;
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
    confirmed_terminal_write(surface, &encoded, "terminal.input.keys")
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
    confirmed_terminal_write(surface, &output, "terminal.input.mouse")
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
    confirmed_terminal_write(surface, bytes, "terminal.input.focus")
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
            .map_err(unconfirmed_browser_action)
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
        .map_err(unconfirmed_browser_action)
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
        .map_err(unconfirmed_browser_action)
}

/// The refusal of a key the encoder does not know names the form it takes: the key
/// "ENTER" or "C-m" (tmux spelling) was refused with no hint, and agents tried four
/// spellings before `enter` (tests/tool-evals r7a).
const INVALID_CHORD: &str = "terminal key chord is invalid: a key is a lowercase name or one \
    character, with modifiers joined by + (enter, tab, escape, up, ctrl+c, alt+left, shift+tab)";

fn validate_terminal_effect_fields(request: &ParsedResourceRequest) -> Result<(), ResourceError> {
    if request.envelope.operation == ResourceOperation::TerminalInputKeys {
        for key in intent_string_array(&request.fields, "keys", "terminal.input.keys").map_err(
            |failure| match failure {
                ActionFailure::Known(error) => error,
                // Reading the request's own fields has no effect to leave indeterminate.
                ActionFailure::Indeterminate(cause) => {
                    ResourceError::operation_failed("terminal.input.keys", cause, json!({}))
                }
            },
        )? {
            if key_input_from_chord(&key).is_none() {
                return Err(validation_error(INVALID_CHORD, json!({"key":key})));
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
    mux.refuse_conversation_browser(&surface)?;
    Ok((browser_id, surface))
}

pub(super) fn browser_surface_for_id(
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
        value.set(
            "underline",
            json!(match underline {
                UnderlineStyle::Single => "single",
                UnderlineStyle::Double => "double",
                UnderlineStyle::Curly => "curly",
                UnderlineStyle::Dotted => "dotted",
                UnderlineStyle::Dashed => "dashed",
            }),
        );
    }
    if let Some(width_hint) = run.width_hint {
        value.set("width_hint", json!(width_hint));
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
    request.mutation().map_err(super::operation_failed)
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
    let mut chars = canonical.chars();
    if let (Some(character), None) = (chars.next(), chars.next()) {
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

/// Browser bridge errors can echo a URL or typed text, so the daemon log
/// gets only the stage of an unconfirmed browser action.
fn unconfirmed_browser_action(_error: anyhow::Error) -> ActionFailure {
    ActionFailure::Indeterminate("the browser did not confirm the action".into())
}

enum ActionFailure {
    Known(ResourceError),
    /// The effect may have run. The text is the cause for the daemon
    /// diagnostic log only; it never enters the API response.
    Indeterminate(String),
}

fn finish_action_failure(
    mux: &Arc<Mux>,
    prepared: PreparedEffect,
    failure: ActionFailure,
) -> Result<Value, ResourceError> {
    match failure {
        ActionFailure::Known(error) => effects::commit_known_failure(mux, prepared, error),
        ActionFailure::Indeterminate(cause) => {
            Err(effects::mark_indeterminate(mux, prepared, &cause))
        }
    }
}

#[cfg(test)]
#[path = "content_tests.rs"]
mod tests;
