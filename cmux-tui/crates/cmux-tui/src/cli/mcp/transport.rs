//! The CLI's transport for a caller that reports results itself
//! (`cmux mcp serve`): one unary daemon request or one app control request
//! with the CLI's contract, returning the result or a `CallFailure` instead
//! of printing. It composes the CLI's own pieces (`wire`, `app`, `resolve`),
//! so the CLI and MCP send identical requests.

use std::io::{BufRead, BufReader};
use std::time::{Duration, Instant};

use cmux_tui_core::resource::{OperationClass, ResourceOperation};
use serde_json::{Map, Value, json};

use super::super::GlobalArgs;
use super::super::command::{RequestPlan, ResponseView, WireOperation, random_prefixed};
use super::super::{app, resolve, wire};
use cmux_json::JsonSet as _;

/// How a request that did not succeed ended: the owner rejected it, it
/// never reached the owner, or it may have reached the owner and its
/// outcome is unknown.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(in crate::cli) enum FailureKind {
    Rejected,
    NotRun,
    InProgress,
}

impl FailureKind {
    /// The `state` word a failure reports.
    pub(super) fn state(self) -> &'static str {
        match self {
            Self::Rejected => "rejected",
            Self::NotRun => "not_run",
            Self::InProgress => "in_progress",
        }
    }
}

/// A failed request: the owner's error object unchanged (or a local one in
/// the same `{code, message, details, retryable}` shape) and the mutation's
/// idempotency key, which a retry reuses so the change cannot apply twice.
#[derive(Clone, Debug, PartialEq)]
pub(in crate::cli) struct CallFailure {
    pub kind: FailureKind,
    pub error: Value,
    pub idempotency_key: Option<String>,
}

impl CallFailure {
    pub(in crate::cli) fn local(kind: FailureKind, code: &str, message: impl Into<String>) -> Self {
        Self {
            kind,
            error: json!({
                "code": code,
                "message": message.into(),
                "details": {},
                "retryable": kind != FailureKind::Rejected,
            }),
            idempotency_key: None,
        }
    }

    fn with_key(mut self, key: Option<&str>) -> Self {
        self.idempotency_key = key.map(str::to_owned);
        self
    }
}

/// A selector or id field that holds a unique prefix of a public id
/// (`ws_1a2b`): the one id `list` reports with that prefix replaces it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(in crate::cli) struct Prefix {
    pub field: String,
    pub list: ResourceOperation,
}

