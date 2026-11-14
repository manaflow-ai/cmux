//! The daemon's link to the local Tasks owner (`cmux-tasks serve`,
//! plans/cmux-next/tasks.md section 5): the routed `tasks` namespace of
//! spec/page-router.json, which the Tasks page calls on its page relay.
//!
//! - `tasks.snapshot {}` answers the owner's mirror bootstrap (the
//!   `task.subscribe` snapshot as the local person sees it).
//! - `tasks.<verb>` runs the owner op `task.<verb>` with the request's
//!   idempotency key and origin `user`, and answers `{result, seq, replay}`: `seq`
//!   is the owner's committed sequence after the request, so a client keeps
//!   its optimistic copy until its mirror reaches it.
//!   `tasks.delegate` names its agent session `agent_session`: the router
//!   takes a page's `session` as its host selector, so the field is the
//!   owner's `session` only on this side of the router.
//! - Every committed owner event reaches subscribers as
//!   `tasks-changed {change: Event}`; `tasks-changed {lost: true}` says the
//!   owner link ended (the page shows it and reads the snapshot again).
//!
//! The daemon only relays: the owner stays the single writer, and the
//! daemon keeps no copy. It never starts the owner; a missing owner is
//! `tasks.owner_unreachable`.

use std::path::PathBuf;
use std::sync::{Arc, Mutex, PoisonError, Weak};

use serde_json::{Value, json};

use crate::Mux;
use crate::resource::ResourceError;

/// The owner's reply deadline for one request (a local socket; the owner
/// answers after one group commit).
#[cfg(unix)]
const CALL_DEADLINE: std::time::Duration = std::time::Duration::from_secs(5);

/// The owner ops a page may run through `tasks.<verb>` (spec/page-router.json
/// `namespaces.tasks.mutation`, owner `task.<verb>`).
pub(crate) const MUTATIONS: &[&str] = &["create", "update", "move", "archive", "delegate"];

/// The daemon's Tasks owner link: where the owner listens, and whether the
/// event watcher runs.
#[derive(Default)]
pub(crate) struct TasksLink {
    /// The owner socket; `None` resolves the local team's
    /// (`cmux_tasks::owner::resolve`, `CMUX_TASKS_HOME`).
    socket: Mutex<Option<PathBuf>>,
    /// True while a watcher holds a subscription on the owner.
    watching: Arc<Mutex<bool>>,
}

impl TasksLink {
    /// Points the link at `socket` (tests).
    #[cfg(test)]
    pub(crate) fn set_socket(&self, socket: PathBuf) {
        *self.socket.lock().unwrap_or_else(PoisonError::into_inner) = Some(socket);
    }

    fn socket(&self) -> Result<PathBuf, String> {
        if let Some(socket) = self.socket.lock().unwrap_or_else(PoisonError::into_inner).clone() {
            return Ok(socket);
        }
        match cmux_tasks::owner::resolve(None, None)? {
            cmux_tasks::owner::Owner::Local(owner) => Ok(owner.socket),
            cmux_tasks::owner::Owner::TeamVm { team } => {
                Err(format!("the Tasks owner of team {team} is not on this machine"))
            }
        }
    }
}

/// The owner's error as a routed failure (`extra.code` is `tasks.<code>`).
fn owner_error(operation: &str, code: &str, message: impl Into<String>) -> ResourceError {
    ResourceError::operation_failed(operation, message, json!({"code": format!("tasks.{code}")}))
}

fn unreachable(operation: &str, message: impl Into<String>) -> ResourceError {
    owner_error(operation, "owner_unreachable", message)
}

/// One routed `tasks.*` request (page_router.rs). `params` carries the
/// routed `idempotency_key` of a mutation.
pub(crate) fn call(
    mux: &Arc<Mux>,
    operation: &str,
    mut params: serde_json::Map<String, Value>,
) -> Result<Value, ResourceError> {
    let link = &mux.control_clients.tasks;
    let socket = link.socket().map_err(|message| unreachable(operation, message))?;
    if operation == "tasks.snapshot" {
        if !params.is_empty() {
            return Err(ResourceError::validation_invalid(
                Some("params"),
                "tasks.snapshot takes no params",
            ));
        }
        return snapshot(mux, &socket, operation);
    }
    let verb = operation.strip_prefix("tasks.").filter(|verb| MUTATIONS.contains(verb));
    let Some(verb) = verb else {
        return Err(owner_error(operation, "usage", "unknown Tasks operation"));
    };
    let key = match params.remove("idempotency_key") {
        Some(Value::String(key)) => key,
        _ => {
            return Err(ResourceError::validation_invalid(
                Some("idempotency_key"),
                "a Tasks mutation needs an idempotency_key",
            ));
        }
    };
    mutate(
        &socket,
        operation,
        &format!("task.{verb}"),
        Value::Object(owner_params(verb, params)),
        key,
    )
}

/// The owner's params for `verb`: a delegate's `agent_session` is the
/// owner's `session` (the page cannot send `session`, the router's selector).
fn owner_params(
    verb: &str,
    mut params: serde_json::Map<String, Value>,
) -> serde_json::Map<String, Value> {
    if verb == "delegate"
        && let Some(session) = params.remove("agent_session")
    {
        params.insert("session".to_owned(), session);
    }
    params
}

