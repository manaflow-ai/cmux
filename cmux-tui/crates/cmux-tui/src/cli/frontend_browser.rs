//! `tab create browser` and `browser open` in a session a cmux app owns.
//!
//! The cmux app draws only the browser tabs it renders itself (frontend
//! browser tabs, with an engine and a profile). A `tab.create_browser` sent
//! straight to the daemon makes a daemon-rendered tab, which the app shows as
//! a blank pane. So when an app owns the session, the CLI runs the app's own
//! `openBrowser` action (the path the palette, keyboard and tab strip use):
//! the app resolves the engine (`browser.defaultEngine`) and the profile.
//!
//! Where the tab goes (plans/cmux-next/state-ownership.md, section 3):
//! 1. the pane the command names (`--workspace`, `--screen`, `--pane`);
//! 2. else the pane of the caller's own terminal (`CMUX_TUI_TERMINAL_ID`);
//! 3. else the focused pane of the app's front window (no target: the app
//!    resolves it). The daemon's shared active pane is only the default for
//!    a CLI with no app, which keeps the old daemon path;
//! 4. else, when the front window shows a page (Home, History: no pane, so
//!    the app refuses a run with no target), the daemon's default pane, the
//!    target before 772c55184089. The app still opens the tab, and then its
//!    window shows it (`tab.focus`), or the person would see nothing.
//!
//! An app refusal of a run it never started (`unavailable`, `not_run`) is
//! final: the CLI prints it and no retry note, as nothing may still apply.
//!
//! The app's `openBrowser` takes a tab target, so a named pane is given by
//! one of its tabs (the daemon resolves the selectors). The reply is the
//! daemon's created path of the new tab, the same shape `tab.create_browser`
//! answers.

use std::io::BufReader;
use std::os::unix::net::UnixStream;
use std::path::Path;

use cmux_tui_core::platform::transport;
use cmux_tui_core::resource::{PROTOCOL, ResourceOperation};
use serde_json::{Map, Value, json};

use super::GlobalArgs;
use super::app::{ActionName, action_run_params, insert_run_key, request_with_retry};
use super::command::{RequestPlan, WireOperation};
use super::resolve::{Failure, read, read_response, send};

type Reader = BufReader<Box<dyn transport::Stream>>;

/// The parent selectors a browser creation may name.
const PARENTS: [&str; 3] = ["workspace", "screen", "pane"];

/// Whether `plan` creates a browser tab the app should render: one on this
/// machine (another machine's tab is that machine's daemon's to place).
fn applies(plan: &RequestPlan) -> bool {
    let this_machine =
        plan.params.get("machine").is_none_or(|machine| machine.as_str() == Some("current"));
    matches!(plan.operation, WireOperation::Typed(ResourceOperation::TabCreateBrowser))
        && plan.params.get("frontend_browser_id").is_none()
        && this_machine
}

/// The app's control socket, connected, when an app owns the session at
/// `daemon_socket` and answers there. `--app-socket` names that app
/// explicitly; otherwise the app this `cmux` belongs to owns the session
/// when the daemon socket is that app's own daemon socket.
fn owning_app(global: &GlobalArgs, daemon_socket: &Path) -> Option<UnixStream> {
    if global.app_socket.is_none() && !app_daemon_is(daemon_socket) {
        return None;
    }
    let socket = super::app::socket_path(global).ok()?;
    super::app::connect(&socket).ok()
}

#[cfg(target_os = "macos")]
fn app_daemon_is(daemon_socket: &Path) -> bool {
    let exe = std::env::current_exe().ok();
    let Some(identity) =
        crate::app_identity::AppIdentity::detect(|key| std::env::var(key).ok(), exe.as_deref())
    else {
        return false;
    };
    crate::app_identity::app_daemon_socket(&identity)
        .is_some_and(|app_socket| same_path(&app_socket, daemon_socket))
}

