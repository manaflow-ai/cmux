//! Reads the CLI runs on a request's own connection before it sends the
//! request, to fill parameters the command named indirectly: the caller's
//! workspace and rooms or groups named by their exact name. The request then
//! carries only ids, so a retry with `--idempotency-key` sends the same
//! fingerprint.

use std::io::{BufReader, Write};
use std::path::Path;
use std::time::{Duration, Instant};

use cmux_tui_core::platform::transport;
use cmux_tui_core::resource::{MAX_MESSAGE_BYTES, PROTOCOL, ResourceOperation, ResponseEnvelope};
use serde_json::{Map, Value, json};

use super::command::{RequestPlan, Resolve, ZoomStep, random_prefixed};
use super::wire::{print_local_error, print_operation_error, random_request_id, read_envelope};
use super::{GlobalArgs, OutputMode};
use crate::cli::json_fields::JsonFields;

type Reader = BufReader<Box<dyn transport::Stream>>;

pub(super) enum Failure {
    /// A resource error from the daemon, or a local one in that shape.
    Resource(Value),
    /// A local error in the resource shape that never reached a daemon,
    /// with its own exit code (the socket resolver's typed failure).
    Local {
        error: Value,
        exit: i32,
    },
    Transport(String),
    /// The request belongs to the app, not the daemon: run this app action
    /// (by id) on this target instead (a browser tab's page zoom).
    AppAction {
        action: &'static str,
        target: String,
    },
}

impl Failure {
    pub(super) fn report(self, output: OutputMode) -> i32 {
        match self {
            Self::AppAction { action, .. } => {
                eprintln!("cmux: {action} is an app action and this cmux cannot reach the app");
                3
            }
            Self::Resource(error) => print_operation_error(&error, output),
            Self::Local { error, exit } => print_local_error(&error, output, exit),
            Self::Transport(message) => {
                eprintln!("{message}");
                3
            }
        }
    }
}

/// The session socket a request's connection reached, so a lookup can open
/// a second connection to the same daemon.
pub(super) struct SocketRoute<'a> {
    pub(super) path: &'a Path,
    pub(super) derived: bool,
}

/// Applies every pending lookup of `plan` and clears them.
pub(super) fn apply(
    reader: &mut Reader,
    plan: &mut RequestPlan,
    caller_route: bool,
    socket: &SocketRoute<'_>,
) -> Result<(), Failure> {
    let steps = std::mem::take(&mut plan.resolve);
    let params = plan
        .params
        .as_object_mut()
        .ok_or_else(|| Failure::Transport("cmux: request params are not an object".into()))?;
    let route = route(params);
    for step in steps {
        match step {
            Resolve::CallerWorkspace { terminal } => {
                let workspace = if caller_route {
                    registered_caller_workspace(reader, &route, &terminal, socket)?
                } else {
                    "current".to_string()
                };
                params.insert("workspace".into(), Value::String(workspace));
            }
            Resolve::StateName { field, list } => {
                let Some(value) = params.get(field).and_then(Value::as_str).map(str::to_owned)
                else {
                    continue;
                };
                let records = read(reader, list, route.clone())?;
                if let Some(id) = state_id(field, &value, &records)? {
                    params.insert(field.into(), Value::String(id));
                }
            }
            Resolve::TabZoom { step } => {
                // A `current` or named tab resolves through its ancestors.
                let mut selector = route.clone();
                for key in ["workspace", "screen", "pane", "tab"] {
                    if let Some(value) = params.get(key) {
                        selector.insert(key.into(), value.clone());
                    }
                }
                let snapshot = read(reader, ResourceOperation::TabGet, selector)?;
                if let Some(action) = tab_zoom_route(&snapshot, step)? {
                    let tab = snapshot.get("id").and_then(Value::as_str).unwrap_or_default();
                    let pane = snapshot.get("pane_id").and_then(Value::as_str).unwrap_or_default();
                    let shown = shown_tab(reader, &route, pane)?;
                    if shown.as_deref() != Some(tab) {
                        return Err(lookup_error(
                            "tab.not_shown",
                            format!(
                                "page zoom acts on the tab its pane shows, and pane {pane} shows \
                                 another tab; run `cmux tab {tab} focus` first"
                            ),
                        ));
                    }
                    return Err(Failure::AppAction { action, target: format!("pane:{pane}") });
                }
            }
            Resolve::AgentTab { agent } => {
                let tab = agent_tab(reader, &route, &agent)?;
                params.insert("tab".into(), Value::String(tab));
            }
        }
    }
    Ok(())
}

