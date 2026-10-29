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
//! (plans/cmux-next/mcp.md). `serve` speaks code mode (`code_mode`): two
//! tools that search this tool list and run scripts against it;
//! `serve --all-tools` lists every tool instead. `CMUX_MCP_TOOLS` (a
//! comma-separated allowlist, the Chief's turns) lists exactly those tools
//! and refuses every other call, from a script too.

use crate::cli::json_fields::JsonFields;

mod action_tools;
mod agent_dispatch_tools;
mod agent_events_tool;
mod agent_tools;
mod agent_wait_tool;
mod browser_tools;
mod caller_scope;
mod catalog;
mod code_mode;
mod computer_use_gate;
mod config;
#[cfg(unix)]
mod host;
mod keybinding_tools;
mod messages;
mod panic_log;
mod placement;
mod render_tool;
mod results;
mod schema;
mod settings_tools;
mod terminal_talk_tools;
#[cfg(test)]
mod tests;
mod transport;
mod upstream;
mod v2_tools;
mod watch;

use std::collections::BTreeSet;
use std::io::{self, BufRead, Read, Write};
use std::path::PathBuf;
use std::time::{Duration, Instant};

use serde_json::{Map, Value, json};

use super::caller_env;
use super::command::RequestPlan;
use super::{GlobalArgs, OutputMode};
use action_tools::ActionTool;
use catalog::{ActionCatalog, SharedCatalog};
pub(super) use config::outside_chats;
use config::refusal;
pub(super) use results::failure_result;
use results::{envelope, error_response, success, tool_error};
use transport::Prefix;
pub(super) use transport::{CallFailure, FailureKind};

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
    transport::app_method(global, method, params, timeout, idempotency_key, false)
        .map_err(agent_failure_value)
}

/// The CLI's transport as a `Backend`, so the agent composite surface runs
/// one code path for the CLI and for MCP tools.
pub(super) fn cli_backend(global: GlobalArgs) -> impl Backend {
    LiveBackend { global }
}

/// A failed owner call as the CLI prints it: the owner's error with its
/// `state` and idempotency key in `details`.
#[cfg(unix)]
pub(super) fn agent_failure_value(failure: CallFailure) -> Value {
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
    `current` is this chat's own workspace or pane; `focused` is the one the person looks at. \
    A change takes idempotency_key: when a call fails with state in_progress, retry it with the \
    key from the error so it cannot apply twice. Tools never move the user's focus unless the \
    call passes focus: true or the tool's purpose is focus. \
    Name workspaces and tabs to the person by their titles, never by an id they cannot see. \
    When the person must act in a tab (log in, confirm, approve, pick), mark it: tab_update \
    {tab, attention: \"reason\"}; when they ask to go there, tab_focus it. \
    In a cmux chat reply, show UI rather than describe it: ![alt](/abs/path.png), a bare image \
    path or an https image address draws as a thumbnail, and two in one paragraph sit side by side.";

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
    /// `mutation`: the request changes app state, so a transport failure
    /// after sending leaves its outcome unknown (`in_progress`).
    fn app(
        &self,
        method: &str,
        params: Value,
        timeout: Duration,
        idempotency_key: Option<&str>,
        mutation: bool,
    ) -> Result<Value, CallFailure>;
    fn browser(
        &self,
        request: browser_tools::Request,
        mutation: bool,
    ) -> Result<Value, CallFailure>;
    /// One harness-agnostic agent dispatch request. The acpmux daemon owns
    /// target selection, brief persistence and sender attribution; this
    /// surface deliberately carries no shell command or remote path.
    fn acpmux(
        &self,
        _method: &str,
        _params: Value,
        _timeout: Duration,
        _idempotency_key: Option<&str>,
        _mutation: bool,
    ) -> Result<Value, CallFailure> {
        Err(CallFailure::local(
            FailureKind::NotRun,
            "acpmux.unavailable",
            "this server cannot reach acpmux agent dispatch",
        ))
    }
    /// App calls that may run on another thread: a computer use call's
    /// setup card waits with the call, not on this server's thread
    /// (`computer_use_gate`). `None`: the call runs without the card.
    fn app_caller(&self) -> Option<computer_use_gate::AppCaller> {
        None
    }
    /// The app's `system.identify` (`caller`, `beside`); `None` with no caller (placement.rs).
    fn identity(&self) -> Result<Option<Value>, CallFailure> {
        Ok(None)
    }
    /// The app's focus from `snapshot.get` (placement.rs).
    fn focus(&self) -> Result<Option<Value>, CallFailure> {
        Ok(None)
    }
    /// Holds the session daemon's `session.events` stream open until
    /// `deadline` and calls `on_wake` with each item (the initial snapshot
    /// first, or with `cursor` the journal batches after it), and with
    /// `None` after each `tick` without one, until it returns `true`. An
    /// error means no stream opened.
    fn session_events(
        &self,
        session: Option<&str>,
        cursor: Option<&Value>,
        deadline: Instant,
        tick: Duration,
        on_wake: &mut dyn FnMut(Option<&Value>) -> bool,
    ) -> Result<(), CallFailure>;

    /// The data of the session daemon's reply to the field-less line `cmd`
    /// (`energy.status`), or why it gave none.
    fn daemon_line(&self, cmd: &str) -> Result<Value, String>;

    /// The app whose `action.list` this backend reads (its control socket),
    /// the key of the catalog the shared host keeps for it.
    fn catalog_key(&self) -> Option<PathBuf> {
        None
    }

    /// A `cmux agents chat` verb: the daemon (agent messages, workspaces)
    /// and acpmux (chats) together. A backend without both runs none.
    fn chat(
        &self,
        _command: &super::agents::chat::ChatCommand,
        _idempotency_key: Option<&str>,
        _origin: &str,
    ) -> Result<Value, CallFailure> {
        Err(CallFailure {
            kind: FailureKind::NotRun,
            error: json!({"code": "chat.unavailable", "message": "this backend reaches no chats",
                          "details": {}, "retryable": false}),
            idempotency_key: None,
        })
    }
}