#[cfg(not(target_os = "macos"))]
fn app_daemon_is(_daemon_socket: &Path) -> bool {
    false
}

/// Two spellings of one socket (`/var` is `/private/var` on macOS).
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
fn same_path(a: &Path, b: &Path) -> bool {
    let canonical = |path: &Path| std::fs::canonicalize(path).unwrap_or_else(|_| path.to_owned());
    a == b || canonical(a) == canonical(b)
}

/// Runs a browser creation through the app when `plan` is one and an app
/// owns the session: `Some(exit code)`, or `None` for the daemon path.
/// `caller_route` says the request addresses the caller's own session, so
/// its terminal (`CMUX_TUI_TERMINAL_ID`) names the pane.
pub(super) fn run_in_app(
    global: &GlobalArgs,
    plan: &RequestPlan,
    request: &Value,
    reader: &mut Reader,
    daemon_socket: &Path,
    caller_route: bool,
    key_report: &super::wire::KeyReport,
) -> Option<i32> {
    if !applies(plan) {
        return None;
    }
    let mut app = owning_app(global, daemon_socket)?;
    let caller_terminal = caller_route
        .then(|| std::env::var("CMUX_TUI_TERMINAL_ID").ok())
        .flatten()
        .filter(|id| !id.is_empty());
    let key = request.get("idempotency_key").and_then(Value::as_str);
    let _ = reader.get_mut().set_read_timeout(super::wire::response_read_timeout(plan, true));
    Some(match open(reader, &mut app, plan, caller_terminal.as_deref(), key) {
        Ok(result) => {
            key_report.succeeded();
            super::wire::print_result(global, plan, result)
        }
        Err(failure) => {
            if never_ran(&failure) {
                key_report.succeeded();
            }
            let code = failure.report(global.output);
            key_report.finish(global.output);
            code
        }
    })
}

/// Opens the browser tab through the app and returns the daemon's created
/// path for it. `caller_terminal` is the caller's own terminal when the
/// request addresses the caller's session; `key` is the request's
/// idempotency key, reused for the app run.
pub(super) fn open(
    reader: &mut Reader,
    app: &mut UnixStream,
    plan: &RequestPlan,
    caller_terminal: Option<&str>,
    key: Option<&str>,
) -> Result<Value, Failure> {
    let params = plan
        .params
        .as_object()
        .ok_or_else(|| Failure::Transport("cmux: request params are not an object".into()))?;
    let route = route(params);
    let url = params.get("url").and_then(Value::as_str).unwrap_or_default();
    let target = target_tab(reader, &route, params, caller_terminal)?;
    let key = match key {
        Some(key) => key.to_owned(),
        None => super::command::random_prefixed("mutation")
            .map_err(|error| app_failure("app.transport", error.to_string()))?,
    };
    let (reply, tab, on_default_pane) = match run_open(app, url, target.as_deref(), &key) {
        // The window shows a page: no focused pane to open in.
        Err(failure) if target.is_none() && never_ran(&failure) => {
            // No default pane either: the app's refusal says why.
            let Ok(default) = read(reader, ResourceOperation::TabGet, default_pane_tab(&route))
                .and_then(|tab| string_field(&tab, "id", "tab"))
            else {
                return Err(failure);
            };
            let (reply, tab) = run_open(app, url, Some(&default), &format!("{key}.default"))?;
            (reply, tab, true)
        }
        opened => {
            let (reply, tab) = opened?;
            (reply, tab, false)
        }
    };
    if on_default_pane {
        // Best effort: the tab exists; a window that cannot show it now
        // still lists it.
        let _ = super::app_focus::focus_in_app(app, &super::app_focus::AppFocus::Tab, &tab);
    }
    if let Some(name) = params.get("name").and_then(Value::as_str) {
        let mut rename = route.clone();
        rename.insert("tab".into(), json!(tab));
        rename.insert("name".into(), json!(name));
        mutate(reader, ResourceOperation::TabRename, rename, &format!("{key}.name"))?;
    }
    let path = created_path(reader, &route, &tab)?;
    let replayed = reply.get("replayed").and_then(Value::as_bool).unwrap_or(false);
    Ok(json!({"value": path, "replayed": replayed}))
}

