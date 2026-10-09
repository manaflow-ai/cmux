//! Agent-facing aliases over the existing cmux daemon and app control planes.
//!
//! The daemon remains the owner of workspaces, panes and tabs. The app remains
//! the owner of windows, palette state and dialogs. This module only composes
//! their existing snapshots and actions into one JSON-first surface for agents.

use std::collections::HashSet;
use std::time::Duration;

use cmux_tui_core::resource::{OperationClass, ResourceOperation};
use serde_json::{Map, Value, json};

use super::app::{self, ActionName};
use super::app_focus;
use super::command::{CommandPlan, RequestPlan, ResponseView, WireOperation};
use super::mcp;
use super::{GlobalArgs, OutputMode, Surface, UsageError, parse_globals, wire};

pub(super) const SNAPSHOT_TOOL: &str = "agents_snapshot";
pub(super) const DEFAULT_SNAPSHOT_LIMIT: usize = 100;
pub(super) const MAX_SNAPSHOT_LIMIT: usize = 1_000;

const HELP: &str = "Usage: cmux agents <snapshot|workspace|tab|terminal|palette|dialog>\n\nAgent-facing JSON topology. Mutations return the changed result and a fresh topology snapshot. Palette and dialogs are owned by the cmux app.\n\n  cmux agents snapshot\n  cmux agents workspace select <workspace-id>\n  cmux agents workspace create [--name <name>] [--empty]\n  cmux agents tab select <tab-id>\n  cmux agents terminal focus <tab-id>\n  cmux agents terminal split <left|right|up|down> [--surface <pane-id>]\n  cmux agents palette open\n  cmux agents dialog list [--all]\n  cmux agents dialog answer <request-id> --mode <mode>\n  cmux agents dialog answer <request-id> --selection <value> [--selection <value> ...]\n";

/// Handles the `agents` namespace before the normal daemon grammar.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (mut global, command_args) = parse_globals(args).ok()?;
    if command_args.first().map(String::as_str) != Some("agents") {
        return None;
    }
    if global.output == OutputMode::Human {
        global.output = OutputMode::Json;
    }
    Some(run(global, &command_args[1..]))
}

fn run(global: GlobalArgs, args: &[String]) -> i32 {
    if args.is_empty() || args.iter().any(|arg| matches!(arg.as_str(), "--help" | "-h")) {
        println!("{HELP}");
        return 0;
    }
    match command(args) {
        Ok(AgentCommand::Snapshot) => run_snapshot(&global),
        Ok(AgentCommand::Resource { action, args }) => run_resource(&global, &action, &args),
        Ok(AgentCommand::App { action, args }) => run_app(&global, &action, &args),
        Err(error) => wire::print_local_error(
            &json!({
                "code": "usage.invalid",
                "message": format!("cmux: {error}"),
                "details": {},
                "retryable": false,
            }),
            global.output,
            2,
        ),
    }
}

enum AgentCommand {
    Snapshot,
    Resource { action: String, args: Vec<String> },
    App { action: String, args: Vec<String> },
}

fn command(args: &[String]) -> Result<AgentCommand, UsageError> {
    let words: Vec<&str> = args.iter().map(String::as_str).collect();
    match words.as_slice() {
        [family] if *family == "snapshot" => Ok(AgentCommand::Snapshot),
        ["workspace", "select", target] => Ok(resource(
            "workspace.select",
            vec!["workspace".into(), (*target).into(), "focus".into()],
        )),
        ["workspace", "create", rest @ ..] => {
            let mut mapped = vec!["workspace".into(), "create".into()];
            mapped.extend(rest.iter().map(|value| (*value).into()));
            Ok(resource("workspace.create", mapped))
        }
        ["tab", "select", target] => {
            Ok(resource("tab.select", scoped_resource_path("tab", target, "focus")))
        }
        ["terminal", "focus", target] => {
            Ok(resource("terminal.focus", scoped_resource_path("tab", target, "focus")))
        }
        ["terminal", "split", direction, rest @ ..]
            if matches!(*direction, "left" | "right" | "up" | "down") =>
        {
            let mut mapped = scoped_resource_path("pane", "current", "split");
            mapped.push(format!("--{direction}"));
            let mut pane = None;
            let mut index = 0;
            while index < rest.len() {
                if rest[index] == "--surface" {
                    let value = rest.get(index + 1).ok_or_else(|| {
                        UsageError::new("agents terminal split: --surface needs a value")
                    })?;
                    pane = Some((*value).into());
                    index += 2;
                } else {
                    return Err(UsageError::new(format!(
                        "agents terminal split: unexpected argument {:?}",
                        rest[index]
                    )));
                }
            }
            if let Some(pane) = pane {
                mapped = scoped_resource_path("pane", &pane, "split");
                mapped.push(format!("--{direction}"));
            }
            Ok(resource("terminal.split", mapped))
        }
        ["palette", "open"] => {
            Ok(AgentCommand::App { action: "palette.open".into(), args: Vec::new() })
        }
        ["dialog", "list"] | ["dialog", "list", "--all"] => Ok(AgentCommand::App {
            action: "dialog.list".into(),
            args: words[2..].iter().map(|value| (*value).into()).collect(),
        }),
        ["dialog", "answer", request_id, rest @ ..] => Ok(AgentCommand::App {
            action: "dialog.answer".into(),
            args: std::iter::once((*request_id).into())
                .chain(rest.iter().map(|value| (*value).into()))
                .collect(),
        }),
        _ => Err(UsageError::new(format!("unknown agents command; run `cmux agents --help`"))),
    }
}

