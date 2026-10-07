use std::io::{self, BufRead, BufReader, Read, Write};
#[cfg(unix)]
use std::net::Shutdown;
use std::path::PathBuf;
use std::time::Duration;

use cmux_tui_core::platform::transport;
use cmux_tui_core::resource::{
    EnvelopeType, OperationClass, PROTOCOL, ResponseEnvelope, StreamEndEnvelope, StreamEndReason,
    StreamItemEnvelope,
};
use ratatui::buffer::CellWidth;
use serde_json::{Value, json};

use super::command::{RequestPlan, WireOperation, random_prefixed};
use super::{GlobalArgs, OutputMode, UsageError};

const RESPONSE_LIMIT: usize = 16 * 1024 * 1024;
pub(super) const SERVER_PREFLIGHT_TIMEOUT: Duration = Duration::from_secs(2);
const SUPPORTED_SERVER_APP: &str = "cmux-tui";
/// The session-journal wire shape is compatible from its introduction through
/// the current protocol. Future protocol versions need an explicit review.
const SESSION_JOURNAL_PROTOCOL_MINIMUM: u64 =
    cmux_tui_core::server::SESSION_JOURNAL_PROTOCOL_VERSION as u64;
const SESSION_JOURNAL_PROTOCOL_MAXIMUM: u64 = cmux_tui_core::server::PROTOCOL_VERSION as u64;

pub(super) fn run(global: GlobalArgs, mut plan: RequestPlan) -> i32 {
    if plan.stream && global.output == OutputMode::Json {
        eprintln!("cmux: streams require --jsonl, --quiet, or human output");
        return 2;
    }
    if let Err(error) = super::resolve::apply_global_route(&global, &mut plan.params) {
        eprintln!("cmux: {error}");
        return 2;
    }
    let mut request = match request_value(&plan) {
        Ok(request) => request,
        Err(error) => {
            eprintln!("cmux: {error}");
            return 2;
        }
    };
    let mut encoded = match encode_request(&request) {
        Ok(encoded) => encoded,
        Err(code) => return code,
    };
    let request_id =
        request["id"].as_str().expect("locally built request IDs are strings").to_string();
    let key_report = KeyReport::new(request.get("idempotency_key").and_then(Value::as_str));

    let (socket, socket_is_derived) = match resolve_socket_with_origin(&global) {
        Ok(resolved) => resolved,
        Err(_) => {
            eprintln!("cmux: {}", crate::localization::catalog().startup.invalid_session_name);
            return 2;
        }
    };
    let stream = match cmux_tui_core::server::connect_session_socket(&socket, socket_is_derived) {
        Ok(stream) => stream,
        Err(error) => {
            eprintln!("{}", connect_failure(&socket, &error));
            return 3;
        }
    };
    let _ = stream.set_read_timeout(Some(SERVER_PREFLIGHT_TIMEOUT));
    let mut reader = BufReader::new(stream);
    if let Some(capability) = required_server_capability(&plan) {
        match require_server_capability(&mut reader, &global, capability) {
            Ok(()) => {}
            Err(exit_code) => return exit_code,
        }
    }
    // The caller's terminal belongs to the session its environment names; an
    // explicit route targets that session's current workspace.
    let caller_route = global.socket.is_none() && global.session.is_none();
    // A browser tab in a session a cmux app owns is the app's to render.
    #[cfg(unix)]
    if let Some(code) = super::frontend_browser::run_in_app(
        &global,
        &plan,
        &request,
        &mut reader,
        &socket,
        caller_route,
        &key_report,
    ) {
        return code;
    }
    if !plan.resolve.is_empty() {
        if let Err(failure) = super::resolve::apply(&mut reader, &mut plan, caller_route) {
            // A browser tab's page zoom: the app hosts the page and owns it.
            #[cfg(unix)]
            if let super::resolve::Failure::AppAction { action, target } = &failure {
                let args = ["--target".to_owned(), target.clone()];
                return match super::app::run_action(action, &args, super::app::ActionName::Any) {
                    Ok(command) => super::app::run(&global, command),
                    Err(error) => print_local_error(
                        &json!({"code":"usage.invalid","message":error.to_string(),"details":{},"retryable":false}),
                        global.output,
                        2,
                    ),
                };
            }
            return failure.report(global.output);
        }
        request["params"] = plan.params.clone();
        encoded = match encode_request(&request) {
            Ok(encoded) => encoded,
            Err(code) => return code,
        };
    }
    #[cfg(unix)]
    let interrupt_handled = !plan.stream || stream_interrupt(reader.get_ref().as_ref());
    #[cfg(not(unix))]
    let interrupt_handled = !plan.stream;
    let _ = reader.get_mut().set_read_timeout(response_read_timeout(&plan, interrupt_handled));
    if let Err(error) = reader.get_mut().write_all(&encoded).and_then(|_| {
        reader.get_mut().write_all(b"\n")?;
        reader.get_mut().flush()
    }) {
        if plan.stream && crate::shutdown_requested() {
            return 0;
        }
        eprintln!("transport error: {error}");
        // Part of the request may have reached the daemon.
        key_report.finish(global.output);
        return 3;
    }
    let code = run_response(&mut reader, &global, &plan, &request_id, &key_report);
    if code != 0 {
        key_report.finish(global.output);
    }
    code
}

