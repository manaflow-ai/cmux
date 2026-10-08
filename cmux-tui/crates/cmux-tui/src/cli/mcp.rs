//! `cmux mcp`: cmux's tools for MCP clients (Claude Code, Codex) over stdio.
//!
//! The tools come from the two catalogs the owners publish, never from the
//! CLI grammar: the session daemon's `cmux.protocol/2` operations
//! (`v2_tools`) and the app's actions marked for the CLI (`action_tools`).
//! Calls go through `transport`, built from the CLI's own pieces, so a
//! tool call has the CLI's contract: socket discovery, `--session` routing,
//! public ids, idempotency keys, read barriers and deadlines. Off by default:
//! `serve` refuses unless cmux.json sets `"mcp": {"enabled": true}`, it
//! speaks only on stdin and stdout, and nothing listens on the network
//! (plans/cmux-next/mcp.md).

mod action_tools;
mod browser_tools;
mod config;
mod keybinding_tools;
mod messages;
mod schema;
#[cfg(test)]
mod tests;
mod transport;
mod v2_tools;
mod watch;

use std::io::{self, BufRead, Read, Write};
use std::path::PathBuf;
use std::time::Duration;

use serde_json::{Map, Value, json};

use super::command::RequestPlan;
use super::{GlobalArgs, OutputMode};
use action_tools::ActionTool;
use transport::{CallFailure, FailureKind, Prefix};

/// Runs one daemon request for the agent composite surface. The composite
/// surface uses the same socket discovery, routing, idempotency and deadline
/// handling as MCP without exposing the transport plumbing to the CLI module.
#[cfg(unix)]
pub(super) fn agent_resource(global: &GlobalArgs, plan: RequestPlan) -> Result<Value, Value> {
    transport::resource(global, plan, &[]).map_err(agent_failure_value)
}

/// Runs one app control request for the agent composite surface.
#[cfg(unix)]
pub(super) fn agent_app(
    global: &GlobalArgs,
    method: &str,
    params: Value,
    timeout: Duration,
    idempotency_key: Option<&str>,
) -> Result<Value, Value> {
    transport::app_method(global, method, params, timeout, idempotency_key)
        .map_err(agent_failure_value)
}

#[cfg(unix)]
fn agent_failure_value(failure: CallFailure) -> Value {
    let mut error = failure.error;
    if let Some(object) = error.as_object_mut() {
        let details = object.entry("details").or_insert_with(|| Value::Object(Map::new()));
        if let Some(details) = details.as_object_mut() {
            details.insert("state".into(), Value::String(failure.kind.state().into()));
            if let Some(key) = failure.idempotency_key {
                details.insert("idempotency_key".into(), Value::String(key));
            }
        }
    }
    error
}

/// MCP revisions this server speaks, newest first.
const PROTOCOL_VERSIONS: &[&str] = &["2025-06-18", "2025-03-26", "2024-11-05"];
/// The largest JSON-RPC line read from the client.
const MAX_MESSAGE_BYTES: usize = 8 << 20;
/// The largest tool result; a larger page is cut and says where to go on.
pub(super) const MAX_RESULT_BYTES: usize = 256 << 10;

const INSTRUCTIONS: &str = "These tools drive the cmux terminal app and its session daemon. \
    Objects have stable public ids (ws_…, screen_…, pane_…, tab_…, term_…, win_…) that the \
    *_list tools report; a unique prefix works, and <session>:<id> reaches another session. \
    A change takes idempotency_key: when a call fails with state in_progress, retry it with the \
    key from the error so it cannot apply twice. Tools never move the user's focus unless the \
    call passes focus: true or the tool's purpose is focus.";

/// A catalog entry that is not a tool, and why.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct Exclusion {
    pub kind: &'static str,
    pub name: String,
    pub reason: String,
}

impl Exclusion {
    fn json(&self) -> Value {
        json!({"kind": self.kind, "name": self.name, "reason": self.reason})
    }
}

/// Where tool calls go: the session daemon, the app and the browser host.
/// Tests replace it.
pub(super) trait Backend {
    fn resource(
        &self,
        session: Option<&str>,
        plan: RequestPlan,
        prefixes: &[Prefix],
    ) -> Result<Value, CallFailure>;
    fn app(
        &self,
        method: &str,
        params: Value,
        timeout: Duration,
        idempotency_key: Option<&str>,
    ) -> Result<Value, CallFailure>;
    fn browser(
        &self,
        request: browser_tools::Request,
        mutation: bool,
    ) -> Result<Value, CallFailure>;
}