/// The CLI's transport, with the CLI's global options.
struct LiveBackend {
    global: GlobalArgs,
}

impl LiveBackend {
    /// The global options with the call's session.
    fn routed(&self, session: Option<&str>) -> Result<GlobalArgs, CallFailure> {
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
        Ok(global)
    }
}

impl Backend for LiveBackend {
    fn resource(
        &self,
        session: Option<&str>,
        plan: RequestPlan,
        prefixes: &[Prefix],
    ) -> Result<Value, CallFailure> {
        transport::resource(&self.routed(session)?, plan, prefixes)
    }

    fn identity(&self) -> Result<Option<Value>, CallFailure> {
        placement::app_identity(&self.global)
    }

    fn app_caller(&self) -> Option<computer_use_gate::AppCaller> {
        let global = self.global.clone();
        Some(std::sync::Arc::new(move |method: &str, params: Value, timeout: Duration| {
            transport::app_method(&global, method, params, timeout, None, false)
        }))
    }

    fn focus(&self) -> Result<Option<Value>, CallFailure> {
        placement::app_focus(&self.global)
    }

    fn session_events(
        &self,
        session: Option<&str>,
        cursor: Option<&Value>,
        deadline: Instant,
        tick: Duration,
        on_wake: &mut dyn FnMut(Option<&Value>) -> bool,
    ) -> Result<(), CallFailure> {
        transport::session_events(&self.routed(session)?, cursor, deadline, tick, on_wake)
    }

    fn app(
        &self,
        method: &str,
        params: Value,
        timeout: Duration,
        idempotency_key: Option<&str>,
        mutation: bool,
    ) -> Result<Value, CallFailure> {
        transport::app_method(&self.global, method, params, timeout, idempotency_key, mutation)
    }

    fn daemon_line(&self, cmd: &str) -> Result<Value, String> {
        super::energy::daemon_line(&self.global, cmd)
    }

    fn catalog_key(&self) -> Option<PathBuf> {
        super::app::socket_path(&self.global).ok()
    }