fn encode_request(request: &Value) -> Result<Vec<u8>, i32> {
    super::resolve::encode_request_bytes(request).map_err(|error| {
        eprintln!("cmux: {error}");
        2
    })
}

/// Reports a mutation's idempotency key once when the command fails after
/// its request was sent, so `--idempotency-key` can retry it safely
/// (plans/cmux-next/state-ownership.md, section 4).
pub(super) struct KeyReport {
    key: Option<String>,
    done: std::cell::Cell<bool>,
}

impl KeyReport {
    pub(super) fn new(key: Option<&str>) -> Self {
        Self { key: key.map(str::to_owned), done: std::cell::Cell::new(false) }
    }

    /// A successful mutation has nothing to retry.
    pub(super) fn succeeded(&self) {
        self.done.set(true);
    }

    /// Adds `details.idempotency_key` to an error the command prints in a
    /// JSON mode. Human modes print the note after the message instead.
    pub(super) fn annotate(&self, error: &mut Value, output: OutputMode) {
        let Some(key) = self.key.as_deref() else { return };
        if !matches!(output, OutputMode::Json | OutputMode::JsonLines) || !error.is_object() {
            return;
        }
        let details = &mut error["details"];
        if !details.is_object() {
            *details = json!({});
        }
        details
            .as_object_mut()
            .expect("details is an object")
            .entry("idempotency_key")
            .or_insert(Value::String(key.to_owned()));
        self.done.set(true);
    }

    /// Prints the key unless an annotated error or a success already did.
    pub(super) fn finish(&self, output: OutputMode) {
        let Some(key) = self.key.as_deref() else { return };
        if self.done.replace(true) {
            return;
        }
        let note =
            crate::localization::catalog().local_server.mutation_key_note.replace("{key}", key);
        match output {
            OutputMode::Json | OutputMode::JsonLines => {
                let error = json!({
                    "code": "mutation.outcome_unknown",
                    "message": note,
                    "details": {"idempotency_key": key},
                    "retryable": true,
                });
                let _ = serde_json::to_writer(io::stderr().lock(), &error);
                eprintln!();
            }
            OutputMode::Quiet | OutputMode::Human => eprintln!("{note}"),
        }
    }
}

/// Makes a stream end on SIGINT, SIGTERM or SIGHUP without a read timeout:
/// a watcher thread shuts the socket down, or, when that thread cannot
/// start, the signals get their default action back and end the process.
#[cfg(unix)]
fn stream_interrupt(stream: &dyn transport::Stream) -> bool {
    arm_signal_interrupt(stream) || crate::restore_default_termination_signals().is_ok()
}

#[cfg(unix)]
pub(super) fn arm_signal_interrupt(stream: &dyn transport::Stream) -> bool {
    let Ok(stream) = stream.try_clone_box() else { return false };
    std::thread::Builder::new()
        .name("cmux-cli-signal-interrupt".into())
        .spawn(move || {
            crate::wait_for_shutdown_signal();
            let _ = stream.shutdown(Shutdown::Both);
        })
        .is_ok()
}

