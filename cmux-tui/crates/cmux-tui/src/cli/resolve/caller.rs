//! Where the caller of a request is: the workspace, screen, pane, tab and
//! terminal a `current` or `caller` selector names, and the place a creation
//! with no place opens in (cli/beside.rs has the rule).

use std::time::{Duration, Instant};

use cmux_tui_core::resource::ResourceOperation;
use serde_json::{Map, Value, json};

#[cfg(unix)]
use super::AppAnswer;
use super::{Failure, Reader, SocketRoute, next_event, read, route, session_events, this_machine};
use crate::cli::command::RequestPlan;

/// How long a lookup waits for the caller's terminal to join its workspace.
const CALLER_TERMINAL_WAIT: Duration = Duration::from_secs(3);

/// The workspace that holds the caller's `terminal`, waiting for the
/// terminal to be placed ([`registered_caller_path`]).
pub(super) fn registered_caller_workspace(
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

/// The caller's workspace, screen, pane, tab and terminal ids, keyed by
/// scope, or `None` when nothing names a caller. An agent session's chat and
/// a Chief turn's Home chat are placed by the app that owns this daemon,
/// which reports the place in `system.identify`; a terminal caller (or an
/// agent session no app places) is followed up from its terminal in the
/// daemon. An agent session neither places falls back to the workspace its
/// environment names (`CMUX_WORKSPACE_ID`), when this session has it, with
/// that workspace's active screen, pane and tab.
pub(super) fn caller_path(
    reader: &mut Reader,
    route: &Map<String, Value>,
    socket: &SocketRoute<'_>,
) -> Result<Option<Map<String, Value>>, Failure> {
    let caller = crate::cli::beside::Caller::of_process();
    let mut failure = None;
    #[cfg(unix)]
    if caller.is_chat() {
        match agent_caller_path(socket) {
            Ok(Some(path)) => return Ok(Some(path)),
            Ok(None) => {}
            Err(unanswered) => failure = Some(unanswered),
        }
    }
    if let Some(terminal) = &caller.terminal {
        match registered_caller_path(reader, route, terminal, socket) {
            Ok(path) => return Ok(Some(path)),
            Err(missing) => failure = failure.or(Some(missing)),
        }
    }
    if let Some(key) = caller.fallback_workspace_key()
        && let Some(path) = workspace_key_path(reader, route, key)
    {
        return Ok(Some(path));
    }
    failure.map_or(Ok(None), Err)
}

/// The place of the workspace whose key is `key` in the request's session:
/// the workspace and, while it has them, its active screen, pane and tab.
/// `None` when the session has no such workspace (the key of another
/// session, or a workspace that was closed).
pub(in crate::cli) fn workspace_key_path(
    reader: &mut Reader,
    route: &Map<String, Value>,
    key: &str,
) -> Option<Map<String, Value>> {
    let workspaces = read(reader, ResourceOperation::WorkspaceList, route.clone()).ok()?;
    let workspace = crate::cli::beside::workspace_of_key(&workspaces, key)?;
    let mut path = Map::new();
    let mut selector = route.clone();
    selector.insert("workspace".into(), Value::String(workspace.clone()));
    path.insert("workspace".into(), Value::String(workspace));
    for (operation, scope) in [
        (ResourceOperation::ScreenGet, "screen"),
        (ResourceOperation::PaneGet, "pane"),
        (ResourceOperation::TabGet, "tab"),
    ] {
        selector.insert(scope.into(), Value::String("current".into()));
        let Ok(snapshot) = read(reader, operation, selector.clone()) else { break };
        let Some(id) = snapshot.get("id").and_then(Value::as_str) else { break };
        selector.insert(scope.into(), Value::String(id.to_owned()));
        path.insert(scope.into(), Value::String(id.to_owned()));
    }
    Some(path)
}

/// Puts the caller's own place into a creation that names none
/// (beside.rs `creation_scopes`): a tab in the caller's pane, a pane on its
/// screen, a screen or a link in its workspace, never the daemon's active
/// one, which follows the person's focus. A caller that cannot be found, no
/// caller, and a request to another session or machine keep the daemon's
/// default (which can create a workspace in an empty session, so the request
/// then still names no place). Returns whether `plan` changed.
pub(in crate::cli) fn place_creation(
    reader: &mut Reader,
    plan: &mut RequestPlan,
    caller_route: bool,
    socket: &SocketRoute<'_>,
) -> bool {
    let crate::cli::command::WireOperation::Typed(operation) = &plan.operation else {
        return false;
    };
    let Some(scopes) = crate::cli::beside::creation_scopes(*operation) else { return false };
    let Some(params) = plan.params.as_object_mut() else { return false };
    if !caller_route || !this_machine(params) || !crate::cli::beside::names_no_place(params) {
        return false;
    }
    let route = route(params);
    match caller_path(reader, &route, socket) {
        Ok(Some(path)) => crate::cli::beside::fill_place(params, scopes, &path),
        Ok(None) | Err(_) => false,
    }
}

/// The app's `caller` from `system.identify`. `None` when no app owns this
/// daemon, as on a Cloud machine, or the app does not place the caller.
#[cfg(unix)]
fn agent_caller_path(socket: &SocketRoute<'_>) -> Result<Option<Map<String, Value>>, Failure> {
    match socket.app_answer() {
        None => Ok(None),
        Some(AppAnswer::Identity(identity)) => Ok(crate::cli::beside::caller_path(identity)),
        Some(AppAnswer::Unreachable(message)) => Err(Failure::Transport(message.clone())),
        Some(AppAnswer::Refused(error)) => Err(Failure::Resource(error.clone())),
    }
}

/// The app's `system.identify` answer for this caller (agent session, Chief
/// turn or terminal), or `None` when nothing names a caller, no app owns
/// this daemon, or the app does not answer (down, restarting, slow): the
/// `current` chain then goes to the daemon as before.
#[cfg(unix)]
pub(super) fn caller_identity<'a>(socket: &'a SocketRoute<'_>) -> Option<&'a Value> {
    crate::cli::app::caller_from(|key| std::env::var(key).ok())?;
    socket.identity()
}

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
