//! Focus in a session a cmux app owns belongs to the app's windows
//! (plans/cmux-next/state-ownership.md, section 3): the daemon's shared
//! focused workspace and tab are only the default for clients with no
//! window. So after the daemon answers:
//!
//! - `workspace|tab|pane|screen <id> focus` also run the app's own focus
//!   action (`goToWorkspace`, `tab.focus`, `pane.focus`, `screen.focus`: the
//!   path the palette, keyboard and menu use), so the window shows what was
//!   asked for;
//! - a reply that reports workspaces' `focused` takes it from the app: the
//!   workspace its window shows, not the daemon default that every
//!   `workspace create` moves.
//!
//! The app half runs only when an app answers on its control socket and
//! owns the session: an app that does not know the workspace or tab
//! (`not_found`), or whose shown workspace is not in the reply, leaves the
//! daemon's answer as it is. Without an app nothing changes.

use std::collections::HashSet;
use std::os::unix::net::UnixStream;

use serde_json::{Value, json};

use super::GlobalArgs;
use super::app::{ActionName, action_run_params, connect, insert_run_key, request_with_retry};
use cmux_tui_core::resource::ResourceOperation;

/// The app action that shows what a daemon focus op named, with the
/// argument or target that names it.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum AppFocus {
    /// `goToWorkspace` with `args.workspace`.
    Workspace,
    /// `tab.focus` with `target`.
    Tab,
    /// `pane.focus` with `target`.
    Pane,
    /// `screen.focus` with `target`.
    Screen,
}

/// What the app adds to the daemon's answer to `operation`.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum Follow {
    Focus(AppFocus),
    /// The reply's workspace records take `focused` from the app.
    Focused,
    Nothing,
}

pub(super) fn follow_for(operation: ResourceOperation) -> Follow {
    match operation {
        ResourceOperation::WorkspaceFocus => Follow::Focus(AppFocus::Workspace),
        ResourceOperation::TabFocus => Follow::Focus(AppFocus::Tab),
        ResourceOperation::PaneFocus => Follow::Focus(AppFocus::Pane),
        ResourceOperation::ScreenFocus => Follow::Focus(AppFocus::Screen),
        ResourceOperation::WorkspaceList
        | ResourceOperation::WorkspaceGet
        | ResourceOperation::WorkspaceRename
        | ResourceOperation::WorkspaceMove => Follow::Focused,
        _ => Follow::Nothing,
    }
}

/// The app's control socket, connected, when an app answers there.
fn app_stream(global: &GlobalArgs) -> Option<UnixStream> {
    let socket = super::app::socket_path(global).ok()?;
    connect(&socket).ok()
}

/// The `action.run` params that show `id` in the app.
pub(super) fn focus_params(focus: &AppFocus, id: &str) -> Value {
    let mut params = match focus {
        AppFocus::Workspace => {
            let mut params = action_run_params("goToWorkspace", ActionName::Any, "script");
            params.insert("args".into(), json!({ "workspace": id }));
            params
        }
        AppFocus::Tab | AppFocus::Pane | AppFocus::Screen => {
            let action = match focus {
                AppFocus::Pane => "pane.focus",
                AppFocus::Screen => "screen.focus",
                _ => "tab.focus",
            };
            let mut params = action_run_params(action, ActionName::Any, "script");
            params.insert("target".into(), json!(id));
            params
        }
    };
    params.insert("focus".into(), json!(true));
    Value::Object(params)
}

/// Runs the app's focus action for `id`. Ok when the app showed it or does
/// not own it (`not_found`); Err carries the app's error otherwise.
pub(super) fn focus_in_app(
    stream: &mut UnixStream,
    focus: &AppFocus,
    id: &str,
) -> Result<(), Value> {
    let mut params = focus_params(focus, id);
    insert_run_key(&mut params, None)
        .map_err(|e| json!({"code": "app.unreachable", "message": e}))?;
    match request_with_retry(stream, "action.run", &params, super::app::WAITING_RUN_TIMEOUT) {
        Ok(Ok(_)) => Ok(()),
        Ok(Err(error)) if is_not_found(&error) => Ok(()),
        Ok(Err(error)) => Err(error),
        Err(transport) => Err(json!({"code": "app.unreachable", "message": transport})),
    }
}

pub(super) fn is_not_found(error: &Value) -> bool {
    matches!(error.get("code").and_then(Value::as_str), Some("not_found" | "target.not_found"))
}

/// What the app's windows show: the focused window's workspace and every
/// workspace the app has (`snapshot.get`).
pub(super) struct AppWorkspaces {
    /// The workspace the app's focused window shows.
    pub(super) shown: String,
    /// Every workspace in the app's topology; empty when the app sent none.
    pub(super) known: HashSet<String>,
}