fn resource(action: &str, args: Vec<String>) -> AgentCommand {
    AgentCommand::Resource { action: action.into(), args }
}

/// Keep non-id aliases on the same contiguous current route as the normal
/// CLI parser. Stable ids stay flat so an id from another workspace is not
/// constrained to the current workspace.
fn scoped_resource_path(scope: &str, target: &str, verb: &str) -> Vec<String> {
    let prefix = format!("{scope}_");
    let mut path = Vec::new();
    if !target.starts_with(&prefix) {
        path.extend(["workspace", "current", "screen", "current"].into_iter().map(str::to_owned));
        if scope == "tab" {
            path.extend(["pane", "current"].into_iter().map(str::to_owned));
        }
    }
    path.extend([scope, target, verb].into_iter().map(str::to_owned));
    path
}

/// The daemon request used by both the CLI and the special MCP snapshot tool.
pub(super) fn snapshot_plan() -> RequestPlan {
    RequestPlan {
        operation: WireOperation::Typed(ResourceOperation::SessionSnapshot),
        params: json!({"machine": "current", "session": "current"}),
        idempotency_key: None,
        stream: false,
        resolve: Vec::new(),
        view: ResponseView::Full,
    }
}

fn run_snapshot(global: &GlobalArgs) -> i32 {
    let daemon = mcp::agent_resource(global, snapshot_plan());
    let app = mcp::agent_app(global, "snapshot.get", json!({}), app::READ_TIMEOUT, None);
    let value = compose_snapshot(daemon, app);
    if let Some(error) = snapshot_error(&value) {
        return wire::print_local_error(&error, global.output, 3);
    }
    wire::print_local_success(&value, global.output)
}

fn run_resource(global: &GlobalArgs, action: &str, args: &[String]) -> i32 {
    let mut plan = match super::command::parse(args, Surface::CmuxTui) {
        Ok(CommandPlan::Protocol(plan)) => *plan,
        Ok(_) => {
            return print_usage(global, "agents resource command did not produce a daemon request");
        }
        Err(error) => return print_usage(global, &error.0),
    };
    if plan.operation.class() == OperationClass::Mutation {
        plan.idempotency_key = global.idempotency_key.clone();
    }
    let result = match mcp::agent_resource(global, plan) {
        Ok(result) => result,
        Err(error) => return wire::print_local_error(&error, global.output, 3),
    };
    let result = match follow_app_focus(global, action, result) {
        Ok(result) => result,
        Err(code) => return code,
    };
    let value = receipt(global, action, result);
    wire::print_local_success(&value, global.output)
}

fn follow_app_focus(global: &GlobalArgs, action: &str, result: Value) -> Result<Value, i32> {
    let operation = match action {
        "workspace.select" => ResourceOperation::WorkspaceFocus,
        "tab.select" | "terminal.focus" => ResourceOperation::TabFocus,
        _ => return Ok(result),
    };
    app_focus::after_daemon(global, operation, result)
        .map_err(|error| wire::print_local_error(&error, global.output, 3))
}

