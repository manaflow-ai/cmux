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
use super::command::{CommandPlan, RequestPlan, Resolve, ResponseView, WireOperation};
use super::mcp::{self, Backend, CallFailure, FailureKind};
use super::{GlobalArgs, OutputMode, Surface, UsageError, parse_globals, wire};

pub(super) const SNAPSHOT_TOOL: &str = "agents_snapshot";
pub(super) const DEFAULT_SNAPSHOT_LIMIT: usize = 100;
pub(super) const MAX_SNAPSHOT_LIMIT: usize = 1_000;

mod events;
mod wait;

pub(super) use events::{
    DEFAULT_LIMIT as DEFAULT_EVENTS_LIMIT, DEFAULT_TIMEOUT_SECONDS as DEFAULT_EVENTS_SECONDS,
    KINDS as EVENT_KINDS, MAX_LIMIT as MAX_EVENTS_LIMIT, MAX_TIMEOUT_SECONDS as MAX_EVENTS_SECONDS,
};
pub(super) use wait::{
    DEFAULT_TIMEOUT_SECONDS as DEFAULT_WAIT_SECONDS, MAX_TIMEOUT_SECONDS as MAX_WAIT_SECONDS,
};

const HELP: &str = "Usage: cmux agents <snapshot|workspace|tab|terminal|palette|dialog|chat|wait|events|doctor>\n\nAgent-facing JSON topology. Mutations return the changed result and a fresh topology snapshot. Palette and dialogs are owned by the cmux app.\n\n  cmux agents snapshot\n  cmux agents workspace select <workspace-id>\n  cmux agents workspace create [--name <name>] [--empty]\n  cmux agents tab select <tab-id>\n  cmux agents terminal focus <tab-id>\n  cmux agents terminal split <left|right|up|down> [--surface <pane-id>]\n  cmux agents palette open\n  cmux agents dialog list [--all]\n  cmux agents dialog answer <request-id> --mode <mode>\n  cmux agents dialog answer <request-id> --selection <value> [--selection <value> ...]\n  cmux agents chat new [--workspace <ws>|--pane <pane>] [--harness <h>] [--model <m>] [--effort <e>] [--mode <m>] [--policy <p>] [--cwd <dir>] [--name <n>] [--] [<prompt>]\n  cmux agents chat send <chat> [--] <text>\n  cmux agents chat read <chat> [--after <item-id>] [--limit <n>]\n  cmux agents chat state <chat>\n  cmux agents chat interrupt <chat>\n  cmux agents chat continue <chat> [[--] <text>]\n  cmux agents wait --until idle|dialog|text [--target <id>] [--text <text> [--regex]] [--timeout <seconds>]\n  cmux agents events [--after <cursor>] [--kind dialog|notification|tab|workspace|agent ...] [--timeout <seconds>] [--limit <n>] [--json]\n  cmux agents doctor [--json]\n";

/// Handles the `agents` namespace before the normal daemon grammar.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (mut global, mut command_args) = parse_globals(args).ok()?;
    if command_args.first().map(String::as_str) != Some("agents") {
        return None;
    }
    // A local, read-only report: its human table stays the default.
    if command_args.get(1).map(String::as_str) == Some("doctor") {
        return Some(super::agents_doctor::run(&global, &command_args[2..]));
    }
    // `agents events` prints one line per event for a person.
    let lines = global.output == OutputMode::Human
        && command_args.get(1).map(String::as_str) == Some("events");
    if global.output == OutputMode::Human {
        global.output = OutputMode::Json;
    }
    let help_requested = asks_help(&command_args[1..]);
    if global.all_sessions && !command_args[1..].is_empty() && !help_requested {
        return Some(print_usage(
            &global,
            "--all-sessions is not supported for the composite agents command; choose one session",
        ));
    }
    if let Err(error) = normalize_qualified_targets(&mut global, &mut command_args[1..]) {
        return Some(print_usage(&global, &error.0));
    }
    Some(run(global, &command_args[1..], lines))
}

