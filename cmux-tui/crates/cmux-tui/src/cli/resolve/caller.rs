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
/// scope, or `None` when nothing names a caller.
///
/// - An agent session's chat and a Chief turn's Home chat are placed by the
///   app that owns this daemon, which reports the place in
///   `system.identify`. The caller names the workspace its session runs in
///   (`CMUX_WORKSPACE_ID`, app.rs `caller_from`), so the app also places an
///   agent whose chat no tab shows, in that workspace.
/// - An agent the owning app cannot place at all is refused
///   ([`unplaced_agent_failure`]), unless it runs in a cmux terminal, which
///   then places it. Its `current` and its creations never go to the focused
///   workspace or Home (user, 2026-11-18).
/// - A terminal caller is followed up from its terminal in the daemon.
/// - In a session no app owns (a plain cmux-tui session, a Cloud machine)
///   an agent with no terminal is placed in the workspace its session runs
///   in, read from the daemon by the same key ([`workspace_key_path`]): the
///   same workspace the app would choose.
pub(super) fn caller_path(
    reader: &mut Reader,
    route: &Map<String, Value>,
    socket: &SocketRoute<'_>,
) -> Result<Option<Map<String, Value>>, Failure> {
    let caller = crate::cli::beside::Caller::of_process();
    #[cfg(unix)]
    if caller.is_chat() {
        match agent_caller_path(socket, &caller) {
            Ok(Some(path)) => return Ok(Some(path)),
            // An unplaced agent in a cmux terminal is still placed by its terminal.
            Err(failure) if !(unplaced_agent(&failure) && caller.terminal.is_some()) => {
                return Err(failure);
            }
            _ => {}
        }
    }
    if let Some(terminal) = &caller.terminal {
        return registered_caller_path(reader, route, terminal, socket).map(Some);
    }
    // The key first: a shell outside cmux names none, and must not pay an
    // app round trip to learn that it has no place.
    let Some(key) = caller.fallback_workspace_key() else { return Ok(None) };
    #[cfg(unix)]
    let owned = socket.has_owner();
    #[cfg(not(unix))]
    let owned = false;
    if owned {
        return Ok(None);
    }
    Ok(workspace_key_path(reader, route, key))
}

/// The place of the workspace whose key is `key` in the request's session:
/// the workspace and, while it has them, its active screen, pane and tab.
/// `None` when the session has no such workspace (the key of another
/// session, or a workspace that was closed).
fn workspace_key_path(
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
/// one, which follows the person's focus. `Ok(true)` when `plan` changed.
///
/// No caller, a terminal that cannot be found, and a request to another
/// session or machine keep the daemon's default (which can create a
/// workspace in an empty session, so the request then still names no place).
/// A Chief turn's pane, screen and link keep the daemon's default too
/// (beside.rs `Caller::creation_scopes`). An agent the owning app cannot
/// place is refused (`Err`): the daemon's default is the focused workspace.
pub(in crate::cli) fn place_creation(
    reader: &mut Reader,
    plan: &mut RequestPlan,
    caller_route: bool,
    socket: &SocketRoute<'_>,
) -> Result<bool, Failure> {
    let crate::cli::command::WireOperation::Typed(operation) = &plan.operation else {
        return Ok(false);
    };
    let caller = crate::cli::beside::Caller::of_process();
    let Some(scopes) = caller.creation_scopes(*operation) else { return Ok(false) };
    let Some(params) = plan.params.as_object_mut() else { return Ok(false) };
    if !caller_route || !this_machine(params) || !crate::cli::beside::names_no_place(params) {
        return Ok(false);
    }
    let route = route(params);
    match caller_path(reader, &route, socket) {
        Ok(Some(path)) => Ok(crate::cli::beside::fill_place(params, scopes, &path)),
        Err(failure) if unplaced_agent(&failure) => Err(failure),
        Ok(None) | Err(_) => Ok(false),
    }
}

/// The app's `caller` from `system.identify`. `None` when no app owns this
/// daemon, as on a Cloud machine, or the app has no place for a Chief turn.
/// An agent (not a Chief turn) the app shows nowhere is an error
/// ([`unplaced_agent_failure`]).
#[cfg(unix)]
fn agent_caller_path(
    socket: &SocketRoute<'_>,
    caller: &crate::cli::beside::Caller,
) -> Result<Option<Map<String, Value>>, Failure> {
    match socket.app_answer() {
        None => Ok(None),
        Some(AppAnswer::Identity(identity)) => match crate::cli::beside::caller_path(identity) {
            Some(path) => Ok(Some(path)),
            // An agent (not a Chief turn) the app shows nowhere: neither a chat
            // tab nor its session's workspace (`CMUX_WORKSPACE_ID`) is open.
            None if caller.home_chat => Ok(None),
            None => Err(unplaced_agent_failure()),
        },
        Some(AppAnswer::Unreachable(message)) => Err(Failure::Transport(message.clone())),
        Some(AppAnswer::Refused(error)) => Err(Failure::Resource(error.clone())),
    }
}

/// The app shows neither the agent's chat nor its session's workspace.
pub(super) fn unplaced_agent_failure() -> Failure {
    Failure::Resource(json!({
        "code": "caller_unavailable",
        "message": "cmux shows neither this agent's chat nor the workspace its session runs in \
                    (CMUX_WORKSPACE_ID); name a workspace by id: cmux workspace <workspace> …",
        "retryable": false,
    }))
}

/// Whether `failure` is [`unplaced_agent_failure`], which `current` and a
/// creation with no place never turn into the focused object.
pub(super) fn unplaced_agent(failure: &Failure) -> bool {
    matches!(failure, Failure::Resource(error) if error["code"] == "caller_unavailable")
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