/// The CLI's transport, with the CLI's global options.
struct LiveBackend {
    global: GlobalArgs,
}

impl Backend for LiveBackend {
    fn resource(
        &self,
        session: Option<&str>,
        plan: RequestPlan,
        prefixes: &[Prefix],
    ) -> Result<Value, CallFailure> {
        let mut global = self.global.clone();
        if let Some(session) = session
            && global.session.as_deref() != Some(session)
        {
            if global.socket.is_some() {
                return Err(CallFailure::local(
                    FailureKind::NotRun,
                    "usage.invalid",
                    "this server was started with --socket, so a call cannot name a session",
                ));
            }
            global.session = Some(session.to_owned());
        }
        transport::resource(&global, plan, prefixes)
    }

    fn app(
        &self,
        method: &str,
        params: Value,
        timeout: Duration,
        idempotency_key: Option<&str>,
    ) -> Result<Value, CallFailure> {
        transport::app_method(&self.global, method, params, timeout, idempotency_key)
    }

    fn browser(
        &self,
        request: browser_tools::Request,
        mutation: bool,
    ) -> Result<Value, CallFailure> {
        transport::browser_host(request.method, request.params, request.timeout, mutation)
    }
}

/// `cmux [global options] mcp …`; `None` when `args` names another scope.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command_args) = super::parse_globals(args).ok()?;
    let (scope, rest) = command_args.split_first()?;
    (scope == "mcp").then(|| run(global, rest))
}

/// `cmux [global options] mcp <command>`.
fn run(global: GlobalArgs, args: &[String]) -> i32 {
    let usage = messages::messages().usage;
    match args {
        [flag] if matches!(flag.as_str(), "-h" | "--help" | "help") => {
            println!("{usage}");
            0
        }
        [command] if command == "serve" => serve(global),
        [command] if command == "tools" => list_tools(global),
        _ => {
            eprintln!("cmux: {usage}");
            2
        }
    }
}

/// Why `serve` must not run with the settings file at `path`, or `None`
/// when cmux.json turns the server on.
pub(super) fn refusal(path: &std::path::Path) -> Option<String> {
    let messages = messages::messages();
    match config::enabled(path) {
        Ok(true) => None,
        Ok(false) => Some(messages.disabled.replace("{path}", &path.display().to_string())),
        Err(error) => Some(messages.config_invalid.replace("{error}", &error)),
    }
}

fn serve(global: GlobalArgs) -> i32 {
    let path = config::path();
    if let Some(message) = refusal(&path) {
        eprintln!("cmux: {message}");
        return 1;
    }
    // The client ends the server by closing stdin, then by SIGTERM; the
    // blocking stdin read must not hide that signal.
    let _ = crate::restore_default_termination_signals();
    let output = watch::Output::new(io::stdout());
    watch::spawn(global.clone(), output.clone());
    let mut server = Server::new(LiveBackend { global }, Some(path));
    server.list_changed = true;
    server.run(io::stdin().lock(), &output)
}

/// `cmux mcp tools [--json]`: what `serve` offers and what it leaves out.
fn list_tools(global: GlobalArgs) -> i32 {
    let output = global.output;
    let mut server = Server::new(LiveBackend { global }, None);
    let tools = server.list();
    let mut excluded = v2_tools::exclusions();
    excluded.extend(server.action_exclusions.iter().cloned());
    excluded.extend(action_tools::EXCLUDED_APP_METHODS.iter().map(|(name, reason)| Exclusion {
        kind: "app_method",
        name: (*name).to_owned(),
        reason: (*reason).to_owned(),
    }));
    let mut stdout = io::stdout().lock();
    let written = match output {
        OutputMode::Quiet => Ok(()),
        OutputMode::Json | OutputMode::JsonLines => {
            let value = json!({
                "count": tools.len(),
                "app_actions": server.actions_loaded,
                "tools": tools,
                "excluded": excluded.iter().map(Exclusion::json).collect::<Vec<_>>(),
            });
            serde_json::to_writer(&mut stdout, &value)
                .map_err(io::Error::other)
                .and_then(|()| writeln!(stdout))
        }
        OutputMode::Human => {
            let mut text = String::new();
            for tool in &tools {
                text.push_str(tool["name"].as_str().unwrap_or_default());
                text.push('\n');
            }
            text.push_str(&format!("\n{} tools", tools.len()));
            if !server.actions_loaded {
                text.push_str(" (the cmux app did not answer: no app action tools)");
            }
            text.push_str("\n\nexcluded:\n");
            for exclusion in &excluded {
                text.push_str(&format!(
                    "  {} {}: {}\n",
                    exclusion.kind, exclusion.name, exclusion.reason
                ));
            }
            stdout.write_all(text.as_bytes())
        }
    };
    i32::from(written.is_err()) * 3
}