fn run_app(global: &GlobalArgs, action: &str, args: &[String]) -> i32 {
    let (method, params, timeout) = match action {
        "palette.open" => {
            let mut params = app::action_run_params("palette.open", ActionName::Any, "agents");
            params.insert("focus".into(), json!(true));
            ("action.run", Value::Object(params), app::WAITING_RUN_TIMEOUT)
        }
        "dialog.list" => {
            let pending_only = !args.iter().any(|arg| arg == "--all");
            ("feed.list", json!({"pending_only": pending_only}), app::READ_TIMEOUT)
        }
        "dialog.answer" => match dialog_answer(args) {
            Ok(value) => value,
            Err(error) => return print_usage(global, &error.0),
        },
        _ => return print_usage(global, "unknown app action"),
    };
    let result =
        match mcp::agent_app(global, method, params, timeout, global.idempotency_key.as_deref()) {
            Ok(result) => result,
            Err(error) => return wire::print_local_error(&error, global.output, 3),
        };
    let value = if action == "dialog.list" {
        json!({"schema_version": 1, "action": action, "result": result})
    } else {
        receipt(global, action, result)
    };
    wire::print_local_success(&value, global.output)
}

fn dialog_answer(args: &[String]) -> Result<(&'static str, Value, Duration), UsageError> {
    let request_id =
        args.first().ok_or_else(|| UsageError::new("dialog answer needs a request id"))?;
    let mut mode = None;
    let mut selections = Vec::new();
    let mut index = 1;
    while index < args.len() {
        match args[index].as_str() {
            "--mode" => {
                if mode.is_some() || !selections.is_empty() {
                    return Err(UsageError::new(
                        "dialog answer accepts one --mode or one or more --selection flags",
                    ));
                }
                mode = Some(
                    args.get(index + 1)
                        .filter(|value| !value.starts_with("--"))
                        .ok_or_else(|| UsageError::new("--mode needs a value"))?
                        .clone(),
                )
            }
            "--selection" => {
                if mode.is_some() {
                    return Err(UsageError::new(
                        "dialog answer cannot combine --mode with --selection",
                    ));
                }
                selections.push(
                    args.get(index + 1)
                        .filter(|value| !value.starts_with("--"))
                        .ok_or_else(|| UsageError::new("--selection needs a value"))?
                        .clone(),
                )
            }
            value => {
                return Err(UsageError::new(format!("unknown dialog answer argument {value:?}")));
            }
        }
        index += 2;
    }
    let mut params = Map::new();
    params.insert("request_id".into(), json!(request_id));
    let method = if let Some(mode) = mode {
        params.insert("mode".into(), json!(mode));
        "feed.permission.reply"
    } else if !selections.is_empty() {
        params.insert("selections".into(), json!(selections));
        "feed.question.reply"
    } else {
        return Err(UsageError::new("dialog answer needs --mode or --selection"));
    };
    Ok((method, Value::Object(params), app::WAITING_RUN_TIMEOUT))
}

fn receipt(global: &GlobalArgs, action: &str, result: Value) -> Value {
    let state = compose_snapshot(
        mcp::agent_resource(global, snapshot_plan()),
        mcp::agent_app(global, "snapshot.get", json!({}), app::READ_TIMEOUT, None),
    );
    json!({"schema_version": 1, "action": action, "result": result, "state": state})
}

fn print_usage(global: &GlobalArgs, message: &str) -> i32 {
    wire::print_local_error(
        &json!({"code":"usage.invalid","message":format!("cmux: {message}"),"details":{},"retryable":false}),
        global.output,
        2,
    )
}

