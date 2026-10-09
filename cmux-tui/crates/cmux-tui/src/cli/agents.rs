//! Agent-facing aliases over the existing cmux daemon and app control planes.
//!
//! The daemon remains the owner of workspaces, panes and tabs. The app remains
//! the owner of windows, palette state and dialogs. This module only composes
//! their existing snapshots and actions into one JSON-first surface for agents.

use std::time::Duration;

use cmux_tui_core::resource::{OperationClass, ResourceOperation};
use serde_json::{Map, Value, json};

use super::app::{self, ActionName};
use super::app_focus;
use super::command::{CommandPlan, RequestPlan, ResponseView, WireOperation};
use super::mcp;
use super::{GlobalArgs, Surface, UsageError, parse_globals, wire};

pub(super) const SNAPSHOT_TOOL: &str = "agents_snapshot";

const HELP: &str = "Usage: cmux agents <snapshot|workspace|tab|surface|palette|dialog>\n\nAgent-facing JSON surface. Mutations return the changed result and a fresh topology snapshot. Palette and dialogs are owned by the cmux app.\n\n  cmux agents snapshot\n  cmux agents workspace select <workspace-id>\n  cmux agents workspace create [--name <name>] [--empty]\n  cmux agents tab select <tab-id>\n  cmux agents surface focus <tab-id>\n  cmux agents surface split <left|right|up|down> [--surface <pane-id>]\n  cmux agents palette open\n  cmux agents dialog list [--all]\n  cmux agents dialog answer <request-id> --mode <mode>\n  cmux agents dialog answer <request-id> --selection <value>\n";

/// Handles the `agents` namespace before the normal daemon grammar.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command_args) = parse_globals(args).ok()?;
    if command_args.first().map(String::as_str) != Some("agents") {
        return None;
    }
    Some(run(global, &command_args[1..]))
}

