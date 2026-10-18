use std::io::{self, BufRead, BufReader, Read, Write};
#[cfg(unix)]
use std::net::Shutdown;
use std::path::PathBuf;
use std::time::Duration;

use cmux_tui_core::platform::transport;
use cmux_tui_core::resource::{
    EnvelopeType, MAX_MESSAGE_BYTES, OperationClass, PROTOCOL, ResponseEnvelope, StreamEndEnvelope,
    StreamEndReason, StreamItemEnvelope,
};
use ratatui::buffer::CellWidth;
use serde_json::{Value, json};

use super::command::{RequestPlan, WireOperation, random_prefixed};
use super::{GlobalArgs, OutputMode, UsageError};

const RESPONSE_LIMIT: usize = 16 * 1024 * 1024;
const SERVER_PREFLIGHT_TIMEOUT: Duration = Duration::from_secs(2);
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
    let Some(params) = plan.params.as_object_mut() else {
        eprintln!("cmux: request params are not an object");
        return 2;
    };
    if let Some(machine) = &global.machine
        && params.get("machine").is_none_or(|value| value.as_str() == Some("current"))
    {
        params.insert("machine".into(), Value::String(machine.clone()));
    }
    if let Some(session) = &global.session
        && params.get("session").is_none_or(|value| value.as_str() == Some("current"))
    {
        params.insert("session".into(), Value::String(session.clone()));
    }
    let request = match request_value(&plan) {
        Ok(request) => request,
        Err(error) => {
            eprintln!("cmux: {error}");
            return 2;
        }
    };
    let encoded = match serde_json::to_vec(&request) {
        Ok(encoded) if encoded.len() <= MAX_MESSAGE_BYTES => encoded,
        Ok(_) => {
            eprintln!("cmux: request exceeds the 4 MiB protocol limit");
            return 2;
        }
        Err(error) => {
            eprintln!("cmux: cannot encode request: {error}");
            return 2;
        }
    };
    let request_id =
        request["id"].as_str().expect("locally built request IDs are strings").to_string();

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
            eprintln!("cannot connect to session socket {}: {error}", socket.display());
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
    #[cfg(unix)]
    let signal_interrupt_armed = plan.stream && arm_signal_interrupt(reader.get_ref().as_ref());
    #[cfg(not(unix))]
    let signal_interrupt_armed = false;
    let _ = reader.get_mut().set_read_timeout(response_read_timeout(&plan, signal_interrupt_armed));
    if let Err(error) = reader.get_mut().write_all(&encoded).and_then(|_| {
        reader.get_mut().write_all(b"\n")?;
        reader.get_mut().flush()
    }) {
        if plan.stream && crate::shutdown_requested() {
            return 0;
        }
        eprintln!("transport error: {error}");
        return 3;
    }
    run_response(&mut reader, &global, &plan, &request_id)
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

fn response_read_timeout(plan: &RequestPlan, signal_interrupt_armed: bool) -> Option<Duration> {
    if plan.stream {
        return (!signal_interrupt_armed).then_some(Duration::from_millis(250));
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

fn request_value(plan: &RequestPlan) -> Result<Value, UsageError> {
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

fn random_request_id() -> Result<String, UsageError> {
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
                    return print_operation_error(&error, global.output);
                }
                let result = response.result.expect("validated result");
                if !plan.stream {
                    let code = print_success(&result, global.output);
                    return if code == 0 { success_exit_code(plan, &result) } else { code };
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
                eprintln!("protocol error: unexpected envelope type");
                return 3;
            }
        }
    }
}