/// One unary daemon request: the CLI's route defaults, socket discovery,
/// idempotency key (generated for a mutation that carries none), response
/// deadline and protocol checks. `prefixes` resolve with list reads on the
/// request's own connection before it is sent, so the request carries ids.
pub(super) fn resource(
    global: &GlobalArgs,
    mut plan: RequestPlan,
    prefixes: &[Prefix],
) -> Result<Value, CallFailure> {
    use FailureKind::{InProgress, NotRun, Rejected};
    if plan.stream || !plan.resolve.is_empty() {
        return Err(CallFailure::local(NotRun, "usage.invalid", "not a plain unary request"));
    }
    resolve::apply_global_route(global, &mut plan)
        .map_err(|error| CallFailure::local(NotRun, "usage.invalid", error))?;
    let mut request = wire::request_value(&plan)
        .map_err(|error| CallFailure::local(NotRun, "usage.invalid", error.0))?;
    let key = request.get("idempotency_key").and_then(Value::as_str).map(str::to_owned);
    let fail = |kind, code: &str, message: String| {
        CallFailure::local(kind, code, message).with_key(key.as_deref())
    };
    let request_id =
        request["id"].as_str().expect("locally built request IDs are strings").to_string();
    let (socket, derived) = wire::resolve_socket_with_origin(global).map_err(|error| {
        CallFailure { kind: NotRun, error: wire::resolve_failure(&error), idempotency_key: None }
            .with_key(key.as_deref())
    })?;
    let stream =
        cmux_tui_core::server::connect_session_socket(&socket, derived).map_err(|error| {
            let message = format!("cannot connect to session socket {}: {error}", socket.display());
            fail(NotRun, "transport.unavailable", message)
        })?;
    let _ = stream.set_read_timeout(Some(wire::SERVER_PREFLIGHT_TIMEOUT));
    let mut reader = BufReader::new(stream);
    super::super::tab_capabilities::negotiate(&mut reader).map_err(|failure| match failure {
        // A local error in the resource shape (a server of another protocol) keeps its code.
        resolve::Failure::Resource(error) | resolve::Failure::Local { error, .. } => {
            CallFailure { kind: NotRun, error, idempotency_key: key.clone() }
        }
        resolve::Failure::Transport(message) => fail(NotRun, "transport.failed", message),
        resolve::Failure::Refused => fail(NotRun, "session.busy", "session is busy".into()),
        _ => fail(NotRun, "transport.failed", "client capability negotiation failed".into()),
    })?;
    if !prefixes.is_empty() {
        let params = plan.params.as_object_mut().expect("validated params object");
        let route = ["machine", "session"]
            .into_iter()
            .filter_map(|key| params.get(key).map(|value| (key.to_string(), value.clone())))
            .collect::<Map<_, _>>();
        for prefix in prefixes {
            let Some(value) = params.get(&prefix.field).and_then(Value::as_str) else { continue };
            let value = value.to_owned();
            let records = resolve::read(
                &mut reader,
                prefix.list,
                if prefix.list == ResourceOperation::MachineList {
                    params
                        .get("catalog")
                        .map(|value| ("catalog".into(), value.clone()))
                        .into_iter()
                        .collect()
                } else {
                    route.clone()
                },
            )
            .map_err(|failure| match failure {
                resolve::Failure::Resource(error) => {
                    CallFailure { kind: NotRun, error, idempotency_key: key.clone() }
                }
                resolve::Failure::Refused => fail(NotRun, "session.busy", "session is busy".into()),
                _ => fail(NotRun, "transport.failed", "lookup failed".into()),
            })?;
            let id = unique_prefix(&prefix.field, &value, &records).map_err(|error| {
                CallFailure { kind: NotRun, error, idempotency_key: key.clone() }
            })?;
            params.insert(prefix.field.clone(), Value::String(id));
        }
        request.set("params", plan.params.clone());
    }
    // A browser tab in a session a cmux app owns is the app's to render
    // (frontend_browser.rs), as the CLI's `tab create browser` does.
    #[cfg(unix)]
    if let Some(opened) = super::super::frontend_browser::open_in_app(
        global,
        &plan,
        &mut reader,
        &socket,
        key.as_deref(),
    ) {
        return opened.map_err(|failure| app_open_failure(failure, key.as_deref()));
    }
    super::super::launch_credential::attach(&mut reader, &socket, &mut request);
    let encoded = resolve::encode_request_bytes(&request)
        .map_err(|message| fail(NotRun, "validation.invalid", message))?;
    let _ = reader.get_mut().set_read_timeout(wire::response_read_timeout(&plan, true));
    // Once sent, a mutation's outcome is unknown until it answers; a read
    // changed nothing either way.
    let sent = if plan.operation.class() == OperationClass::Mutation { InProgress } else { NotRun };
    resolve::send_request(&mut reader, &encoded).map_err(|failure| match failure {
        resolve::Failure::Refused => fail(sent, "session.busy", "session is busy".into()),
        resolve::Failure::Transport(message) => fail(sent, "transport.failed", message),
        _ => fail(sent, "transport.failed", "request could not be sent".into()),
    })?;
    match resolve::read_response(&mut reader, &request_id).map_err(resolve::response_failure) {
        Ok(Ok(result)) => Ok(result),
        Ok(Err(error)) => {
            // A browser the cmux app draws: the app runs the verb
            // (app_browser_route.rs), as `cmux browser <id> <verb>` does.
            #[cfg(unix)]
            if let Some(routed) =
                super::super::app_browser_route::run(global, &plan, &error, &socket)
            {
                return routed.map_err(|error| CallFailure {
                    kind: Rejected,
                    error,
                    idempotency_key: key.clone(),
                });
            }
            Err(CallFailure { kind: Rejected, error, idempotency_key: key.clone() })
        }
        Err(resolve::Failure::Refused) => Err(fail(sent, "session.busy", "session is busy".into())),
        Err(resolve::Failure::Transport(message)) => Err(fail(sent, "transport.failed", message)),
        Err(_) => Err(fail(sent, "transport.failed", "request failed".into())),
    }
}