    fn browser(
        &self,
        request: browser_tools::Request,
        mutation: bool,
    ) -> Result<Value, CallFailure> {
        transport::browser_host(request.method, request.params, request.timeout, mutation)
    }

    fn acpmux(
        &self,
        method: &str,
        params: Value,
        timeout: Duration,
        idempotency_key: Option<&str>,
        mutation: bool,
    ) -> Result<Value, CallFailure> {
        agent_dispatch_tools::acpmux_request(method, params, timeout, idempotency_key, mutation)
    }

    fn chat(
        &self,
        command: &super::agents::chat::ChatCommand,
        idempotency_key: Option<&str>,
        origin: &str,
    ) -> Result<Value, CallFailure> {
        super::agents::chat::run(&self.global, command, idempotency_key, origin)
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
        [command] if command == "serve" => serve(global, true),
        [command, flag] if command == "serve" && flag == "--all-tools" => serve(global, false),
        [command] if command == "tools" => list_tools(global),
        #[cfg(unix)]
        [command, socket] if command == host::START_VERB => {
            host::start_detached(std::path::Path::new(socket))
        }
        #[cfg(unix)]
        [command, socket] if command == host::RUN_VERB => host::run(std::path::Path::new(socket)),
        _ => {
            eprintln!("cmux: {usage}");
            2
        }
    }
}

/// The env acpmux gives the cmux MCP server of a session whose preset names
/// the tools it may use (acpmux `agent_tools::MCP_TOOLS_ENV`, the Chief's
/// turns). Fail closed: an empty value allows no tool.
const ALLOWED_TOOLS_ENV: &str = "CMUX_MCP_TOOLS";

/// The allowlist in `value`, or `None` when the env is unset.
fn allowed_tools(value: Option<std::ffi::OsString>) -> Option<BTreeSet<String>> {
    let value = value?;
    Some(
        value
            .to_str()
            .unwrap_or_default()
            .split(',')
            .map(str::trim)
            .filter(|name| !name.is_empty())
            .map(str::to_owned)
            .collect(),
    )
}

fn serve(global: GlobalArgs, code_mode: bool) -> i32 {
    let path = config::path();
    if let Some(message) = refusal(&path) {
        eprintln!("cmux: {message}");
        return 1;
    }
    // With `mcpCatalogHost` on, this process becomes a relay to the shared
    // host (`host.rs`) and does not return; it serves here only when it can not.
    #[cfg(unix)]
    if let Some(why) = host::relay(&global, code_mode, &path) {
        eprintln!("cmux mcp: serving in this process: {why}");
    }
    // The process that serves logs its panics; a relay above has replaced
    // itself, and the shared host installs the same hook (`host::run`).
    panic_log::install();
    // The client ends the server by closing stdin, then by SIGTERM; the
    // blocking stdin read must not hide that signal.
    let _ = crate::restore_default_termination_signals();
    let output = watch::Output::new(io::stdout());
    let notes = output.clone();
    watch::spawn(global.clone(), move || {
        let _ = notes.tools_changed();
    });
    client_server(global, path, code_mode).run(io::stdin().lock(), &output)
}

/// The server of one client: its settings file and mode, and the allowlist
/// and proxied servers its environment names (the caller in scope, in the
/// shared host).
fn client_server(global: GlobalArgs, config: PathBuf, code_mode: bool) -> Server<LiveBackend> {
    let mut server = Server::new(LiveBackend { global }, Some(config));
    server.list_changed = true;
    server.code_mode = code_mode;
    server.allowed = allowed_tools(caller_env::var_os(ALLOWED_TOOLS_ENV));
    server.upstreams = upstream::specs(caller_env::var_os(upstream::ENV))
        .into_iter()
        .map(|spec| upstream::Proxied::new(upstream::Upstream::new(spec)))
        .collect();
    server
}