/// Combines app windows/focus with daemon-owned resources without taking
/// ownership of either topology. Errors are retained so a partial snapshot is
/// actionable when one owner is temporarily unavailable.
pub(super) fn compose_snapshot(daemon: Result<Value, Value>, app: Result<Value, Value>) -> Value {
    let (daemon_value, daemon_error) = match daemon {
        Ok(value) => (Some(value), None),
        Err(error) => (None, Some(error)),
    };
    let (app_value, app_error) = match app {
        Ok(value) => (Some(value), None),
        Err(error) => (None, Some(error)),
    };
    let topology = app_value.as_ref().and_then(|value| value.get("topology"));
    let mut tabs = daemon_value
        .as_ref()
        .and_then(|value| value.get("tabs"))
        .cloned()
        .unwrap_or_else(|| json!([]));
    merge_app_tabs(&mut tabs, topology);
    let focus = topology
        .and_then(|value| value.get("focus"))
        .filter(|value| has_resource_focus(value))
        .cloned()
        .or_else(|| daemon_value.as_ref().and_then(|value| value.get("focus")).cloned())
        .unwrap_or(Value::Null);
    let mut snapshot = json!({
        "schema_version": 1,
        "windows": topology.and_then(|value| value.get("windows")).cloned().unwrap_or_else(|| json!([])),
        "workspaces": daemon_value.as_ref().and_then(|value| value.get("workspaces")).cloned().or_else(|| topology.and_then(|value| value.get("workspaces")).cloned()).unwrap_or_else(|| json!([])),
        "screens": daemon_value.as_ref().and_then(|value| value.get("screens")).cloned().unwrap_or_else(|| json!([])),
        "panes": daemon_value.as_ref().and_then(|value| value.get("panes")).cloned().unwrap_or_else(|| json!([])),
        "tabs": tabs,
        "terminals": daemon_value.as_ref().and_then(|value| value.get("terminals")).cloned().unwrap_or_else(|| json!([])),
        "browsers": daemon_value.as_ref().and_then(|value| value.get("browsers")).cloned().unwrap_or_else(|| json!([])),
        "focus": focus,
        "selection": selection(topology, daemon_value.as_ref()),
        "sources": {
            "daemon": {"available": daemon_value.is_some(), "error": daemon_error.unwrap_or(Value::Null)},
            "app": {"available": app_value.is_some(), "error": app_error.unwrap_or(Value::Null)},
        },
    });
    if let Some(shown) = topology
        .filter(|value| value.get("focus").is_some_and(has_resource_focus))
        .and_then(|value| value.get("focus"))
        .and_then(|value| value.get("workspace"))
        .and_then(Value::as_str)
    {
        app_focus::overlay_focused(&mut snapshot["workspaces"], shown);
    }
    snapshot
}

fn has_resource_focus(value: &Value) -> bool {
    ["workspace", "pane", "tab"].iter().any(|key| value.get(*key).and_then(Value::as_str).is_some())
}

fn merge_app_tabs(tabs: &mut Value, topology: Option<&Value>) {
    let Some(Value::Array(app_tabs)) = topology.map(collect_app_tabs) else { return };
    let Some(daemon_tabs) = tabs.as_array_mut() else {
        *tabs = Value::Array(app_tabs);
        return;
    };
    let mut ids = daemon_tabs
        .iter()
        .filter_map(|tab| tab.get("id").and_then(Value::as_str))
        .map(str::to_owned)
        .collect::<HashSet<_>>();
    for tab in app_tabs {
        let Some(id) = tab.get("id").and_then(Value::as_str) else { continue };
        if ids.insert(id.to_owned()) {
            daemon_tabs.push(tab);
        }
    }
}

fn collect_app_tabs(topology: &Value) -> Value {
    fn visit(value: &Value, out: &mut Vec<Value>, ids: &mut HashSet<String>) {
        match value {
            Value::Object(object) => {
                for (key, child) in object {
                    if key == "tabs" {
                        if let Value::Array(tabs) = child {
                            for tab in tabs {
                                if let Some(id) = tab.get("id").and_then(Value::as_str)
                                    && ids.insert(id.to_owned())
                                {
                                    out.push(tab.clone());
                                }
                            }
                        }
                    }
                    visit(child, out, ids);
                }
            }
            Value::Array(values) => values.iter().for_each(|value| visit(value, out, ids)),
            _ => {}
        }
    }

    let mut tabs = Vec::new();
    visit(topology, &mut tabs, &mut HashSet::new());
    Value::Array(tabs)
}