/// `Some(app action)` when `tab` is a browser tab, whose page zoom the app
/// that hosts the page owns; `None` for a terminal's font zoom, which the
/// daemon's `tab.update` sets.
fn tab_zoom_route(tab: &Value, step: ZoomStep) -> Result<Option<&'static str>, Failure> {
    let browser = tab.get("content_kind").and_then(Value::as_str) == Some("browser");
    match (browser, step) {
        (false, ZoomStep::In | ZoomStep::Out) => Err(lookup_error(
            "validation.invalid",
            "zoom in|out applies to browser tabs; give a terminal tab a value: zoom <0.25..5>|reset"
                .into(),
        )),
        (false, _) => Ok(None),
        (true, ZoomStep::Value) => Err(lookup_error(
            "validation.invalid",
            "a browser tab's page zoom takes in, out or reset; the app has no action that sets an \
             exact page zoom yet"
                .into(),
        )),
        (true, ZoomStep::In) => Ok(Some("browserZoomIn")),
        (true, ZoomStep::Out) => Ok(Some("browserZoomOut")),
        (true, ZoomStep::Reset) => Ok(Some("browserZoomReset")),
    }
}

fn lookup_error(code: &str, message: String) -> Failure {
    Failure::Resource(json!({
        "code": code,
        "message": message,
        "details": {},
        "retryable": false,
    }))
}

/// The tab that shows `agent`'s terminal. `agent` is an `agent_...` id from
/// `agent.list`, or the `term_...` id of a terminal that has an agent.
fn agent_tab(
    reader: &mut Reader,
    route: &Map<String, Value>,
    agent: &str,
) -> Result<String, Failure> {
    let listed = read(reader, ResourceOperation::AgentList, route.clone())?;
    let rows = listed.get("agents").unwrap_or(&listed);
    let key = if agent.starts_with("term_") { "terminal_id" } else { "id" };
    let terminal = rows
        .as_array()
        .into_iter()
        .flatten()
        .find(|row| row[key] == agent)
        .and_then(|row| row["terminal_id"].as_str())
        .map(str::to_owned)
        .ok_or_else(|| {
            lookup_error(
                "selector.not_found",
                format!("this session has no agent {agent}; `cmux agent list` lists its agents"),
            )
        })?;
    let mut selector = route.clone();
    selector.insert("terminal".into(), Value::String(terminal.clone()));
    let snapshot = read(reader, ResourceOperation::TerminalGet, selector)?;
    snapshot.get("tab_id").and_then(Value::as_str).map(str::to_owned).ok_or_else(|| {
        lookup_error(
            "selector.not_found",
            format!("agent {agent} runs in terminal {terminal}, which no tab shows"),
        )
    })
}

/// The tab `pane` shows: its leaf's `active_tab_id` in its screen's layout.
fn shown_tab(
    reader: &mut Reader,
    route: &Map<String, Value>,
    pane: &str,
) -> Result<Option<String>, Failure> {
    let mut selector = route.clone();
    selector.insert("pane".into(), Value::String(pane.to_owned()));
    let pane_snapshot = read(reader, ResourceOperation::PaneGet, selector)?;
    let Some(screen) = pane_snapshot.get("screen_id").and_then(Value::as_str) else {
        return Ok(None);
    };
    let mut selector = route.clone();
    selector.insert("screen".into(), Value::String(screen.to_owned()));
    let screen = read(reader, ResourceOperation::ScreenGet, selector)?;
    Ok(active_tab_of(&screen, pane))
}

/// Searches every layout object of a screen snapshot for the leaf of `pane`.
fn active_tab_of(value: &Value, pane: &str) -> Option<String> {
    match value {
        Value::Object(object) => {
            if object.get("pane_id").and_then(Value::as_str) == Some(pane)
                && let Some(active) = object.get("active_tab_id").and_then(Value::as_str)
            {
                return Some(active.to_owned());
            }
            object.values().find_map(|value| active_tab_of(value, pane))
        }
        Value::Array(values) => values.iter().find_map(|value| active_tab_of(value, pane)),
        _ => None,
    }
}

pub(super) fn route(params: &Map<String, Value>) -> Map<String, Value> {
    ["machine", "session"]
        .into_iter()
        .filter_map(|key| params.get(key).map(|value| (key.to_string(), value.clone())))
        .collect()
}

/// How long a lookup waits for the caller's terminal to join its workspace.
const CALLER_TERMINAL_WAIT: Duration = Duration::from_secs(3);