#[cfg(unix)]
fn connect(
    socket: &std::path::Path,
    operation: &str,
) -> Result<cmux_tasks::client::Conn, ResourceError> {
    use std::os::unix::net::UnixStream;
    // No hello: the owner stamps a connection without one as the machine's
    // person (P8: a caller never states its actor).
    let stream = UnixStream::connect(socket).map_err(|_| {
        unreachable(operation, "Tasks is not running. Start it with cmux task serve.")
    })?;
    let _ = stream.set_read_timeout(Some(CALL_DEADLINE));
    cmux_tasks::client::Conn::from_socket(stream)
        .map_err(|error| unreachable(operation, error.to_string()))
}

#[cfg(unix)]
fn mutate(
    socket: &std::path::Path,
    operation: &str,
    op: &str,
    params: Value,
    key: String,
) -> Result<Value, ResourceError> {
    let mut conn = connect(socket, operation)?;
    match conn.call_with_origin(
        op,
        params,
        Some(key),
        Some(cmux_tasks_core::Origin::User),
        CALL_DEADLINE,
    ) {
        Ok((reply, seq)) => Ok(routed_reply(reply, seq)),
        Err(error) => Err(owner_error(operation, &error_code(&error.code), error.message)),
    }
}

/// The routed mutation answer `{result, seq, replay}`: the owner's reply
/// `{result, seq, replay}` with its op result at the top level, and `seq` the
/// settled sequence the page waits for (not a second `result` wrapper).
fn routed_reply(reply: Value, seq: u64) -> Value {
    let (result, replay) = match reply {
        Value::Object(mut fields) => (
            fields.remove("result").unwrap_or(Value::Null),
            fields.remove("replay").unwrap_or(Value::Bool(false)),
        ),
        other => (other, Value::Bool(false)),
    };
    json!({"result": result, "seq": seq, "replay": replay})
}

#[cfg(unix)]
fn error_code(code: &cmux_tasks::protocol::ErrorCode) -> String {
    serde_json::to_value(code)
        .ok()
        .and_then(|value| value.as_str().map(str::to_owned))
        .unwrap_or_else(|| "internal".to_owned())
}

/// The owner's snapshot. The first read also starts the watcher on the same
/// subscription, so no committed event falls between the snapshot and the
/// events subscribers hear; later reads take a fresh subscription's snapshot.
#[cfg(unix)]
fn snapshot(
    mux: &Arc<Mux>,
    socket: &std::path::Path,
    operation: &str,
) -> Result<Value, ResourceError> {
    let watching = mux.control_clients.tasks.watching.clone();
    let mut running = watching.lock().unwrap_or_else(PoisonError::into_inner);
    let mut conn = connect(socket, operation)?;
    let snapshot = read_snapshot(&mut conn, operation)?;
    if !*running {
        *running = true;
        conn.clear_deadline();
        let mux = Arc::downgrade(mux);
        let flag = watching.clone();
        let spawned = std::thread::Builder::new()
            .name("cmux-tasks-watch".to_owned())
            .spawn(move || watch(conn, &mux, &flag));
        if spawned.is_err() {
            *running = false;
        }
    }
    Ok(snapshot)
}

#[cfg(unix)]
fn read_snapshot(
    conn: &mut cmux_tasks::client::Conn,
    operation: &str,
) -> Result<Value, ResourceError> {
    use cmux_tasks::protocol::ServerLine;
    let (_, _) = conn
        .call_with_origin("task.subscribe", json!({}), None, None, CALL_DEADLINE)
        .map_err(|error| owner_error(operation, &error_code(&error.code), error.message))?;
    // The snapshot line follows the subscribe's settle line.
    loop {
        match conn.read_line() {
            Ok(ServerLine::Snapshot { snapshot }) => return Ok(snapshot),
            Ok(_) => {}
            Err(error) => {
                return Err(owner_error(operation, &error_code(&error.code), error.message));
            }
        }
    }
}

/// Forwards each owner event as `tasks-changed` until the owner ends the
/// connection (the stop condition), or the daemon is gone.
#[cfg(unix)]
fn watch(mut conn: cmux_tasks::client::Conn, mux: &Weak<Mux>, running: &Mutex<bool>) {
    use cmux_tasks::protocol::ServerLine;
    loop {
        let line = conn.read_line();
        let Some(mux) = mux.upgrade() else { break };
        match line {
            Ok(ServerLine::Event { event }) => {
                let change = serde_json::to_value(&event).unwrap_or(Value::Null);
                mux.emit(crate::MuxEvent::TasksChanged(Arc::new(
                    json!({"event": "tasks-changed", "change": change}),
                )));
            }
            Ok(_) => {}
            Err(_) => {
                *running.lock().unwrap_or_else(PoisonError::into_inner) = false;
                mux.emit(crate::MuxEvent::TasksChanged(Arc::new(
                    json!({"event": "tasks-changed", "lost": true}),
                )));
                return;
            }
        }
    }
    *running.lock().unwrap_or_else(PoisonError::into_inner) = false;
}

#[cfg(not(unix))]
fn snapshot(
    _mux: &Arc<Mux>,
    _socket: &std::path::Path,
    operation: &str,
) -> Result<Value, ResourceError> {
    Err(unreachable(operation, "the Tasks owner is reachable on Unix only"))
}

#[cfg(not(unix))]
fn mutate(
    _socket: &std::path::Path,
    operation: &str,
    _op: &str,
    _params: Value,
    _key: String,
) -> Result<Value, ResourceError> {
    Err(unreachable(operation, "the Tasks owner is reachable on Unix only"))
}

#[cfg(all(test, unix))]
mod tests;