/// Page whole objects, never silently truncate relationship arrays inside an
/// object. MCP's shared size limiter can shrink `items` and advance the cursor.
pub(super) fn snapshot_page(mut snapshot: Value, offset: usize, limit: usize) -> Value {
    let mut items = Vec::new();
    let mut total = 0;
    for (collection, kind) in [
        ("windows", "window"),
        ("workspaces", "workspace"),
        ("screens", "screen"),
        ("panes", "pane"),
        ("tabs", "tab"),
        ("terminals", "terminal"),
        ("browsers", "browser"),
    ] {
        if let Some(Value::Array(values)) = snapshot.as_object_mut().unwrap().remove(collection) {
            for value in values {
                if total >= offset && items.len() < limit {
                    items.push(json!({"kind": kind, "value": value}));
                }
                total += 1;
            }
        }
    }
    let returned = items.len();
    let next = offset.saturating_add(returned);
    snapshot["items"] = Value::Array(items);
    snapshot["offset"] = json!(offset);
    snapshot["limit"] = json!(limit);
    snapshot["total"] = json!(total);
    snapshot["returned"] = json!(returned);
    snapshot["next_offset"] = if next < total { json!(next) } else { Value::Null };
    snapshot["truncated"] = json!(offset > 0 || next < total);
    snapshot
}

pub(super) fn snapshot_error(snapshot: &Value) -> Option<Value> {
    (snapshot["sources"]["daemon"]["available"] == false
        && snapshot["sources"]["app"]["available"] == false)
        .then(|| {
            json!({
                "code": "agents.unavailable",
                "message": "neither the cmux app nor its session daemon answered",
                "details": snapshot["sources"],
                "retryable": true,
            })
        })
}

fn selection(topology: Option<&Value>, daemon: Option<&Value>) -> Value {
    let focus = topology
        .and_then(|value| value.get("focus"))
        .filter(|value| has_resource_focus(value))
        .or_else(|| daemon.and_then(|value| value.get("focus")));
    json!({
        "workspace": focus.and_then(|value| value.get("workspace")).cloned().unwrap_or(Value::Null),
        "pane": focus.and_then(|value| value.get("pane")).cloned().unwrap_or(Value::Null),
        "tab": focus.and_then(|value| value.get("tab")).cloned().unwrap_or(Value::Null),
    })
}