fn required_server_capability(plan: &RequestPlan) -> Option<&'static str> {
    matches!(
        &plan.operation,
        WireOperation::Typed(
            cmux_tui_core::resource::ResourceOperation::SessionJournalSubscribe
                | cmux_tui_core::resource::ResourceOperation::SessionJournalProducerList
                | cmux_tui_core::resource::ResourceOperation::SessionJournalProducerPut
                | cmux_tui_core::resource::ResourceOperation::SessionJournalAppend
                | cmux_tui_core::resource::ResourceOperation::SessionJournalHookList
                | cmux_tui_core::resource::ResourceOperation::SessionJournalHookPut
                | cmux_tui_core::resource::ResourceOperation::SessionJournalCheckpointCreate
                | cmux_tui_core::resource::ResourceOperation::SessionJournalCheckpointList
                | cmux_tui_core::resource::ResourceOperation::SessionJournalRestorePreview
                | cmux_tui_core::resource::ResourceOperation::SessionJournalSegmentList
                | cmux_tui_core::resource::ResourceOperation::SessionJournalSegmentSeal
        )
    )
    .then_some(cmux_tui_core::server::SESSION_JOURNAL_CAPABILITY)
}

fn require_server_capability(
    reader: &mut BufReader<Box<dyn transport::Stream>>,
    global: &GlobalArgs,
    capability: &'static str,
) -> Result<(), i32> {
    let request_id = random_request_id().map_err(|error| {
        eprintln!("cmux: {error}");
        2
    })?;
    let request = json!({"id":request_id,"cmd":"identify"});
    let encoded = serde_json::to_vec(&request).map_err(|error| {
        eprintln!("cmux: cannot encode capability request: {error}");
        2
    })?;
    reader
        .get_mut()
        .write_all(&encoded)
        .and_then(|_| reader.get_mut().write_all(b"\n"))
        .and_then(|_| reader.get_mut().flush())
        .map_err(|error| {
            eprintln!("transport error while checking session capabilities: {error}");
            3
        })?;
    let response = read_envelope(reader, false)
        .map_err(|error| {
            eprintln!("{error}");
            3
        })?
        .ok_or_else(|| {
            eprintln!("transport closed before capability response");
            3
        })?;
    if response.get("id").and_then(Value::as_str) != Some(request_id.as_str())
        || response.get("ok").and_then(Value::as_bool) != Some(true)
    {
        eprintln!("protocol error: invalid identify response during capability negotiation");
        return Err(3);
    }
    let identity = response.get("data").unwrap_or(&Value::Null);
    if let Err(reason) = validate_capability_identity(identity) {
        eprintln!(
            "protocol error: invalid identify response during capability negotiation: {reason}"
        );
        return Err(3);
    }
    let supported = crate::session::parse_identity_capabilities(identity)
        .map(|capabilities| capabilities.contains(capability))
        .unwrap_or(false);
    if supported {
        return Ok(());
    }
    let details = json!({
        "capability":capability,
        "action":"restart_session"
    });
    let error = json!({
        "code":"operation.unsupported",
        "message":"resident session does not support journal subscriptions; restart it with this cmux-tui binary",
        "details":details,
        "retryable":false
    });
    Err(print_local_error(&error, global.output, 1))
}

fn validate_capability_identity(identity: &Value) -> Result<(), &'static str> {
    if identity.get("app").and_then(Value::as_str) != Some(SUPPORTED_SERVER_APP) {
        return Err("unexpected server app");
    }
    let Some(protocol) = identity.get("protocol").and_then(Value::as_u64) else {
        return Err("unsupported server protocol");
    };
    if !(SESSION_JOURNAL_PROTOCOL_MINIMUM..=SESSION_JOURNAL_PROTOCOL_MAXIMUM).contains(&protocol) {
        return Err("unsupported server protocol");
    }
    crate::session::parse_identity_capabilities(identity)?;
    Ok(())
}

/// `interrupt_handled` is false only for a stream on a platform with no
/// signal watcher (Windows): there a console interrupt only sets the
/// shutdown flag, so the read wakes every 250 ms to look at it.
pub(super) fn response_read_timeout(
    plan: &RequestPlan,
    interrupt_handled: bool,
) -> Option<Duration> {
    if plan.stream {
        return (!interrupt_handled).then_some(Duration::from_millis(250));
    }
    if matches!(
        &plan.operation,
        WireOperation::Typed(
            cmux_tui_core::resource::ResourceOperation::TerminalWait
                | cmux_tui_core::resource::ResourceOperation::TerminalWaitExit
        )
    ) {
        return plan
            .params
            .get("timeout_ms")
            .and_then(Value::as_str)
            .and_then(|value| value.parse::<u64>().ok())
            .map(Duration::from_millis)
            .and_then(|timeout| timeout.checked_add(Duration::from_secs(2)));
    }
    Some(Duration::from_secs(10))
}

