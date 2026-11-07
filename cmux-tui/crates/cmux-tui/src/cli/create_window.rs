//! The window a `workspace create` opens in (#32989).
//!
//! The daemon has no windows: the app files each new workspace into one, and
//! a create it did not make itself went to the most recent window. So a
//! Chief prompted from one window had its workspaces open in another. Before
//! the create, the CLI tells the app which window it is for
//! (`workspace.expect_window`, keyed by the create's idempotency key, which
//! the daemon echoes on the workspace-added delta). The app then files the
//! workspace there as it arrives:
//!
//! - `--window <win_…>`: that window; an unknown or closed one is refused,
//!   and with no app to place it the create is refused too.
//! - otherwise, with a caller (a Chief turn, an agent session, a terminal):
//!   a Chief turn's prompting window, else the window that lists the
//!   caller's own workspace. With no app, or an app that cannot say, the
//!   create goes on and lands where it did before.

use std::path::Path;
#[cfg(unix)]
use std::time::Duration;

use cmux_tui_core::resource::ResourceOperation;
use serde_json::{Value, json};

use super::GlobalArgs;
use super::command::{RequestPlan, WireOperation};

/// The private param `workspace create --window` puts in the plan; it is
/// taken out before the request goes to the daemon, which has no windows.
pub(super) const WINDOW_PARAM: &str = "window";

/// The app method that announces a create.
pub(super) const METHOD: &str = "workspace.expect_window";

#[cfg(unix)]
const WAIT: Duration = Duration::from_secs(2);

/// Whether `plan` is a workspace create, which may name a window.
pub(super) fn applies(plan: &RequestPlan) -> bool {
    matches!(plan.operation, WireOperation::Typed(ResourceOperation::WorkspaceCreate))
}

/// The `--window` of `plan`, taken out of its params.
pub(super) fn take_window(plan: &mut RequestPlan) -> Option<String> {
    let params = plan.params.as_object_mut()?;
    params.remove(WINDOW_PARAM).and_then(|value| value.as_str().map(str::to_owned))
}

/// The `workspace.expect_window` params for the create keyed `key`. The CLI
/// adds the caller (app.rs `with_caller`).
pub(super) fn expect_params(key: &str, window: Option<&str>, focus: bool) -> Value {
    let mut params = json!({"idempotency_key": key});
    if let Some(window) = window {
        params["window"] = json!(window);
    }
    if focus {
        params["focus"] = json!(true);
    }
    params
}

/// Whether the create should be announced: it names a window, or it runs
/// for a caller in this machine's own session (`caller_route`, the request
/// names no other session or machine).
pub(super) fn announces(
    window: Option<&str>,
    caller_route: bool,
    this_machine: bool,
    has_caller: bool,
) -> bool {
    window.is_some() || (caller_route && this_machine && has_caller)
}

/// Announces `plan`'s create to the app that owns `daemon_socket` and takes
/// `--window` out of its params. `key` is the create's idempotency key.
/// `Err` is a resource error that stops the create: a window it named that
/// the app cannot place it in.
pub(super) fn announce(
    global: &GlobalArgs,
    plan: &mut RequestPlan,
    key: Option<&str>,
    daemon_socket: &Path,
    caller_route: bool,
) -> Result<(), Value> {
    if !applies(plan) {
        return Ok(());
    }
    let window = take_window(plan);
    let this_machine = plan
        .params
        .get("machine")
        .and_then(Value::as_str)
        .is_none_or(|machine| machine == "current");
    if !announces(window.as_deref(), caller_route, this_machine, has_caller()) {
        return Ok(());
    }
    let focus = plan.params.get("focus").and_then(Value::as_bool) == Some(true);
    let Some(key) = key else { return window.map_or(Ok(()), |window| Err(no_app(&window))) };
    let params = expect_params(key, window.as_deref(), focus);
    match (send(global, daemon_socket, params), window) {
        (Ok(Ok(_)), _) => Ok(()),
        // The window named is not one the app has: never create it elsewhere.
        (Ok(Err(error)), Some(_)) => Err(error),
        (Err(_), Some(window)) => Err(no_app(&window)),
        // No app, or one from before this method: the most recent window, as before.
        (_, None) => Ok(()),
    }
}

/// A caller is named in the environment (a Chief turn, an agent session, a terminal).
#[cfg(unix)]
fn has_caller() -> bool {
    super::app::caller_from(|name| std::env::var(name).ok()).is_some()
}

#[cfg(not(unix))]
fn has_caller() -> bool {
    false
}

#[cfg(unix)]
fn send(
    global: &GlobalArgs,
    daemon_socket: &Path,
    params: Value,
) -> Result<Result<Value, Value>, String> {
    let app = super::frontend_browser::owning_app_socket(global, daemon_socket)
        .ok_or_else(|| "no cmux app owns this session".to_owned())?;
    let mut stream = super::app::connect(&app)?;
    super::app::request(&mut stream, METHOD, params, WAIT)
}

#[cfg(not(unix))]
fn send(_: &GlobalArgs, _: &Path, _: Value) -> Result<Result<Value, Value>, String> {
    Err("no cmux app on this platform".to_owned())
}

fn no_app(window: &str) -> Value {
    json!({
        "code": "app.unavailable",
        "message": format!(
            "--window {window} needs the cmux app that shows this session's windows; \
             without it the workspace would open in another window"
        ),
        "details": {"window": window},
        "retryable": true,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_named_window_is_always_announced() {
        assert!(announces(Some("win_a"), false, false, false));
    }

    #[test]
    fn a_caller_in_its_own_session_is_announced() {
        assert!(announces(None, true, true, true));
        assert!(
            !announces(None, true, true, false),
            "no caller: the most recent window, as before"
        );
        assert!(!announces(None, false, true, true), "another session's create");
        assert!(!announces(None, true, false, true), "another machine's create");
    }

    #[test]
    fn the_announcement_names_the_key_window_and_focus() {
        assert_eq!(expect_params("k1", None, false), json!({"idempotency_key": "k1"}));
        assert_eq!(
            expect_params("k1", Some("win_a"), true),
            json!({"idempotency_key": "k1", "window": "win_a", "focus": true})
        );
    }
}
