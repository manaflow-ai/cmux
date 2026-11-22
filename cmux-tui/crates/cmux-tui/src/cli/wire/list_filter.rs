//! Applies a list's `--name`, `--cwd` and `--id` filters and `--tree`
//! (command/list_filter.rs) to the rows the daemon returned. `terminal list
//! --cwd` and `--name` read only those rows. A workspace or pane `--cwd`, and
//! `workspace list --tree`, make one more read on the same connection,
//! `session.snapshot`, and join its terminals to their tabs, panes and
//! screens in memory: two requests whatever the number of workspaces, never
//! one per row.

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
    let result = by_creator(filter, result);
    let Value::Array(rows) = result else { return Ok(result) };
    let Some(scope) = scope_of(*operation) else { return Ok(Value::Array(rows)) };
    let folder_filter = filter.cwd.is_some() && scope != Scope::Terminal;
    let tree = filter.tree && scope == Scope::Workspace;
    let snapshot = if folder_filter || tree {
        let route = plan.params.as_object().map(super::super::resolve::route).unwrap_or_default();
        Some(
            super::super::resolve::read(reader, ResourceOperation::SessionSnapshot, route)
                .map_err(snapshot_error)?,
        )
    } else {
        None
    };
    let in_folder = match (&filter.cwd, &snapshot) {
        (Some(cwd), Some(snapshot)) if folder_filter => {
            Some(ids_in_folder(snapshot, scope, |folder| cwd.contains(folder)))
        }
        _ => None,
    };
    let kept = rows.into_iter().filter(|row| keeps(filter, scope, in_folder.as_ref(), row));
    match snapshot.filter(|_| tree) {
        Some(snapshot) => Ok(with_trees(&snapshot, kept.collect())),
        None => Ok(Value::Array(kept.collect())),
    }
}

/// `result` with only the rows `plan.filter` keeps, for rows that did not
/// come from this session (the app's Cloud machine workspaces): `--name`
/// filters them, and a workspace or pane `--cwd`, which needs the session's
/// terminals, is refused rather than ignored.
pub(super) fn apply_listed(plan: &RequestPlan, result: Value) -> Result<Value, Value> {
    let WireOperation::Typed(operation) = &plan.operation else { return Ok(result) };
    let result = by_creator(&plan.filter, result);
    let Some(scope) = scope_of(*operation) else { return Ok(result) };
    listed(&plan.filter, scope, result)
}

/// The rows `--created-by` keeps: a space carries `created_by`, a workspace and a tab
/// `extra.created_by`.
fn by_creator(filter: &ListFilter, result: Value) -> Value {
    let Some(wanted) = &filter.created_by else { return result };
    let Value::Array(rows) = result else { return result };
    Value::Array(
        rows.into_iter()
            .filter(|row| {
                wanted.keeps(row.get("created_by").or_else(|| row["extra"].get("created_by")))
            })
            .collect(),
    )
}

fn listed(filter: &ListFilter, scope: Scope, result: Value) -> Result<Value, Value> {
    if filter.is_empty() {
        return Ok(result);
    }
    if filter.tree && scope == Scope::Workspace {
        return Err(serde_json::json!({
            "code": "validation.invalid",
            "message": "--tree needs the session's panes and tabs, and a Cloud machine's \
                        workspaces come from the app without them; drop --tree, or list the \
                        machine's terminals with `cmux --machine <machine> terminal list`",
            "retryable": false,
        }));
    }
    if filter.cwd.is_some() && scope != Scope::Terminal {
        return Err(serde_json::json!({
            "code": "validation.invalid",
            "message": "--cwd needs the session's terminals, and a Cloud machine's workspaces \
                        come from the app without them; filter with --name, or list the \
                        machine's terminals with `cmux --machine <machine> terminal list --cwd <path>`",
            "retryable": false,
        }));
    }
    let Value::Array(rows) = result else { return Ok(result) };
    Ok(Value::Array(rows.into_iter().filter(|row| keeps(filter, scope, None, row)).collect()))
}