/// [`caller_workspace`], waiting for the caller's terminal to be placed. A
/// new tab's shell runs before the daemon commits the tab, so a command at
/// its first prompt can ask for a terminal the daemon does not show yet.
/// The wait follows the session's event stream on a second connection and
/// looks again after each event, up to [`CALLER_TERMINAL_WAIT`].
fn registered_caller_workspace(
    reader: &mut Reader,
    route: &Map<String, Value>,
    terminal: &str,
    socket: &SocketRoute<'_>,
) -> Result<String, Failure> {
    match caller_workspace(reader, route, terminal) {
        Err(Failure::Resource(error)) if is_missing(&error, terminal) => {}
        settled => return settled,
    }
    let deadline = Instant::now() + CALLER_TERMINAL_WAIT;
    let mut events = session_events(socket, route, deadline);
    loop {
        let changed = events.as_mut().is_some_and(|events| next_event(events, deadline));
        match caller_workspace(reader, route, terminal) {
            Err(Failure::Resource(error)) if is_missing(&error, terminal) => {
                if !changed {
                    return Err(unregistered_terminal(terminal));
                }
            }
            settled => return settled,
        }
    }
}

/// The lookup found no placed `terminal`; any other miss (an unknown
/// `--machine`, say) is reported as it is.
fn is_missing(error: &Value, terminal: &str) -> bool {
    let details = &error["details"];
    error.get("code").and_then(Value::as_str) == Some("selector.not_found")
        && (details["selector"] == terminal || details["terminal"] == terminal)
}

fn unregistered_terminal(terminal: &str) -> Failure {
    Failure::Resource(json!({
        "code": "selector.not_found",
        "message": format!(
            "the caller's terminal {terminal} did not join a workspace of this cmux session \
             within {}s; name one: cmux workspace <workspace> …",
            CALLER_TERMINAL_WAIT.as_secs()
        ),
        "details": {"terminal": terminal},
        "retryable": false,
    }))
}

/// A `session.events` stream of the request's session on its own
/// connection, or `None` when the daemon cannot give one before `deadline`.
pub(super) fn session_events(
    socket: &SocketRoute<'_>,
    route: &Map<String, Value>,
    deadline: Instant,
) -> Option<Reader> {
    let stream = cmux_tui_core::server::connect_session_socket(socket.path, socket.derived).ok()?;
    let mut events = BufReader::new(stream);
    let remaining = deadline.checked_duration_since(Instant::now())?;
    events.get_mut().set_read_timeout(Some(remaining)).ok()?;
    let id = random_request_id().ok()?;
    let mut params = route.clone();
    params.entry("session").or_insert_with(|| Value::String("current".into()));
    params.insert("stream_id".into(), Value::String(random_prefixed("stream").ok()?));
    let request = json!({
        "protocol": PROTOCOL,
        "type": "request",
        "id": id,
        "operation": ResourceOperation::SessionEvents.wire_name(),
        "params": params,
    });
    send(&mut events, &serde_json::to_vec(&request).ok()?).ok()?;
    match read_response(&mut events, &id) {
        Ok(Ok(_)) => Some(events),
        _ => None,
    }
}

/// Blocks until the stream's next item; `false` at `deadline` or when the
/// stream ends.
fn next_event(events: &mut Reader, deadline: Instant) -> bool {
    let Some(remaining) = deadline.checked_duration_since(Instant::now()) else {
        return false;
    };
    if remaining.is_zero() || events.get_mut().set_read_timeout(Some(remaining)).is_err() {
        return false;
    }
    matches!(read_envelope(events, false), Ok(Some(_)))
}

/// The workspace that holds `terminal`: terminal -> tab -> pane -> screen.
fn caller_workspace(
    reader: &mut Reader,
    route: &Map<String, Value>,
    terminal: &str,
) -> Result<String, Failure> {
    let mut id = terminal.to_string();
    for (operation, selector, parent) in [
        (ResourceOperation::TerminalGet, "terminal", "tab_id"),
        (ResourceOperation::TabGet, "tab", "pane_id"),
        (ResourceOperation::PaneGet, "pane", "screen_id"),
        (ResourceOperation::ScreenGet, "screen", "workspace_id"),
    ] {
        let mut params = route.clone();
        params.insert(selector.into(), Value::String(id));
        let snapshot = read(reader, operation, params)?;
        id = snapshot.get(parent).and_then(Value::as_str).map(str::to_owned).ok_or_else(|| {
            Failure::Resource(json!({
                "code": "selector.not_found",
                "message": format!(
                    "the caller's terminal {terminal} is not in a workspace; name one: \
                     cmux workspace <workspace> …"
                ),
                "details": {"terminal": terminal},
                "retryable": false,
            }))
        })?;
    }
    Ok(id)
}