/// Routes a `<session>:<id>` target to its session (`global.session`) and
/// leaves the bare id in `args`.
pub(super) fn normalize_qualified_targets(
    global: &mut GlobalArgs,
    args: &mut [String],
) -> Result<(), UsageError> {
    let target_indices = match (args.first().map(String::as_str), args.get(1).map(String::as_str)) {
        (Some("workspace" | "tab"), Some("select")) | (Some("terminal"), Some("focus")) => Some(2),
        (Some("terminal"), Some("split")) => {
            args.iter().position(|value| value == "--surface").map(|index| index + 1)
        }
        (Some("wait"), _) => {
            args.iter().position(|value| value == "--target").map(|index| index + 1)
        }
        _ => None,
    };
    if let Some(index) = target_indices {
        let Some(target) = args.get_mut(index) else {
            return Err(UsageError::new("agent alias target is missing"));
        };
        normalize_qualified_target(global, target)?;
    }
    Ok(())
}

fn normalize_qualified_target(
    global: &mut GlobalArgs,
    target: &mut String,
) -> Result<(), UsageError> {
    let Some((session, id)) = super::federation::qualified(target) else { return Ok(()) };
    if global.socket.is_some() {
        return Err(UsageError::new(format!(
            "{session}: a qualified id names its session; drop --socket"
        )));
    }
    if let Some(named) = &global.session
        && named != session
    {
        return Err(UsageError::new(format!(
            "--session {named} and an id qualified with {session}: name one session"
        )));
    }
    global.session = Some(session.to_owned());
    *target = id.to_owned();
    Ok(())
}

fn run(global: GlobalArgs, args: &[String], lines: bool) -> i32 {
    if args.is_empty() || asks_help(args) {
        println!("{HELP}");
        return 0;
    }
    let command = match command(args) {
        Ok(AgentCommand::Snapshot) => return run_snapshot(&global),
        Ok(command) => command,
        Err(error) => return print_usage(&global, &error.0),
    };
    let backend = mcp::cli_backend(global.clone());
    // A long wait shows the progress notes app waits show (app/wait.rs).
    let notes = match &command {
        AgentCommand::Wait(request) => Some(app::wait::notes(
            &request.describe(),
            crate::localization::catalog().app_control.agents_waiting_progress,
            request.timeout,
            global.output,
        )),
        _ => None,
    };
    let outcome = execute(&backend, None, &command, global.idempotency_key.as_deref(), "agents");
    drop(notes);
    match outcome {
        // A wait that timed out prints its receipt and exits 1, as
        // `screen wait` does (docs/cli-contract.md).
        Ok(value) if matches!(command, AgentCommand::Wait(_)) && value["matched"] == false => {
            wire::print_local_success(&value, global.output).max(1)
        }
        // The cursor goes to stderr, so stdout is only the events.
        Ok(value) if lines => {
            print!("{}", events::human_lines(&value));
            eprintln!("next_after={}", value["next_after"].as_str().unwrap_or_default());
            0
        }
        Ok(value) => {
            let code = wire::print_local_success(&value, global.output);
            // A chat message stored but not handed to its chat: the receipt
            // is printed, and the exit status says it failed.
            if code == 0 && chat::delivery_failed(&value) { 1 } else { code }
        }
        Err(AgentFailure::Usage(message)) => print_usage(&global, &message),
        Err(AgentFailure::Owner(failure)) => {
            wire::print_local_error(&mcp::agent_failure_value(failure), global.output, 3)
        }
    }
}

/// `--help` or `-h` before any `--` (chat text after `--` may hold either).
fn asks_help(args: &[String]) -> bool {
    args.iter().take_while(|arg| *arg != "--").any(|arg| matches!(arg.as_str(), "--help" | "-h"))
}

pub(super) enum AgentCommand {
    Snapshot,
    Resource {
        action: String,
        args: Vec<String>,
    },
    App {
        action: String,
        args: Vec<String>,
    },
    Wait(wait::WaitRequest),
    Events(events::EventsRequest),
    /// Prompt another agent chat or read its transcript (chat.rs).
    Chat(chat::ChatCommand),
}