/// The stdio JSON-RPC server: one request per line, answered in order.
pub(super) struct Server<B> {
    backend: B,
    /// The settings file to check before every call; `None` lists only.
    config: Option<PathBuf>,
    actions: Vec<ActionTool>,
    action_exclusions: Vec<Exclusion>,
    actions_loaded: bool,
    /// Sends `notifications/tools/list_changed` (`watch`); `serve` only.
    list_changed: bool,
    /// The client sent `notifications/initialized`.
    initialized: bool,
}

impl<B: Backend> Server<B> {
    pub(super) fn new(backend: B, config: Option<PathBuf>) -> Self {
        Self {
            backend,
            config,
            actions: Vec::new(),
            action_exclusions: Vec::new(),
            actions_loaded: false,
            list_changed: false,
            initialized: false,
        }
    }

    /// Answers each line of `input` on `output` until stdin closes.
    pub(super) fn run(&mut self, mut input: impl BufRead, output: &watch::Output) -> i32 {
        let mut line = Vec::new();
        loop {
            line.clear();
            match input.by_ref().take(MAX_MESSAGE_BYTES as u64 + 1).read_until(b'\n', &mut line) {
                Ok(0) => return 0,
                Ok(_) => {}
                Err(error) => {
                    eprintln!("cmux mcp: cannot read stdin: {error}");
                    return 1;
                }
            }
            if line.len() > MAX_MESSAGE_BYTES {
                let response = error_response(Value::Null, -32600, "message exceeds 8 MiB");
                let _ = output.send(&response);
                return 1;
            }
            let text = line.trim_ascii();
            if text.is_empty() {
                continue;
            }
            let response = match serde_json::from_slice::<Value>(text) {
                Ok(message) => self.handle(&message),
                Err(error) => Some(error_response(Value::Null, -32700, &format!("{error}"))),
            };
            if let Some(response) = response
                && output.send(&response).is_err()
            {
                return 0;
            }
            if self.initialized {
                output.set_ready();
            }
        }
    }

    /// One JSON-RPC message; `None` for a notification or a client response.
    pub(super) fn handle(&mut self, message: &Value) -> Option<Value> {
        let Some(object) = message.as_object() else {
            return Some(error_response(Value::Null, -32600, "expected a JSON-RPC object"));
        };
        let id = object.get("id").cloned();
        let Some(method) = object.get("method").and_then(Value::as_str) else {
            // A response to a request this server never sends.
            if object.contains_key("result") || object.contains_key("error") {
                return None;
            }
            return Some(error_response(id.unwrap_or(Value::Null), -32600, "missing method"));
        };
        if method == "notifications/initialized" {
            self.initialized = true;
        }
        let id = id?;
        let params = object.get("params").cloned().unwrap_or_else(|| json!({}));
        let result = match method {
            "initialize" => Ok(initialize(&params, self.list_changed)),
            "ping" => Ok(json!({})),
            "tools/list" => Ok(json!({ "tools": self.list() })),
            "tools/call" => self.call(&params),
            _ => Err((-32601, format!("method not found: {method}"))),
        };
        Some(match result {
            Ok(result) => json!({"jsonrpc": "2.0", "id": id, "result": result}),
            Err((code, message)) => error_response(id, code, &message),
        })
    }

    /// Every tool: the daemon operations, the browser host's REPL ops,
    /// `window_list`, and the app's CLI actions when the app answers.
    pub(super) fn list(&mut self) -> Vec<Value> {
        self.refresh_actions();
        let mut tools =
            v2_tools::tools().iter().map(v2_tools::V2Tool::descriptor_json).collect::<Vec<_>>();
        tools
            .extend(browser_tools::tools().iter().map(browser_tools::BrowserTool::descriptor_json));
        tools.push(action_tools::window_list_tool());
        tools.push(super::agents::snapshot_tool());
        tools.extend(
            keybinding_tools::TOOLS.iter().map(keybinding_tools::KeybindingTool::descriptor_json),
        );
        tools.extend(self.actions.iter().map(ActionTool::descriptor_json));
        tools
    }

    fn refresh_actions(&mut self) {
        match self.backend.app("action.list", json!({}), super::app::READ_TIMEOUT, None) {
            Ok(list) => {
                (self.actions, self.action_exclusions) = action_tools::from_list(&list);
                self.actions_loaded = true;
            }
            Err(failure) => {
                let message = failure.error["message"].as_str().unwrap_or("no answer");
                eprintln!("cmux mcp: the cmux app's actions are unavailable: {message}");
            }
        }
    }