/// Opens the session daemon's `session.events` stream, from `cursor` when
/// given, and calls `on_wake` with each item (its initial snapshot first, or
/// the journal batches after `cursor`), and with `None` after each
/// `tick` without one, until `on_wake` returns `true`, the stream ends or
/// `deadline` passes. Blocking reads bounded by the tick; the daemon is
/// never polled, and dropping the connection ends the stream.
pub(super) fn session_events(
    global: &GlobalArgs,
    cursor: Option<&Value>,
    deadline: Instant,
    tick: Duration,
    on_wake: &mut dyn FnMut(Option<&Value>) -> bool,
) -> Result<(), CallFailure> {
    use FailureKind::{NotRun, Rejected};
    let local = |code: &str, message: String| CallFailure::local(NotRun, code, message);
    let stream_id = random_prefixed("stream").map_err(|error| local("usage.invalid", error.0))?;
    let mut plan = RequestPlan {
        operation: WireOperation::Typed(ResourceOperation::SessionEvents),
        params: json!({"machine": "current", "session": "current", "stream_id": stream_id}),
        idempotency_key: None,
        stream: true,
        resolve: Vec::new(),
        view: ResponseView::Full,
    };
    if let Some(cursor) = cursor {
        plan.params.set("cursor", cursor.clone());
    }
    resolve::apply_global_route(global, &mut plan)
        .map_err(|error| local("usage.invalid", error.into()))?;
    let request = wire::request_value(&plan).map_err(|error| local("usage.invalid", error.0))?;
    let request_id = request["id"].clone();
    let (socket, derived) = wire::resolve_socket_with_origin(global).map_err(|error| {
        CallFailure { kind: NotRun, error: wire::resolve_failure(&error), idempotency_key: None }
    })?;
    let stream =
        cmux_tui_core::server::connect_session_socket(&socket, derived).map_err(|error| {
            let message = format!("cannot connect to session socket {}: {error}", socket.display());
            local("transport.unavailable", message)
        })?;
    let left = deadline.saturating_duration_since(Instant::now());
    if left.is_zero() {
        return Ok(());
    }
    let _ = stream.set_read_timeout(Some(left.min(wire::SERVER_PREFLIGHT_TIMEOUT)));
    let mut reader = BufReader::new(stream);
    let negotiated = super::super::tab_capabilities::negotiate(&mut reader);
    if Instant::now() >= deadline {
        return Ok(());
    }
    negotiated.map_err(|failure| match failure {
        resolve::Failure::Resource(error) | resolve::Failure::Local { error, .. } => {
            CallFailure { kind: NotRun, error, idempotency_key: None }
        }
        resolve::Failure::Transport(message) => local("transport.failed", message),
        resolve::Failure::Refused => local("session.busy", "session is busy".into()),
        _ => local("transport.failed", "client capability negotiation failed".into()),
    })?;
    let encoded = resolve::encode_request_bytes(&request)
        .map_err(|message| local("validation.invalid", message))?;
    resolve::send_request(&mut reader, &encoded).map_err(|failure| match failure {
        resolve::Failure::Refused => local("session.busy", "session is busy".into()),
        resolve::Failure::Transport(message) => local("transport.failed", message),
        _ => local("transport.failed", "request could not be sent".into()),
    })?;
    let mut opened = false;
    let mut line = Vec::new();
    loop {
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return Ok(());
        }
        let _ = reader.get_mut().set_read_timeout(Some(left.min(tick)));
        // A read cut by the timeout keeps its bytes in `line` for the next one.
        match reader.read_until(b'\n', &mut line) {
            Ok(0) if opened => return Ok(()),
            Ok(0) => return Err(local("transport.failed", "the daemon closed the stream".into())),
            Ok(_) if line.ends_with(b"\n") => {}
            Ok(_) => continue,
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) =>
            {
                if opened && on_wake(None) {
                    return Ok(());
                }
                continue;
            }
            Err(_) if opened => return Ok(()),
            Err(error) => return Err(local("transport.failed", error.to_string())),
        }
        let frame = serde_json::from_slice::<Value>(&line);
        line.clear();
        let Ok(frame) = frame else { continue };
        match frame["type"].as_str() {
            Some("response") if frame["id"] == request_id => {
                if frame["ok"] != true {
                    let error = frame.get("error").cloned().unwrap_or(Value::Null);
                    return Err(CallFailure { kind: Rejected, error, idempotency_key: None });
                }
                opened = true;
            }
            // An item the caller does not stop on keeps the stream open.
            Some("stream_item")
                if opened
                    && frame["stream_id"] == plan.params["stream_id"]
                    && on_wake(Some(&frame["item"])) =>
            {
                return Ok(());
            }
            Some("stream_end") if opened => return Ok(()),
            _ => {}
        }
    }
}