fn run(global: GlobalArgs, args: &[String]) -> i32 {
    if is_help_request(args) {
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

fn is_help_request(args: &[String]) -> bool {
    args.first().is_none_or(|arg| matches!(arg.as_str(), "--help" | "-h"))
}

enum AgentCommand {
    Snapshot,
    Resource { action: String, args: Vec<String> },
    App { action: String, args: Vec<String> },
}

fn command(args: &[String]) -> Result<AgentCommand, UsageError> {
    let words = args.iter().map(String::as_str).collect::<Vec<_>>();
    match words.as_slice() {
        [family] if family == "snapshot" => Ok(AgentCommand::Snapshot),
        ["workspace", "select", target] => Ok(resource(
            "workspace.select",
            vec!["workspace".into(), (*target).into(), "focus".into()],
        )),
        ["workspace", "create", rest @ ..] => {
            let mut mapped = vec!["workspace".into(), "create".into()];
            mapped.extend(rest.iter().map(ToString::to_string));
            Ok(resource("workspace.create", mapped))
        }
        ["tab", "select", target] => {
            Ok(resource("tab.select", vec!["tab".into(), (*target).into(), "focus".into()]))
        }
        ["surface", "focus", target] => {
            Ok(resource("surface.focus", vec!["tab".into(), (*target).into(), "focus".into()]))
        }
        ["surface", "split", direction, rest @ ..]
            if matches!(*direction, "left" | "right" | "up" | "down") =>
        {
            let mut mapped = vec!["pane".into(), "current".into(), "split".into()];
            mapped.push(format!("--{direction}"));
            let mut surface = None;
            let mut index = 0;
            while index < rest.len() {
                if rest[index] == "--surface" {
                    let value = rest.get(index + 1).ok_or_else(|| {
                        UsageError::new("agents surface split: --surface needs a value")
                    })?;
                    surface = Some((*value).to_owned());
                    index += 2;
                } else {
                    return Err(UsageError::new(format!(
                        "agents surface split: unexpected argument {:?}",
                        rest[index]
                    )));
                }
            }
            if let Some(surface) = surface {
                mapped[1] = surface;
            }
            Ok(resource("surface.split", mapped))
        }
        ["palette", "open"] => {
            Ok(AgentCommand::App { action: "palette.open".into(), args: Vec::new() })
        }
        ["dialog", "list"] | ["dialog", "list", "--all"] => {
            Ok(AgentCommand::App {
                action: "dialog.list".into(),
                args: words[2..].iter().map(ToString::to_string).collect(),
            })
        }
        ["dialog", "answer", request_id, rest @ ..] => Ok(AgentCommand::App {
            action: "dialog.answer".into(),
            args: std::iter::once((*request_id).to_owned())
                .chain(rest.iter().map(ToString::to_string))
                .collect(),
        }),
        _ => Err(UsageError::new("unknown agents command; run `cmux agents --help`")),
    }
}

fn resource(action: &str, args: Vec<String>) -> AgentCommand {
    AgentCommand::Resource { action: action.into(), args }
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
    if value["sources"]["daemon"]["available"] == Value::Bool(false)
        && value["sources"]["app"]["available"] == Value::Bool(false)
    {
        return wire::print_local_error(
            &json!({
                "code": "agents.unavailable",
                "message": "neither the cmux app nor its session daemon answered",
                "details": value["sources"],
                "retryable": true,
            }),
            global.output,
            3,
        );
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
        "tab.select" | "surface.focus" => ResourceOperation::TabFocus,
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
    let mut selection = None;
    let mut index = 1;
    while index < args.len() {
        match args[index].as_str() {
            "--mode" => {
                mode = Some(
                    args.get(index + 1)
                        .ok_or_else(|| UsageError::new("--mode needs a value"))?
                        .clone(),
                )
            }
            "--selection" => {
                selection = Some(
                    args.get(index + 1)
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
    } else if let Some(selection) = selection {
        params.insert("selections".into(), json!([selection]));
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
    let daemon_value = daemon.clone().ok();
    let app_value = app.clone().ok();
    let daemon_error = daemon.err();
    let app_error = app.err();
    let topology = app_value.as_ref().and_then(|value| value.get("topology"));
    let mut snapshot = json!({
        "schema_version": 1,
        "windows": topology.and_then(|value| value.get("windows")).cloned().unwrap_or_else(|| json!([])),
        "workspaces": daemon_value.as_ref().and_then(|value| value.get("workspaces")).cloned().or_else(|| topology.and_then(|value| value.get("workspaces")).cloned()).unwrap_or_else(|| json!([])),
        "screens": daemon_value.as_ref().and_then(|value| value.get("screens")).cloned().unwrap_or_else(|| json!([])),
        "panes": daemon_value.as_ref().and_then(|value| value.get("panes")).cloned().unwrap_or_else(|| json!([])),
        "tabs": daemon_value.as_ref().and_then(|value| value.get("tabs")).cloned().unwrap_or_else(|| json!([])),
        "surfaces": daemon_value.as_ref().and_then(|value| value.get("surfaces")).cloned().or_else(|| daemon_value.as_ref().and_then(|value| value.get("tabs")).cloned()).unwrap_or_else(|| json!([])),
        "terminals": daemon_value.as_ref().and_then(|value| value.get("terminals")).cloned().unwrap_or_else(|| json!([])),
        "focus": topology.and_then(|value| value.get("focus")).cloned().or_else(|| daemon_value.as_ref().and_then(|value| value.get("focus")).cloned()).unwrap_or(Value::Null),
        "selection": selection(topology, daemon_value.as_ref()),
        "sources": {
            "daemon": {"available": daemon_value.is_some(), "error": daemon_error.unwrap_or(Value::Null)},
            "app": {"available": app_value.is_some(), "error": app_error.unwrap_or(Value::Null)},
        },
    });
    if let Some(value) = daemon_value {
        snapshot["daemon"] = value;
    }
    if let Some(value) = app_value {
        snapshot["app"] = value;
    }
    snapshot
}

fn selection(topology: Option<&Value>, daemon: Option<&Value>) -> Value {
    let focus = topology
        .and_then(|value| value.get("focus"))
        .or_else(|| daemon.and_then(|value| value.get("focus")));
    json!({
        "workspace": focus.and_then(|value| value.get("workspace")).cloned().unwrap_or(Value::Null),
        "pane": focus.and_then(|value| value.get("pane")).cloned().unwrap_or(Value::Null),
        "tab": focus.and_then(|value| value.get("tab")).cloned().unwrap_or(Value::Null),
        "surface": focus.and_then(|value| value.get("surface")).cloned().or_else(|| focus.and_then(|value| value.get("tab")).cloned()).unwrap_or(Value::Null),
    })
}

pub(super) fn snapshot_tool() -> Value {
    json!({
        "name": SNAPSHOT_TOOL,
        "title": "Agent topology snapshot",
        "description": "Read windows, workspaces, panes, tabs, focus and selection with stable public ids. Combines the app and session daemon snapshots.",
        "inputSchema": {"type": "object", "additionalProperties": false},
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
        assert_eq!(value["surfaces"][0]["id"], "tab_a");
        assert_eq!(value["selection"]["tab"], "tab_a");
        assert_eq!(value["selection"]["surface"], "tab_a");
        assert_eq!(value["sources"]["daemon"]["available"], true);
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
    fn aliases_map_to_existing_typed_operations() {
        let AgentCommand::Resource { action, args } = command(&[
            "surface".into(),
            "split".into(),
            "right".into(),
            "--surface".into(),
            "pane_a".into(),
        ])
        .unwrap() else {
            panic!("expected resource command")
        };
        assert_eq!(action, "surface.split");
        assert_eq!(args, vec!["pane", "pane_a", "split", "--right"]);
    }

    #[test]
    fn help_flags_inside_payloads_are_not_command_help() {
        assert!(!is_help_request(&[
            "dialog".into(),
            "answer".into(),
            "request_a".into(),
            "--selection".into(),
            "-h".into(),
        ]));
    }
}
