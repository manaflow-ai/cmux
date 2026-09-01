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

    let socket = match resolve_socket(&global) {
        Ok(socket) => socket,
        Err(_) => {
            eprintln!("cmux: {}", crate::localization::catalog().startup.invalid_session_name);
            return 2;
        }
    };
    let stream = match transport::connect(&socket) {
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
fn arm_signal_interrupt(stream: &dyn transport::Stream) -> bool {
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
                    return print_success(&result, global.output);
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
                eprintln!("{message}");
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
    let is_lifecycle_operation = matches!(
        &plan.operation,
        WireOperation::Typed(
            cmux_tui_core::resource::ResourceOperation::SessionShutdown
                | cmux_tui_core::resource::ResourceOperation::SessionReloadConfig
        )
    );
    if is_lifecycle_operation && error["code"] == "operation.failed" {
        let message = match error["details"]["reason"].as_str() {
            Some("lifecycle_not_ready") => {
                Some(crate::localization::catalog().local_server.starting)
            }
            Some("owner_stopped") => {
                Some(crate::localization::catalog().local_server.reload_owner_stopped)
            }
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
            let message =
                error.get("message").and_then(Value::as_str).unwrap_or("operation failed");
            eprintln!("{message}");
            if let Some(candidates) = error
                .get("details")
                .and_then(|details| details.get("candidates"))
                .and_then(Value::as_array)
            {
                for candidate in candidates {
                    if let Some(candidate) = candidate.as_str() {
                        eprintln!("  {candidate}");
                    }
                }
            }
        }
    }
    exit_code
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
            output.push_str(value);
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
            let width = rows.iter().map(|(key, _)| key.chars().count()).max().unwrap_or(0);
            for (key, value) in rows {
                output.push_str(&key);
                output.push_str(&" ".repeat(width.saturating_sub(key.chars().count())));
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
                .map(|row| row[index].chars().count())
                .max()
                .unwrap_or(0)
                .max(human_header(column).chars().count())
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
            output.push_str(&" ".repeat(widths[index].saturating_sub(cell.chars().count())));
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
            rows.push((path, human_cell(value)));
        }
    }
}

fn human_cell(value: &Value) -> String {
    match value {
        Value::Null => "-".to_string(),
        Value::String(value) => value.replace(['\r', '\n'], "\\n"),
        Value::Bool(value) => value.to_string(),
        Value::Number(value) => value.to_string(),
        value => serde_json::to_string(value).expect("JSON value serialization cannot fail"),
    }
}

fn human_header(key: &str) -> String {
    key.replace('_', " ").to_uppercase()
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

pub(super) fn resolve_socket(global: &GlobalArgs) -> anyhow::Result<PathBuf> {
    Ok(resolve_socket_with_origin(global)?.0)
}

/// Resolve a socket and report whether it belongs to cmux's private runtime
/// directory. Environment-selected and explicit paths remain caller-managed.
pub(super) fn resolve_socket_with_origin(global: &GlobalArgs) -> anyhow::Result<(PathBuf, bool)> {
    if let Some(path) = &global.socket {
        return Ok((path.clone(), false));
    }
    if let Some(session) = &global.session {
        return Ok((cmux_tui_core::server::try_default_socket_path(session)?, true));
    }
    for name in ["CMUX_TUI_SOCKET", "CMUX_MUX_SOCKET"] {
        if let Some(path) = std::env::var_os(name)
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
