//! `chief.engine.get`, `chief.engine.set`, `chief.stop` and
//! `chief.automation.list|update` (the Chief's automations, issue 25573):
//! the owner's control of the Chief brain on `cmux.protocol/2`. Like `chief-inspect`, the
//! daemon forwards one line to the brain host's tools socket
//! (`CMUX_TUI_CHIEF_TOOLS_SOCKET`) and answers its JSON; the brain owns the
//! engine file and the turn. Owner only (risk: owner): a registered Unix
//! client with no link peer record acting as `user_local` (a local client or
//! the link's owner_session splice). An agent-bound connection (the Chief's
//! own turns, its subagents), a relayed, WebSocket or page connection is
//! refused before anything is forwarded, so no agent can change the Chief's
//! engine or stop its turn.
//!
//! chief-brains-v1 (cx-ebm.60.11): the optional `chief` field names the
//! Chief. Absent, null or the default Chief's id: the default Chief's brain
//! (the configured socket), as before. Another live Chief: its own brain's
//! tools socket under the daemon's Chief home (`chief_brains::tools_socket`),
//! so the request acts on that Chief only. An unknown Chief reaches no brain.

use crate::panic_free::JsonFields;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use serde_json::{Value, json};

use super::{
    ClientTransport, MessageWriter, Mux, ResourceError, ResourceOperation, send_resource_response,
};
use crate::chief_registry::DEFAULT_CHIEF;
use crate::conversation_store::LOCAL_USER;
use crate::resource_router::ParsedResourceRequest;