/// `Some(id)` when `value` is not an id but the exact name of one record.
/// An id, or a name nothing has, goes to the daemon unchanged, which reports
/// `resource.not_found` for an unknown one.
fn state_id(field: &str, value: &str, records: &Value) -> Result<Option<String>, Failure> {
    let records = records.as_array().map(Vec::as_slice).unwrap_or_default();
    if records.iter().any(|record| record.get("id").and_then(Value::as_str) == Some(value)) {
        return Ok(None);
    }
    let named = records
        .iter()
        .filter(|record| record.get("name").and_then(Value::as_str) == Some(value))
        .filter_map(|record| record.get("id").and_then(Value::as_str))
        .collect::<Vec<_>>();
    match named.as_slice() {
        [] => Ok(None),
        [id] => Ok(Some((*id).to_string())),
        candidates => Err(Failure::Resource(json!({
            "code": "selector.ambiguous",
            "message": format!(
                "more than one {} is named {value:?}; use its id",
                field.replace('_', " ")
            ),
            "details": {"field": field, "candidates": candidates},
            "retryable": false,
        }))),
    }
}

/// Applies route defaults shared by CLI and MCP. Catalog reads have no session ancestor;
/// `--session` still chooses their socket but never becomes a metadata field.
pub(super) fn apply_global_route(
    global: &GlobalArgs,
    plan: &mut RequestPlan,
) -> Result<(), &'static str> {
    let has_session = !matches!(
        plan.operation,
        super::command::WireOperation::Typed(
            ResourceOperation::MachineList | ResourceOperation::MachineGet
        )
    );
    let Some(params) = plan.params.as_object_mut() else {
        return Err("request params are not an object");
    };
    if let Some(machine) = &global.machine
        && params.get("machine").is_none_or(|value| value.as_str() == Some("current"))
    {
        params.insert("machine".into(), Value::String(machine.clone()));
    }
    if let Some(session) = &global.session
        && has_session
        && params.get("session").is_none_or(|value| value.as_str() == Some("current"))
    {
        params.insert("session".into(), Value::String(session.clone()));
    }
    Ok(())
}

pub(super) fn encode_request_bytes(request: &Value) -> Result<Vec<u8>, String> {
    match serde_json::to_vec(request) {
        Ok(encoded) if encoded.len() <= MAX_MESSAGE_BYTES => Ok(encoded),
        Ok(_) => Err("request exceeds the 4 MiB protocol limit".into()),
        Err(error) => Err(format!("cannot encode request: {error}")),
    }
}

/// Reads envelopes until the response to `request_id`: `Ok(Ok(result))`,
/// `Ok(Err(resource error))`, or `Err` for a transport or protocol failure.
pub(super) fn read_response(
    reader: &mut Reader,
    request_id: &str,
) -> Result<Result<Value, Value>, String> {
    loop {
        let value = read_envelope(reader, false)?
            .ok_or_else(|| "transport closed before response".to_string())?;
        if value.get("type").and_then(Value::as_str) != Some("response") {
            continue;
        }
        let response: ResponseEnvelope = serde_json::from_value(value)
            .map_err(|error| format!("protocol error: invalid response envelope: {error}"))?;
        if response.id.as_str() != request_id {
            continue;
        }
        response.validate().map_err(|error| format!("protocol error: {}", error.message))?;
        if response.ok {
            return Ok(Ok(response.result.unwrap_or(Value::Null)));
        }
        let error = response
            .error
            .and_then(|error| serde_json::to_value(error).ok())
            .unwrap_or_else(|| json!({"code": "operation.failed", "message": "request failed"}));
        return Ok(Err(error));
    }
}

/// Writes one encoded request line and flushes it.
pub(super) fn send(reader: &mut Reader, encoded: &[u8]) -> Result<(), String> {
    let stream = reader.get_mut();
    stream
        .write_all(encoded)
        .and_then(|()| stream.write_all(b"\n"))
        .and_then(|()| stream.flush())
        .map_err(|error| format!("transport error: {error}"))
}

/// One read on the connection; returns its result.
pub(super) fn read(
    reader: &mut Reader,
    operation: ResourceOperation,
    params: Map<String, Value>,
) -> Result<Value, Failure> {
    call(reader, operation, params, None)
}

/// One request on the connection; returns its result. A mutation carries
/// `idempotency_key`.
pub(super) fn call(
    reader: &mut Reader,
    operation: ResourceOperation,
    params: Map<String, Value>,
    idempotency_key: Option<&str>,
) -> Result<Value, Failure> {
    call_as(reader, operation, params, idempotency_key, None)
}