pub(super) fn snapshot_tool() -> Value {
    json!({
        "name": SNAPSHOT_TOOL,
        "title": "Agent topology snapshot",
        "description": "Read topology as paged items with kind and value, plus focus, selection and source readiness. Follow next_offset until null to read all windows, workspaces, screens, panes, tabs, terminals and browsers. Pages are live reads; restart from offset 0 if topology changes.",
        "inputSchema": {
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "limit": {"type": "integer", "minimum": 1, "maximum": 1000, "default": 100},
                "offset": {"type": "integer", "minimum": 0, "default": 0}
            }
        },
        "annotations": {"readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false},
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn snapshot_keeps_stable_ids_and_selection() {
        let value = compose_snapshot(
            Ok(json!({"workspaces":[{"id":"ws_a"}],"tabs":[{"id":"tab_a"}]})),
            Ok(
                json!({"topology":{"windows":[{"id":"win_a"}],"focus":{"workspace":"ws_a","pane":"pane_a","tab":"tab_a"}}}),
            ),
        );
        assert_eq!(value["windows"][0]["id"], "win_a");
        assert_eq!(value["workspaces"][0]["id"], "ws_a");
        assert_eq!(value["selection"]["tab"], "tab_a");
        assert_eq!(value["sources"]["daemon"]["available"], true);
    }

    #[test]
    fn snapshot_merges_nested_app_page_tabs_without_duplicates() {
        let value = compose_snapshot(
            Ok(json!({"tabs":[{"id":"tab_a"}]})),
            Ok(json!({
                "topology": {
                    "windows": [{
                        "workspaces": [{
                            "tabs": [{"id":"page_settings","kind":"page"},{"id":"tab_a"}]
                        }]
                    }]
                }
            })),
        );
        let tabs = value["tabs"].as_array().unwrap();
        assert_eq!(tabs.iter().filter(|tab| tab["id"] == "tab_a").count(), 1);
        assert_eq!(tabs.iter().filter(|tab| tab["id"] == "page_settings").count(), 1);
    }

    #[test]
    fn snapshot_retains_owner_failures_for_partial_readiness() {
        let value = compose_snapshot(
            Err(json!({"code":"transport.unavailable"})),
            Ok(json!({"topology":{"windows":[]}})),
        );
        assert_eq!(value["sources"]["daemon"]["available"], false);
        assert_eq!(value["sources"]["app"]["available"], true);
        assert_eq!(value["sources"]["daemon"]["error"]["code"], "transport.unavailable");
    }

    #[test]
    fn agents_snapshot_page_preserves_complete_objects_and_continues() {
        let value = compose_snapshot(
            Ok(json!({"workspaces": [{"id": "ws_a"}, {"id": "ws_b"}]})),
            Ok(json!({"topology": {"windows": [{"workspaces": ["ws_a", "ws_b"]}]}})),
        );
        let first = snapshot_page(value.clone(), 0, 1);
        assert_eq!(first["items"][0]["kind"], "window");
        assert_eq!(first["items"][0]["value"]["workspaces"], json!(["ws_a", "ws_b"]));
        assert_eq!(first["next_offset"], 1);
        let last = snapshot_page(value, 1, 10);
        assert_eq!(last["items"].as_array().unwrap().len(), 2);
        assert_eq!(last["items"][0]["value"]["id"], "ws_a");
        assert_eq!(last["items"][1]["value"]["id"], "ws_b");
        assert_eq!(last["next_offset"], Value::Null);
    }

    #[test]
    fn snapshot_uses_app_workspace_focus_when_both_owners_disagree() {
        let value = compose_snapshot(
            Ok(json!({
                "workspaces": [
                    {"id": "ws_a", "focused": true},
                    {"id": "ws_b", "focused": false}
                ]
            })),
            Ok(json!({"topology": {"focus": {"workspace": "ws_b"}}})),
        );
        assert_eq!(value["workspaces"][0]["focused"], false);
        assert_eq!(value["workspaces"][1]["focused"], true);
    }

    #[test]
    fn snapshot_falls_back_to_daemon_focus_when_app_has_no_active_resource() {
        let value = compose_snapshot(
            Ok(json!({"focus":{"workspace":"ws_daemon","tab":"tab_daemon"}})),
            Ok(json!({"topology":{"focus":{"workspace":null,"pane":null,"tab":null}}})),
        );
        assert_eq!(value["focus"]["workspace"], "ws_daemon");
        assert_eq!(value["selection"]["tab"], "tab_daemon");
    }

    #[test]
    fn aliases_scope_current_targets_before_resource_actions() {
        let AgentCommand::Resource { args, .. } =
            command(&["terminal".into(), "split".into(), "right".into()]).unwrap()
        else {
            panic!("expected resource command")
        };
        assert_eq!(
            args,
            vec![
                "workspace",
                "current",
                "screen",
                "current",
                "pane",
                "current",
                "split",
                "--right"
            ]
        );

        let AgentCommand::Resource { args, .. } =
            command(&["tab".into(), "select".into(), "current".into()]).unwrap()
        else {
            panic!("expected resource command")
        };
        assert_eq!(
            args,
            vec![
                "workspace",
                "current",
                "screen",
                "current",
                "pane",
                "current",
                "tab",
                "current",
                "focus"
            ]
        );
    }

    #[test]
    fn aliases_map_to_existing_typed_operations() {
        let AgentCommand::Resource { action, args } = command(&[
            "terminal".into(),
            "split".into(),
            "right".into(),
            "--surface".into(),
            "pane_a".into(),
        ])
        .unwrap() else {
            panic!("expected resource command")
        };
        assert_eq!(action, "terminal.split");
        assert_eq!(args, vec!["pane", "pane_a", "split", "--right"]);
    }

    #[test]
    fn dialog_answers_preserve_multiple_selections_and_reject_mixed_modes() {
        let AgentCommand::App { action, args } = command(&[
            "dialog".into(),
            "answer".into(),
            "request_a".into(),
            "--selection".into(),
            "one".into(),
            "--selection".into(),
            "two".into(),
        ])
        .unwrap() else {
            panic!("expected app command")
        };
        assert_eq!(action, "dialog.answer");
        assert_eq!(args, vec!["request_a", "--selection", "one", "--selection", "two"]);
        assert!(
            command(&[
                "dialog".into(),
                "answer".into(),
                "request_a".into(),
                "--mode".into(),
                "permission".into(),
                "--selection".into(),
                "one".into(),
            ])
            .is_ok()
        );
        assert!(
            dialog_answer(&[
                "request_a".into(),
                "--mode".into(),
                "permission".into(),
                "--selection".into(),
                "one".into(),
            ])
            .is_err()
        );
        let (_, params, _) = dialog_answer(&[
            "request_a".into(),
            "--selection".into(),
            "one".into(),
            "--selection".into(),
            "two".into(),
        ])
        .unwrap();
        assert_eq!(params["selections"], json!(["one", "two"]));
    }
}