fn scope_of(operation: ResourceOperation) -> Option<Scope> {
    match operation {
        ResourceOperation::WorkspaceList => Some(Scope::Workspace),
        ResourceOperation::PaneList => Some(Scope::Pane),
        ResourceOperation::TerminalList => Some(Scope::Terminal),
        _ => None,
    }
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
    if !filter.name_matches(text("name")) || !filter.id_matches(text("id")) {
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

/// `workspace list --tree`: each of this session's `rows` with `panes` (in
/// order, each with its `tabs` in order; a terminal tab with its `cwd`) and
/// `created_by` lifted from `extra`. A row the snapshot has no screen for (a
/// Cloud machine's, merged from the app) stays as it is.
fn with_trees(snapshot: &Value, rows: Vec<Value>) -> Value {
    let list =
        |key: &str| snapshot.get(key).and_then(Value::as_array).map(Vec::as_slice).unwrap_or(&[]);
    let text = |row: &Value, field: &str| row.get(field).and_then(Value::as_str).map(str::to_owned);
    let index = |row: &Value| row.get("index").and_then(Value::as_u64).unwrap_or(u64::MAX);
    let folder: HashMap<String, Value> = list("terminals")
        .iter()
        .filter_map(|terminal| Some((text(terminal, "id")?, terminal.get("cwd")?.clone())))
        .collect();
    let workspace_of: HashMap<String, String> = list("screens")
        .iter()
        .filter_map(|screen| Some((text(screen, "id")?, text(screen, "workspace_id")?)))
        .collect();
    let mut tabs_of: HashMap<String, Vec<&Value>> = HashMap::new();
    for tab in list("tabs") {
        if let Some(pane) = text(tab, "pane_id") {
            tabs_of.entry(pane).or_default().push(tab);
        }
    }
    let mut panes_of: HashMap<String, Vec<&Value>> = HashMap::new();
    for pane in list("panes") {
        if let Some(workspace) = text(pane, "screen_id").and_then(|s| workspace_of.get(&s).cloned())
        {
            panes_of.entry(workspace).or_default().push(pane);
        }
    }
    let tab_view = |tab: &Value| {
        let mut view = serde_json::Map::new();
        for field in ["id", "name", "focused", "content_kind", "content_id"] {
            if let Some(value) = tab.get(field) {
                view.insert(field.into(), value.clone());
            }
        }
        if tab.get("content_kind").and_then(Value::as_str) == Some("terminal")
            && let Some(cwd) = text(tab, "content_id").and_then(|id| folder.get(&id))
        {
            view.insert("cwd".into(), cwd.clone());
        }
        Value::Object(view)
    };
    let pane_view = |pane: &Value| {
        let mut view = serde_json::Map::new();
        for field in ["id", "name", "focused", "screen_id"] {
            if let Some(value) = pane.get(field) {
                view.insert(field.into(), value.clone());
            }
        }
        let mut tabs =
            text(pane, "id").and_then(|id| tabs_of.get(&id)).cloned().unwrap_or_default();
        tabs.sort_by_key(|tab| index(tab));
        view.insert("tabs".into(), Value::Array(tabs.into_iter().map(tab_view).collect()));
        Value::Object(view)
    };
    let seen: HashSet<&String> = workspace_of.values().collect();
    Value::Array(
        rows.into_iter()
            .map(|mut row| {
                let Some(id) = text(&row, "id").filter(|id| seen.contains(id)) else {
                    return row;
                };
                let mut panes = panes_of.get(&id).cloned().unwrap_or_default();
                panes.sort_by_key(|pane| index(pane));
                let created_by = row.pointer("/extra/created_by").cloned();
                if let Some(object) = row.as_object_mut() {
                    object.insert("created_by".into(), created_by.unwrap_or(Value::Null));
                    object.insert(
                        "panes".into(),
                        Value::Array(panes.into_iter().map(pane_view).collect()),
                    );
                }
                row
            })
            .collect(),
    )
}

/// The human table of `workspace list --tree`: one row per tab, with its
/// workspace, creator and pane, so the whole tree reads as one table.
pub(super) fn tree_human_rows(rows: &[Value]) -> Value {
    let text = |row: &Value, field: &str| {
        row.get(field).and_then(Value::as_str).unwrap_or_default().to_owned()
    };
    let creator = |row: &Value| match row.get("created_by") {
        Some(Value::Object(by)) => {
            let kind = by.get("kind").and_then(Value::as_str).unwrap_or("?");
            match by.get("session").and_then(Value::as_str) {
                Some(session) => format!("{kind} {session}"),
                None => kind.to_owned(),
            }
        }
        _ => String::new(),
    };
    let mut out = Vec::new();
    for workspace in rows {
        let panes = workspace.get("panes").and_then(Value::as_array).cloned().unwrap_or_default();
        let base = serde_json::json!({
            "workspace": text(workspace, "id"),
            "workspace_name": text(workspace, "name"),
            "created_by": creator(workspace),
        });
        let mut wrote = false;
        for pane in &panes {
            for tab in pane.get("tabs").and_then(Value::as_array).into_iter().flatten() {
                let mut row = base.clone();
                if let Some(object) = row.as_object_mut() {
                    object.insert("pane".into(), Value::String(text(pane, "id")));
                    object.insert("tab".into(), Value::String(text(tab, "id")));
                    object.insert("kind".into(), Value::String(text(tab, "content_kind")));
                    object.insert("tab_name".into(), Value::String(text(tab, "name")));
                    object.insert("cwd".into(), Value::String(text(tab, "cwd")));
                }
                out.push(row);
                wrote = true;
            }
        }
        if !wrote {
            out.push(base);
        }
    }
    Value::Array(out)
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
#[path = "list_filter_tests.rs"]
mod tests;