/// A failed app-rendered browser creation as a `CallFailure`: a refusal of
/// a run that never started is `not_run`, another refusal `rejected`, and a
/// transport failure after the run may have started `in_progress`.
#[cfg(unix)]
fn app_open_failure(failure: resolve::Failure, key: Option<&str>) -> CallFailure {
    use FailureKind::{InProgress, NotRun, Rejected};
    let never_ran = super::super::frontend_browser::never_ran(&failure);
    let (kind, error) = match failure {
        resolve::Failure::Resource(error) => (if never_ran { NotRun } else { Rejected }, error),
        // A local refusal (the socket resolver's) never reached a daemon.
        resolve::Failure::Local { error, .. } => (NotRun, error),
        resolve::Failure::Transport(message) => (
            InProgress,
            json!({"code": "transport.failed", "message": message, "details": {}, "retryable": true}),
        ),
        resolve::Failure::Refused => (
            NotRun,
            json!({"code": "session.busy", "message": "session is busy", "details": {}, "retryable": true}),
        ),
        resolve::Failure::AppAction { action, .. } => (
            NotRun,
            json!({"code": "app.unreachable", "message": format!("{action} is an app action"), "details": {}, "retryable": false}),
        ),
    };
    CallFailure { kind, error, idempotency_key: key.map(str::to_owned) }
}

/// One app control request: the CLI's app discovery, read barrier
/// (`after: "sync"`), busy retry and, for `action.run`, an idempotency key
/// (`idempotency_key`, else a new one).
pub(super) fn app_method(
    global: &GlobalArgs,
    method: &str,
    mut params: Value,
    timeout: Duration,
    idempotency_key: Option<&str>,
    mutation: bool,
) -> Result<Value, CallFailure> {
    let socket = app::socket_path(global)
        .map_err(|error| CallFailure::local(FailureKind::NotRun, "app.not_found", error))?;
    let mut stream = app::connect(&socket)
        .map_err(|error| CallFailure::local(FailureKind::NotRun, "app.unreachable", error))?;
    let key = if method == "action.run" {
        let key = app::insert_run_key(&mut params, idempotency_key)
            .map_err(|error| CallFailure::local(FailureKind::NotRun, "app.transport", error))?;
        Some(key)
    } else {
        None
    };
    let failure = |kind, error| CallFailure { kind, error, idempotency_key: key.clone() };
    match app::request_with_retry(&mut stream, method, &params, timeout) {
        Ok(Ok(result)) => Ok(result),
        Ok(Err(error)) => Err(failure(FailureKind::Rejected, error)),
        // Once sent, a change's outcome is unknown; a read changed nothing.
        // Only a read or a keyed run is safe to send again.
        Err(message) => Err(failure(
            if key.is_some() || mutation { FailureKind::InProgress } else { FailureKind::NotRun },
            json!({
                "code": "app.transport",
                "message": message,
                "details": {},
                "retryable": key.is_some() || !mutation,
            }),
        )),
    }
}