/// Runs `openBrowser` for `url` on `target` with idempotency key `key`:
/// the app's reply and the tab it created.
fn run_open(
    app: &mut UnixStream,
    url: &str,
    target: Option<&str>,
    key: &str,
) -> Result<(Value, String), Failure> {
    let mut run = Value::Object(open_browser_params(url, target));
    insert_run_key(&mut run, Some(key)).map_err(|error| app_failure("app.transport", error))?;
    let reply = match request_with_retry(app, "action.run", &run, super::app::WAITING_RUN_TIMEOUT) {
        Ok(Ok(reply)) => reply,
        Ok(Err(error)) => return Err(Failure::Resource(resource_error(error))),
        Err(transport) => return Err(app_failure("app.unreachable", transport)),
    };
    let tab = created_tab(&reply).ok_or_else(|| {
        app_failure(
            "operation.failed",
            "the app opened no browser tab (its openBrowser reply names no created tab)".into(),
        )
    })?;
    Ok((reply, tab))
}

/// Whether the app refused a run it never started: `unavailable` (not in
/// this context, for example a page with no tabs) or a `not_run` state.
pub(super) fn never_ran(failure: &Failure) -> bool {
    let Failure::Resource(error) = failure else { return false };
    let details = &error["details"];
    error["code"] == "unavailable" || details["not_run"] == true || details["state"] == "not_run"
}

/// The `tab.get` selector for the shown tab of the daemon's default pane
/// (its current workspace, screen and pane).
pub(super) fn default_pane_tab(route: &Map<String, Value>) -> Map<String, Value> {
    let mut selector = route.clone();
    for key in PARENTS.iter().chain(["tab"].iter()) {
        selector.insert((*key).into(), json!("current"));
    }
    selector
}

/// The `action.run` params of `openBrowser` for `url`, on `target` (a tab
/// whose pane gets the new tab) or, with none, the app's focused pane.
pub(super) fn open_browser_params(url: &str, target: Option<&str>) -> Map<String, Value> {
    let origin = super::app::action_origin();
    let mut params = action_run_params("openBrowser", ActionName::Any, origin);
    params.insert("args".into(), json!({ "url": url }));
    if let Some(tab) = target {
        params.insert("target".into(), json!(format!("tab:{tab}")));
    }
    params
}

/// A tab of the pane the new browser tab goes to, or `None` for the app's
/// focused pane.
fn target_tab(
    reader: &mut Reader,
    route: &Map<String, Value>,
    params: &Map<String, Value>,
    caller_terminal: Option<&str>,
) -> Result<Option<String>, Failure> {
    if let Some(selector) = named_pane_tab(route, params) {
        let tab = read(reader, ResourceOperation::TabGet, selector)?;
        return Ok(Some(string_field(&tab, "id", "tab")?));
    }
    if let Some(terminal) = caller_terminal {
        let mut selector = route.clone();
        selector.insert("terminal".into(), json!(terminal));
        let snapshot = read(reader, ResourceOperation::TerminalGet, selector)?;
        return Ok(Some(string_field(&snapshot, "tab_id", "terminal")?));
    }
    Ok(None)
}

/// The `tab.get` selector for the shown tab of the pane the command names:
/// the given parents, and `current` for each level below the deepest one.
/// `None` when the command names no parent.
pub(super) fn named_pane_tab(
    route: &Map<String, Value>,
    params: &Map<String, Value>,
) -> Option<Map<String, Value>> {
    let deepest = PARENTS.iter().rposition(|key| params.contains_key(*key))?;
    let mut selector = route.clone();
    for key in &PARENTS[..=deepest] {
        if let Some(value) = params.get(*key) {
            selector.insert((*key).into(), value.clone());
        }
    }
    for key in PARENTS[deepest + 1..].iter().chain(["tab"].iter()) {
        selector.insert((*key).into(), json!("current"));
    }
    Some(selector)
}

