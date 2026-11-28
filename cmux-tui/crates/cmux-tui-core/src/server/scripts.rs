//! Wire adapter for script sessions (crate::scripts,
//! plans/cmux-next/scripting-runtime.md phase 1).
//!
//! Requests (JSON lines like every v12 command):
//!
//! | `cmd` | fields | reply `data` |
//! | --- | --- | --- |
//! | `script-run` | `code`, `args?` (object), `timeout_ms?` | `{value}` |
//! | `script-repl-open` | | `{session}` |
//! | `script-repl-eval` | `session`, `code`, `args?`, `timeout_ms?` | `{value}` |
//! | `script-repl-close` | `session` | `{closed}` |
//!
//! Console output arrives before the reply as events `{event: "script-log",
//! request?, session?, level, message}`. `cancel-request {target}` ends a
//! running cell (and its session). Only local connections that are not bound
//! to an agent may run scripts; the connection's sessions end when it closes.

use std::sync::Arc;

use cmux_app_host::script::{LogSink, ScriptError};
use serde::Deserialize;
use serde_json::{Value, json};

use super::{MessageWriter, Response, send_response};
use crate::mux::Mux;
use crate::scripts::{Answer, FORBIDDEN, LogBudget, ScriptsSlot, UNAVAILABLE, timeout_from};

#[derive(Deserialize)]
#[serde(tag = "cmd")]
enum Command {
    #[serde(rename = "script-run")]
    Run {
        code: String,
        #[serde(default)]
        args: Value,
        #[serde(default)]
        timeout_ms: Option<u64>,
    },
    #[serde(rename = "script-repl-open")]
    Open,
    #[serde(rename = "script-repl-eval")]
    Eval {
        session: String,
        code: String,
        #[serde(default)]
        args: Value,
        #[serde(default)]
        timeout_ms: Option<u64>,
    },
    #[serde(rename = "script-repl-close")]
    Close { session: String },
}

#[derive(Deserialize)]
struct Request {
    #[serde(default)]
    id: Option<Value>,
    #[serde(flatten)]
    command: Command,
}

fn reply(writer: &MessageWriter, id: Option<Value>, result: Result<Value, ScriptError>) -> bool {
    match result {
        Ok(data) => send_response(
            writer,
            Response {
                id,
                ok: true,
                data: Some(data),
                error: None,
                error_code: None,
                error_delivery: None,
            },
        ),
        Err(e) => {
            let mut value = json!({ "ok": false, "error": e.message, "error_code": e.code });
            if let Some(id) = id {
                value["id"] = id;
            }
            if !e.details.is_null() {
                value["error_details"] = e.details;
            }
            writer.send_control(&value).is_ok()
        }
    }
}