/// Reads the app's `events.stream` and calls `on_frame` with each JSON frame
/// (the acknowledgement first), blocking until the app closes the stream
/// (`Ok`) or cannot be reached. Blocking reads, no polling.
pub(super) fn watch_app_events(
    global: &GlobalArgs,
    params: Value,
    mut on_frame: impl FnMut(&Value),
) -> Result<(), String> {
    let socket = app::socket_path(global)?;
    let mut stream = app::connect(&socket)?;
    let subscribe = json!({ "id": "events", "method": "events.stream", "params": params });
    app::send_line(&mut stream, &subscribe)?;
    let reader = BufReader::new(stream.try_clone().map_err(|error| error.to_string())?);
    for line in reader.lines() {
        let line = line.map_err(|error| error.to_string())?;
        let Ok(frame) = serde_json::from_str::<Value>(&line) else { continue };
        if frame.get("ok").and_then(Value::as_bool) == Some(false) {
            let message = frame["error"]["message"].as_str().unwrap_or("events.stream failed");
            return Err(message.to_owned());
        }
        on_frame(&frame);
    }
    Ok(())
}

/// The browser host's listener (`cmux-browser-host`'s `default_socket_path`):
/// `CMUX_BROWSER_HOST_SOCKET`, else `$XDG_RUNTIME_DIR/cmux/browser-host.sock`,
/// else `$TMPDIR/cmux-<uid>/browser-host.sock`.
pub(super) fn browser_host_socket() -> std::path::PathBuf {
    let env = |name: &str| std::env::var_os(name).filter(|value| !value.is_empty());
    if let Some(path) = env("CMUX_BROWSER_HOST_SOCKET") {
        return path.into();
    }
    let base = match env("XDG_RUNTIME_DIR") {
        Some(dir) => std::path::PathBuf::from(dir).join("cmux"),
        // SAFETY: getuid(2) has no failure modes or memory effects.
        None => std::env::temp_dir().join(format!("cmux-{}", unsafe { libc::getuid() })),
    };
    base.join("browser-host.sock")
}

/// `params` with the server's own terminal (`CMUX_TUI_TERMINAL_ID`) on the
/// operations that can open a session, so the app draws the session's lease
/// in that agent's presence colour. Display only; the agent cannot name it.
fn with_caller_terminal(method: &str, mut params: Value) -> Value {
    let opens = matches!(method, "browser.repl.open" | "browser.repl.eval" | "browser.repl.reset");
    let terminal = std::env::var("CMUX_TUI_TERMINAL_ID").ok().filter(|id| !id.is_empty());
    if let (true, Some(terminal), Some(fields)) = (opens, terminal, params.as_object_mut()) {
        fields.insert("terminal".into(), Value::String(terminal));
    }
    params
}