pub(super) fn request_value(plan: &RequestPlan) -> Result<Value, UsageError> {
    let class = plan.operation.class();
    let mut request = json!({
        "protocol": PROTOCOL,
        "type": "request",
        "id": random_request_id()?,
        "operation": plan.operation.name()?,
        "params": plan.params,
    });
    match class {
        OperationClass::Mutation => {
            request["idempotency_key"] = Value::String(
                plan.idempotency_key.clone().map(Ok).unwrap_or_else(random_idempotency_key)?,
            );
        }
        _ if plan.idempotency_key.is_some() => {
            return Err(UsageError::new("only mutations may carry an idempotency key"));
        }
        _ => {}
    }
    Ok(request)
}

pub(super) fn random_request_id() -> Result<String, UsageError> {
    random_prefixed("request")
}

fn random_idempotency_key() -> Result<String, UsageError> {
    random_prefixed("mutation")
}

fn run_response(
    reader: &mut BufReader<Box<dyn transport::Stream>>,
    global: &GlobalArgs,
    plan: &RequestPlan,
    request_id: &str,
    key_report: &KeyReport,
) -> i32 {
    let mut accepted_stream = false;
    let expose_stream_lifecycle = matches!(
        &plan.operation,
        WireOperation::Typed(cmux_tui_core::resource::ResourceOperation::SessionJournalSubscribe)
    );
    let expected_stream_id = plan.params.get("stream_id").and_then(Value::as_str);
    loop {
        if plan.stream && crate::shutdown_requested() {
            return 0;
        }
        let value = match read_envelope(reader, plan.stream) {
            Ok(Some(value)) => value,
            Ok(None) if plan.stream && accepted_stream => return 0,
            Ok(None) => {
                eprintln!("transport closed before response");
                return 3;
            }
            Err(error) => {
                if plan.stream && crate::shutdown_requested() {
                    return 0;
                }
                eprintln!("{error}");
                return 3;
            }
        };
        match value.get("type").and_then(Value::as_str) {
            Some("response") => {
                let response: ResponseEnvelope = match serde_json::from_value(value.clone()) {
                    Ok(response) => response,
                    Err(error) => {
                        eprintln!("protocol error: invalid response envelope: {error}");
                        return 3;
                    }
                };
                if let Err(error) = response.validate() {
                    eprintln!("protocol error: {}", error.message);
                    return 3;
                }
                if response.id.as_str() != request_id {
                    continue;
                }
                if !response.ok {
                    let mut error = serde_json::to_value(response.error.expect("validated error"))
                        .expect("resource errors serialize");
                    if matches!(global.output, OutputMode::Quiet | OutputMode::Human) {
                        localize_operation_error(plan, &mut error);
                    }
                    key_report.annotate(&mut error, global.output);
                    if hints::settles_mutation(&error) {
                        key_report.succeeded();
                    }
                    return print_operation_error(&error, global.output);
                }
                let result = response.result.expect("validated result");
                key_report.succeeded();
                if !plan.stream {
                    // Focus in a session a cmux app owns is the app's (app_focus).
                    #[cfg(unix)]
                    let result = match &plan.operation {
                        WireOperation::Typed(operation) => {
                            match super::app_focus::after_daemon(global, *operation, result) {
                                Ok(result) => result,
                                Err(error) => return print_operation_error(&error, global.output),
                            }
                        }
                        WireOperation::Raw { .. } => result,
                    };
                    return print_result(global, plan, result);
                }
                if result.get("stream_id").and_then(Value::as_str) != expected_stream_id {
                    eprintln!("protocol error: stream response did not confirm the requested ID");
                    return 3;
                }
                if expose_stream_lifecycle
                    && global.output == OutputMode::JsonLines
                    && let Err(error) = write_json_line(&value)
                {
                    eprintln!("stdout error: {error}");
                    return 3;
                }
                accepted_stream = true;
            }
            Some("stream_item") if plan.stream && accepted_stream => {
                let item: StreamItemEnvelope = match serde_json::from_value(value.clone()) {
                    Ok(item) => item,
                    Err(error) => {
                        eprintln!("protocol error: invalid stream item: {error}");
                        return 3;
                    }
                };
                if item.protocol != PROTOCOL
                    || item.envelope_type != EnvelopeType::StreamItem
                    || Some(item.stream_id.as_str()) != expected_stream_id
                {
                    eprintln!("protocol error: stream item does not match the opened stream");
                    return 3;
                }
                if let Err(error) = print_stream_item(&value, global.output) {
                    eprintln!("stdout error: {error}");
                    return 3;
                }
            }
            Some("stream_end") if plan.stream && accepted_stream => {
                let end: StreamEndEnvelope = match serde_json::from_value(value.clone()) {
                    Ok(end) => end,
                    Err(error) => {
                        eprintln!("protocol error: invalid stream end: {error}");
                        return 3;
                    }
                };
                if end.protocol != PROTOCOL
                    || end.envelope_type != EnvelopeType::StreamEnd
                    || Some(end.stream_id.as_str()) != expected_stream_id
                {
                    eprintln!("protocol error: stream end does not match the opened stream");
                    return 3;
                }
                if expose_stream_lifecycle
                    && global.output == OutputMode::JsonLines
                    && let Err(error) = write_json_line(&value)
                {
                    eprintln!("stdout error: {error}");
                    return 3;
                }
                if matches!(
                    end.reason,
                    StreamEndReason::Completed
                        | StreamEndReason::Canceled
                        | StreamEndReason::Closed
                ) {
                    return 0;
                }
                if let Some(error) = end.error {
                    let error = serde_json::to_value(error).expect("resource errors serialize");
                    return print_operation_error(&error, global.output);
                }
                let message = end.recovery.unwrap_or_else(|| "stream ended with an error".into());
                eprintln!("{}", sanitize_human_block(&message));
                return 1;
            }
            _ => {
                eprintln!("protocol error: {}", hints::wrong_protocol());
                return 3;
            }
        }
    }
}