/// The public id of the tab an `openBrowser` run created.
pub(super) fn created_tab(reply: &Value) -> Option<String> {
    reply
        .get("created")?
        .as_array()?
        .iter()
        .filter_map(Value::as_str)
        .find(|id| id.starts_with("tab_"))
        .map(str::to_owned)
}

/// `tab.create_browser`'s created path for `tab`: tab -> pane -> screen.
fn created_path(
    reader: &mut Reader,
    route: &Map<String, Value>,
    tab: &str,
) -> Result<Value, Failure> {
    let mut selector = route.clone();
    selector.insert("tab".into(), json!(tab));
    let tab_snapshot = read(reader, ResourceOperation::TabGet, selector)?;
    let pane = string_field(&tab_snapshot, "pane_id", "tab")?;
    let mut selector = route.clone();
    selector.insert("pane".into(), json!(pane));
    let screen =
        string_field(&read(reader, ResourceOperation::PaneGet, selector)?, "screen_id", "pane")?;
    let mut selector = route.clone();
    selector.insert("screen".into(), json!(screen));
    let workspace = string_field(
        &read(reader, ResourceOperation::ScreenGet, selector)?,
        "workspace_id",
        "screen",
    )?;
    Ok(json!({
        "kind": "browser",
        "workspace_id": workspace,
        "screen_id": screen,
        "pane_id": pane,
        "tab_id": tab,
        "browser_id": tab_snapshot.get("content_id").cloned().unwrap_or(Value::Null),
    }))
}

fn string_field(snapshot: &Value, field: &str, kind: &str) -> Result<String, Failure> {
    snapshot.get(field).and_then(Value::as_str).map(str::to_owned).ok_or_else(|| {
        Failure::Transport(format!("protocol error: the daemon's {kind} snapshot has no {field}"))
    })
}

fn route(params: &Map<String, Value>) -> Map<String, Value> {
    ["machine", "session"]
        .into_iter()
        .filter_map(|key| params.get(key).map(|value| (key.to_string(), value.clone())))
        .collect()
}

/// One mutation on the daemon connection with idempotency key `key`.
fn mutate(
    reader: &mut Reader,
    operation: ResourceOperation,
    params: Map<String, Value>,
    key: &str,
) -> Result<Value, Failure> {
    let id = super::wire::random_request_id()
        .map_err(|error| Failure::Transport(format!("cmux: {error}")))?;
    let request = json!({
        "protocol": PROTOCOL,
        "type": "request",
        "id": id,
        "operation": operation.wire_name(),
        "params": params,
        "idempotency_key": key,
    });
    let encoded = super::resolve::encode_request_bytes(&request)
        .map_err(|error| Failure::Transport(format!("cmux: {error}")))?;
    send(reader, &encoded).map_err(Failure::Transport)?;
    match read_response(reader, &id).map_err(Failure::Transport)? {
        Ok(result) => Ok(result),
        Err(error) => Err(Failure::Resource(error)),
    }
}

/// An app error (`{code, message, data}`) in the resource error shape.
fn resource_error(error: Value) -> Value {
    json!({
        "code": error.get("code").cloned().unwrap_or_else(|| json!("operation.failed")),
        "message": error.get("message").cloned().unwrap_or_else(|| json!("the app refused openBrowser")),
        "details": error.get("data").cloned().unwrap_or_else(|| json!({})),
        "retryable": false,
    })
}

fn app_failure(code: &str, message: String) -> Failure {
    Failure::Resource(json!({"code": code, "message": message, "details": {}, "retryable": false}))
}

#[cfg(test)]
mod tests;