/// Why an agent action answered without a receipt.
pub(super) enum AgentFailure {
    /// The arguments name no request; nothing reached an owner.
    Usage(String),
    /// An owner refused the call or did not answer.
    Owner(CallFailure),
}

/// Parses `cmux agents` words (after `agents`) into a command. The MCP
/// `agents_<verb>` tools build the same words, so both run this grammar.
pub(super) fn command(args: &[String]) -> Result<AgentCommand, UsageError> {
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
            let mut pane: Option<String> = None;
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
        ["chat", rest @ ..] => chat::parse(rest).map(AgentCommand::Chat),
        ["dialog", "answer", request_id, rest @ ..] => Ok(AgentCommand::App {
            action: "dialog.answer".into(),
            args: std::iter::once((*request_id).into())
                .chain(rest.iter().map(|value| (*value).into()))
                .collect(),
        }),
        ["wait", rest @ ..] => wait::parse(rest).map(AgentCommand::Wait),
        ["events", rest @ ..] => events::parse(rest).map(AgentCommand::Events),
        _ => Err(UsageError::new("unknown agents command; run `cmux agents --help`")),
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

/// Runs one agent action for `cmux agents` and the `agents_<verb>` MCP
/// tools alike: the owner's request, the app focus a select implies, then a
/// receipt with a fresh composed snapshot and the idempotency key a change
/// carried. `session` routes daemon requests; the CLI routes with its global
/// options and passes `None`. `origin` names the caller in app runs
/// (`agents` for the CLI, `mcp` for tools).
pub(super) fn execute<B: Backend>(
    backend: &B,
    session: Option<&str>,
    command: &AgentCommand,
    idempotency_key: Option<&str>,
    origin: &str,
) -> Result<Value, AgentFailure> {
    let (action, (result, key)) = match command {
        AgentCommand::Snapshot => {
            return Err(AgentFailure::Usage("snapshot is a read, not an action".into()));
        }
        AgentCommand::Resource { action, args } => {
            (action, run_resource(backend, session, action, args, idempotency_key)?)
        }
        AgentCommand::App { action, args } => {
            (action, run_app(backend, action, args, idempotency_key, origin)?)
        }
        // A chat verb answers its own receipt or page: a topology snapshot
        // says nothing about what a chat was sent or answered.
        AgentCommand::Chat(command) => {
            return backend.chat(command, idempotency_key, origin).map_err(AgentFailure::Owner);
        }
        AgentCommand::Wait(request) => return wait::run(backend, session, request),
        AgentCommand::Events(request) => return events::run(backend, session, request),
    };
    Ok(receipt(backend, session, action, result, key))
}

/// The key a change carries: the caller's, else a new one, so the receipt
/// and a failure can both name it.
fn change_key(given: Option<&str>) -> Result<String, AgentFailure> {
    match given {
        Some(key) => Ok(key.to_owned()),
        None => wire::random_idempotency_key().map_err(|error| AgentFailure::Usage(error.0)),
    }
}

fn run_resource<B: Backend>(
    backend: &B,
    session: Option<&str>,
    action: &str,
    args: &[String],
    idempotency_key: Option<&str>,
) -> Result<(Value, Option<String>), AgentFailure> {
    let mut plan = match super::command::parse(args, Surface::CmuxTui) {
        Ok(CommandPlan::Protocol(plan)) => *plan,
        Ok(_) => {
            return Err(AgentFailure::Usage(
                "agents resource command did not produce a daemon request".into(),
            ));
        }
        Err(error) => return Err(AgentFailure::Usage(error.0)),
    };
    // `cmux agents` sends plain unary requests with no caller placement: its
    // `current` is still the focused object, and it has no `caller`.
    let caller = json!("caller");
    if plan.params.as_object().is_some_and(|params| {
        super::command::plan::CALLER_SCOPES.iter().any(|scope| params.get(*scope) == Some(&caller))
    }) {
        return Err(AgentFailure::Usage(
            "cmux agents takes ids, current or names; `caller` is for the cmux resource commands"
                .into(),
        ));
    }
    plan.resolve.retain(|step| *step != Resolve::Caller);
    if plan.operation.class() == OperationClass::Mutation {
        plan.idempotency_key = Some(change_key(idempotency_key)?);
    }
    let key = plan.idempotency_key.clone();
    let result = backend.resource(session, plan, &[]).map_err(AgentFailure::Owner)?;
    Ok((follow_app_focus(backend, action, result)?, key))
}

/// A select or focus also shows its object in the app's window, as
/// `cmux workspace <id> focus` does (app_focus.rs). With no app, or an app
/// that does not know the object, the daemon's answer stands.
fn follow_app_focus<B: Backend>(
    backend: &B,
    action: &str,
    result: Value,
) -> Result<Value, AgentFailure> {
    let operation = match action {
        "workspace.select" => ResourceOperation::WorkspaceFocus,
        "tab.select" | "terminal.focus" => ResourceOperation::TabFocus,
        _ => return Ok(result),
    };
    let app_focus::Follow::Focus(focus) = app_focus::follow_for(operation) else {
        return Ok(result);
    };
    let Some(id) = app_focus::reply_id(&result) else { return Ok(result) };
    let params = app_focus::focus_params(&focus, &id);
    match backend.app("action.run", params, app::WAITING_RUN_TIMEOUT, None, true) {
        Ok(_) => Ok(result),
        Err(failure) if app_focus::is_not_found(&failure.error) || no_app(&failure) => Ok(result),
        Err(failure) => Err(AgentFailure::Owner(failure)),
    }
}

/// No app answers on its control socket, so no window follows.
fn no_app(failure: &CallFailure) -> bool {
    failure.kind == FailureKind::NotRun
        && matches!(failure.error["code"].as_str(), Some("app.not_found" | "app.unreachable"))
}

fn run_app<B: Backend>(
    backend: &B,
    action: &str,
    args: &[String],
    idempotency_key: Option<&str>,
    origin: &str,
) -> Result<(Value, Option<String>), AgentFailure> {
    let (method, params, timeout) = match action {
        "palette.open" => {
            // The app takes cli, mcp, script or remote; `agents` is only the receipt's label.
            let app_origin = if origin == "mcp" { "mcp" } else { "cli" };
            let mut params = app::action_run_params("palette.open", ActionName::Any, app_origin);
            params.insert("focus".into(), json!(true));
            ("action.run", Value::Object(params), app::WAITING_RUN_TIMEOUT)
        }
        "dialog.list" => {
            let pending_only = !args.iter().any(|arg| arg == "--all");
            ("feed.list", json!({"pending_only": pending_only}), app::READ_TIMEOUT)
        }
        "dialog.answer" => dialog_answer(args).map_err(|error| AgentFailure::Usage(error.0))?,
        _ => return Err(AgentFailure::Usage("unknown app action".into())),
    };
    // Feed replies change the app but take no key; only `action.run` does.
    let mutation = method != "feed.list";
    let key = if method == "action.run" { Some(change_key(idempotency_key)?) } else { None };
    let result = backend
        .app(method, params, timeout, key.as_deref(), mutation)
        .map_err(AgentFailure::Owner)?;
    Ok((result, key))
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
                );
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
                );
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