pub(super) fn read_envelope(
    reader: &mut BufReader<Box<dyn transport::Stream>>,
    allow_timeout: bool,
) -> Result<Option<Value>, String> {
    loop {
        let mut bytes = Vec::new();
        match reader.by_ref().take((RESPONSE_LIMIT + 2) as u64).read_until(b'\n', &mut bytes) {
            Ok(0) => return Ok(None),
            Ok(_) => {}
            Err(error)
                if allow_timeout
                    && matches!(
                        error.kind(),
                        io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
                    ) =>
            {
                if crate::shutdown_requested() {
                    return Ok(None);
                }
                continue;
            }
            Err(error) if hints::is_no_answer(&error) => return Err(hints::no_answer().into()),
            Err(error) => return Err(format!("transport error: {error}")),
        }
        if bytes.len() > RESPONSE_LIMIT {
            return Err("protocol error: response exceeds the 16 MiB limit".into());
        }
        if !bytes.ends_with(b"\n") {
            return Err("transport closed with a partial JSON line".into());
        }
        bytes.pop();
        if bytes.last() == Some(&b'\r') {
            bytes.pop();
        }
        return serde_json::from_slice(&bytes)
            .map(Some)
            .map_err(|error| format!("protocol error: invalid JSON response: {error}"));
    }
}

/// Prints a request's successful result as the command shows it; returns
/// the exit code.
pub(super) fn print_result(global: &GlobalArgs, plan: &RequestPlan, result: Value) -> i32 {
    let result = plan.view.project(result);
    let shown = match global.output {
        OutputMode::Human => human_view(plan, &result),
        _ => std::borrow::Cow::Borrowed(&result),
    };
    let code = print_success(&shown, global.output);
    if code == 0 { success_exit_code(plan, &result) } else { code }
}

/// `terminal <id> screen wait` reports a timeout as a normal result with
/// `matched: false`. The result is still printed, but the exit status is 1
/// (spec/commands.md), so a script can tell a timeout from a match.
fn success_exit_code(plan: &RequestPlan, result: &Value) -> i32 {
    let unmatched_wait = matches!(
        &plan.operation,
        WireOperation::Typed(cmux_tui_core::resource::ResourceOperation::TerminalWait)
    ) && result.get("matched") == Some(&Value::Bool(false));
    i32::from(unmatched_wait)
}

