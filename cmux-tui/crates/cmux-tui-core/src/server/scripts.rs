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

use crate::panic_free::JsonFields;
use std::sync::Arc;

use cmux_app_host::script::{LogSink, ScriptError};
use serde::Deserialize;
use serde_json::{Value, json};

use super::routes::RouteLine;
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
                value.insert("id", id);
            }
            if !e.details.is_null() {
                value.insert("error_details", e.details);
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
        event.insert(name, value);
        let _ = writer.send_control(&event);
    })
}

/// `{value, dropped_log_lines?}`.
fn answer_json(answer: Answer) -> Value {
    let mut data = json!({ "value": answer.value });
    if answer.dropped_log_lines > 0 {
        data.insert("dropped_log_lines", json!(answer.dropped_log_lines));
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

/// Runs `job` off the connection thread and replies with its result: a
/// request wait (`request_wait.rs`; the script host is another process),
/// not a thread per request.
fn answer_later(
    mux: &Mux,
    writer: &MessageWriter,
    id: Option<Value>,
    job: impl FnOnce() -> Result<Value, ScriptError> + Send + 'static,
) -> bool {
    // The job keeps the cause and class of the frame that started it.
    let (cause, request_qos) = (crate::event_cause::EventCause::current(), mux.request_qos());
    let (job_writer, job_id) = (writer.clone(), id.clone());
    let posted = mux.post_request_wait(move || {
        let _cause = request_qos.enter(cause);
        reply(&job_writer, job_id, job());
    });
    match posted {
        Ok(()) => true,
        Err(_) => {
            reply(writer, id, Err(ScriptError::new("script.host", "the daemon is shutting down")))
        }
    }
}

/// The `cmd` names this module answers (server/routes.rs).
pub(in crate::server) const ROUTES: &[crate::server::routes::Route] =
    &[crate::server::routes::Route {
        names: &[crate::server::routes::RouteName::Prefix("script-")],
        stage: crate::server::FrameStage::Scripts,
        entry: handle,
    }];

/// Answers a line whose `cmd` starts with `script-` (the route found it by
/// name). The line's one decode is its `Value`: it gives every reply the
/// `id` as written, a refused one too, and then the typed [`Request`].
/// `None` only for a line with no `Value` (a number past `f64`, a lone
/// surrogate); the `Command` parse answers it.
fn handle(line: &RouteLine<'_>) -> Option<bool> {
    let RouteLine { mux, client, message, writer, .. } = *line;
    let value: Value = crate::line_parses::parse(message).ok()?;
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
            let owner = mux;
            let mux = mux.clone();
            let budget = Arc::new(LogBudget::default());
            let tag = request_id;
            let log = log_sink(writer, budget.clone(), Arc::new(move || ("request", tag.clone())));
            answer_later(owner, writer, id, move || {
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
            let owner = mux;
            let mux = mux.clone();
            let writer = writer.clone();
            answer_later(owner, &writer.clone(), id, move || {
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
            let owner = mux;
            let mux = mux.clone();
            answer_later(owner, writer, id, move || {
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