    fn call(&mut self, params: &Value) -> Result<Value, (i64, String)> {
        let name = params["name"]
            .as_str()
            .ok_or_else(|| (-32602, "tools/call needs a tool name".to_string()))?;
        let arguments = match params.get("arguments") {
            None | Some(Value::Null) => Map::new(),
            Some(Value::Object(arguments)) => arguments.clone(),
            Some(_) => return Err((-32602, "tools/call arguments must be an object".into())),
        };
        if let Some(path) = &self.config
            && let Some(message) = refusal(path)
        {
            let error = json!({
                "code": "mcp.disabled",
                "message": message,
                "details": {},
                "retryable": false,
            });
            return Ok(tool_error(envelope(error, "not_run", None)));
        }
        if let Some(tool) = v2_tools::find(name) {
            return Ok(self.call_v2(tool, &arguments));
        }
        if let Some(tool) = browser_tools::find(name) {
            return Ok(match tool.request(&arguments) {
                Ok(request) => match self.backend.browser(request, tool.mutation) {
                    Ok(value) => success(value, tool.mutation),
                    Err(failure) => failure_result(failure),
                },
                Err(error) => tool_error(envelope(error, "not_run", None)),
            });
        }
        if name == action_tools::WINDOW_LIST {
            return Ok(self.call_window_list(&arguments));
        }
        if name == super::agents::SNAPSHOT_TOOL {
            if let Some(name) = arguments.keys().next() {
                return Ok(tool_error(envelope(
                    v2_tools::invalid(format!("agents_snapshot has no argument {name:?}")),
                    "not_run",
                    None,
                )));
            }
            let daemon = self
                .backend
                .resource(None, super::agents::snapshot_plan(), &[])
                .map_err(agent_failure_value);
            let app = self
                .backend
                .app("snapshot.get", json!({}), super::app::READ_TIMEOUT, None)
                .map_err(agent_failure_value);
            return Ok(success(super::agents::compose_snapshot(daemon, app), false));
        }
        if let Some(tool) = keybinding_tools::find(name) {
            return Ok(match tool.params(&arguments) {
                Ok(params) => {
                    match self.backend.app(tool.method, params, super::app::READ_TIMEOUT, None) {
                        Ok(value) => success(value, false),
                        Err(failure) => failure_result(failure),
                    }
                }
                Err(message) => tool_error(envelope(v2_tools::invalid(message), "not_run", None)),
            });
        }
        if !self.actions.iter().any(|tool| tool.name == name) {
            self.refresh_actions();
        }
        let Some(tool) = self.actions.iter().find(|tool| tool.name == name) else {
            return Err((-32602, format!("unknown tool: {name}")));
        };
        Ok(self.call_action(tool, &arguments))
    }

    fn call_v2(&self, tool: &v2_tools::V2Tool, arguments: &Map<String, Value>) -> Value {
        let call = match tool.plan(arguments) {
            Ok(call) => call,
            Err(error) => return tool_error(envelope(error, "not_run", None)),
        };
        let page = call.page;
        match self.backend.resource(call.session.as_deref(), call.plan, &call.prefixes) {
            Ok(value) => success(
                match page {
                    Some(page) => v2_tools::paginate(value, page),
                    None => value,
                },
                tool.mutation,
            ),
            Err(failure) => failure_result(failure),
        }
    }

    fn call_window_list(&self, arguments: &Map<String, Value>) -> Value {
        if let Some(name) = arguments.keys().next() {
            return tool_error(envelope(
                v2_tools::invalid(format!("window_list has no argument {name:?}")),
                "not_run",
                None,
            ));
        }
        match self.backend.app("snapshot.get", json!({}), super::app::READ_TIMEOUT, None) {
            Ok(snapshot) => success(json!({ "items": snapshot["topology"]["windows"] }), false),
            Err(failure) => failure_result(failure),
        }
    }

    fn call_action(&self, tool: &ActionTool, arguments: &Map<String, Value>) -> Value {
        let (params, key) = match tool.run_params(arguments) {
            Ok(run) => run,
            Err(error) => return tool_error(envelope(error, "not_run", None)),
        };
        let timeout = super::app::WAITING_RUN_TIMEOUT;
        match self.backend.app("action.run", params, timeout, key.as_deref()) {
            Ok(value) => success(value, true),
            Err(failure) => failure_result(failure),
        }
    }
}

