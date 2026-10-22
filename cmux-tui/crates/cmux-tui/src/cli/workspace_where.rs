//! `cmux workspace where`: the caller's workspace and the personal sidebar
//! group that holds it. Agents ask it before they file a new workspace, so
//! the new one joins the caller's group instead of a new group of one name.
//!
//! The caller is, in order: the terminal the CLI runs in
//! (`CMUX_TUI_TERMINAL_ID`), the workspace an agent chat runs in
//! (`CMUX_WORKSPACE_ID`, the workspace key), else the session's `current`
//! workspace. `source` names which one answered.

use std::io::BufReader;
use std::time::Duration;

use cmux_tui_core::resource::ResourceOperation;
use serde_json::{Map, Value, json};

use super::resolve::{Failure, caller_workspace, read};
use super::{GlobalArgs, OutputMode};

type Reader = BufReader<Box<dyn cmux_tui_core::platform::transport::Stream>>;

const READ_TIMEOUT: Duration = Duration::from_secs(30);

/// Runs `workspace where` and prints the answer; returns the exit code.
pub(super) fn run(global: &GlobalArgs) -> i32 {
    match answer(global) {
        Ok(value) => match global.output {
            OutputMode::Quiet => 0,
            OutputMode::Human => {
                println!("{}", human(&value));
                0
            }
            _ => {
                println!("{value}");
                0
            }
        },
        Err(failure) => failure.report(global.output),
    }
}

fn answer(global: &GlobalArgs) -> Result<Value, Failure> {
    let (socket, derived) =
        super::wire::resolve_socket_with_origin(global).map_err(|error| Failure::Local {
            error: super::wire::resolve_failure(&error),
            exit: super::wire::RESOLVE_FAILURE_EXIT,
        })?;
    let stream =
        cmux_tui_core::server::connect_session_socket(&socket, derived).map_err(|error| {
            Failure::Transport(format!(
                "cannot connect to session socket {}: {error}",
                socket.display()
            ))
        })?;
    let _ = stream.set_read_timeout(Some(READ_TIMEOUT));
    let mut reader: Reader = BufReader::new(stream);
    let mut route = Map::new();
    route.insert("machine".into(), json!(global.machine.as_deref().unwrap_or("current")));
    route.insert("session".into(), json!(global.session.as_deref().unwrap_or("current")));
    // An explicit --socket or --session names another session: its current
    // workspace, never the caller's.
    let caller_route = global.socket.is_none() && global.session.is_none();
    let (workspace, source) = caller(&mut reader, &route, caller_route)?;
    let mut params = route.clone();
    params.insert("workspace".into(), Value::String(workspace));
    let snapshot = read(&mut reader, ResourceOperation::WorkspaceGet, params)?;
    let placements = read(&mut reader, ResourceOperation::WorkspacePlacementList, route.clone())?;
    let groups = read(&mut reader, ResourceOperation::WorkspaceGroupList, route)?;
    Ok(location(&snapshot, &placements, &groups, source))
}

/// The caller's workspace selector and which source named it.
fn caller(
    reader: &mut Reader,
    route: &Map<String, Value>,
    caller_route: bool,
) -> Result<(String, &'static str), Failure> {
    if caller_route {
        if let Some(terminal) = env_value("CMUX_TUI_TERMINAL_ID") {
            return Ok((caller_workspace(reader, route, &terminal)?, "terminal"));
        }
        if let Some(key) = env_value("CMUX_WORKSPACE_ID") {
            let workspaces = read(reader, ResourceOperation::WorkspaceList, route.clone())?;
            if let Some(id) = workspace_with_key(&workspaces, &key) {
                return Ok((id, "agent_chat"));
            }
        }
    }
    Ok(("current".into(), "current"))
}

fn env_value(name: &str) -> Option<String> {
    std::env::var(name).ok().filter(|value| !value.trim().is_empty())
}

/// The id of the workspace whose key (`extra.key`) or id is `key`.
fn workspace_with_key(workspaces: &Value, key: &str) -> Option<String> {
    workspaces.as_array()?.iter().find_map(|workspace| {
        let id = workspace.get("id").and_then(Value::as_str)?;
        let keyed = workspace.pointer("/extra/key").and_then(Value::as_str) == Some(key);
        (keyed || id == key).then(|| id.to_owned())
    })
}

/// The answer: the workspace (id, name, key), its group (id and name, or
/// null), its room and the source that named the caller.
pub(super) fn location(
    workspace: &Value,
    placements: &Value,
    groups: &Value,
    source: &str,
) -> Value {
    let id = workspace.get("id").and_then(Value::as_str).unwrap_or_default();
    let placement = placements.as_array().and_then(|rows| {
        rows.iter()
            .find(|row| row.pointer("/workspace/workspace_id").and_then(Value::as_str) == Some(id))
    });
    let group_id = placement.and_then(|row| row.get("group_id")).and_then(Value::as_str);
    let group = group_id
        .and_then(|group_id| {
            groups.as_array()?.iter().find(|group| group["id"].as_str() == Some(group_id))
        })
        .map_or(Value::Null, |group| json!({"id": group["id"], "name": group["name"]}));
    json!({
        "workspace": {
            "id": id,
            "name": workspace.get("name").cloned().unwrap_or(Value::Null),
            "key": workspace.pointer("/extra/key").cloned().unwrap_or(Value::Null),
        },
        "group": group,
        "room_id": placement.and_then(|row| row.get("room_id")).cloned().unwrap_or(Value::Null),
        "source": source,
    })
}

fn human(value: &Value) -> String {
    let workspace = &value["workspace"];
    let group = match value["group"]["name"].as_str() {
        Some(name) => format!("{name} ({})", value["group"]["id"].as_str().unwrap_or_default()),
        None => "none".into(),
    };
    format!(
        "workspace: {} ({})\ngroup: {group}",
        workspace["name"].as_str().unwrap_or_default(),
        workspace["id"].as_str().unwrap_or_default()
    )
}

#[cfg(test)]
mod tests;