/// [`call`] with the caller's launch credential in the envelope
/// (launch_credential.rs decides whether this connection may get it).
pub(super) fn call_as(
    reader: &mut Reader,
    operation: ResourceOperation,
    params: Map<String, Value>,
    idempotency_key: Option<&str>,
    credential: Option<&str>,
) -> Result<Value, Failure> {
    let id = random_request_id().map_err(|error| Failure::Transport(format!("cmux: {error}")))?;
    let mut request = json!({
        "protocol": PROTOCOL,
        "type": "request",
        "id": id,
        "operation": operation.wire_name(),
        "params": params,
    });
    if let Some(key) = idempotency_key {
        request.insert("idempotency_key", Value::String(key.to_owned()));
    }
    if let Some(credential) = credential {
        request.insert("credential", Value::String(credential.to_owned()));
    }
    let encoded = request.to_string().into_bytes();
    send(reader, &encoded).map_err(Failure::Transport)?;
    match read_response(reader, &id).map_err(Failure::Transport)? {
        Ok(result) => Ok(result),
        Err(error) => Err(Failure::Resource(error)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_unique_exact_name_becomes_its_id_and_an_id_stays() {
        let records = json!([
            {"id": "room-a", "name": "Work"},
            {"id": "room-b", "name": "Home"},
            {"id": "room-c", "name": "room-a"},
        ]);
        assert_eq!(state_id("room", "Work", &records).ok().flatten().as_deref(), Some("room-a"));
        // An id wins over a record named like it.
        assert_eq!(state_id("room", "room-a", &records).ok().flatten(), None);
        assert_eq!(state_id("room", "Nowhere", &records).ok().flatten(), None);
    }

    #[test]
    fn a_shared_name_is_ambiguous_with_candidates() {
        let records = json!([
            {"id": "g1", "name": "agents"},
            {"id": "g2", "name": "agents"},
        ]);
        let Err(Failure::Resource(error)) = state_id("tab_group", "agents", &records) else {
            panic!("a shared name resolved");
        };
        assert_eq!(error["code"], "selector.ambiguous");
        assert_eq!(error["details"]["candidates"], json!(["g1", "g2"]));
        assert!(error["message"].as_str().unwrap().contains("tab group"));
    }

    #[test]
    fn browser_zoom_goes_to_the_app_and_terminal_zoom_to_the_daemon() {
        let browser = json!({"id": "tab_1", "content_kind": "browser", "pane_id": "pane_1"});
        let terminal = json!({"id": "tab_2", "content_kind": "terminal", "pane_id": "pane_1"});
        let route = |tab: &Value, step| match tab_zoom_route(tab, step) {
            Ok(action) => Ok(action),
            Err(Failure::Resource(error)) => Err(error["code"].as_str().unwrap().to_owned()),
            Err(_) => Err("other".into()),
        };
        assert_eq!(route(&browser, ZoomStep::In), Ok(Some("browserZoomIn")));
        assert_eq!(route(&browser, ZoomStep::Out), Ok(Some("browserZoomOut")));
        assert_eq!(route(&browser, ZoomStep::Reset), Ok(Some("browserZoomReset")));
        assert_eq!(route(&browser, ZoomStep::Value), Err("validation.invalid".into()));
        assert_eq!(route(&terminal, ZoomStep::Value), Ok(None));
        assert_eq!(route(&terminal, ZoomStep::Reset), Ok(None));
        assert_eq!(route(&terminal, ZoomStep::In), Err("validation.invalid".into()));
    }

    #[test]
    fn the_shown_tab_is_read_from_the_pane_leaf_of_the_screen_layout() {
        let screen = json!({"layout": {"root": {"columns": [{"root": {
            "kind": "split",
            "first": {"kind": "leaf", "pane_id": "pane_a", "active_tab_id": "tab_a"},
            "second": {"kind": "leaf", "pane_id": "pane_b", "active_tab_id": "tab_b"},
        }}]}}});
        assert_eq!(active_tab_of(&screen, "pane_b").as_deref(), Some("tab_b"));
        assert_eq!(active_tab_of(&screen, "pane_c"), None);
    }

    #[test]
    fn route_keeps_only_machine_and_session() {
        let params = json!({"machine": "current", "session": "s", "room": "x"});
        assert_eq!(
            Value::Object(route(params.as_object().unwrap())),
            json!({"machine": "current", "session": "s"})
        );
    }
}