fn receipt<B: Backend>(
    backend: &B,
    session: Option<&str>,
    action: &str,
    result: Value,
    idempotency_key: Option<String>,
) -> Value {
    let state = fresh_state(backend, session);
    let mut receipt =
        json!({"schema_version": 1, "action": action, "result": result, "state": state});
    if let Some(key) = idempotency_key {
        receipt["idempotency_key"] = Value::String(key);
    }
    receipt
}

/// A fresh composed snapshot, the `state` of every receipt.
fn fresh_state<B: Backend>(backend: &B, session: Option<&str>) -> Value {
    compose_snapshot(
        backend.resource(session, snapshot_plan(), &[]).map_err(mcp::agent_failure_value),
        backend
            .app("snapshot.get", json!({}), app::READ_TIMEOUT, None, false)
            .map_err(mcp::agent_failure_value),
    )
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
    let workspace_ids = daemon_workspace_ids(daemon_value.as_ref());
    let mut tabs = daemon_value
        .as_ref()
        .and_then(|value| value.get("tabs"))
        .cloned()
        .unwrap_or_else(|| json!([]));
    merge_app_tabs(&mut tabs, topology, workspace_ids.as_ref());
    let focus = topology
        .and_then(|value| value.get("focus"))
        .filter(|value| focus_in_scope(value, workspace_ids.as_ref()))
        .cloned()
        .or_else(|| daemon_value.as_ref().and_then(|value| value.get("focus")).cloned())
        .unwrap_or(Value::Null);
    let mut snapshot = json!({
        "schema_version": 1,
        "windows": scoped_windows(topology, workspace_ids.as_ref()),
        "workspaces": daemon_value.as_ref().and_then(|value| value.get("workspaces")).cloned().or_else(|| topology.and_then(|value| value.get("workspaces")).cloned()).unwrap_or_else(|| json!([])),
        "screens": daemon_value.as_ref().and_then(|value| value.get("screens")).cloned().unwrap_or_else(|| json!([])),
        "panes": daemon_value.as_ref().and_then(|value| value.get("panes")).cloned().unwrap_or_else(|| json!([])),
        "tabs": tabs,
        "terminals": daemon_value.as_ref().and_then(|value| value.get("terminals")).cloned().unwrap_or_else(|| json!([])),
        "browsers": daemon_value.as_ref().and_then(|value| value.get("browsers")).cloned().unwrap_or_else(|| json!([])),
        "focus": focus,
        "selection": selection(topology, daemon_value.as_ref(), workspace_ids.as_ref()),
        "sources": {
            "daemon": {"available": daemon_value.is_some(), "error": daemon_error.unwrap_or(Value::Null)},
            "app": {"available": app_value.is_some(), "error": app_error.unwrap_or(Value::Null)},
        },
    });
    // Where the caller is (the app resolves its agent session or terminal):
    // `caller` marks its own workspace, pane and tab, `beside` the column
    // right of it, where the app opens the caller's new tabs.
    for key in ["caller", "beside"] {
        if let Some(value) = app_value.as_ref().and_then(|value| value.get(key)) {
            snapshot[key] = value.clone();
        }
    }
    if let Some(shown) = topology
        .filter(|value| {
            value.get("focus").is_some_and(|focus| focus_in_scope(focus, workspace_ids.as_ref()))
        })
        .and_then(|value| value.get("focus"))
        .and_then(|value| value.get("workspace"))
        .and_then(Value::as_str)
    {
        app_focus::overlay_focused(
            &mut snapshot["workspaces"],
            &app_focus::AppWorkspaces::showing(shown),
        );
    }
    snapshot
}

