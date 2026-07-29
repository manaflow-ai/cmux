use std::io::{self, BufRead, BufReader, Read, Write};
use std::path::PathBuf;
use std::time::Duration;

use cmux_tui_core::platform::transport;
use cmux_tui_core::resource::{
    EnvelopeType, MAX_MESSAGE_BYTES, OperationClass, PROTOCOL, ResponseEnvelope, StreamEndEnvelope,
    StreamEndReason, StreamItemEnvelope,
};
use serde_json::{Value, json};

use super::command::{RequestPlan, random_prefixed};
use super::{GlobalArgs, OutputMode, UsageError};

const RESPONSE_LIMIT: usize = 16 * 1024 * 1024;

pub(super) fn run(global: GlobalArgs, mut plan: RequestPlan) -> i32 {
    if plan.stream && global.output == OutputMode::Json {
        eprintln!("cmux-tui: streams require --jsonl, --quiet, or human output");
        return 2;
    }
    let Some(params) = plan.params.as_object_mut() else {
        eprintln!("cmux-tui: request params are not an object");
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
            eprintln!("cmux-tui: {error}");
            return 2;
        }
    };
    let encoded = match serde_json::to_vec(&request) {
        Ok(encoded) if encoded.len() <= MAX_MESSAGE_BYTES => encoded,
        Ok(_) => {
            eprintln!("cmux-tui: request exceeds the 4 MiB protocol limit");
            return 2;
        }
        Err(error) => {
            eprintln!("cmux-tui: cannot encode request: {error}");
            return 2;
        }
    };
    let request_id =
        request["id"].as_str().expect("locally built request IDs are strings").to_string();

    let socket = resolve_socket(&global);
    let stream = match transport::connect(&socket) {
        Ok(stream) => stream,
        Err(error) => {
            eprintln!("cannot connect to session socket {}: {error}", socket.display());
            return 3;
        }
    };
    let _ = stream.set_read_timeout(Some(if plan.stream {
        Duration::from_millis(250)
    } else {
        Duration::from_secs(10)
    }));
    let mut reader = BufReader::new(stream);
    if let Err(error) = reader.get_mut().write_all(&encoded).and_then(|_| {
        reader.get_mut().write_all(b"\n")?;
        reader.get_mut().flush()
    }) {
        eprintln!("transport error: {error}");
        return 3;
    }
    run_response(&mut reader, &global, &plan, &request_id)
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
                eprintln!("{error}");
                return 3;
            }
        };
        match value.get("type").and_then(Value::as_str) {
            Some("response") => {
                let response: ResponseEnvelope = match serde_json::from_value(value) {
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
                    let error = serde_json::to_value(response.error.expect("validated error"))
                        .expect("resource errors serialize");
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
                let end: StreamEndEnvelope = match serde_json::from_value(value) {
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
    match value {
        Value::Null => {}
        Value::String(value) => {
            stdout.write_all(value.as_bytes())?;
            if !value.ends_with('\n') {
                stdout.write_all(b"\n")?;
            }
        }
        Value::Array(values) => {
            for value in values {
                serde_json::to_writer(&mut stdout, value).map_err(io::Error::other)?;
                stdout.write_all(b"\n")?;
            }
        }
        value => {
            serde_json::to_writer(&mut stdout, value).map_err(io::Error::other)?;
            stdout.write_all(b"\n")?;
        }
    }
    stdout.flush()
}

fn resolve_socket(global: &GlobalArgs) -> PathBuf {
    if let Some(path) = &global.socket {
        return path.clone();
    }
    for name in ["CMUX_TUI_SOCKET", "CMUX_MUX_SOCKET"] {
        if let Some(path) = std::env::var_os(name)
            && !path.is_empty()
        {
            return PathBuf::from(path);
        }
    }
    cmux_tui_core::server::default_socket_path(global.session.as_deref().unwrap_or("main"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use cmux_tui_core::resource::ResourceOperation;

    #[test]
    fn mutation_request_has_a_key_and_read_does_not() {
        let mutation = RequestPlan {
            operation: super::super::command::WireOperation::Typed(
                ResourceOperation::WorkspaceCreate,
            ),
            params: json!({"initial_content":"empty"}),
            idempotency_key: None,
            stream: false,
        };
        assert!(request_value(&mutation).unwrap().get("idempotency_key").is_some());

        let read = RequestPlan {
            operation: super::super::command::WireOperation::Typed(
                ResourceOperation::WorkspaceList,
            ),
            params: json!({}),
            idempotency_key: None,
            stream: false,
        };
        assert!(request_value(&read).unwrap().get("idempotency_key").is_none());
    }
}
