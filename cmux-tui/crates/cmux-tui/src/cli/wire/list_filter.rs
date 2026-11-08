//! Applies a list's `--name` and `--cwd` filters (command/list_filter.rs)
//! to the rows the daemon returned. `terminal list --cwd` and `--name`
//! read only those rows. A workspace or pane `--cwd` makes one more read
//! on the same connection, `session.snapshot`, and joins its terminals to
//! their tabs, panes and screens in memory: two requests whatever the
//! number of workspaces, never one per row.

use std::collections::{HashMap, HashSet};
use std::io::BufReader;

use cmux_tui_core::platform::transport;
use cmux_tui_core::resource::ResourceOperation;
use serde_json::Value;

use super::super::command::{ListFilter, RequestPlan, WireOperation};
use super::super::resolve::Failure;

/// `result` with only the rows `plan.filter` keeps; an error when the
/// snapshot a `--cwd` needs could not be read.
pub(super) fn apply(
    reader: &mut BufReader<Box<dyn transport::Stream>>,
    plan: &RequestPlan,
    result: Value,
) -> Result<Value, Value> {
    let filter = &plan.filter;
    if filter.is_empty() {
        return Ok(result);
    }
    let WireOperation::Typed(operation) = &plan.operation else { return Ok(result) };
    let Value::Array(rows) = result else { return Ok(result) };
    let scope = match *operation {
        ResourceOperation::WorkspaceList => Scope::Workspace,
        ResourceOperation::PaneList => Scope::Pane,
        ResourceOperation::TerminalList => Scope::Terminal,
        _ => return Ok(Value::Array(rows)),
    };
    let in_folder = match (&filter.cwd, scope) {
        (None, _) | (Some(_), Scope::Terminal) => None,
        (Some(cwd), scope) => {
            let route =
                plan.params.as_object().map(super::super::resolve::route).unwrap_or_default();
            let snapshot =
                super::super::resolve::read(reader, ResourceOperation::SessionSnapshot, route)
                    .map_err(snapshot_error)?;
            Some(ids_in_folder(&snapshot, scope, |folder| cwd.contains(folder)))
        }
    };
    Ok(Value::Array(
        rows.into_iter().filter(|row| keeps(filter, scope, in_folder.as_ref(), row)).collect(),
    ))
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Scope {
    Workspace,
    Pane,
    Terminal,
}

fn keeps(
    filter: &ListFilter,
    scope: Scope,
    in_folder: Option<&HashSet<String>>,
    row: &Value,
) -> bool {
    let text = |field: &str| row.get(field).and_then(Value::as_str);
    if !filter.name_matches(text("name")) {
        return false;
    }
    match (&filter.cwd, scope, in_folder) {
        (None, _, _) => true,
        (Some(cwd), Scope::Terminal, _) => text("cwd").is_some_and(|folder| cwd.contains(folder)),
        (Some(_), _, Some(ids)) => text("id").is_some_and(|id| ids.contains(id)),
        (Some(_), _, None) => false,
    }
}

/// The ids of the workspaces or panes (by `scope`) of `snapshot` that show
/// a terminal whose `cwd` passes `in_folder`.
fn ids_in_folder(
    snapshot: &Value,
    scope: Scope,
    in_folder: impl Fn(&str) -> bool,
) -> HashSet<String> {
    let rows =
        |key: &str| snapshot.get(key).and_then(Value::as_array).map(Vec::as_slice).unwrap_or(&[]);
    let text = |row: &Value, field: &str| row.get(field).and_then(Value::as_str).map(str::to_owned);
    let terminals: HashSet<String> = rows("terminals")
        .iter()
        .filter(|terminal| terminal.get("cwd").and_then(Value::as_str).is_some_and(&in_folder))
        .filter_map(|terminal| text(terminal, "id"))
        .collect();
    let panes: HashSet<String> = rows("tabs")
        .iter()
        .filter(|tab| tab.get("content_kind").and_then(Value::as_str) == Some("terminal"))
        .filter(|tab| text(tab, "content_id").is_some_and(|id| terminals.contains(&id)))
        .filter_map(|tab| text(tab, "pane_id"))
        .collect();
    if scope == Scope::Pane {
        return panes;
    }
    let screen_of: HashMap<String, String> = rows("panes")
        .iter()
        .filter_map(|pane| Some((text(pane, "id")?, text(pane, "screen_id")?)))
        .collect();
    let workspace_of: HashMap<String, String> = rows("screens")
        .iter()
        .filter_map(|screen| Some((text(screen, "id")?, text(screen, "workspace_id")?)))
        .collect();
    panes.iter().filter_map(|pane| workspace_of.get(screen_of.get(pane)?).cloned()).collect()
}

/// The error a `--cwd` list prints when its snapshot read failed.
fn snapshot_error(failure: Failure) -> Value {
    match failure {
        Failure::Resource(error) | Failure::Local { error, .. } => error,
        Failure::Transport(message) => serde_json::json!({
            "code": "session.unreachable",
            "message": format!(
                "--cwd needs the session's terminals and the read failed: {message}; \
                 run the list again, or without --cwd"
            ),
            "retryable": true,
        }),
        Failure::Refused | Failure::AppAction { .. } => serde_json::json!({
            "code": "session.busy",
            "message": "--cwd needs the session's terminals and the session refused the read; \
                        run the list again",
            "retryable": true,
        }),
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    fn snapshot() -> Value {
        json!({
            "screens": [
                {"id": "scr_a", "workspace_id": "ws_a"},
                {"id": "scr_b", "workspace_id": "ws_b"},
            ],
            "panes": [
                {"id": "pane_a", "screen_id": "scr_a"},
                {"id": "pane_b", "screen_id": "scr_b"},
            ],
            "tabs": [
                {"id": "tab_a", "pane_id": "pane_a", "content_kind": "terminal", "content_id": "term_a"},
                {"id": "tab_b", "pane_id": "pane_b", "content_kind": "terminal", "content_id": "term_b"},
                {"id": "tab_w", "pane_id": "pane_b", "content_kind": "browser", "content_id": "term_a"},
            ],
            "terminals": [
                {"id": "term_a", "cwd": "/work/app"},
                {"id": "term_b", "cwd": "/home"},
            ],
        })
    }

    #[test]
    fn a_workspace_or_pane_is_in_a_folder_when_one_of_its_terminals_is() {
        let under_work = |folder: &str| folder.starts_with("/work");
        let workspaces = ids_in_folder(&snapshot(), Scope::Workspace, under_work);
        assert_eq!(workspaces, HashSet::from(["ws_a".to_owned()]));
        let panes = ids_in_folder(&snapshot(), Scope::Pane, under_work);
        assert_eq!(panes, HashSet::from(["pane_a".to_owned()]));
        assert!(ids_in_folder(&snapshot(), Scope::Workspace, |_| false).is_empty());
    }
}