impl AppWorkspaces {
    /// The app shows `shown` and lists no workspaces of its own.
    pub(super) fn showing(shown: &str) -> Self {
        Self { shown: shown.to_owned(), known: HashSet::new() }
    }
}

/// What the app's windows show (`snapshot.get`).
pub(super) fn app_workspaces(stream: &mut UnixStream) -> Option<AppWorkspaces> {
    let reply = super::app::request(stream, "snapshot.get", json!({}), super::app::READ_TIMEOUT)
        .ok()?
        .ok()?;
    let shown = reply.pointer("/topology/focus/workspace").and_then(Value::as_str)?.to_owned();
    let known = reply
        .pointer("/topology/workspaces")
        .and_then(Value::as_array)
        .map(|workspaces| {
            workspaces
                .iter()
                .filter_map(|workspace| workspace.get("id").and_then(Value::as_str))
                .map(str::to_owned)
                .collect()
        })
        .unwrap_or_default();
    Some(AppWorkspaces { shown, known })
}

/// Sets `focused` on the workspace records in `value` (objects with a `ws_`
/// id and a `focused` field) to whether the app's window shows them. A
/// record the app has (`app.known`) always takes the app's answer, also a
/// single `workspace <id> show`; when the app lists no workspaces, the
/// records take it only when `app.shown` is one of them. Records of another
/// session stay as the daemon said. Returns whether it changed the records.
pub(super) fn overlay_focused(value: &mut Value, app: &AppWorkspaces) -> bool {
    let shown = app.shown.as_str();
    fn ids(value: &Value, out: &mut Vec<String>) {
        match value {
            Value::Object(map) => {
                if let (Some(Value::String(id)), Some(Value::Bool(_))) =
                    (map.get("id"), map.get("focused"))
                    && id.starts_with("ws_")
                {
                    out.push(id.clone());
                }
                map.values().for_each(|v| ids(v, out));
            }
            Value::Array(items) => items.iter().for_each(|v| ids(v, out)),
            _ => {}
        }
    }
    fn set(value: &mut Value, shown: &str, owned: &dyn Fn(&str) -> bool) {
        match value {
            Value::Object(map) => {
                let id = map.get("id").and_then(Value::as_str).map(str::to_owned);
                let is_workspace = id.as_deref().is_some_and(|id| id.starts_with("ws_"))
                    && map.get("focused").is_some_and(Value::is_boolean);
                if is_workspace && let Some(id) = id.as_deref().filter(|id| owned(id)) {
                    map.insert("focused".into(), Value::Bool(id == shown));
                }
                map.values_mut().for_each(|v| set(v, shown, owned));
            }
            Value::Array(items) => items.iter_mut().for_each(|v| set(v, shown, owned)),
            _ => {}
        }
    }
    let mut found = Vec::new();
    ids(value, &mut found);
    if app.known.is_empty() {
        if !found.iter().any(|id| id == shown) {
            return false;
        }
        set(value, shown, &|_| true);
        return true;
    }
    if !found.iter().any(|id| app.known.contains(id)) {
        return false;
    }
    set(value, shown, &|id| app.known.contains(id));
    true
}

/// The id a focus op's reply names (`value.id`, else `id`).
pub(super) fn reply_id(result: &Value) -> Option<String> {
    result
        .pointer("/value/id")
        .or_else(|| result.get("id"))
        .and_then(Value::as_str)
        .map(str::to_owned)
}

/// The app half of a daemon answer: Ok with the result to print, Err with
/// the app's error when its focus action failed.
pub(super) fn after_daemon(
    global: &GlobalArgs,
    operation: ResourceOperation,
    mut result: Value,
) -> Result<Value, Value> {
    let follow = follow_for(operation);
    if follow == Follow::Nothing {
        return Ok(result);
    }
    let Some(mut stream) = app_stream(global) else { return Ok(result) };
    after_daemon_with(&mut stream, &follow, &mut result)?;
    Ok(result)
}

pub(super) fn after_daemon_with(
    stream: &mut UnixStream,
    follow: &Follow,
    result: &mut Value,
) -> Result<(), Value> {
    match follow {
        Follow::Nothing => Ok(()),
        Follow::Focus(focus) => {
            let Some(id) = reply_id(result) else { return Ok(()) };
            focus_in_app(stream, focus, &id)
        }
        Follow::Focused => {
            if let Some(app) = app_workspaces(stream) {
                overlay_focused(result, &app);
            }
            Ok(())
        }
    }
}

#[cfg(test)]
mod tests;