fn has_resource_focus(value: &Value) -> bool {
    ["workspace", "pane", "tab"].iter().any(|key| value.get(*key).and_then(Value::as_str).is_some())
}

fn focus_in_scope(value: &Value, workspace_ids: Option<&HashSet<String>>) -> bool {
    has_resource_focus(value)
        && workspace_ids.is_none_or(|ids| {
            value
                .get("workspace")
                .and_then(Value::as_str)
                .is_some_and(|workspace| ids.contains(workspace))
        })
}

fn daemon_workspace_ids(daemon: Option<&Value>) -> Option<HashSet<String>> {
    let workspaces = daemon?.get("workspaces")?.as_array()?;
    Some(
        workspaces
            .iter()
            .filter_map(|workspace| workspace.get("id").and_then(Value::as_str))
            .map(str::to_owned)
            .collect(),
    )
}

fn scoped_windows(topology: Option<&Value>, workspace_ids: Option<&HashSet<String>>) -> Value {
    let Some(Value::Array(windows)) = topology.and_then(|value| value.get("windows")) else {
        return json!([]);
    };
    let Some(workspace_ids) = workspace_ids else { return Value::Array(windows.clone()) };
    Value::Array(
        windows
            .iter()
            .filter_map(|window| {
                let Some(workspaces) = window.get("workspaces").and_then(Value::as_array) else {
                    return Some(window.clone());
                };
                let selected = workspaces
                    .iter()
                    .filter(|workspace| {
                        workspace
                            .as_str()
                            .or_else(|| workspace.get("id").and_then(Value::as_str))
                            .is_some_and(|id| workspace_ids.contains(id))
                    })
                    .cloned()
                    .collect::<Vec<_>>();
                if selected.is_empty() {
                    return None;
                }
                let mut window = window.clone();
                window["workspaces"] = Value::Array(selected);
                if let Some(workspace) = window.get("workspace").cloned() {
                    let workspace_id =
                        workspace.as_str().or_else(|| workspace.get("id").and_then(Value::as_str));
                    if workspace_id.is_none_or(|id| !workspace_ids.contains(id)) {
                        window["workspace"] = window["workspaces"][0].clone();
                    }
                }
                Some(window)
            })
            .collect(),
    )
}

