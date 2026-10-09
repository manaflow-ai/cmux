//! `chief.engine.get`, `chief.engine.set` and `chief.stop`: the owner's
//! control of the Chief brain on `cmux.protocol/2`. Like `chief-inspect`, the
//! daemon forwards one line to the brain host's tools socket
//! (`CMUX_TUI_CHIEF_TOOLS_SOCKET`) and answers its JSON; the brain owns the
//! engine file and the turn. Owner only (risk: owner): a registered Unix
//! client with no link peer record acting as `user_local` (a local client or
//! the link's owner_session splice). An agent-bound connection (the Chief's
//! own turns, its subagents), a relayed, WebSocket or page connection is
//! refused before anything is forwarded, so no agent can change the Chief's
//! engine or stop its turn.

use std::path::Path;
use std::sync::Arc;

use serde_json::{Value, json};

use super::{
    ClientTransport, MessageWriter, Mux, ResourceError, ResourceOperation, send_resource_response,
};
use crate::conversation_store::LOCAL_USER;
use crate::resource_router::ParsedResourceRequest;

#[cfg(unix)]
const TIMEOUT: std::time::Duration = std::time::Duration::from_secs(10);
/// The brain's answers are small; a larger line is refused.
#[cfg(unix)]
const MAX_REPLY_BYTES: u64 = 1024 * 1024;

pub(super) const fn handles(operation: ResourceOperation) -> bool {
    matches!(
        operation,
        ResourceOperation::ChiefEngineGet
            | ResourceOperation::ChiefEngineSet
            | ResourceOperation::ChiefStop
    )
}

/// Checks the owner on this thread, then asks the brain on its own thread
/// (it waits on another process) and answers through `writer`.
pub(super) fn handle(
    mux: &Arc<Mux>,
    client: u64,
    request: ParsedResourceRequest,
    writer: &MessageWriter,
) -> bool {
    handle_with(mux, client, request, writer, None)
}

/// [`handle`] with the brain's tools socket given (tests); `None` is the
/// configured one.
pub(super) fn handle_with(
    mux: &Arc<Mux>,
    client: u64,
    request: ParsedResourceRequest,
    writer: &MessageWriter,
    socket: Option<std::path::PathBuf>,
) -> bool {
    let id = request.envelope.id.clone();
    let operation = request.envelope.operation;
    if let Err(error) = require_owner(mux, client) {
        return send_resource_response(writer, id, operation, Err(error));
    }
    let line = tool_line(operation, &request.fields);
    let (mux, thread_writer, reply_id) = (mux.clone(), writer.clone(), id.clone());
    let spawned = std::thread::Builder::new().name("mux-chief-control".into()).spawn(move || {
        let answer = ask(operation, &line, socket.as_deref());
        send_resource_response(
            &thread_writer,
            reply_id,
            operation,
            result(&mux, operation, answer),
        );
    });
    spawned.is_ok()
        || send_resource_response(
            writer,
            id,
            operation,
            Err(ResourceError::operation_failed(
                operation.wire_name(),
                "unavailable",
                json!({"message": "cannot start the Chief control request"}),
            )),
        )
}

/// The owner rule of `chief-inspect`, as an `origin.forbidden` refusal.
pub(super) fn require_owner(mux: &Mux, client: u64) -> Result<(), ResourceError> {
    let unix = matches!(mux.control_clients.transport_of(client), Some(ClientTransport::Unix));
    let principal = mux.conversation_principal(client);
    if unix && !mux.is_remote_client(client) && principal == LOCAL_USER {
        return Ok(());
    }
    Err(crate::request_origin::forbidden(
        "Chief control is for the owner's trusted connection only",
        json!({"derived": "agent", "required": "user", "reason": "chief_owner_only"}),
    ))
}

/// The tools-socket line of `operation` (optchat-chief's `engine` and
/// `stop` tools).
pub(super) fn tool_line(
    operation: ResourceOperation,
    fields: &serde_json::Map<String, Value>,
) -> Value {
    match operation {
        ResourceOperation::ChiefEngineGet => json!({"tool": "engine", "action": "show"}),
        ResourceOperation::ChiefEngineSet => {
            let mut line = json!({"tool": "engine", "action": "set"});
            for key in ["harness", "model", "effort"] {
                if let Some(value) = fields.get(key) {
                    line[key] = value.clone();
                }
            }
            line
        }
        _ => json!({"tool": "stop"}),
    }
}

/// The v2 result of the brain's `answer`.
pub(super) fn result(
    mux: &Mux,
    operation: ResourceOperation,
    answer: Result<Value, ResourceError>,
) -> Result<Value, ResourceError> {
    let answer = answer?;
    if let Some(error) = answer.get("error") {
        let code = error.get("code").and_then(Value::as_str).filter(|c| !c.is_empty());
        let message = error.get("message").and_then(Value::as_str).unwrap_or_default();
        return Err(ResourceError::operation_failed(
            operation.wire_name(),
            code.unwrap_or("internal"),
            json!({"message": message}),
        ));
    }
    let value = match operation {
        ResourceOperation::ChiefEngineGet => return Ok(answer),
        ResourceOperation::ChiefStop => {
            json!({"stopped": answer.get("stopped").and_then(Value::as_bool).unwrap_or(false)})
        }
        _ => answer,
    };
    // The change is the brain's, not the session registry's: revision 0.
    let (_, generation) = mux.registry_identity();
    Ok(json!({"value": value, "generation": generation, "revision": "0", "replayed": false}))
}

/// Sends `line` to the brain's tools socket (`socket` overrides the
/// configured one in tests) and reads its one-line JSON answer.
#[cfg(unix)]
pub(super) fn ask(
    operation: ResourceOperation,
    line: &Value,
    socket: Option<&Path>,
) -> Result<Value, ResourceError> {
    use std::io::{BufRead, BufReader, Read, Write};
    let failed = |reason: &str, message: String| {
        ResourceError::operation_failed(operation.wire_name(), reason, json!({"message": message}))
    };
    let path = match socket {
        Some(path) => path.to_owned(),
        None => super::chief_inspect::tools_socket().ok_or_else(|| {
            failed("not_configured", "no Chief tools socket on this daemon".into())
        })?,
    };
    let stream =
        super::chief_inspect::checked(&path).map_err(|e| failed("unavailable", e.to_string()))?;
    let io = |e: std::io::Error| failed("unavailable", e.to_string());
    stream.set_read_timeout(Some(TIMEOUT)).map_err(io)?;
    stream.set_write_timeout(Some(TIMEOUT)).map_err(io)?;
    (&stream).write_all(format!("{line}\n").as_bytes()).map_err(io)?;
    let mut reply = String::new();
    BufReader::new((&stream).take(MAX_REPLY_BYTES + 1)).read_line(&mut reply).map_err(io)?;
    if !reply.ends_with('\n') {
        return Err(failed("unavailable", "the Chief closed the tools socket mid-answer".into()));
    }
    serde_json::from_str(&reply).map_err(|e| failed("internal", e.to_string()))
}

#[cfg(not(unix))]
pub(super) fn ask(
    operation: ResourceOperation,
    _line: &Value,
    _socket: Option<&Path>,
) -> Result<Value, ResourceError> {
    Err(ResourceError::operation_failed(
        operation.wire_name(),
        "not_configured",
        json!({"message": "no Chief tools socket on this platform"}),
    ))
}

#[cfg(all(test, unix))]
#[path = "chief_control_tests.rs"]
mod tests;
