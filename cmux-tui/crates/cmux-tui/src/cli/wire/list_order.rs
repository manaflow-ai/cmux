//! `workspace list` with no `--order` in the cmux app's context asks for the
//! personal order, the order the app's sidebar shows (a new workspace on
//! top, Move Up/Down and row drags move only the personal row). The app's
//! context is a daemon socket that is the app's own daemon: the one its
//! Chief names in `CMUX_APP_DAEMON_SOCKET`, or, in an app terminal, the
//! daemon of the app this `cmux` belongs to (`app_owns_daemon`). Elsewhere
//! the daemon's default stays: with the sidebar document (`sidebar-doc-v1`)
//! that is the sidebar order for every caller too, so this only matters for a
//! daemon without the document, whose default is the session order.
//! `--order` always wins.

use std::path::{Path, PathBuf};

use serde_json::Value;

use super::super::command::{RequestPlan, WireOperation};
use cmux_tui_core::resource::ResourceOperation;

/// Adds `order: "personal"` to `plan` and `request` when it applies;
/// whether it did (the request must be encoded again).
pub(super) fn apply(plan: &mut RequestPlan, request: &mut Value, daemon_socket: &Path) -> bool {
    let list = matches!(plan.operation, WireOperation::Typed(ResourceOperation::WorkspaceList));
    if !list || plan.params.get("order").is_some() || !app_context(daemon_socket) {
        return false;
    }
    let order = Value::String("personal".into());
    let (Some(params), Some(sent)) =
        (plan.params.as_object_mut(), request.get_mut("params").and_then(Value::as_object_mut))
    else {
        return false;
    };
    params.insert("order".into(), order.clone());
    sent.insert("order".into(), order);
    true
}

/// Whether `daemon_socket` is the cmux app's own daemon.
fn app_context(daemon_socket: &Path) -> bool {
    let named = super::super::caller_env::var_os(super::super::chief_target::APP_DAEMON_KEY)
        .filter(|value| !value.is_empty())
        .map(PathBuf::from);
    if named.is_some_and(|named| same_socket(&named, daemon_socket)) {
        return true;
    }
    #[cfg(unix)]
    if super::super::frontend_browser::app_daemon_is(daemon_socket) {
        return true;
    }
    false
}

/// Two spellings of one socket (a link, `/var` and `/private/var`).
fn same_socket(left: &Path, right: &Path) -> bool {
    let canonical =
        |path: &Path| cmux_blocking::fs::canonicalize(path).unwrap_or_else(|_| path.to_owned());
    left == right || canonical(left) == canonical(right)
}