/// What the human table shows for a result. `workspace list --order
/// personal` adds an ORDER column (the row's place in the returned order),
/// because INDEX stays the session order.
fn human_view<'a>(plan: &RequestPlan, result: &'a Value) -> std::borrow::Cow<'a, Value> {
    let personal = matches!(
        &plan.operation,
        WireOperation::Typed(cmux_tui_core::resource::ResourceOperation::WorkspaceList)
    ) && plan.params.get("order").and_then(Value::as_str) == Some("personal");
    match result.as_array() {
        Some(rows) if personal => std::borrow::Cow::Owned(Value::Array(
            rows.iter()
                .enumerate()
                .map(|(order, row)| {
                    let mut row = row.clone();
                    if let Some(object) = row.as_object_mut() {
                        object.insert("order".into(), json!(order));
                    }
                    row
                })
                .collect(),
        )),
        Some(rows) if is_closed_list(plan) => std::borrow::Cow::Owned(closed_view::summarize(rows)),
        _ => std::borrow::Cow::Borrowed(result),
    }
}

fn is_closed_list(plan: &RequestPlan) -> bool {
    matches!(
        &plan.operation,
        WireOperation::Typed(cmux_tui_core::resource::ResourceOperation::ClosedList)
    )
}

fn print_success(value: &Value, output: OutputMode) -> i32 {
    let result = match output {
        OutputMode::Quiet => Ok(()),
        OutputMode::Json => write_json_line(value),
        OutputMode::JsonLines => write_json_lines(value),
        OutputMode::Human => write_human(value),
    };
    match result {
        Ok(()) => 0,
        Err(error) => {
            eprintln!("stdout error: {error}");
            3
        }
    }
}

pub(super) fn print_operation_error(error: &Value, output: OutputMode) -> i32 {
    print_local_error(error, output, 1)
}

fn localize_operation_error(plan: &RequestPlan, error: &mut Value) {
    localize_operation_error_with_catalog(plan, error, crate::localization::catalog());
}

fn localize_operation_error_with_catalog(
    plan: &RequestPlan,
    error: &mut Value,
    catalog: &crate::localization::Catalog,
) {
    if matches!(
        &plan.operation,
        WireOperation::Typed(
            cmux_tui_core::resource::ResourceOperation::TerminalInputWrite
                | cmux_tui_core::resource::ResourceOperation::TerminalInputKeys
                | cmux_tui_core::resource::ResourceOperation::TerminalInputMouse
                | cmux_tui_core::resource::ResourceOperation::TerminalInputFocus
        )
    ) && error["code"] == "operation.failed"
    {
        let message = match error["details"]["reason"].as_str() {
            Some("terminal_input_too_large") => Some(catalog.terminal_input.too_large),
            Some("terminal_input_unavailable") => Some(catalog.terminal_input.unavailable),
            Some("terminal_input_confirmation_unsupported") => {
                Some(catalog.terminal_input.confirmation_unsupported)
            }
            Some("terminal_input_delivery_failed") => Some(catalog.terminal_input.delivery_failed),
            _ => None,
        };
        if let Some(message) = message {
            error["message"] = Value::String(message.into());
        }
    }

    let is_lifecycle_operation = matches!(
        &plan.operation,
        WireOperation::Typed(
            cmux_tui_core::resource::ResourceOperation::SessionShutdown
                | cmux_tui_core::resource::ResourceOperation::SessionReloadConfig
        )
    );
    if is_lifecycle_operation && error["code"] == "operation.failed" {
        let message = match error["details"]["reason"].as_str() {
            Some("lifecycle_not_ready") => Some(catalog.local_server.starting),
            Some("owner_stopped") => Some(catalog.local_server.reload_owner_stopped),
            _ => None,
        };
        if let Some(message) = message {
            error["message"] = Value::String(message.to_string());
        }
    }
}

pub(super) fn print_local_error(error: &Value, output: OutputMode, exit_code: i32) -> i32 {
    match output {
        OutputMode::Json | OutputMode::JsonLines => {
            let _ = serde_json::to_writer(io::stderr().lock(), error);
            eprintln!();
        }
        OutputMode::Quiet | OutputMode::Human => {
            eprint!("{}", human_error_lines(error));
        }
    }
    exit_code
}

