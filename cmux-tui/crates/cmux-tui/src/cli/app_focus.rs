//! Focus in a session a cmux app owns belongs to the app's windows
//! (plans/cmux-next/state-ownership.md, section 3): the daemon's shared
//! focused workspace and tab are only the default for clients with no
//! window. So after the daemon answers:
//!
//! - `workspace <id> focus` and `tab <id> focus` also run the app's own
//!   focus action (`goToWorkspace`, `tab.focus`: the path the palette,
//!   keyboard and menu use), so the window shows what was asked for;
//! - a reply that reports workspaces' `focused` takes it from the app: the
//!   workspace its window shows, not the daemon default that every
//!   `workspace create` moves.
//!
//! The app half runs only when an app answers on its control socket and
//! owns the session: an app that does not know the workspace or tab
//! (`not_found`), or whose shown workspace is not in the reply, leaves the
//! daemon's answer as it is. Without an app nothing changes.

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
        AppFocus::Tab => {
            let mut params = action_run_params("tab.focus", ActionName::Any, "script");
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

fn is_not_found(error: &Value) -> bool {
    matches!(error.get("code").and_then(Value::as_str), Some("not_found" | "target.not_found"))
}

/// The workspace the app's focused window shows (`snapshot.get`).
pub(super) fn app_focused_workspace(stream: &mut UnixStream) -> Option<String> {
    let reply = super::app::request(stream, "snapshot.get", json!({}), super::app::READ_TIMEOUT)
        .ok()?
        .ok()?;
    reply.pointer("/topology/focus/workspace").and_then(Value::as_str).map(str::to_owned)
}

/// Sets `focused` on every workspace record in `value` (an object with a
/// `ws_` id and a `focused` field) to whether it is `shown`, when `shown`
/// is one of them; otherwise the app does not own this session and `value`
/// stays as it is. Returns whether it changed the records.
pub(super) fn overlay_focused(_value: &mut Value, _shown: &str) -> bool {
    false
}

/// The id a focus op's reply names (`value.id`, else `id`).
fn reply_id(result: &Value) -> Option<String> {
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
    _stream: &mut UnixStream,
    _follow: &Follow,
    _result: &mut Value,
) -> Result<(), Value> {
    Ok(())
}

#[cfg(test)]
mod tests;