/// Advertised in identify when this daemon runs Chief brains
/// (`CMUX_TUI_CHIEF_BRAINS`): `chief.engine.*` and `chief.stop` take `chief`.
/// The default Chief's brain is still the app's (not the daemon's).
pub(super) const CAPABILITY: &str = "chief-brains-v1";

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
            | ResourceOperation::ChiefAutomationList
            | ResourceOperation::ChiefAutomationUpdate
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
    socket: Option<PathBuf>,
) -> bool {
    let id = request.envelope.id.clone();
    let operation = request.envelope.operation;
    if let Err(error) = require_owner(mux, client) {
        return send_resource_response(writer, id, operation, Err(error));
    }
    let route = match target(mux, operation, &request.fields, socket) {
        Ok(route) => route,
        Err(error) => return send_resource_response(writer, id, operation, Err(error)),
    };
    let line = tool_line(operation, &request.fields);
    let (mux, thread_writer, reply_id) = (mux.clone(), writer.clone(), id.clone());
    let spawned = std::thread::Builder::new().name("mux-chief-control".into()).spawn(move || {
        let chief = match &route {
            Route::Default(_) => DEFAULT_CHIEF.to_owned(),
            Route::Named(chief) => chief.clone(),
        };
        let socket = match route {
            Route::Default(socket) => Ok(socket),
            Route::Named(chief) => named_socket(&mux, operation, &chief).map(Some),
        };
        let answer = socket.and_then(|socket| {
            disabled_unless_answered(operation, ask(operation, &line, socket.as_deref()))
        });
        let answer = result(&mux, operation, answer);
        // The record is the backend's one source (u2586): a set the brain
        // took is written into the Chief's record too.
        if operation == ResourceOperation::ChiefEngineSet
            && let Ok(value) = &answer
            && let Some(choice) = value.pointer("/value/choice")
        {
            super::chief_registry_resource::record_brain_engine(&mux, &chief, choice);
        }
        send_resource_response(&thread_writer, reply_id, operation, answer);
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

/// Where a request goes: the default Chief's brain (the configured socket, or
/// a test's), or a live Chief named by id.
enum Route {
    Default(Option<PathBuf>),
    Named(String),
}

/// How long `chief.engine.set` waits for a brain it started on demand to
/// serve its tools socket.
#[cfg(unix)]
const START_WAIT: std::time::Duration = std::time::Duration::from_secs(15);

/// The route of the request: [`Route::Default`] for no `chief`, null or the
/// default Chief; [`Route::Named`] for another live Chief.
fn target(
    mux: &Mux,
    operation: ResourceOperation,
    fields: &serde_json::Map<String, Value>,
    default: Option<PathBuf>,
) -> Result<Route, ResourceError> {
    let chief = match fields.get("chief") {
        None | Some(Value::Null) => return Ok(Route::Default(default)),
        Some(Value::String(chief)) if chief == DEFAULT_CHIEF => return Ok(Route::Default(default)),
        Some(Value::String(chief)) => chief.as_str(),
        Some(_) => {
            return Err(ResourceError::validation_invalid(Some("chief"), "chief must be a string"));
        }
    };
    let failed = |reason: &str, message: String| {
        ResourceError::operation_failed(operation.wire_name(), reason, json!({"message": message}))
    };
    let live = {
        let mut store =
            mux.chiefs().store.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        if store.is_none() {
            let directory = mux.session_state_directory();
            *store = Some(
                crate::chief_registry::ChiefStore::open(directory.as_deref())
                    .map_err(|e| failed("internal", format!("{e:#}")))?,
            );
        }
        let Some(store) = store.as_ref() else {
            return Err(failed("internal", "chief registry is not open".to_owned()));
        };
        store.get(chief).map_err(|e| failed("internal", format!("{e:#}")))?.is_some()
    };
    if !live {
        return Err(failed("not_found", format!("no Chief {chief}")));
    }
    Ok(Route::Named(chief.to_owned()))
}

/// The tools socket of live Chief `chief`'s brain (runs on the request's own
/// thread). `chief.engine.set` starts a brain that does not run now (never
/// started, stopped after its idle time, or between restarts) through the
/// supervisor, the same start a message gives it, and waits up to
/// [`START_WAIT`] for its socket to answer; reads and `chief.stop` never
/// start a brain. A socket that does not answer is `unavailable` in `ask`.
#[cfg(unix)]
fn named_socket(
    mux: &Mux,
    operation: ResourceOperation,
    chief: &str,
) -> Result<PathBuf, ResourceError> {
    let failed = |reason: &str, message: String| {
        // As for the default Chief: with agents off no brain starts, so say why.
        if crate::agent_launch::disabled() {
            return ResourceError::operation_failed(
                operation.wire_name(),
                crate::agent_launch::REASON,
                json!({"message": crate::agent_launch::MESSAGE}),
            );
        }
        ResourceError::operation_failed(operation.wire_name(), reason, json!({"message": message}))
    };
    let answering = || {
        crate::chief_brains::tools_socket(chief)
            .ok()
            .filter(|path| super::chief_inspect::checked(path).is_ok())
    };
    if let Some(path) = answering() {
        return Ok(path);
    }
    let startable = operation == ResourceOperation::ChiefEngineSet
        && !crate::agent_launch::disabled()
        && !matches!(crate::chief_brains::tools_socket(chief), Err(("not_configured", _)));
    if startable {
        // The supervisor says at once when no brain process runs (restart
        // backoff, a start that failed): then do not wait.
        if let Some(answer) = mux.chiefs().brains.start_for_control(chief)
            && !answer.recv_timeout(std::time::Duration::from_secs(5)).unwrap_or(false)
        {
            return Err(match crate::chief_brains::tools_socket(chief) {
                Err((reason, message)) => failed(reason, message),
                Ok(_) => failed("unavailable", format!("Chief {chief}'s brain did not start")),
            });
        }
        // A readiness probe with a deadline: the brain binds its socket
        // when its host is up, and there is no start event to wait on.
        let deadline = std::time::Instant::now() + START_WAIT;
        while std::time::Instant::now() < deadline {
            if let Some(path) = answering() {
                return Ok(path);
            }
            std::thread::sleep(std::time::Duration::from_millis(50));
        }
    }
    crate::chief_brains::tools_socket(chief).map_err(|(reason, message)| failed(reason, message))
}

#[cfg(not(unix))]
fn named_socket(
    _mux: &Mux,
    operation: ResourceOperation,
    _chief: &str,
) -> Result<PathBuf, ResourceError> {
    Err(ResourceError::operation_failed(
        operation.wire_name(),
        "not_configured",
        json!({"message": "Chief brains run on unix only"}),
    ))
}

/// cx-tgf4h: with agents off in this build session the daemon starts no
/// brain, so a brain that does not answer is not "not running" but off on
/// purpose: the typed refusal. A brain that still runs (started before)
/// answers as always, so its turn can still be stopped.
fn disabled_unless_answered(
    operation: ResourceOperation,
    answer: Result<Value, ResourceError>,
) -> Result<Value, ResourceError> {
    match answer {
        Err(_) if crate::agent_launch::disabled() => Err(ResourceError::operation_failed(
            operation.wire_name(),
            crate::agent_launch::REASON,
            json!({"message": crate::agent_launch::MESSAGE}),
        )),
        other => other,
    }
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

/// The tools-socket line of `operation` (optchat-chief's `engine`, `stop`
/// and `automations` lines).
pub(super) fn tool_line(
    operation: ResourceOperation,
    fields: &serde_json::Map<String, Value>,
) -> Value {
    match operation {
        ResourceOperation::ChiefEngineGet => json!({"tool": "engine", "action": "show"}),
        ResourceOperation::ChiefEngineSet => {
            let mut line = json!({"tool": "engine", "action": "set"});
            for key in [
                "harness",
                "model",
                "effort",
                "speed",
                "compactor_speed",
                "compactor_harness",
                "compactor_model",
                // The reaction classifier (optchat-chief brain/reaction_wake.rs).
                "classifier_harness",
                "classifier_model",
                "classifier_prompt",
                "reactions_can_wake",
            ] {
                if let Some(value) = fields.get(key) {
                    line.insert(key, value.clone());
                }
            }
            line
        }
        ResourceOperation::ChiefAutomationList => json!({"tool": "automations", "action": "list"}),
        ResourceOperation::ChiefAutomationUpdate => {
            let mut line = json!({"tool": "automations"});
            for key in ["automation", "action"] {
                if let Some(value) = fields.get(key) {
                    line.insert(key, value.clone());
                }
            }
            line
        }
        _ => {
            let mut line = json!({"tool": "stop"});
            for key in ["name", "all", "restart"] {
                if let Some(value) = fields.get(key) {
                    line.insert(key, value.clone());
                }
            }
            line
        }
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
        ResourceOperation::ChiefEngineGet | ResourceOperation::ChiefAutomationList => {
            return Ok(answer);
        }
        ResourceOperation::ChiefStop => {
            let mut value =
                json!({"stopped": answer.get("stopped").and_then(Value::as_bool).unwrap_or(false)});
            // A named or stop-all stop's subagents and note, a restart's
            // restarted and errors (the brain's own words).
            for key in ["subagents", "note", "restarted", "errors"] {
                if let Some(v) = answer.get(key).filter(|v| !v.is_null()) {
                    value.insert(key, v.clone());
                }
            }
            value
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