/// `cmux mcp tools [--json]`: what `serve` offers and what it leaves out.
fn list_tools(global: GlobalArgs) -> i32 {
    let output = global.output;
    let mut server = Server::new(LiveBackend { global }, None);
    let tools = server.list();
    let mut excluded = v2_tools::exclusions();
    excluded.extend(server.actions.exclusions.iter().cloned());
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
    /// The app's action tools as last read; in the shared host, the one
    /// copy all clients of the app hold (`shared`).
    actions: std::sync::Arc<ActionCatalog>,
    actions_loaded: bool,
    shared: Option<SharedCatalog>,
    /// Sends `notifications/tools/list_changed` (`watch`); `serve` only.
    list_changed: bool,
    /// The client sent `notifications/initialized`.
    initialized: bool,
    /// `tools/list` offers only `cmux_docs` and `cmux_exec` (`code_mode`).
    code_mode: bool,
    /// What one `cmux_exec` script may use.
    script_limits: code_mode::Limits,
    /// `CMUX_MCP_TOOLS`: the only tools listed and callable. It turns code
    /// mode off (the few tools are listed directly).
    allowed: Option<BTreeSet<String>>,
    /// The agent chat's other MCP servers (`upstream`), behind this one.
    upstreams: Vec<upstream::Proxied>,
    /// While a `cmux_exec` script runs: its time limit, which also bounds a
    /// proxied call it makes (the script holds this thread).
    call_cap: Option<Duration>,
    /// While a `cmux_exec` script runs: when its time limit ends.
    call_deadline: Option<Instant>,
    /// Where `run` writes, for a call's `notifications/progress`.
    notes: Option<watch::Output>,
    /// The ids `render` returned in this process: a render may update only one of these.
    renders: std::collections::HashSet<String>,
}

impl<B: Backend> Server<B> {
    pub(super) fn new(backend: B, config: Option<PathBuf>) -> Self {
        Self {
            backend,
            config,
            actions: std::sync::Arc::default(),
            actions_loaded: false,
            shared: None,
            list_changed: false,
            initialized: false,
            code_mode: false,
            script_limits: code_mode::Limits::default(),
            allowed: None,
            upstreams: Vec::new(),
            call_cap: None,
            call_deadline: None,
            notes: None,
            renders: std::collections::HashSet::new(),
        }
    }