/// Render an operation error for human-readable stderr. The message and any
/// candidate names can carry remote-supplied text, so they get the same
/// visible sanitizing as human stdout.
fn human_error_lines(error: &Value) -> String {
    let message = error.get("message").and_then(Value::as_str).unwrap_or("operation failed");
    let mut text = sanitize_human_block(message);
    text.push('\n');
    if let Some(candidates) =
        error.get("details").and_then(|details| details.get("candidates")).and_then(Value::as_array)
    {
        for candidate in candidates {
            if let Some(candidate) = candidate.as_str() {
                text.push_str("  ");
                text.push_str(&sanitize_human_cell(candidate));
                text.push('\n');
            }
        }
    }
    text
}

pub(super) fn print_local_success(value: &Value, output: OutputMode) -> i32 {
    print_success(value, output)
}

fn print_stream_item(value: &Value, output: OutputMode) -> io::Result<()> {
    match output {
        OutputMode::Quiet => Ok(()),
        OutputMode::Json | OutputMode::JsonLines => write_json_line(value),
        OutputMode::Human => write_human(value.get("item").unwrap_or(value)),
    }
}

fn write_json_line(value: &Value) -> io::Result<()> {
    let mut stdout = io::stdout().lock();
    serde_json::to_writer(&mut stdout, value).map_err(io::Error::other)?;
    stdout.write_all(b"\n")?;
    stdout.flush()
}

fn write_json_lines(value: &Value) -> io::Result<()> {
    if let Some(items) = value.as_array() {
        for item in items {
            write_json_line(item)?;
        }
        return Ok(());
    }
    if let Some(object) = value.as_object()
        && object.len() == 1
        && let Some(items) = object.values().next().and_then(Value::as_array)
    {
        for item in items {
            write_json_line(item)?;
        }
        return Ok(());
    }
    write_json_line(value)
}

fn write_human(value: &Value) -> io::Result<()> {
    let mut stdout = io::stdout().lock();
    stdout.write_all(human_text(value).as_bytes())?;
    stdout.flush()
}

fn human_text(value: &Value) -> String {
    let mut output = String::new();
    append_human(value, &mut output);
    output
}

fn append_human(value: &Value, output: &mut String) {
    match value {
        Value::Null => {}
        Value::String(value) => {
            let value = sanitize_human_block(value);
            output.push_str(&value);
            if !value.ends_with('\n') {
                output.push('\n');
            }
        }
        Value::Array(values) if values.iter().all(Value::is_object) => {
            append_record_table(values, output);
        }
        Value::Array(values) => {
            for value in values {
                output.push_str(&human_cell(value));
                output.push('\n');
            }
        }
        Value::Object(object) => {
            if object.len() == 1
                && let Some(values) = object.values().next()
                && values.is_array()
            {
                append_human(values, output);
                return;
            }
            let mut rows = Vec::new();
            flatten_human_object(None, object, &mut rows);
            let width =
                rows.iter().map(|(key, _)| usize::from(key.cell_width())).max().unwrap_or(0);
            for (key, value) in rows {
                output.push_str(&key);
                output.push_str(&" ".repeat(width.saturating_sub(usize::from(key.cell_width()))));
                output.push_str("  ");
                output.push_str(&value);
                output.push('\n');
            }
        }
        value => {
            output.push_str(&human_cell(value));
            output.push('\n');
        }
    }
}

fn append_record_table(values: &[Value], output: &mut String) {
    if values.is_empty() {
        return;
    }
    let mut columns = values
        .iter()
        .filter_map(Value::as_object)
        .flat_map(|object| object.keys().cloned())
        .collect::<Vec<_>>();
    columns.sort_by(|left, right| {
        human_key_rank(left).cmp(&human_key_rank(right)).then_with(|| left.cmp(right))
    });
    columns.dedup();

    let rows = values
        .iter()
        .filter_map(Value::as_object)
        .map(|object| {
            columns
                .iter()
                .map(|column| object.get(column).map_or_else(|| "-".to_string(), human_cell))
                .collect::<Vec<_>>()
        })
        .collect::<Vec<_>>();
    let widths = columns
        .iter()
        .enumerate()
        .map(|(index, column)| {
            rows.iter()
                .map(|row| usize::from(row[index].cell_width()))
                .max()
                .unwrap_or(0)
                .max(usize::from(human_header(column).cell_width()))
        })
        .collect::<Vec<_>>();

    append_table_row(
        &columns.iter().map(|column| human_header(column)).collect::<Vec<_>>(),
        &widths,
        output,
    );
    for row in rows {
        append_table_row(&row, &widths, output);
    }
}

