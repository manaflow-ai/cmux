//! Reads the CLI runs on a request's own connection before it sends the
//! request, to fill parameters the command named indirectly: the caller's
//! workspace and rooms or groups named by their exact name. The request then
//! carries only ids, so a retry with `--idempotency-key` sends the same
//! fingerprint.

use std::io::{BufReader, Write};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use cmux_tui_core::platform::transport;
use cmux_tui_core::resource::{MAX_MESSAGE_BYTES, PROTOCOL, ResourceOperation, ResponseEnvelope};
use serde_json::{Map, Value, json};

use super::command::plan::CALLER_SCOPES;
use super::command::{RequestPlan, Resolve, ZoomStep, random_prefixed};
use super::wire::{print_local_error, print_operation_error, random_request_id, read_envelope};
use super::{GlobalArgs, OutputMode};

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
    /// The control socket of the app that owns this daemon, which knows
    /// where an agent session's chat is (`system.identify`).
    #[cfg_attr(not(unix), allow(dead_code))]
    pub(super) app: Option<PathBuf>,
}

impl<'a> SocketRoute<'a> {
    /// The route of a request on `path`, with the app that owns that daemon.
    pub(super) fn new(path: &'a Path, derived: bool, global: &GlobalArgs) -> Self {
        #[cfg(unix)]
        let app = super::frontend_browser::owning_app_socket(global, path);
        #[cfg(not(unix))]
        let app = {
            let _ = global;
            None
        };
        Self { path, derived, app }
    }
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
    let caller_route = caller_route && this_machine(params);
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
            Resolve::Caller => {
                caller_scopes(params, caller_route, || caller_path(reader, &route, socket))?;
                focused_scopes(params, caller_route, socket);
            }
            Resolve::CallerPlace => {
                if caller_route
                    && let Ok(Some(path)) = caller_path(reader, &route, socket)
                    && let Some(place) = ["workspace", "screen", "pane"]
                        .map(|scope| path.get(scope).and_then(Value::as_str).map(str::to_owned))
                        .into_iter()
                        .collect::<Option<Vec<_>>>()
                {
                    for (scope, id) in ["workspace", "screen", "pane"].into_iter().zip(place) {
                        params.insert(scope.into(), Value::String(id));
                    }
                }
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

/// The workspace that holds the caller's `terminal`, waiting for the
/// terminal to be placed ([`registered_caller_path`]).
fn registered_caller_workspace(
    reader: &mut Reader,
    route: &Map<String, Value>,
    terminal: &str,
    socket: &SocketRoute<'_>,
) -> Result<String, Failure> {
    match registered_caller_path(reader, route, terminal, socket)?.remove("workspace") {
        Some(Value::String(workspace)) => Ok(workspace),
        _ => Err(not_in_a_workspace(terminal)),
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

/// Fills the structural selectors of a request with the caller's own
/// objects ([`Resolve::Caller`]). `caller` names the caller's object at its
/// scope and fails without a caller. `current` names it too while the
/// selectors above it name the caller's own path, so an agent or a script in
/// a cmux terminal acts on its own workspace and pane, never on the one the
/// person is looking at. `current` stays the focused object when the request
/// routes to another session or machine (`caller_route` is false), when no
/// caller is known or it cannot be found, below a parent that is not the
/// caller's, above an explicit id or name, and for a browser target, which a
/// caller never is.
fn caller_scopes(
    params: &mut Map<String, Value>,
    caller_route: bool,
    path: impl FnOnce() -> Result<Option<Map<String, Value>>, Failure>,
) -> Result<(), Failure> {
    let value = |params: &Map<String, Value>, scope: &str| {
        params.get(scope).and_then(Value::as_str).map(str::to_owned)
    };
    let named = |selector: &str| {
        CALLER_SCOPES.iter().any(|scope| value(params, scope).as_deref() == Some(selector))
    };
    let explicit = named("caller");
    let current = caller_route && !params.contains_key("browser") && named("current");
    if !explicit && !current {
        return Ok(());
    }
    if explicit && !caller_route {
        return Err(lookup_error(
            "selector.invalid",
            "`caller` names the caller's own objects, which are not in a session or machine \
             named with --socket, --session or --machine; name an id instead"
                .into(),
        ));
    }
    let path = match path() {
        Ok(Some(path)) => path,
        Ok(None) if explicit => {
            return Err(lookup_error(
                "selector.not_found",
                "`caller` needs a caller: run it in a cmux terminal or agent session \
                 (CMUX_TUI_TERMINAL_ID or CMUX_AGENT_SESSION), or name an id"
                    .into(),
            ));
        }
        Err(failure) if explicit => return Err(failure),
        // A caller that cannot be found leaves `current` the focused object.
        Ok(None) | Err(_) => return Ok(()),
    };
    // An explicit id or name below a `current` keeps that `current` the
    // daemon's, so the id is still checked against the focused parents.
    let selectors: Vec<Option<String>> =
        CALLER_SCOPES.iter().map(|scope| value(params, scope)).collect();
    // `focused` is resolved after this (`focused_scopes`), so it does not
    // stop a `current` above it from following the caller.
    let keyword = |selector: &str| matches!(selector, "caller" | "current" | FOCUSED);
    let deepest_named = selectors
        .iter()
        .rposition(|selector| selector.as_deref().is_some_and(|selector| !keyword(selector)))
        .map_or(0, |index| index + 1);
    let mut updates = Vec::new();
    let mut on_caller_path = true;
    for (index, (scope, selector)) in CALLER_SCOPES.into_iter().zip(&selectors).enumerate() {
        let Some(selector) = selector else { continue };
        let own = path.get(scope).and_then(Value::as_str);
        let follows = selector == "current" && current && on_caller_path && index >= deepest_named;
        if selector == "caller" || follows {
            let Some(own) = own else {
                if explicit {
                    return Err(lookup_error(
                        "selector.not_found",
                        format!("the caller has no {scope}; name one by id"),
                    ));
                }
                return Ok(());
            };
            updates.push((scope, own.to_owned()));
        } else {
            on_caller_path = own == Some(selector.as_str());
        }
    }
    for (scope, id) in updates {
        params.insert(scope.into(), Value::String(id));
    }
    Ok(())
}

/// Puts what the person looks at in place of `focused` selectors: the
/// focus of the app that owns this daemon (`snapshot.get`), each level while
/// the levels above it are the focused ones. Without that app, on another
/// session or machine, or below another object, `focused` is the daemon's
/// `current`, its active object.
fn focused_scopes(params: &mut Map<String, Value>, caller_route: bool, socket: &SocketRoute<'_>) {
    let focused =
        |params: &Map<String, Value>, scope: &str| params.get(scope) == Some(&json!(FOCUSED));
    if !CALLER_SCOPES.iter().any(|scope| focused(params, scope)) {
        return;
    }
    #[cfg(unix)]
    let focus = if caller_route { app_focus(socket) } else { None };
    #[cfg(not(unix))]
    let focus = {
        let _ = (caller_route, socket);
        None
    };
    super::caller_scope::apply(params, None, focus.as_ref());
    // `caller_scope` places workspaces to tabs; a focused terminal is the
    // focused tab's, which the daemon's `current` names.
    for scope in CALLER_SCOPES {
        if focused(params, scope) {
            params.insert(scope.into(), json!("current"));
        }
    }
}

const FOCUSED: &str = "focused";

/// The app's focus (`topology.focus` of `snapshot.get`: window, workspace,
/// screen, pane and tab ids), or `None` when no app owns this daemon or it
/// does not answer.
#[cfg(unix)]
fn app_focus(socket: &SocketRoute<'_>) -> Option<Value> {
    let app = socket.app.as_ref()?;
    let mut stream = super::app::connect(app).ok()?;
    let snapshot = super::app::request(&mut stream, "snapshot.get", json!({}), APP_IDENTIFY_WAIT)
        .ok()?
        .ok()?;
    snapshot.get("topology").and_then(|topology| topology.get("focus")).cloned()
}

/// Whether the request stays on this machine: another machine is never the
/// caller's (`--machine`).
fn this_machine(params: &Map<String, Value>) -> bool {
    params.get("machine").and_then(Value::as_str).is_none_or(|machine| machine == "current")
}

/// The caller's workspace, screen, pane, tab and terminal ids, keyed by
/// scope, or `None` when nothing names a caller. An agent session's chat is
/// placed by the app, which reports it in `system.identify`; a terminal
/// caller (or an agent session no app places) is followed up from its
/// terminal in the daemon.
fn caller_path(
    reader: &mut Reader,
    route: &Map<String, Value>,
    socket: &SocketRoute<'_>,
) -> Result<Option<Map<String, Value>>, Failure> {
    let env = |key: &str| std::env::var(key).ok().filter(|value| !value.is_empty());
    // An agent session, or a Chief turn the app places at the Home chat.
    #[cfg(unix)]
    if (env("CMUX_AGENT_SESSION").is_some() || env("CMUX_CALLER_HOME_CHAT").as_deref() == Some("1"))
        && let Some(path) = agent_caller_path(socket)?
    {
        return Ok(Some(path));
    }
    let Some(terminal) = env("CMUX_TUI_TERMINAL_ID") else { return Ok(None) };
    registered_caller_path(reader, route, &terminal, socket).map(Some)
}

/// The app's `caller` from `system.identify` (the CLI names the agent
/// session in it, app.rs `with_caller`). `None` when no app owns this
/// daemon, as on a Cloud machine, or the app does not place the session.
#[cfg(unix)]
fn agent_caller_path(socket: &SocketRoute<'_>) -> Result<Option<Map<String, Value>>, Failure> {
    let Some(app) = &socket.app else { return Ok(None) };
    let mut stream = super::app::connect(app).map_err(Failure::Transport)?;
    let reply = super::app::request(&mut stream, "system.identify", json!({}), APP_IDENTIFY_WAIT);
    let identity = reply.map_err(Failure::Transport)?.map_err(Failure::Resource)?;
    let Some(caller) = identity.get("caller").and_then(Value::as_object) else { return Ok(None) };
    if caller.get("workspace").and_then(Value::as_str).is_none() {
        return Ok(None);
    }
    let mut path = Map::new();
    for (scope, field) in [
        ("workspace", "workspace"),
        ("screen", "screen"),
        ("pane", "pane"),
        ("tab", "tab"),
        ("terminal", "terminal_id"),
    ] {
        if let Some(id) = caller.get(field).filter(|id| id.is_string()) {
            path.insert(scope.into(), id.clone());
        }
    }
    Ok(Some(path))
}

#[cfg(unix)]
const APP_IDENTIFY_WAIT: Duration = Duration::from_secs(5);

/// [`caller_path_of`], waiting for the caller's terminal to be placed. A
/// new tab's shell runs before the daemon commits the tab, so a command at
/// its first prompt can ask for a terminal the daemon does not show yet.
/// The wait follows the session's event stream on a second connection and
/// looks again after each event, up to [`CALLER_TERMINAL_WAIT`].
fn registered_caller_path(
    reader: &mut Reader,
    route: &Map<String, Value>,
    terminal: &str,
    socket: &SocketRoute<'_>,
) -> Result<Map<String, Value>, Failure> {
    match caller_path_of(reader, route, terminal) {
        Err(Failure::Resource(error)) if is_missing(&error, terminal) => {}
        settled => return settled,
    }
    let deadline = Instant::now() + CALLER_TERMINAL_WAIT;
    let mut events = session_events(socket, route, deadline);
    loop {
        let changed = events.as_mut().is_some_and(|events| next_event(events, deadline));
        match caller_path_of(reader, route, terminal) {
            Err(Failure::Resource(error)) if is_missing(&error, terminal) => {
                if !changed {
                    return Err(unregistered_terminal(terminal));
                }
            }
            settled => return settled,
        }
    }
}

/// The ids that hold `terminal`, keyed by scope: terminal -> tab -> pane ->
/// screen -> workspace.
fn caller_path_of(
    reader: &mut Reader,
    route: &Map<String, Value>,
    terminal: &str,
) -> Result<Map<String, Value>, Failure> {
    let mut path = Map::new();
    path.insert("terminal".into(), Value::String(terminal.to_owned()));
    let mut id = terminal.to_string();
    for (operation, selector, parent, parent_scope) in [
        (ResourceOperation::TerminalGet, "terminal", "tab_id", "tab"),
        (ResourceOperation::TabGet, "tab", "pane_id", "pane"),
        (ResourceOperation::PaneGet, "pane", "screen_id", "screen"),
        (ResourceOperation::ScreenGet, "screen", "workspace_id", "workspace"),
    ] {
        let mut params = route.clone();
        params.insert(selector.into(), Value::String(id));
        let snapshot = read(reader, operation, params)?;
        id = snapshot
            .get(parent)
            .and_then(Value::as_str)
            .map(str::to_owned)
            .ok_or_else(|| not_in_a_workspace(terminal))?;
        path.insert(parent_scope.into(), Value::String(id.clone()));
    }
    Ok(path)
}

fn not_in_a_workspace(terminal: &str) -> Failure {
    Failure::Resource(json!({
        "code": "selector.not_found",
        "message": format!(
            "the caller's terminal {terminal} is not in a workspace; name one: \
             cmux workspace <workspace> …"
        ),
        "details": {"terminal": terminal},
        "retryable": false,
    }))
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
        request["idempotency_key"] = Value::String(key.to_owned());
    }
    if let Some(credential) = credential {
        request["credential"] = Value::String(credential.to_owned());
    }
    let encoded = serde_json::to_vec(&request).expect("JSON values serialize");
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

    fn caller_path_fixture() -> Map<String, Value> {
        json!({
            "workspace": "ws_mine", "screen": "screen_mine", "pane": "pane_mine",
            "tab": "tab_mine", "terminal": "term_mine",
        })
        .as_object()
        .unwrap()
        .clone()
    }

    fn scoped(
        params: Value,
        caller_route: bool,
        path: Option<Map<String, Value>>,
    ) -> Result<Value, String> {
        let mut params = params.as_object().unwrap().clone();
        match caller_scopes(&mut params, caller_route, || Ok(path)) {
            Ok(()) => Ok(Value::Object(params)),
            Err(Failure::Resource(error)) => Err(error["code"].as_str().unwrap().to_owned()),
            Err(_) => Err("other".into()),
        }
    }

    #[test]
    fn caller_and_current_become_the_callers_own_ids() {
        let mine = Some(caller_path_fixture());
        let chain = json!({"workspace": "current", "screen": "current", "pane": "caller"});
        assert_eq!(
            scoped(chain.clone(), true, mine.clone()),
            Ok(json!({"workspace": "ws_mine", "screen": "screen_mine", "pane": "pane_mine"}))
        );
        let current = json!({"workspace": "current", "screen": "current", "pane": "current"});
        assert_eq!(
            scoped(current.clone(), true, mine.clone()),
            Ok(json!({"workspace": "ws_mine", "screen": "screen_mine", "pane": "pane_mine"}))
        );
        // No caller, or a route to another session: `current` stays focused.
        assert_eq!(scoped(current.clone(), true, None), Ok(current.clone()));
        assert_eq!(scoped(current.clone(), false, mine.clone()), Ok(current));
        // `caller` refuses instead of guessing.
        assert_eq!(scoped(chain.clone(), true, None), Err("selector.not_found".into()));
        assert_eq!(scoped(chain, false, mine), Err("selector.invalid".into()));
    }

    #[test]
    fn current_below_a_parent_that_is_not_the_callers_stays_that_parents() {
        let mine = Some(caller_path_fixture());
        let theirs = json!({"workspace": "ws_theirs", "screen": "current", "pane": "current"});
        assert_eq!(scoped(theirs.clone(), true, mine.clone()), Ok(theirs));
        let own = json!({"workspace": "ws_mine", "screen": "current", "pane": "current"});
        assert_eq!(
            scoped(own, true, mine.clone()),
            Ok(json!({"workspace": "ws_mine", "screen": "screen_mine", "pane": "pane_mine"}))
        );
        // A browser is never the caller: its `current` chain stays focused.
        let browser = json!({"workspace": "current", "tab": "current", "browser": "current"});
        assert_eq!(scoped(browser.clone(), true, mine.clone()), Ok(browser));
        // An agent chat has no terminal of its own: `caller` refuses,
        // `current` stays the focused terminal.
        let mut chat = caller_path_fixture();
        chat.remove("terminal");
        let terminal = json!({"workspace": "current", "terminal": "caller"});
        assert_eq!(scoped(terminal, true, Some(chat.clone())), Err("selector.not_found".into()));
        let focused = json!({"workspace": "current", "terminal": "current"});
        assert_eq!(scoped(focused.clone(), true, Some(chat)), Ok(focused));
        // An explicit id below `current` keeps its focused parents.
        let below = json!({"workspace": "current", "screen": "current", "pane": "pane_x"});
        assert_eq!(scoped(below.clone(), true, mine.clone()), Ok(below));
        // Another machine is never the caller's: `apply` routes it as
        // another session.
        let remote = json!({"machine": "m2", "workspace": "current", "pane": "current"});
        assert!(!this_machine(remote.as_object().unwrap()));
        assert!(this_machine(json!({"machine": "current"}).as_object().unwrap()));
        assert!(this_machine(&Map::new()));
        assert_eq!(scoped(remote.clone(), false, mine.clone()), Ok(remote));
        let remote_caller = json!({"machine": "m2", "workspace": "current", "pane": "caller"});
        assert_eq!(scoped(remote_caller, false, mine), Err("selector.invalid".into()));
    }

    #[test]
    fn a_caller_that_cannot_be_found_leaves_current_focused() {
        let current = json!({"workspace": "current", "pane": "current"});
        let mut params = current.as_object().unwrap().clone();
        let lost = || Err(Failure::Transport("app did not answer".into()));
        assert!(caller_scopes(&mut params, true, lost).is_ok());
        assert_eq!(Value::Object(params), current);
        let caller = json!({"workspace": "current", "pane": "caller"});
        let mut params = caller.as_object().unwrap().clone();
        let lost = || Err(Failure::Transport("app did not answer".into()));
        assert!(caller_scopes(&mut params, true, lost).is_err());
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