fn read_envelope(
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

fn print_operation_error(error: &Value, output: OutputMode) -> i32 {
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

/// Visible placeholder for characters a terminal could interpret as part of
/// a control or escape sequence. Remote-supplied strings (browser titles,
/// terminal titles set by programs, workspace and notification names) flow
/// into human output and must render as inert text.
const CONTROL_PLACEHOLDER: char = '\u{fffd}';

/// C0 controls, DEL, C1 controls, and the Unicode line and paragraph
/// separators. Written raw, any of these can alter terminal state or break
/// the line structure of human output. Callers decide which whitespace
/// controls keep a meaning before falling through to this check.
fn is_terminal_control(ch: char) -> bool {
    matches!(ch, '\u{0}'..='\u{1f}' | '\u{7f}'..='\u{9f}' | '\u{2028}' | '\u{2029}')
}

/// Sanitize a single-line human cell. CR and LF keep the visible `\n` escape
/// so multi-line values stay on one table row; every other control character,
/// including TAB, becomes a placeholder so the cell-width padding stays
/// correct. Width math must always use the sanitized string.
fn sanitize_human_cell(value: &str) -> String {
    let mut sanitized = String::with_capacity(value.len());
    for ch in value.chars() {
        match ch {
            '\r' | '\n' => sanitized.push_str("\\n"),
            ch if is_terminal_control(ch) => sanitized.push(CONTROL_PLACEHOLDER),
            ch => sanitized.push(ch),
        }
    }
    sanitized
}

/// Sanitize multi-line human text (top-level strings, error messages). LF and
/// TAB keep their meaning, CRLF collapses to LF, and a lone CR becomes a
/// placeholder because it can rewrite the current line.
fn sanitize_human_block(value: &str) -> String {
    let mut sanitized = String::with_capacity(value.len());
    let mut chars = value.chars().peekable();
    while let Some(ch) = chars.next() {
        match ch {
            '\n' | '\t' => sanitized.push(ch),
            '\r' if chars.peek() == Some(&'\n') => {}
            ch if is_terminal_control(ch) => sanitized.push(CONTROL_PLACEHOLDER),
            ch => sanitized.push(ch),
        }
    }
    sanitized
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
        "lifecycle" => 5,
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
        return Ok((cmux_tui_core::server::try_default_socket_path(session)?, true));
    }
    for name in ["CMUX_TUI_SOCKET", "CMUX_MUX_SOCKET"] {
        if let Some(path) = env(name)
            && !path.is_empty()
        {
            return Ok((PathBuf::from(path), false));
        }
    }
    Ok((cmux_tui_core::server::try_default_socket_path("main")?, true))
}

#[cfg(test)]
mod tests {
    use super::*;
    use cmux_tui_core::resource::ResourceOperation;

    fn plan(operation: ResourceOperation) -> RequestPlan {
        RequestPlan {
            operation: WireOperation::Typed(operation),
            params: json!({}),
            idempotency_key: None,
            stream: false,
        }
    }

    #[test]
    fn screen_wait_timeout_exits_one_and_a_match_exits_zero() {
        let wait = plan(ResourceOperation::TerminalWait);
        assert_eq!(success_exit_code(&wait, &json!({"matched": false, "text": ""})), 1);
        assert_eq!(success_exit_code(&wait, &json!({"matched": true, "text": "ready"})), 0);
        let read = plan(ResourceOperation::TerminalScreenRead);
        assert_eq!(success_exit_code(&read, &json!({"matched": false})), 0);
    }

    #[test]
    fn capability_preflight_rejects_wrong_app_even_when_capability_is_present() {
        let identity = json!({"app":"other", "protocol":12, "capabilities":[cmux_tui_core::server::SESSION_JOURNAL_CAPABILITY]});
        assert!(validate_capability_identity(&identity).is_err());
    }

    #[test]
    fn capability_preflight_rejects_pre_capability_protocol_even_when_capability_is_present() {
        let identity = json!({"app":"cmux-tui", "protocol":cmux_tui_core::server::SESSION_JOURNAL_PROTOCOL_VERSION - 1, "capabilities":[cmux_tui_core::server::SESSION_JOURNAL_CAPABILITY]});
        assert!(validate_capability_identity(&identity).is_err());
    }

    #[test]
    fn capability_preflight_accepts_capability_introduction_protocol() {
        let identity = json!({"app":"cmux-tui", "protocol":cmux_tui_core::server::SESSION_JOURNAL_PROTOCOL_VERSION, "capabilities":[cmux_tui_core::server::SESSION_JOURNAL_CAPABILITY]});
        assert!(validate_capability_identity(&identity).is_ok());
    }

    #[test]
    fn capability_preflight_accepts_current_protocol() {
        let identity = json!({"app":"cmux-tui", "protocol":cmux_tui_core::server::PROTOCOL_VERSION, "capabilities":[cmux_tui_core::server::SESSION_JOURNAL_CAPABILITY]});
        assert_eq!(validate_capability_identity(&identity), Ok(()));
    }

    #[test]
    fn capability_preflight_rejects_future_protocol() {
        let identity = json!({"app":"cmux-tui", "protocol":cmux_tui_core::server::PROTOCOL_VERSION + 1, "capabilities":[cmux_tui_core::server::SESSION_JOURNAL_CAPABILITY]});
        assert_eq!(validate_capability_identity(&identity), Err("unsupported server protocol"));
    }

    #[test]
    fn capability_preflight_rejects_max_protocol() {
        let identity = json!({"app":"cmux-tui", "protocol":u64::MAX, "capabilities":[cmux_tui_core::server::SESSION_JOURNAL_CAPABILITY]});
        assert_eq!(validate_capability_identity(&identity), Err("unsupported server protocol"));
    }

    #[test]
    fn capability_preflight_rejects_malformed_capabilities() {
        for capabilities in [json!(null), json!("journal-v1"), json!(["journal-v1", false])] {
            assert!(
                validate_capability_identity(&json!({
                    "app": "cmux-tui", "protocol": 12, "capabilities": capabilities,
                }))
                .is_err()
            );
        }
    }

    #[test]
    fn mutation_request_has_a_key_and_read_does_not() {
        let mutation = RequestPlan {
            operation: WireOperation::Typed(ResourceOperation::WorkspaceCreate),
            params: json!({"initial_content":"empty"}),
            idempotency_key: None,
            stream: false,
        };
        assert!(request_value(&mutation).unwrap().get("idempotency_key").is_some());

        let read = RequestPlan {
            operation: WireOperation::Typed(ResourceOperation::WorkspaceList),
            params: json!({}),
            idempotency_key: None,
            stream: false,
        };
        assert!(request_value(&read).unwrap().get("idempotency_key").is_none());
    }

    #[test]
    fn human_lists_are_readable_tables_instead_of_json_lines() {
        let output = human_text(&json!([
            {"id":"ws_a","name":"build","focused":true},
            {"id":"ws_b","name":"docs","focused":false}
        ]));
        assert_eq!(output, "ID    NAME   FOCUSED\nws_a  build  true\nws_b  docs   false\n");
        assert!(!output.contains(['{', '}', '"']));
    }

    #[test]
    fn human_tables_pad_wide_cells_by_terminal_width() {
        let output = human_text(&json!([
            {"name":"界","value":"a"},
            {"name":"x","value":"界"}
        ]));
        assert_eq!(output, "NAME  VALUE\n界    a\nx     界\n");
    }

    #[test]
    #[allow(clippy::unicode_not_nfc)]
    fn human_tables_pad_halfwidth_dakuten_by_terminal_width() {
        let output = human_text(&json!([
            {"name":"ｶﾞ","value":"a"},
            {"name":"x","value":"ｶﾞ"}
        ]));
        assert_eq!(output, "NAME  VALUE\nｶﾞ    a\nx     ｶﾞ\n");
    }

    #[test]
    fn human_single_array_wrappers_use_the_same_table() {
        let output = human_text(&json!({
            "workspaces": [
                {"id":"ws_a","name":"build"},
                {"id":"ws_b","name":"docs"}
            ]
        }));
        assert_eq!(output, "ID    NAME\nws_a  build\nws_b  docs\n");
    }

    #[test]
    fn human_records_flatten_nested_results_without_losing_fields() {
        let output = human_text(&json!({
            "generation": "generation-1",
            "revision": "7",
            "replayed": false,
            "value": {"kind": "workspace", "workspace_id": "ws_a"}
        }));
        for expected in [
            "generation",
            "generation-1",
            "revision",
            "7",
            "replayed",
            "false",
            "value.kind",
            "workspace",
            "value.workspace_id",
            "ws_a",
        ] {
            assert!(output.contains(expected), "missing {expected:?} in {output:?}");
        }
        assert!(!output.contains(['{', '}', '"']));
    }

    #[test]
    fn human_cells_disarm_escape_sequences_in_remote_titles() {
        // A remote-supplied title (browser page, terminal program) must not
        // reach the invoking terminal as a live escape sequence. Here the
        // payload is an OSC title change.
        let output = human_text(&json!([
            {"id":"b_1","title":"page\u{1b}]0;owned\u{7}title"}
        ]));
        assert!(!output.contains('\u{1b}'), "raw ESC in {output:?}");
        assert!(!output.contains('\u{7}'), "raw BEL in {output:?}");
        assert_eq!(output, "ID   TITLE\nb_1  page\u{fffd}]0;owned\u{fffd}title\n");
    }

    #[test]
    fn human_cells_disarm_osc52_clipboard_payloads() {
        // OSC 52 writes the clipboard on supporting terminals; the sequence
        // must render as inert text.
        let output = human_text(&json!([
            {"id":"b_1","title":"\u{1b}]52;c;aGVsbG8=\u{7}"}
        ]));
        assert!(!output.contains("\u{1b}]52"), "live OSC 52 in {output:?}");
        assert_eq!(output, "ID   TITLE\nb_1  \u{fffd}]52;c;aGVsbG8=\u{fffd}\n");
    }

    #[test]
    fn human_rows_replace_c1_and_del_controls_with_placeholders() {
        // C1 controls (CSI, DCS, OSC) and DEL are control bytes even without
        // a leading ESC on terminals that accept 8-bit controls.
        let output = human_text(&json!({"title":"a\u{9b}31mb\u{90}c\u{9d}d\u{7f}e"}));
        assert_eq!(output, "title  a\u{fffd}31mb\u{fffd}c\u{fffd}d\u{fffd}e\n");
    }

    #[test]
    fn human_cells_replace_unicode_line_separators() {
        let output = human_text(&json!([{"id":"w","name":"x\u{2028}y\u{2029}z"}]));
        assert_eq!(output, "ID  NAME\nw   x\u{fffd}y\u{fffd}z\n");
    }

    #[test]
    fn human_cells_keep_the_visible_newline_escape_for_cr_and_lf() {
        let output = human_text(&json!([{"id":"s_1","title":"line1\r\nline2"}]));
        assert_eq!(output, "ID   TITLE\ns_1  line1\\n\\nline2\n");
    }

    #[test]
    fn human_cells_replace_tabs_so_column_math_stays_aligned() {
        let output = human_text(&json!([{"id":"x","title":"a\tb"}]));
        assert_eq!(output, "ID  TITLE\nx   a\u{fffd}b\n");
    }

    #[test]
    fn human_headers_and_keys_cannot_carry_control_sequences() {
        let table = human_text(&json!([{"id":"x","bad\u{1b}key":"v"}]));
        assert_eq!(table, "ID  BAD\u{fffd}KEY\nx   v\n");
        let object = human_text(&json!({"k\u{1b}ey":"v"}));
        assert_eq!(object, "k\u{fffd}ey  v\n");
    }

    #[test]
    fn human_nested_values_disarm_c1_controls_after_json_serialization() {
        // serde_json escapes C0 controls but writes C1 controls raw, so the
        // serialized fallback cell needs the same sanitizing as plain strings.
        let output = human_text(&json!([{"id":"x","tags":["a\u{85}b"]}]));
        assert!(!output.contains('\u{85}'), "raw C1 NEL in {output:?}");
        assert_eq!(output, "ID  TAGS\nx   [\"a\u{fffd}b\"]\n");
    }

    #[test]
    fn human_top_level_strings_keep_newlines_but_disarm_controls() {
        assert_eq!(
            human_text(&json!("line1\nline2\u{1b}[2Jline3")),
            "line1\nline2\u{fffd}[2Jline3\n"
        );
        assert_eq!(human_text(&json!("crlf\r\nkept")), "crlf\nkept\n");
        assert_eq!(human_text(&json!("overwrite\rspoof")), "overwrite\u{fffd}spoof\n");
        assert_eq!(human_text(&json!("tab\tkept")), "tab\tkept\n");
    }

    #[test]
    fn human_string_lists_disarm_controls_per_line() {
        let output = human_text(&json!(["a\u{1b}b", "plain"]));
        assert_eq!(output, "a\u{fffd}b\nplain\n");
    }

    #[test]
    fn human_output_keeps_plain_unicode_text_unchanged() {
        let output = human_text(&json!({"title":"日本語 🚀 ｶﾞ title"}));
        assert_eq!(output, "title  日本語 🚀 ｶﾞ title\n");
    }

    #[test]
    fn human_error_text_disarms_control_sequences() {
        let error = json!({
            "code": "operation.failed",
            "message": "no workspace named b\u{1b}]0;owned\u{7}ad",
            "details": {"candidates": ["work\u{9b}space", "plain"]},
            "retryable": false
        });
        let text = human_error_lines(&error);
        assert!(!text.contains('\u{1b}'), "raw ESC in {text:?}");
        assert!(!text.contains('\u{9b}'), "raw C1 CSI in {text:?}");
        assert_eq!(
            text,
            "no workspace named b\u{fffd}]0;owned\u{fffd}ad\n  work\u{fffd}space\n  plain\n"
        );
    }

    #[test]
    fn sanitizers_cover_every_control_range() {
        let controls =
            ('\u{0}'..='\u{1f}').chain('\u{7f}'..='\u{9f}').chain(['\u{2028}', '\u{2029}']);
        for ch in controls {
            let cell = sanitize_human_cell(&format!("a{ch}b"));
            assert!(!cell.contains(ch), "cell kept {ch:?}: {cell:?}");
            let block = sanitize_human_block(&format!("a{ch}b"));
            if matches!(ch, '\n' | '\t') {
                assert_eq!(block, format!("a{ch}b"));
            } else {
                assert!(!block.contains(ch), "block kept {ch:?}: {block:?}");
            }
        }
        assert_eq!(sanitize_human_cell("plain ascii"), "plain ascii");
        assert_eq!(sanitize_human_block("plain ascii"), "plain ascii");
    }

    #[test]
    fn json_output_keeps_remote_title_bytes_intact() {
        // JSON modes rely on JSON escaping, not visible sanitizing: C0
        // controls are escaped, C1 controls and separator characters stay in
        // the encoded text, and the exact title survives a round-trip for
        // machine consumers.
        let title = "a\u{1b}]52;c;aGk=\u{7}b\u{9b}c\u{2028}d";
        let encoded = serde_json::to_string(&json!({"title": title})).expect("titles encode");
        assert!(!encoded.contains('\u{1b}'));
        assert!(!encoded.contains('\u{7}'));
        assert!(encoded.contains('\u{9b}'));
        assert!(encoded.contains('\u{2028}'));
        let decoded: Value = serde_json::from_str(&encoded).expect("titles decode");
        assert_eq!(decoded["title"].as_str(), Some(title));
    }

    #[test]
    fn terminal_wait_transport_timeout_follows_the_operation_timeout() {
        for operation in [ResourceOperation::TerminalWait, ResourceOperation::TerminalWaitExit] {
            let bounded = RequestPlan {
                operation: WireOperation::Typed(operation),
                params: json!({"timeout_ms":"5000"}),
                idempotency_key: None,
                stream: false,
            };
            assert_eq!(response_read_timeout(&bounded, false), Some(Duration::from_secs(7)));

            let unbounded = RequestPlan { params: json!({}), ..bounded };
            assert_eq!(response_read_timeout(&unbounded, false), None);
        }
    }

    #[test]
    fn stream_timeout_polling_is_only_a_signal_watcher_fallback() {
        let stream = RequestPlan {
            operation: WireOperation::Typed(ResourceOperation::SessionJournalSubscribe),
            params: json!({}),
            idempotency_key: None,
            stream: true,
        };
        assert_eq!(response_read_timeout(&stream, false), Some(Duration::from_millis(250)));
        assert_eq!(response_read_timeout(&stream, true), None);
    }

    #[test]
    fn terminal_input_errors_use_localized_copy_and_keep_wire_reasons() {
        for operation in [
            ResourceOperation::TerminalInputWrite,
            ResourceOperation::TerminalInputKeys,
            ResourceOperation::TerminalInputMouse,
            ResourceOperation::TerminalInputFocus,
        ] {
            for locale in ["en", "ja"] {
                let catalog = crate::localization::catalog_for_locale(locale);
                let plan = RequestPlan {
                    operation: WireOperation::Typed(operation),
                    params: json!({}),
                    idempotency_key: Some("input-error".into()),
                    stream: false,
                };
                for (reason, expected) in [
                    ("terminal_input_too_large", catalog.terminal_input.too_large),
                    ("terminal_input_unavailable", catalog.terminal_input.unavailable),
                    (
                        "terminal_input_confirmation_unsupported",
                        catalog.terminal_input.confirmation_unsupported,
                    ),
                    ("terminal_input_delivery_failed", catalog.terminal_input.delivery_failed),
                ] {
                    let wire = json!({"code":"operation.failed", "message":reason,
                        "details":{"reason":reason}, "retryable":false});
                    let mut human = wire.clone();
                    localize_operation_error_with_catalog(&plan, &mut human, catalog);
                    assert_eq!(human["message"], expected);
                    assert_ne!(human["message"], reason);
                    assert_eq!(human["details"], wire["details"]);
                    assert_eq!(wire["message"], reason);
                    assert_eq!(human["retryable"], false);
                }
            }
        }
        assert_ne!(
            crate::localization::catalog_for_locale("en").terminal_input,
            crate::localization::catalog_for_locale("ja").terminal_input
        );
    }

    #[test]
    fn stopped_owner_reload_error_is_localized_for_human_output() {
        const PROBE_LOCALE: &str = "CMUX_TEST_STOPPED_OWNER_RELOAD_LOCALE";
        if let Ok(locale) = std::env::var(PROBE_LOCALE) {
            let plan = RequestPlan {
                operation: WireOperation::Typed(ResourceOperation::SessionReloadConfig),
                params: json!({}),
                idempotency_key: Some("reload-owner-stopped".into()),
                stream: false,
            };
            let mut error = json!({
                "code":"operation.failed",
                "message":"owner_stopped",
                "details":{"operation":"session.reload_config","reason":"owner_stopped"},
                "retryable":false,
            });

            localize_operation_error(&plan, &mut error);

            let expected = match locale.as_str() {
                "en_US.UTF-8" => {
                    "the local server stopped before it applied the configuration reload; start the session and retry"
                }
                "ja_JP.UTF-8" => {
                    "ローカルサーバーが設定の再読み込みを適用する前に停止しました。セッションを起動して再試行してください"
                }
                _ => panic!("unexpected probe locale {locale}"),
            };
            assert_eq!(error["message"], expected);
            return;
        }

        for locale in ["en_US.UTF-8", "ja_JP.UTF-8"] {
            let status = std::process::Command::new(std::env::current_exe().unwrap())
                .arg("stopped_owner_reload_error_is_localized_for_human_output")
                .arg("--nocapture")
                .env(PROBE_LOCALE, locale)
                .env("LC_ALL", locale)
                .status()
                .unwrap();
            assert!(status.success(), "{locale} localization probe failed");
        }
    }
}