/// `script-log` events for one request or session, on this connection,
/// within the cell's line budget.
fn log_sink(
    writer: &MessageWriter,
    budget: Arc<LogBudget>,
    tag: Arc<dyn Fn() -> (&'static str, Value) + Send + Sync>,
) -> LogSink {
    let writer = writer.clone();
    Arc::new(move |level: &str, message: &str| {
        if !budget.admit() {
            return;
        }
        let (name, value) = tag();
        let mut event = json!({ "event": "script-log", "level": level, "message": message });
        event[name] = value;
        let _ = writer.send_control(&event);
    })
}

/// `{value, dropped_log_lines?}`.
fn answer_json(answer: Answer) -> Value {
    let mut data = json!({ "value": answer.value });
    if answer.dropped_log_lines > 0 {
        data["dropped_log_lines"] = json!(answer.dropped_log_lines);
    }
    data
}

/// Script args are an object; anything else is empty.
fn args_object(args: Value) -> Value {
    if args.is_object() { args } else { json!({}) }
}

/// Why `client` may not run scripts, if it may not.
fn refusal(mux: &Mux, client: u64) -> Option<ScriptError> {
    if !mux.control_clients.is_unix(client) {
        return Some(ScriptError::new(FORBIDDEN, "scripts need a local connection"));
    }
    // A page relay carries a page's requests (origin page); a script must
    // never run with more than its caller's rights.
    let page = {
        let state =
            mux.control_clients.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        state.clients.get(&client).is_some_and(|record| {
            record.origin.derive() == crate::request_origin::RequestOrigin::Page
        })
    };
    if page {
        return Some(ScriptError::new(FORBIDDEN, "page connections cannot run scripts"));
    }
    // Agent principals and their review gates come with phase 3; until then
    // a connection bound to an agent runs no scripts.
    if mux.conversation_principal(client) != crate::conversation_store::LOCAL_USER {
        return Some(ScriptError::new(FORBIDDEN, "agent connections cannot run scripts yet"));
    }
    if !ScriptsSlot::available() {
        return Some(ScriptError::new(UNAVAILABLE, "this daemon has no script host"));
    }
    None
}

/// Runs `job` off the connection thread and replies with its result.
fn answer_later(
    writer: &MessageWriter,
    id: Option<Value>,
    job: impl FnOnce() -> Result<Value, ScriptError> + Send + 'static,
) -> bool {
    let writer = writer.clone();
    let spawned = std::thread::Builder::new().name("cmux-script".into()).spawn({
        let writer = writer.clone();
        let id = id.clone();
        move || {
            reply(&writer, id, job());
        }
    });
    match spawned {
        Ok(_) => true,
        Err(e) => {
            reply(&writer, id, Err(ScriptError::new("script.host", format!("no thread: {e}"))))
        }
    }
}

/// Handles a `script-*` command; `None` when the message is not one.
pub(super) fn try_handle(
    mux: &Arc<Mux>,
    client: u64,
    message: &str,
    writer: &MessageWriter,
) -> Option<bool> {
    if !message.contains("\"script-") {
        return None;
    }
    let value: Value = serde_json::from_str(message).ok()?;
    if !value.get("cmd").and_then(Value::as_str)?.starts_with("script-") {
        return None;
    }
    let id = value.get("id").cloned();
    let request = match serde_json::from_value::<Request>(value) {
        Ok(request) => request,
        Err(e) => {
            return Some(reply(writer, id, Err(ScriptError::new("bad-request", e.to_string()))));
        }
    };
    let Request { id, command } = request;
    // Cancel and bookkeeping key by request id: a cell needs one.
    let request_id = id.clone().filter(|id| !id.is_null());
    if request_id.is_none() && !matches!(command, Command::Close { .. }) {
        return Some(reply(
            writer,
            id,
            Err(ScriptError::new("bad-request", "script requests need an id")),
        ));
    }
    if let Some(refused) = refusal(mux, client) {
        return Some(reply(writer, id, Err(refused)));
    }
    let request_id = request_id.unwrap_or_default();
    let request_key = request_id.to_string();
    Some(match command {
        Command::Run { code, args, timeout_ms } => {
            let mux = mux.clone();
            let budget = Arc::new(LogBudget::default());
            let tag = request_id;
            let log = log_sink(writer, budget.clone(), Arc::new(move || ("request", tag.clone())));
            answer_later(writer, id, move || {
                mux.control_clients
                    .scripts
                    .run(
                        &mux,
                        client,
                        request_key,
                        &code,
                        args_object(args),
                        timeout_from(timeout_ms),
                        log,
                        budget,
                    )
                    .map(answer_json)
            })
        }
        Command::Open => {
            let mux = mux.clone();
            let writer = writer.clone();
            answer_later(&writer.clone(), id, move || {
                // The session id is known only after the host starts, so the
                // sink reads it from a cell set right after.
                let session_tag = Arc::new(std::sync::OnceLock::<String>::new());
                let read_tag = session_tag.clone();
                let budget = Arc::new(LogBudget::default());
                let sink = log_sink(
                    &writer,
                    budget.clone(),
                    Arc::new(move || {
                        ("session", json!(read_tag.get().cloned().unwrap_or_default()))
                    }),
                );
                let session =
                    mux.control_clients.scripts.open(&mux, client, request_key, sink, budget)?;
                let _ = session_tag.set(session.clone());
                Ok(json!({ "session": session }))
            })
        }
        Command::Eval { session, code, args, timeout_ms } => {
            let mux = mux.clone();
            answer_later(writer, id, move || {
                mux.control_clients
                    .scripts
                    .eval(
                        client,
                        request_key,
                        &session,
                        &code,
                        args_object(args),
                        timeout_from(timeout_ms),
                    )
                    .map(answer_json)
            })
        }
        Command::Close { session } => {
            let closed = mux.control_clients.scripts.close(client, &session);
            reply(writer, id, Ok(json!({ "closed": closed })))
        }
    })
}

#[cfg(test)]
#[path = "scripts_tests.rs"]
mod tests;
