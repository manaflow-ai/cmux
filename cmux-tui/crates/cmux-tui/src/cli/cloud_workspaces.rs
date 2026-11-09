//! `workspace list` (the CLI and MCP `workspace_list`) also lists the
//! workspaces on the cmux Cloud machines the app is connected to.
//!
//! The local daemon answers `workspace.list` with its own session's
//! workspaces. A Cloud workspace lives in the Cloud machine's daemon, which
//! only the app is connected to (`services.machines`), and the local daemon
//! cannot route a read there (`--machine vm-…` was `selector.not_found`). So
//! a workspace `cmux cloud new-workspace` had just opened was in no list an
//! agent reads (Leo, 2026-11-02: "chief will be using this kind of flow").
//!
//! After the daemon answers, the app's `cloud.machines` (a main-actor read of
//! its stores, no network) adds one row per Cloud workspace, marked with its
//! machine: `machine_id` (the Cloud id `cloud new-workspace` answers),
//! `machine_name`, `target: machine:<id>` and `origin: "cloud"`, its
//! `workspace_id` (the durable id `cloud new-workspace` answers) and, on
//! registry daemons, its `ws_…` id as `id`. Machines made from one image can
//! list the same workspace ids, so a Cloud row is named by `machine_id` and
//! `id` together.
//!
//! `--machine <vm-…|machine:vm-…|title>` (MCP: `machine`) lists one Cloud
//! machine's workspaces. Reading the app fails open: with no app, or Cloud
//! off, the daemon's list stands alone.

use serde_json::{Map, Value, json};

/// Every Cloud workspace in the app's `cloud.machines` rows, as
/// `workspace list` rows.
pub(super) fn rows(machines: &[Value]) -> Vec<Value> {
    machines.iter().flat_map(machine_rows).collect()
}

/// One Cloud machine's workspaces as `workspace list` rows.
pub(super) fn machine_rows(machine: &Value) -> Vec<Value> {
    let Some(machine_id) = machine.get("id").and_then(Value::as_str).filter(|id| !id.is_empty())
    else {
        return Vec::new();
    };
    let text = |key: &str| machine.get(key).and_then(Value::as_str).filter(|text| !text.is_empty());
    let machine_name = text("title").unwrap_or(machine_id);
    let workspaces = machine.get("workspaces").and_then(Value::as_array);
    workspaces
        .into_iter()
        .flatten()
        .filter_map(|workspace| {
            let key = workspace.get("id").and_then(Value::as_str).filter(|id| !id.is_empty())?;
            let resource =
                workspace.get("resource_id").and_then(Value::as_str).filter(|id| !id.is_empty());
            let mut row = Map::new();
            row.insert("id".into(), json!(resource.unwrap_or(key)));
            row.insert("workspace_id".into(), json!(key));
            row.insert(
                "name".into(),
                workspace.get("name").filter(|name| name.is_string()).cloned().unwrap_or(json!("")),
            );
            row.insert("machine_id".into(), json!(machine_id));
            row.insert("machine_name".into(), json!(machine_name));
            row.insert("target".into(), json!(format!("machine:{machine_id}")));
            row.insert("origin".into(), json!("cloud"));
            if let Some(daemon) = text("daemon") {
                row.insert("daemon".into(), json!(daemon));
            }
            Some(Value::Object(row))
        })
        .collect()
}

/// The Cloud machine `selector` names: its Cloud id (`vm-…`), its target
/// (`machine:vm-…`) or its exact title. `Ok(None)`: no Cloud machine has it.
/// A title two machines share is ambiguous: name the machine by its id.
pub(super) fn find<'a>(machines: &'a [Value], selector: &str) -> Result<Option<&'a Value>, Value> {
    // `name:` is the CLI's escape for a name that is no plain selector (`build_box`).
    let selector = selector.strip_prefix("name:").unwrap_or(selector);
    let id = selector.strip_prefix("machine:").unwrap_or(selector);
    if let Some(machine) =
        machines.iter().find(|machine| machine.get("id").and_then(Value::as_str) == Some(id))
    {
        return Ok(Some(machine));
    }
    let titled = machines
        .iter()
        .filter(|machine| machine.get("title").and_then(Value::as_str) == Some(selector))
        .collect::<Vec<_>>();
    match titled.as_slice() {
        [] => Ok(None),
        [machine] => Ok(Some(machine)),
        several => Err(json!({
            "code": "selector.ambiguous",
            "message": format!("more than one Cloud machine is named {selector:?}; use its id"),
            "details": {
                "scope": "machine",
                "candidates": several.iter().filter_map(|machine| machine.get("id")).collect::<Vec<_>>(),
            },
            "retryable": false,
        })),
    }
}

/// `result` (the daemon's rows: an array, or `{"items": [...]}`) with
/// `rows` appended.
pub(super) fn append(mut result: Value, rows: Vec<Value>) -> Value {
    if rows.is_empty() {
        return result;
    }
    match &mut result {
        Value::Array(listed) => listed.extend(rows),
        Value::Object(object) => {
            if let Some(Value::Array(listed)) = object.get_mut("items") {
                listed.extend(rows);
            }
        }
        _ => {}
    }
    result
}

/// The app's `cloud.machines` rows from a reply, `None` when it has none
/// (an older app, a refusal).
pub(super) fn machines_of(reply: &Value) -> Option<Vec<Value>> {
    reply.get("machines").and_then(Value::as_array).cloned()
}

/// The CLI's best-effort read of the app's Cloud machines: `None` with no
/// app, an explicit daemon route the app does not own, or a failed read.
fn read(global: &super::GlobalArgs) -> Option<Vec<Value>> {
    if global.app_socket.is_none() && !super::cloud_machines::app_found() {
        return None;
    }
    let socket = super::app::socket_path(global).ok()?;
    super::cloud_machines::read_by_deadline(socket).ok()
}

/// Whether a `workspace list` result takes the Cloud rows: the session the
/// app owns (no `--machine`, no `--session`, no `--socket`).
fn joins(global: &super::GlobalArgs) -> bool {
    global.machine.is_none() && global.session.is_none() && global.socket.is_none()
}

/// The daemon's `workspace list` with the app's Cloud workspaces appended.
pub(super) fn merge(global: &super::GlobalArgs, result: Value) -> Value {
    if !joins(global) {
        return result;
    }
    match read(global) {
        Some(machines) => append(result, rows(&machines)),
        None => result,
    }
}

/// `--machine <Cloud machine> workspace list`: the local daemon has no such
/// machine (`selector.not_found`, or `validation.invalid` for a title such as
/// `build_box`), so the app's rows for it answer. `None` for a machine the
/// app does not have, whose daemon error then stands.
pub(super) fn for_machine(
    global: &super::GlobalArgs,
    plan: &super::command::RequestPlan,
    error: &Value,
) -> Option<Result<Value, Value>> {
    use super::command::WireOperation;
    use cmux_tui_core::resource::ResourceOperation;
    if !matches!(plan.operation, WireOperation::Typed(ResourceOperation::WorkspaceList))
        || !matches!(error["code"].as_str(), Some("selector.not_found" | "validation.invalid"))
    {
        return None;
    }
    let selector = global.machine.as_deref()?;
    let machines = read(global)?;
    match find(&machines, selector) {
        Ok(Some(machine)) => Some(Ok(Value::Array(machine_rows(machine)))),
        Ok(None) => None,
        Err(ambiguous) => Some(Err(ambiguous)),
    }
}

#[cfg(test)]
mod tests;