/// One request to the browser host: `{id, method, params, origin: "mcp"}`
/// as one JSON line, answered by `{id, result}` or `{id, error}`. The host
/// runs each request at most once, so a lost answer to a change is
/// `in_progress`, never retried here.
pub(super) fn browser_host(
    method: &str,
    params: Value,
    timeout: Duration,
    mutation: bool,
) -> Result<Value, CallFailure> {
    use std::io::Write;
    let socket = browser_host_socket();
    let mut stream = std::os::unix::net::UnixStream::connect(&socket).map_err(|error| {
        CallFailure::local(
            FailureKind::NotRun,
            "browser_host.unavailable",
            format!(
                "no browser host listens on {} ({error}); start it with `cmux-browser-host serve`",
                socket.display()
            ),
        )
    })?;
    let id = wire::random_request_id()
        .map_err(|error| CallFailure::local(FailureKind::NotRun, "usage.invalid", error.0))?;
    let request = json!({"id": id, "method": method, "params": with_caller_terminal(method, params), "origin": "mcp"});
    let mut line = serde_json::to_vec(&request).expect("JSON values serialize");
    line.push(b'\n');
    let sent = if mutation { FailureKind::InProgress } else { FailureKind::NotRun };
    let lost = |message: String| CallFailure::local(sent, "transport.failed", message);
    stream.write_all(&line).map_err(|error| lost(format!("transport error: {error}")))?;
    stream.set_read_timeout(Some(timeout)).map_err(|error| lost(error.to_string()))?;
    let mut reader = BufReader::new(stream);
    loop {
        let mut answer = String::new();
        match reader.read_line(&mut answer) {
            Ok(0) => return Err(lost("the browser host closed the connection".into())),
            Ok(_) => {}
            Err(error) => return Err(lost(format!("no answer from the browser host: {error}"))),
        }
        let Ok(reply) = serde_json::from_str::<Value>(&answer) else { continue };
        if reply["id"] != json!(id) {
            continue;
        }
        if let Some(error) = reply.get("error").filter(|error| !error.is_null()) {
            return Err(CallFailure {
                kind: FailureKind::Rejected,
                error: error.clone(),
                idempotency_key: None,
            });
        }
        return Ok(reply.get("result").cloned().unwrap_or(Value::Null));
    }
}

/// `ws_1a2b`: fewer than 32 lowercase hex digits after the prefix, so not a
/// whole id but a unique prefix of one.
pub(super) fn is_partial_id(value: &str, prefix: &str) -> bool {
    value.strip_prefix(prefix).and_then(|rest| rest.strip_prefix('_')).is_some_and(|hex| {
        !hex.is_empty()
            && hex.len() < 32
            && hex.bytes().all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    })
}

/// The one id in `records` that starts with `prefix`. No match is
/// `selector.not_found`; more than one is `selector.ambiguous` with the
/// candidates, as the daemon reports for a name.
fn unique_prefix(field: &str, prefix: &str, records: &Value) -> Result<String, Value> {
    let records = records.as_array().map(Vec::as_slice).unwrap_or_default();
    let matches = records
        .iter()
        .filter_map(|record| record.get("id").and_then(Value::as_str))
        .filter(|id| id.starts_with(prefix))
        .collect::<Vec<_>>();
    match matches.as_slice() {
        [id] => Ok((*id).to_string()),
        [] => Err(json!({
            "code": "selector.not_found",
            "message": format!("no {field} id starts with {prefix:?}"),
            "details": {"field": field, "prefix": prefix},
            "retryable": false,
        })),
        candidates => Err(json!({
            "code": "selector.ambiguous",
            "message": format!("more than one {field} id starts with {prefix:?}; use more of it"),
            "details": {"field": field, "prefix": prefix, "candidates": candidates},
            "retryable": false,
        })),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_id_prefix_resolves_only_when_unique() {
        let records = json!([
            {"id": "ws_1a2b0000000000000000000000000000"},
            {"id": "ws_1a2c0000000000000000000000000000"},
            {"id": "ws_9f000000000000000000000000000000"},
        ]);
        assert_eq!(
            unique_prefix("workspace", "ws_9", &records).ok().as_deref(),
            Some("ws_9f000000000000000000000000000000")
        );
        let ambiguous = unique_prefix("workspace", "ws_1a", &records).unwrap_err();
        assert_eq!(ambiguous["code"], "selector.ambiguous");
        assert_eq!(ambiguous["details"]["candidates"].as_array().map(Vec::len), Some(2));
        let missing = unique_prefix("workspace", "ws_77", &records).unwrap_err();
        assert_eq!(missing["code"], "selector.not_found");
    }

    #[test]
    fn a_partial_id_has_fewer_than_32_hex_digits() {
        assert!(is_partial_id("ws_1a", "ws"));
        assert!(!is_partial_id("ws_0123456789abcdef0123456789abcdef", "ws"));
        assert!(!is_partial_id("ws_", "ws"));
        assert!(!is_partial_id("ws_XY", "ws"));
    }
}

#[cfg(all(test, unix))]
#[path = "transport_capabilities_tests.rs"]
mod capabilities_tests;