fn initialize(params: &Value, list_changed: bool) -> Value {
    let requested = params["protocolVersion"].as_str();
    let version = PROTOCOL_VERSIONS
        .iter()
        .find(|version| Some(**version) == requested)
        .unwrap_or(&PROTOCOL_VERSIONS[0]);
    json!({
        "protocolVersion": version,
        "capabilities": {"tools": {"listChanged": list_changed}},
        "serverInfo": {"name": "cmux", "title": "cmux", "version": env!("CARGO_PKG_VERSION")},
        "instructions": INSTRUCTIONS,
    })
}

fn error_response(id: Value, code: i64, message: &str) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}})
}

/// A successful tool result: the owner's value as structured content (an
/// array as `{items}`), cut to `MAX_RESULT_BYTES`. A change (`applied`)
/// whose result does not fit still reports success, so a client never
/// retries a change that applied.
pub(super) fn success(value: Value, applied: bool) -> Value {
    let value = match value {
        Value::Object(_) => value,
        Value::Array(items) => json!({ "items": items }),
        other => json!({ "result": other }),
    };
    match fit(value) {
        Ok(value) => {
            let text = serde_json::to_string(&value).unwrap_or_default();
            json!({
                "content": [{"type": "text", "text": text}],
                "structuredContent": value,
                "isError": false,
            })
        }
        Err(_) if applied => {
            let value = json!({
                "applied": true,
                "truncated": true,
                "message": format!(
                    "the change applied; its result is larger than {} KiB, so read the object \
                     with a get or list tool",
                    MAX_RESULT_BYTES >> 10
                ),
            });
            let text = serde_json::to_string(&value).unwrap_or_default();
            json!({
                "content": [{"type": "text", "text": text}],
                "structuredContent": value,
                "isError": false,
            })
        }
        Err(error) => tool_error(envelope(error, "rejected", None)),
    }
}

/// `value` when it serializes within `MAX_RESULT_BYTES`; else its `items`
/// halved until it does (`truncated`, `next_offset`), else an error.
fn fit(mut value: Value) -> Result<Value, Value> {
    let size = |value: &Value| serde_json::to_vec(value).map(|bytes| bytes.len()).unwrap_or(0);
    if size(&value) <= MAX_RESULT_BYTES {
        return Ok(value);
    }
    while let Some(items) = value.get_mut("items").and_then(Value::as_array_mut)
        && items.len() > 1
    {
        let keep = items.len() / 2;
        items.truncate(keep);
        value["truncated"] = json!(true);
        value["returned"] = json!(keep);
        if let Some(offset) = value.get("offset").and_then(Value::as_u64) {
            value["next_offset"] = json!(offset + keep as u64);
        }
        if size(&value) <= MAX_RESULT_BYTES {
            return Ok(value);
        }
    }
    Err(json!({
        "code": "result.too_large",
        "message": format!(
            "the result is larger than {} KiB; ask for less (limit, max_bytes, or a narrower \
             selector)",
            MAX_RESULT_BYTES >> 10
        ),
        "details": {},
        "retryable": false,
    }))
}

/// The error a failed call reports: the owner's error unchanged, its
/// `state` (`rejected`, `not_run`, `in_progress`) and the idempotency key
/// to retry with.
fn envelope(error: Value, state: &str, idempotency_key: Option<&str>) -> Value {
    let mut envelope = json!({ "error": error, "state": state });
    if let Some(key) = idempotency_key {
        envelope["idempotency_key"] = json!(key);
    }
    envelope
}

pub(super) fn failure_result(failure: CallFailure) -> Value {
    // An owner that says whether the run started (the app's `busy` and
    // `timeout`) decides the state.
    let data = failure.error.get("data").or_else(|| failure.error.get("details"));
    let owner_state = data.and_then(|data| {
        if data.get("not_run") == Some(&Value::Bool(true)) {
            return Some("not_run");
        }
        data.get("state")
            .and_then(Value::as_str)
            .filter(|state| matches!(*state, "not_run" | "in_progress"))
    });
    // The app's queue deadline (`timeout`) says nothing about whether the
    // run started; a retry with the same key is safe either way.
    let timed_out = failure.kind == FailureKind::Rejected && failure.error["code"] == "timeout";
    let state = owner_state
        .or(timed_out.then_some("in_progress"))
        .unwrap_or(failure.kind.state())
        .to_owned();
    tool_error(envelope(failure.error, &state, failure.idempotency_key.as_deref()))
}

fn tool_error(envelope: Value) -> Value {
    let text = serde_json::to_string(&envelope).unwrap_or_default();
    json!({
        "content": [{"type": "text", "text": text}],
        "structuredContent": envelope,
        "isError": true,
    })
}