    /// Answers each line of `input` on `output` until stdin closes.
    pub(super) fn run(&mut self, mut input: impl BufRead, output: &watch::Output) -> i32 {
        self.notes = Some(output.clone());
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
            "initialize" => {
                Ok(initialize(&params, self.list_changed, self.code_mode && self.allowed.is_none()))
            }
            "ping" => Ok(json!({})),
            "tools/list" if self.code_mode && self.allowed.is_none() => {
                let tools = self.list();
                Ok(json!({ "tools": code_mode::descriptors(&tools) }))
            }
            "tools/list" => Ok(json!({ "tools": self.list() })),
            "tools/call" => {
                // A proxied server's call runs on its own thread, so one that
                // waits (a secret card) never holds up the other tools.
                if let Some(output) = self.notes.clone()
                    && let Some(job) = self.proxied_job(&params)
                {
                    let caller = caller_env::current();
                    let call_id = id.clone();
                    // supervise-allow: one proxied tool call; a panic ends that call only, and the MCP client's own timeout ends its wait.
                    let started = cmux_threads::spawn(
                        "cmux-mcp-proxied-call",
                        cmux_threads::ThreadQos::UserInitiated,
                        move || {
                            let result = match caller {
                                Some(caller) => caller_env::scope(caller, || job.run(None)),
                                None => job.run(None),
                            };
                            let response =
                                json!({"jsonrpc": "2.0", "id": call_id, "result": result});
                            let _ = output.send(&response);
                        },
                    );
                    match started {
                        Ok(_) => return None,
                        Err(error) => Err((-32603, format!("cannot start the call: {error}"))),
                    }
                } else {
                    self.call(&params)
                }
            }
            _ => Err((-32601, format!("method not found: {method}"))),
        };
        Some(match result {
            Ok(result) => json!({"jsonrpc": "2.0", "id": id, "result": result}),
            Err((code, message)) => error_response(id, code, &message),
        })
    }

    /// Every tool: the daemon operations, the browser host's REPL ops,
    /// `window_list`, `agents_snapshot`, `agents_doctor`, `render`, and the app's CLI actions
    /// when the app answers.
    pub(super) fn list(&mut self) -> Vec<Value> {
        self.refresh_actions();
        let mut tools =
            v2_tools::tools().iter().map(v2_tools::V2Tool::descriptor_json).collect::<Vec<_>>();
        tools
            .extend(browser_tools::tools().iter().map(browser_tools::BrowserTool::descriptor_json));
        tools.push(action_tools::window_list_tool());
        tools.push(super::agents::snapshot_tool());
        tools.extend(agent_tools::TOOLS.iter().map(agent_tools::AgentTool::descriptor_json));
        tools.extend(agent_dispatch_tools::descriptors());
        tools.push(super::agents_doctor::mcp_tool());
        tools.push(agent_wait_tool::descriptor());
        tools.push(agent_events_tool::descriptor());
        tools.extend(terminal_talk_tools::descriptors());
        tools.push(render_tool::descriptor());
        tools.push(super::energy::mcp_tool());
        tools
            .extend(settings_tools::TOOLS.iter().map(settings_tools::SettingTool::descriptor_json));
        tools.extend(
            keybinding_tools::TOOLS.iter().map(keybinding_tools::KeybindingTool::descriptor_json),
        );
        tools.extend(self.actions.tools.iter().map(ActionTool::descriptor_json));
        for proxied in &mut self.upstreams {
            proxied.refresh();
            let taken = tools
                .iter()
                .filter_map(|tool| tool["name"].as_str().map(str::to_owned))
                .collect::<BTreeSet<_>>();
            tools.extend(
                proxied
                    .listed
                    .iter()
                    .filter(|t| t["name"].as_str().is_some_and(|n| !taken.contains(n)))
                    .cloned(),
            );
        }
        if let Some(allowed) = &self.allowed {
            tools.retain(|tool| tool["name"].as_str().is_some_and(|name| allowed.contains(name)));
        }
        tools
    }

    fn refresh_actions(&mut self) {
        match self.backend.app("action.list", json!({}), super::app::READ_TIMEOUT, None, false) {
            Ok(list) => {
                let read = std::sync::Arc::new(ActionCatalog::parse(&list));
                drop(list);
                self.actions = match (&self.shared, self.backend.catalog_key()) {
                    (Some(shared), Some(app)) => shared.intern(app, read),
                    _ => read,
                };
                self.actions_loaded = true;
            }
            Err(failure) => {
                let message = failure.error.field("message").as_str().unwrap_or("no answer");
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
        if let Some(allowed) = &self.allowed
            && !allowed.contains(name)
        {
            let error = json!({
                "code": "tool.not_allowed",
                "message": format!("this chat may not use {name}"),
                "details": {},
                "retryable": false,
            });
            return Ok(tool_error(envelope(error, "not_run", None)));
        }
        if name == code_mode::DOCS {
            let tools = self.list();
            return Ok(match code_mode::docs(&tools, &arguments) {
                Ok(mut value) => {
                    self.add_server_rules(&mut value);
                    success(value, false)
                }
                Err(message) => tool_error(envelope(v2_tools::invalid(message), "not_run", None)),
            });
        }
        if name == code_mode::EXEC {
            // One tool list per script, for its docs searches.
            let mut tools = None;
            let mut images = Vec::new();
            self.call_cap = Some(self.script_limits.total);
            self.call_deadline = Some(Instant::now() + self.script_limits.total);
            let answered = code_mode::exec(&arguments, self.script_limits, &mut |request| {
                self.script_request(request, &mut tools, &mut images)
            });
            self.call_cap = None;
            self.call_deadline = None;
            let mut result = answered.unwrap_or_else(|message| {
                tool_error(envelope(v2_tools::invalid(message), "not_run", None))
            });
            if let Some(content) = result.get_mut("content").and_then(Value::as_array_mut) {
                content.extend(images);
            }
            return Ok(result);
        }
        if let Some(job) = self.proxied_tool(name, &arguments) {
            return Ok(job.run(self.call_cap));
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
            let limit = match arguments.get("limit") {
                None => super::agents::DEFAULT_SNAPSHOT_LIMIT,
                Some(value) => match value.as_u64().and_then(|value| usize::try_from(value).ok()) {
                    Some(value) if (1..=super::agents::MAX_SNAPSHOT_LIMIT).contains(&value) => {
                        value
                    }
                    _ => {
                        return Ok(tool_error(envelope(
                            v2_tools::invalid(
                                "agents_snapshot limit must be an integer from 1 to 1000",
                            ),
                            "not_run",
                            None,
                        )));
                    }
                },
            };
            let offset = match arguments.get("offset") {
                None => 0,
                Some(value) => match value.as_u64().and_then(|value| usize::try_from(value).ok()) {
                    Some(value) => value,
                    None => {
                        return Ok(tool_error(envelope(
                            v2_tools::invalid(
                                "agents_snapshot offset must be a nonnegative integer",
                            ),
                            "not_run",
                            None,
                        )));
                    }
                },
            };
            if let Some(name) =
                arguments.keys().find(|name| !matches!(name.as_str(), "limit" | "offset"))
            {
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
                .app("snapshot.get", json!({}), super::app::READ_TIMEOUT, None, false)
                .map_err(agent_failure_value);
            let snapshot = super::agents::compose_snapshot(daemon, app);
            if let Some(error) = super::agents::snapshot_error(&snapshot) {
                return Ok(tool_error(envelope(error, "not_run", None)));
            }
            return Ok(success(super::agents::snapshot_page(snapshot, offset, limit), false));
        }
        if name == super::agents_doctor::MCP_TOOL {
            // Read-only: the CLI's checks, and at most one app read.
            let app_status = || {
                self.backend
                    .app(
                        super::agents_doctor::STATUS_METHOD,
                        json!({}),
                        super::app::READ_TIMEOUT,
                        None,
                        false,
                    )
                    .map_err(agent_failure_value)
            };
            return Ok(match super::agents_doctor::mcp_findings(&arguments, app_status) {
                Ok(report) => success(report, false),
                Err(message) => tool_error(envelope(v2_tools::invalid(message), "not_run", None)),
            });
        }
        if let Some(tool) = agent_tools::find(name) {
            return Ok(tool.call(&self.backend, &arguments));
        }
        if let Some(tool) = agent_dispatch_tools::find(name) {
            return Ok(tool.call(&self.backend, &arguments));
        }
        if name == agent_wait_tool::NAME {
            let progress = agent_wait_tool::Progress::requested(params, self.notes.as_ref());
            return Ok(agent_wait_tool::call(&self.backend, &arguments, progress));
        }
        if name == agent_events_tool::NAME {
            return Ok(agent_events_tool::call(&self.backend, &arguments));
        }
        if name == terminal_talk_tools::LIST {
            return Ok(terminal_talk_tools::call_list(&self.backend, &arguments));
        }
        if name == terminal_talk_tools::SEND {
            let progress = agent_wait_tool::Progress::requested(params, self.notes.as_ref());
            return Ok(terminal_talk_tools::call_send(&self.backend, &arguments, progress));
        }
        if name == render_tool::NAME {
            return Ok(match render_tool::receipt(&arguments, &mut self.renders) {
                Ok(receipt) => success(receipt, false),
                Err(message) => tool_error(envelope(v2_tools::invalid(message), "not_run", None)),
            });
        }
        if let Some(tool) = settings_tools::find(name) {
            return Ok(tool.call(&self.backend, &arguments));
        }
        if name == super::energy::MCP_STATUS_TOOL {
            return Ok(match super::energy::mcp_arguments(&arguments) {
                Ok(()) => {
                    let app = self
                        .backend
                        .app(
                            super::energy::APP_STATUS_METHOD,
                            json!({}),
                            super::app::READ_TIMEOUT,
                            None,
                            false,
                        )
                        .map(|report| super::energy::app_part(&report))
                        .map_err(|failure| super::energy::error_text(&failure.error));
                    let daemon = self.backend.daemon_line(super::energy::DAEMON_STATUS_COMMAND);
                    success(super::energy::report(app, daemon), false)
                }
                Err(message) => tool_error(envelope(v2_tools::invalid(message), "not_run", None)),
            });
        }
        if let Some(tool) = keybinding_tools::find(name) {
            return Ok(match tool.params(&arguments) {
                Ok(params) => {
                    match self.backend.app(
                        tool.method,
                        params,
                        super::app::READ_TIMEOUT,
                        None,
                        false,
                    ) {
                        Ok(value) => success(value, false),
                        Err(failure) => failure_result(failure),
                    }
                }
                Err(message) => tool_error(envelope(v2_tools::invalid(message), "not_run", None)),
            });
        }
        if self.actions.find(name).is_none() {
            self.refresh_actions();
        }
        let actions = self.actions.clone();
        let Some(tool) = actions.find(name) else {
            return Err((-32602, format!("unknown tool: {name}")));
        };
        Ok(self.call_action(tool, &arguments))
    }

    /// One request from a running `cmux_exec` script: a tool call through
    /// `call`, so a script has the rights of a direct call, or a docs search.
    fn script_request(
        &mut self,
        request: code_mode::Request,
        tools: &mut Option<Vec<Value>>,
        images: &mut Vec<Value>,
    ) -> Value {
        match request {
            code_mode::Request::Call { name, .. } if name == code_mode::EXEC => {
                code_mode::script_answer(
                    Err((-32602, "a script cannot start another script".into())),
                    images,
                )
            }
            code_mode::Request::Call { name, arguments } => {
                let result = self.call(&json!({"name": name, "arguments": arguments}));
                code_mode::script_answer(result, images)
            }
            code_mode::Request::Docs { query } => {
                let tools = match tools {
                    Some(tools) => tools,
                    None => tools.insert(self.list()),
                };
                let mut arguments = Map::new();
                arguments.insert("query".into(), Value::String(query));
                let mut value = code_mode::docs(tools, &arguments)
                    .unwrap_or_else(|message| json!({"error": message}));
                self.add_server_rules(&mut value);
                value
            }
        }
    }

    fn call_v2(&self, tool: &v2_tools::V2Tool, arguments: &Map<String, Value>) -> Value {
        let arguments = match self.place_beside(tool, arguments) {
            Ok(arguments) => arguments,
            Err(answer) => return answer,
        };
        let mut call = match tool.plan(&arguments) {
            Ok(call) => call,
            Err(error) => return tool_error(envelope(error, "not_run", None)),
        };
        if let Err(error) = self.place_caller(&mut call) {
            return tool_error(envelope(error, "not_run", None));
        }
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
        match self.backend.app("snapshot.get", json!({}), super::app::READ_TIMEOUT, None, false) {
            Ok(snapshot) => {
                success(json!({ "items": snapshot.field("topology").field("windows") }), false)
            }
            Err(failure) => failure_result(failure),
        }
    }

    fn call_action(&self, tool: &ActionTool, arguments: &Map<String, Value>) -> Value {
        let (params, key) = match tool.run_params(arguments) {
            Ok(run) => run,
            Err(error) => return tool_error(envelope(error, "not_run", None)),
        };
        let timeout = super::app::waiting_run_timeout(&tool.cli_name);
        match self.backend.app("action.run", params, timeout, key.as_deref(), true) {
            Ok(value) => success(value, true),
            Err(failure) => failure_result(failure),
        }
    }
}

fn initialize(params: &Value, list_changed: bool, code_mode: bool) -> Value {
    let requested = params["protocolVersion"].as_str();
    let version = PROTOCOL_VERSIONS
        .iter()
        .find(|version| Some(**version) == requested)
        .or_else(|| PROTOCOL_VERSIONS.first());
    json!({
        "protocolVersion": version,
        "capabilities": {"tools": {"listChanged": list_changed}},
        "serverInfo": {"name": "cmux", "title": "cmux", "version": env!("CARGO_PKG_VERSION")},
        "instructions": format!(
            "{} {}",
            if code_mode { code_mode::INSTRUCTIONS } else { INSTRUCTIONS },
            acpmux::agent_tools::ASKING_RULE
        ),
    })
}