fn append_table_row(cells: &[String], widths: &[usize], output: &mut String) {
    for (index, cell) in cells.iter().enumerate() {
        if index != 0 {
            output.push_str("  ");
        }
        output.push_str(cell);
        if index + 1 != cells.len() {
            output.push_str(
                &" ".repeat(widths[index].saturating_sub(usize::from(cell.cell_width()))),
            );
        }
    }
    output.push('\n');
}

fn flatten_human_object(
    prefix: Option<&str>,
    object: &serde_json::Map<String, Value>,
    rows: &mut Vec<(String, String)>,
) {
    let mut fields = object.iter().collect::<Vec<_>>();
    fields.sort_by(|(left, _), (right, _)| {
        human_key_rank(left).cmp(&human_key_rank(right)).then_with(|| left.cmp(right))
    });
    for (key, value) in fields {
        let path = prefix.map_or_else(|| key.clone(), |prefix| format!("{prefix}.{key}"));
        if let Value::Object(nested) = value {
            flatten_human_object(Some(&path), nested, rows);
        } else {
            rows.push((sanitize_human_cell(&path), human_cell(value)));
        }
    }
}

fn human_cell(value: &Value) -> String {
    match value {
        Value::Null => "-".to_string(),
        Value::String(value) => sanitize_human_cell(value),
        Value::Bool(value) => value.to_string(),
        Value::Number(value) => value.to_string(),
        // serde_json escapes C0 controls but writes C1 controls and the
        // Unicode separators raw, so the serialized form needs the same pass.
        value => sanitize_human_cell(
            &serde_json::to_string(value).expect("JSON value serialization cannot fail"),
        ),
    }
}

fn human_header(key: &str) -> String {
    sanitize_human_cell(&key.replace('_', " ").to_uppercase())
}

fn human_key_rank(key: &str) -> usize {
    match key {
        "id" => 0,
        "name" => 1,
        "title" => 2,
        "kind" => 3,
        "state" => 4,
        "lifecycle" | "order" => 5,
        "index" => 6,
        "focused" => 7,
        "running" => 8,
        _ => 9,
    }
}

/// Resolve a socket and report whether it belongs to cmux's private runtime
/// directory. Environment-selected and explicit paths remain caller-managed.
pub(super) fn resolve_socket_with_origin(global: &GlobalArgs) -> anyhow::Result<(PathBuf, bool)> {
    resolve_socket_with_env(global, |name| std::env::var_os(name))
}

pub(super) fn resolve_socket_with_env(
    global: &GlobalArgs,
    env: impl Fn(&str) -> Option<std::ffi::OsString>,
) -> anyhow::Result<(PathBuf, bool)> {
    if let Some(path) = &global.socket {
        return Ok((path.clone(), false));
    }
    if let Some(session) = &global.session {
        // The bundling app starts its own session under the Darwin per-user
        // temp directory, whatever this process's TMPDIR is.
        #[cfg(target_os = "macos")]
        if let Some(identity) = crate::app_identity::AppIdentity::detect(
            |name| env(name).and_then(|value| value.into_string().ok()),
            std::env::current_exe().ok().as_deref(),
        ) && identity.daemon_session().as_deref() == Some(session.as_str())
            && let Some(path) = crate::app_identity::app_daemon_socket(&identity)
        {
            return Ok((path, true));
        }
        return Ok((cmux_tui_core::server::try_default_socket_path(session)?, true));
    }
    for name in ["CMUX_TUI_SOCKET", "CMUX_MUX_SOCKET"] {
        if let Some(path) = env(name)
            && !path.is_empty()
        {
            return Ok((PathBuf::from(path), false));
        }
    }
    // The `cmux` bundled in a cmux app talks to that app's session.
    #[cfg(target_os = "macos")]
    if let Some(identity) = crate::app_identity::AppIdentity::detect(
        |name| env(name).and_then(|value| value.into_string().ok()),
        std::env::current_exe().ok().as_deref(),
    ) && let Some(path) = crate::app_identity::app_daemon_socket(&identity)
    {
        return Ok((path, true));
    }
    Ok((cmux_tui_core::server::try_default_socket_path("main")?, true))
}

mod closed_view;
mod hints;
mod sanitize;
pub(super) use hints::connect_failure;
use sanitize::{sanitize_human_block, sanitize_human_cell};

#[cfg(test)]
mod tests;