fn merge_app_tabs(
    tabs: &mut Value,
    topology: Option<&Value>,
    workspace_ids: Option<&HashSet<String>>,
) {
    let Some(Value::Array(app_tabs)) = topology.map(|value| collect_app_tabs(value, workspace_ids))
    else {
        return;
    };
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

fn collect_app_tabs(topology: &Value, workspace_ids: Option<&HashSet<String>>) -> Value {
    fn visit(
        value: &Value,
        out: &mut Vec<Value>,
        ids: &mut HashSet<String>,
        workspace_ids: Option<&HashSet<String>>,
        workspace_context: Option<&str>,
    ) {
        match value {
            Value::Object(object) => {
                let workspace_context = object
                    .get("workspace_id")
                    .and_then(Value::as_str)
                    .or_else(|| {
                        object.get("id").and_then(Value::as_str).filter(|id| id.starts_with("ws_"))
                    })
                    .or(workspace_context);
                for (key, child) in object {
                    if matches!(key.as_str(), "tabs" | "pageTabs" | "page_tabs")
                        && let Value::Array(tabs) = child
                    {
                        for tab in tabs {
                            if !is_app_page_tab(tab)
                                || !tab_belongs_to_workspace(tab, workspace_ids, workspace_context)
                            {
                                continue;
                            }
                            if let Some(id) = tab.get("id").and_then(Value::as_str)
                                && ids.insert(id.to_owned())
                            {
                                out.push(tab.clone());
                            }
                        }
                    }
                    visit(child, out, ids, workspace_ids, workspace_context);
                }
            }
            Value::Array(values) => values
                .iter()
                .for_each(|value| visit(value, out, ids, workspace_ids, workspace_context)),
            _ => {}
        }
    }

    let mut tabs = Vec::new();
    visit(topology, &mut tabs, &mut HashSet::new(), workspace_ids, None);
    Value::Array(tabs)
}

fn is_app_page_tab(tab: &Value) -> bool {
    ["kind", "content_kind", "type"].iter().any(|field| {
        matches!(
            tab.get(*field).and_then(Value::as_str),
            Some("page" | "local-page" | "internal-page")
        )
    }) || tab.get("id").and_then(Value::as_str).is_some_and(|id| id.starts_with("local-page:"))
}

fn tab_belongs_to_workspace(
    tab: &Value,
    workspace_ids: Option<&HashSet<String>>,
    workspace_context: Option<&str>,
) -> bool {
    let tab_workspace = tab.get("workspace_id").and_then(Value::as_str).or(workspace_context);
    workspace_ids.is_none_or(|ids| tab_workspace.is_some_and(|id| ids.contains(id)))
}

/// Page whole objects, never silently truncate relationship arrays inside an
/// object. MCP's shared size limiter can shrink `items` and advance the cursor.
pub(super) fn snapshot_page(mut snapshot: Value, offset: usize, limit: usize) -> Value {
    let Some(object) = snapshot.as_object_mut() else {
        return snapshot;
    };
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
        if let Some(Value::Array(values)) = object.remove(collection) {
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

fn selection(
    topology: Option<&Value>,
    daemon: Option<&Value>,
    workspace_ids: Option<&HashSet<String>>,
) -> Value {
    let focus = topology
        .and_then(|value| value.get("focus"))
        .filter(|value| focus_in_scope(value, workspace_ids))
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

pub(super) mod chat;
mod chat_control;
#[cfg(test)]
mod tests;
