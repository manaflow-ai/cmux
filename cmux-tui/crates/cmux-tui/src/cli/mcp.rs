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

use cmux_json::JsonSet as _;

mod action_tools;
mod agent_dispatch_tools;
mod agent_events_tool;
mod agent_tools;
mod agent_wait_tool;
mod app_op_tools;
mod automation_tools;
mod browser_tools;
use super::caller_scope;
mod chat_tools;
mod cloud_connect_tools;
mod cloud_repo_tools;
mod cloud_tools;
mod code_mode;
mod config;
mod customize_kit_tools;
mod customize_library_tool;
mod customize_tools;
mod device_tools;
mod keybinding_tools;
mod keys_tools;
mod live_code_tools;
mod live_file;
mod md_deck;
mod messages;
mod off;
mod open_tool;
mod placement;
mod pptx_view;
mod remote_tools;
mod render_tool;
mod schema;
mod settings_tools;
mod slides_tool;
mod terminal_talk_tools;
#[cfg(test)]
mod tests;
mod tool_list;
mod transport;
mod upstream;
mod upstream_listing;
mod v2_tools;
mod video_tools;
mod watch;
mod workflow;
mod workflow_tools;

use std::collections::BTreeSet;
use std::io::{self, BufRead, Read, Write};
use std::path::PathBuf;
use std::time::{Duration, Instant};

use serde_json::{Map, Value, json};

use super::cloud_workspaces;
use super::command::RequestPlan;
use super::{GlobalArgs, OutputMode};
use action_tools::ActionTool;
use code_mode::computer_use::TERMINAL_AGENT_ENV;
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

pub(super) fn workflow_run(global: GlobalArgs, run_id: String, generation: u64) -> i32 {
    workflow::run(global, run_id, generation)
}

pub(super) fn workflow_command(global: GlobalArgs, arguments: Value) -> i32 {
    let output = global.output;
    let mut server = Server::new(LiveBackend { global }, None);
    server.allowed = allowed_tools(std::env::var_os(ALLOWED_TOOLS_ENV));
    match server.call(&json!({"name":workflow_tools::NAME,"arguments":arguments})) {
        Ok(result) if result.get("isError").and_then(Value::as_bool) == Some(true) => {
            super::wire::print_local_error(
                result.pointer("/structuredContent/error").unwrap_or(&Value::Null),
                output,
                1,
            )
        }
        Ok(result) => super::wire::print_local_success(
            result.get("structuredContent").unwrap_or(&Value::Null),
            output,
        ),
        Err((code, message)) => {
            super::wire::print_local_error(&json!({"code":code,"message":message}), output, 2)
        }
    }
}

/// `cmux cloud chat …` and `cmux cloud computer …` (cloud_agent.rs): the `cloud_*` tool `name`
/// with `arguments`, run by the same code as the MCP tool, answered as its tool result.
#[cfg(unix)]
pub(super) fn cloud_tool(global: GlobalArgs, name: &str, arguments: &Map<String, Value>) -> Value {
    let backend = LiveBackend { global };
    cloud_tools::run(&backend, name, arguments, super::app::action_origin()).unwrap_or_else(|| {
        tool_error(envelope(v2_tools::invalid(format!("no cloud tool {name}")), "not_run", None))
    })
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

/// The largest JSON-RPC line read from the client.
const MAX_MESSAGE_BYTES: usize = 8 << 20;
/// The largest tool result; a larger page is cut and says where to go on.
pub(super) const MAX_RESULT_BYTES: usize = 256 << 10;

const INSTRUCTIONS: &str = acpmux::agent_tools::prompt_sources::BASE_INSTRUCTIONS;

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
    /// One legacy daemon command (cmux Remote's `remote-host-*`).
    fn daemon(&self, _request: Value) -> Result<Value, CallFailure> {
        Err(CallFailure::local(
            FailureKind::NotRun,
            "daemon.unavailable",
            "this server cannot reach the daemon",
        ))
    }
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
    /// One `cmux automation WORDS…` verb, run by the CLI's own code
    /// (`automation_tools`); `idempotency_key` keys a Cloud mutation.
    fn automation(
        &self,
        _words: &[String],
        _idempotency_key: Option<&str>,
    ) -> Result<Value, CallFailure> {
        Err(CallFailure::local(
            FailureKind::NotRun,
            "automation.unavailable",
            "this server cannot reach the automation store",
        ))
    }

    /// The Cloud machine attached to the Chief this server runs for (its `engine.json`
    /// `computer`, `cloud_tools::CHIEF_ENGINE_ENV`): `cloud_computer`'s default machine.
    fn chief_computer(&self) -> Option<String> {
        cloud_tools::chief_computer_from_env()
    }

    /// One `cmux customize WORDS…` verb, run by the CLI's own code
    /// (`customize_tools`).
    fn customize(&self, _words: &[String]) -> Result<Value, CallFailure> {
        Err(CallFailure::local(
            FailureKind::NotRun,
            "customize.unavailable",
            "this server cannot reach the customization files",
        ))
    }

    /// Cloud chat repo actions run on the selected machine daemon.
    fn cloud_repo(&self, _action: &str, _args: Value) -> Result<Value, CallFailure> {
        Err(CallFailure::local(
            FailureKind::NotRun,
            "repo.unavailable",
            "Connect to the Cloud machine and retry.",
        ))
    }

    /// Daemon requests from another thread: `open {live}` reloads a changed file's
    /// tab from its watch thread (`live_file`). `None`: no live files.
    fn resource_sender(&self) -> Option<live_file::Sender> {
        None
    }
    /// One daemon request for `session` that may run on its own thread: a terminal wait
    /// does ([`Server::detached_wait`]), so the calls after it are not held behind it.
    /// `None`: this backend answers on the server's thread only.
    fn resource_job(&self, _session: Option<&str>) -> Option<ResourceJob> {
        None
    }
    /// `agents_wait` on its own thread, as [`Self::resource_job`]; `None`: on the server's.
    fn agent_wait_job(&self) -> Option<AgentWaitJob> {
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
    /// The terminal this server's client runs in (`CMUX_TUI_TERMINAL_ID`),
    /// for placing it without an app (placement.rs `daemon_caller`).
    fn caller_terminal(&self) -> Option<String> {
        std::env::var("CMUX_TUI_TERMINAL_ID").ok().filter(|id| !id.is_empty())
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

    /// Whether this server's default route is the session the cmux app owns
    /// (no `--session`, `--socket` or `--machine`), so `workspace_list` adds
    /// the app's Cloud workspaces.
    fn app_session(&self) -> bool {
        true
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

    /// A scoped chat read for agent waits. The session is routed by the same
    /// owner policy as a daemon read; the default does not guess another session.
    fn chat_in_session(
        &self,
        session: Option<&str>,
        command: &super::agents::chat::ChatCommand,
        idempotency_key: Option<&str>,
        origin: &str,
    ) -> Result<Value, CallFailure> {
        if session.is_some() {
            return Err(CallFailure::local(
                FailureKind::NotRun,
                "chat.unavailable",
                "this backend cannot route chats to another cmux session",
            ));
        }
        self.chat(command, idempotency_key, origin)
    }
}

/// A daemon request sent from its own thread ([`Backend::resource_job`]).
pub(super) type ResourceJob =
    Box<dyn FnOnce(RequestPlan, Vec<Prefix>) -> Result<Value, CallFailure> + Send>;
/// `agents_wait` run from its own thread ([`Backend::agent_wait_job`]).
pub(super) type AgentWaitJob =
    Box<dyn FnOnce(Map<String, Value>, Option<agent_wait_tool::Progress>) -> Value + Send>;

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
    fn app_session(&self) -> bool {
        self.global.session.is_none()
            && self.global.socket.is_none()
            && self.global.machine.is_none()
    }

    fn cloud_repo(&self, action: &str, args: Value) -> Result<Value, CallFailure> {
        super::cloud_repo::call(&self.global, action, args)
    }

    fn automation(
        &self,
        words: &[String],
        idempotency_key: Option<&str>,
    ) -> Result<Value, CallFailure> {
        let mut global = self.global.clone();
        global.output = OutputMode::Json;
        global.idempotency_key = idempotency_key.map(str::to_owned);
        super::automation::run_json(&global, words).map_err(|(error, unknown)| CallFailure {
            kind: if unknown { FailureKind::InProgress } else { FailureKind::Rejected },
            error,
            idempotency_key: idempotency_key.map(str::to_owned),
        })
    }

    #[cfg(unix)]
    fn customize(&self, words: &[String]) -> Result<Value, CallFailure> {
        super::customize::run_json(&self.global, words, "mcp").map_err(|error| CallFailure {
            kind: FailureKind::Rejected,
            error,
            idempotency_key: None,
        })
    }

    #[cfg(unix)]
    fn daemon(&self, mut request: Value) -> Result<Value, CallFailure> {
        if let Some(fields) = request.as_object_mut() {
            fields.insert("id".into(), json!(1));
        }
        super::remote_host::daemon_value(&self.global, &request)
            .map_err(remote_tools::daemon_failure)
    }

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

    fn resource_sender(&self) -> Option<live_file::Sender> {
        let global = self.global.clone();
        Some(std::sync::Arc::new(move |plan| transport::resource(&global, plan, &[])))
    }

    fn resource_job(&self, session: Option<&str>) -> Option<ResourceJob> {
        // A session this server cannot route to answers its refusal on the server's thread.
        let global = self.routed(session).ok()?;
        Some(Box::new(move |plan, prefixes| transport::resource(&global, plan, &prefixes)))
    }

    fn agent_wait_job(&self) -> Option<AgentWaitJob> {
        let backend = LiveBackend { global: self.global.clone() };
        Some(Box::new(move |arguments, progress| {
            agent_wait_tool::call(&backend, &arguments, progress)
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

    fn chat_in_session(
        &self,
        session: Option<&str>,
        command: &super::agents::chat::ChatCommand,
        idempotency_key: Option<&str>,
        origin: &str,
    ) -> Result<Value, CallFailure> {
        super::agents::chat::run(&self.routed(session)?, command, idempotency_key, origin)
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
        _ => super::scope_usage_failure(
            global.output,
            "mcp",
            &super::unknown_words("mcp", args),
            usage.strip_prefix("usage: ").unwrap_or(usage),
        ),
    }
}

/// The env acpmux gives the cmux MCP server of an agent chat
/// (`CMUX_AGENT_SESSION`, acpmux `agent_tools.rs`).
const AGENT_SESSION_ENV: &str = "CMUX_AGENT_SESSION";

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

/// Who started this `serve`, by the env acpmux gives the server.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Caller {
    /// A client outside cmux's agent chats (a terminal agent, another app).
    Outside,
    /// An agent chat cmux started (`CMUX_AGENT_SESSION` set): also a server a
    /// `cmux` entry in the person's own agent config starts inside a chat,
    /// which inherits the chat's env or gets these keys from the chat's launch
    /// (`acpmux::agent_tools::person_entry_env`), and one a Codex started in a
    /// cmux terminal starts, which the shim gives `CMUX_AGENT_TOOLS_ANSWER`.
    AgentChat,
    /// A Chief turn: an agent chat whose preset names its cmux tools
    /// (`CMUX_MCP_TOOLS`).
    ChiefTurn,
}

/// Why `serve` must not run with the settings file at `path`, or `None`
/// when it is on for this caller. The caller is told by the env: acpmux puts
/// `CMUX_AGENT_SESSION` (and the Chief's `CMUX_MCP_TOOLS`) in the `cmux`
/// server's own `env` (`agent_tools::for_session`), so it arrives whatever
/// env the harness passes a stdio server (Codex passes only an allowlist and
/// the server's own); a server a person's own entry starts in a Claude chat
/// inherits the chat's. The env is no security boundary: the same process
/// can run the cmux CLI. The setting is the person's switch for their
/// agents, not a sandbox.
pub(super) fn refusal(path: &std::path::Path) -> Option<String> {
    let set = |key: &str| std::env::var_os(key).is_some_and(|v| !v.is_empty());
    // An agent cmux started: a chat (`CMUX_AGENT_SESSION`), or a Codex cmux started whose
    // person's own `cmux` entry it told the answer (`CMUX_AGENT_TOOLS_ANSWER`; the terminal shim).
    let chat = set(AGENT_SESSION_ENV);
    let caller = match (chat, std::env::var_os(ALLOWED_TOOLS_ENV).is_some()) {
        (true, true) => Caller::ChiefTurn,
        (true, false) => Caller::AgentChat,
        _ if set(acpmux::agent_tools::TOOLS_ANSWER_ENV) => Caller::AgentChat,
        _ => Caller::Outside,
    };
    let started_with = match std::env::var(acpmux::agent_tools::TOOLS_ANSWER_ENV).as_deref() {
        Ok("on") => Some(true),
        Ok("off") => Some(false),
        _ => None,
    };
    refusal_for(path, caller, started_with)
}

/// [`refusal`] for `caller`. `"mcp": {"enabled": false}` turns it off for
/// everyone. An agent chat follows the setting "cmux Tools for Agents in
/// cmux" (`agents.cmuxMcp`, on unless `off`), whatever else the file says,
/// so a `cmux` entry an older cmux wrote into the person's own config is the
/// off server in every chat while the setting is off. A chat cmux-next
/// started from another Mac (a peer link, a Cloud VM, a headless daemon)
/// follows that Mac's setting, `started_with`
/// (`acpmux::agent_tools::TOOLS_ANSWER_ENV`), over this machine's file. A
/// Chief turn, cmux's own orchestrator, is served unless the file says
/// `false`. Any other client needs `mcp.enabled` true, or unset with
/// `agents.cmuxMcp` on.
fn refusal_for(
    path: &std::path::Path,
    caller: Caller,
    started_with: Option<bool>,
) -> Option<String> {
    let messages = messages::messages();
    let shown = path.display().to_string();
    let setting = match config::setting(path) {
        Ok(setting) => setting,
        Err(error) => return Some(messages.config_invalid.replace("{error}", &error)),
    };
    if setting == Some(false) {
        return Some(messages.switched_off.replace("{path}", &shown));
    }
    let yes = started_with.unwrap_or_else(|| {
        cmux_tui_core::user_settings::AgentsCmuxMcp::from_config_file(path)
            == cmux_tui_core::user_settings::AgentsCmuxMcp::On
    });
    match caller {
        Caller::ChiefTurn => None,
        Caller::AgentChat if yes => None,
        Caller::Outside if setting == Some(true) => None,
        Caller::AgentChat | Caller::Outside => Some(messages.disabled.replace("{path}", &shown)),
    }
}

/// The settings file, and whether it turns `serve` on for a client outside
/// a cmux agent chat (Claude Code or Codex started in a terminal), or why
/// it cannot be read (`cmux setup mcp`).
pub(super) fn outside_chats() -> (PathBuf, Result<bool, String>) {
    let path = config::path();
    let on = config::setting(&path).map(|setting| setting == Some(true));
    (path, on)
}

fn serve(global: GlobalArgs, code_mode: bool) -> i32 {
    let path = config::path();
    let terminal_agent = std::env::var_os(TERMINAL_AGENT_ENV).is_some_and(|v| v == "1");
    let mut config = Some(path.clone());
    let mut computer_use_only = false;
    if let Some(message) = refusal(&path) {
        if !terminal_agent {
            // Still complete the handshake and say why, so the agent shows the
            // reason instead of a closed connection; no cmux tool runs (`off`).
            eprintln!("cmux: {message}");
            let _ = crate::restore_default_termination_signals();
            acpmux::parent_watch::exit_with_parent();
            let output = watch::Output::new(io::stdout());
            return off::Off::new(message).run(io::stdin().lock(), &output);
        }
        // A terminal agent with the cmux tools off: Computer Use only.
        computer_use_only = true;
        config = None;
    }
    // Closed stdin, SIGTERM (not hidden by the blocking read) or the client's death end it.
    let _ = crate::restore_default_termination_signals();
    acpmux::parent_watch::exit_with_parent();
    let output = watch::Output::new(io::stdout());
    if !computer_use_only {
        watch::spawn(global.clone(), output.clone());
    }
    let mut server = Server::new(LiveBackend { global }, config);
    server.list_changed = !computer_use_only;
    server.code_mode = code_mode;
    server.computer_use_only = computer_use_only;
    server.allowed = allowed_tools(std::env::var_os(ALLOWED_TOOLS_ENV));
    server.upstreams = upstream::specs(std::env::var_os(upstream::ENV))
        .into_iter()
        .map(|spec| upstream::Proxied::new(upstream::Upstream::new(spec)))
        .collect();
    // An idle chat's other servers end (`upstream::IDLE_STOP`) while the harness keeps this one.
    let idle = server.upstreams.iter().map(|p| std::sync::Arc::downgrade(&p.inner)).collect();
    if let Err(error) = upstream::stop_idle(idle, upstream::IDLE_STOP) {
        eprintln!("cmux mcp: idle servers keep running: no thread: {error}");
    }
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

/// The session and terminal a planned terminal call names: where
/// [`Server::wait_past_typed`] remembers what was typed.
fn typed_key(call: &v2_tools::CallPlan) -> Option<(Option<String>, String)> {
    let terminal = call.plan.params.get("terminal")?.as_str()?;
    Some((call.session.clone(), terminal.to_owned()))
}

/// A history answer's rows as one `text` of lines (`{start, next, text}`): each unstyled
/// row is one run, so the row's text is its runs joined.
fn history_text(mut value: Value) -> Value {
    let Some(rows) = value.get("rows").and_then(Value::as_array) else { return value };
    let text = rows
        .iter()
        .map(|row| {
            row.get("runs")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(|run| run.get("text").and_then(Value::as_str))
                .collect::<String>()
        })
        .collect::<Vec<_>>()
        .join("\n");
    if let Some(object) = value.as_object_mut() {
        object.remove("rows");
        object.insert("text".into(), json!(text));
    }
    value
}

/// The stdio JSON-RPC server: one request per line, answered in order, but for a proxied
/// server's call and a wait (`Server::detached_wait`), which answer from their own threads.
pub(super) struct Server<B> {
    backend: B,
    /// The settings file to check before every call; `None` lists only.
    config: Option<PathBuf>,
    actions: Vec<ActionTool>,
    action_exclusions: Vec<Exclusion>,
    actions_loaded: bool,
    /// Installed extensions' ops offered to agents (`app_op_tools`), as last read.
    app_ops: Vec<app_op_tools::AppOpTool>,
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
    /// Only the workflow host adapter can install this one-use operation.
    /// Script arguments never create an authenticated daemon activity.
    workflow_activity: Option<workflow::Internal>,
    /// The agent chat's other MCP servers (`upstream`), behind this one.
    upstreams: Vec<upstream::Proxied>,
    /// Only cmux Computer Use (`cu_*`, plus `cmux_exec` and `cmux_docs` to
    /// script it): a terminal agent while the cmux tools are off
    /// ([`TERMINAL_AGENT_ENV`]).
    computer_use_only: bool,
    /// While a `cmux_exec` script runs: its time limit, which also bounds a
    /// proxied call it makes (the script holds this thread).
    call_cap: Option<Duration>,
    /// While a `cmux_exec` script runs: the `_meta` its calls pass on (`upstream::passed_meta`).
    call_meta: Option<Value>,
    /// Where `run` writes, for a call's `notifications/progress`.
    notes: Option<watch::Output>,
    /// The ids `render` returned in this process: a render may update only one of these.
    renders: std::collections::HashSet<String>,
    /// The last text `terminal_input_write` typed into each terminal (by the session and
    /// terminal the call named), for [`Self::wait_past_typed`].
    typed: std::cell::RefCell<std::collections::HashMap<(Option<String>, String), String>>,
    /// The files `open {live}` reloads on change, started with the first.
    live_files: std::cell::RefCell<Option<live_file::Watches>>,
    /// The decks `open` previews, served on loopback, started with the first.
    decks: std::cell::RefCell<Option<pptx_view::Decks>>,
}

impl<B: Backend> Server<B> {
    pub(super) fn new(backend: B, config: Option<PathBuf>) -> Self {
        Self {
            backend,
            config,
            actions: Vec::new(),
            action_exclusions: Vec::new(),
            actions_loaded: false,
            app_ops: Vec::new(),
            list_changed: false,
            initialized: false,
            code_mode: false,
            script_limits: code_mode::Limits::default(),
            allowed: None,
            workflow_activity: None,
            upstreams: Vec::new(),
            computer_use_only: false,
            call_cap: None,
            call_meta: None,
            typed: std::cell::RefCell::default(),
            live_files: std::cell::RefCell::default(),
            decks: std::cell::RefCell::default(),
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
                chat_tools::remember_client(&params);
                // Codex keeps its own Computer Use first: the folded cu_* tools say so.
                let defer = acpmux::computer_use::mcp::defers_to_own_computer_use(&params);
                for proxied in &mut self.upstreams {
                    proxied.set_defer(defer);
                }
                if self.computer_use_only {
                    return Some(json!({"jsonrpc": "2.0", "id": id,
                        "result": code_mode::computer_use::initialize(&params, defer, self.code_mode)}));
                }
                let code_mode = self.code_mode && self.allowed.is_none();
                Ok(initialize(&params, self.list_changed, code_mode))
            }
            "ping" => Ok(json!({})),
            "tools/list" if self.code_mode && self.allowed.is_none() => {
                // cmux_workflow is not listed on its own: no chat called it in 172 NEXT
                // transcripts while its schema cost every Claude chat about 450 tokens of
                // deferred listing (2026-11-09 audit). A script still reaches it as
                // `cmux.cmux_workflow`, and `cmux workflow` calls it directly.
                Ok(json!({ "tools": code_mode::descriptors(&self.list(), self.computer_use_only) }))
            }
            "tools/list" => Ok(json!({ "tools": self.list() })),
            "tools/call" => {
                // A proxied server's call runs on its own thread, so one that
                // waits (a secret card) never holds up the other tools. A wait
                // (`terminal_wait`, `terminal_wait_exit`, `agents_wait`) holds its answer up
                // to minutes: it runs on its own thread too, so a call sent after it is
                // answered meanwhile instead of queued behind it (head-of-line blocking).
                if let Some(output) = self.notes.clone()
                    && let Some(job) = self.detached_job(&params)
                {
                    std::thread::spawn(move || {
                        let response = json!({"jsonrpc": "2.0", "id": id, "result": job()});
                        let _ = output.send(&response);
                    });
                    return None;
                }
                self.call(&params)
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
        if !self.computer_use_only {
            self.refresh_actions();
            self.refresh_app_ops();
        }
        for proxied in &mut self.upstreams {
            proxied.refresh();
        }
        self.listed()
    }

    /// [`Self::list`] from the actions and proxied tools as last read,
    /// asking nothing again.
    fn listed(&self) -> Vec<Value> {
        let mut tools = tool_list::first_party();
        tools.extend(self.actions.iter().map(ActionTool::descriptor_json));
        // An extension's op never takes a cmux tool's name.
        let taken = tools
            .iter()
            .filter_map(|tool| tool["name"].as_str().map(str::to_owned))
            .collect::<BTreeSet<_>>();
        tools.extend(
            self.app_ops
                .iter()
                .filter(|tool| !taken.contains(&tool.name))
                .map(app_op_tools::AppOpTool::descriptor_json),
        );
        for proxied in &self.upstreams {
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
        if self.computer_use_only {
            tools
                .retain(|tool| tool["name"].as_str().is_some_and(code_mode::computer_use::is_tool));
        }
        tools
    }

    fn refresh_actions(&mut self) {
        match self.backend.app("action.list", json!({}), super::app::READ_TIMEOUT, None, false) {
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

    /// Reads the offered extension ops again; a daemon that does not answer
    /// keeps the last list (none before the first answer).
    fn refresh_app_ops(&mut self) {
        if let Some(app_ops) = app_op_tools::read(&self.backend) {
            self.app_ops = app_ops;
        }
    }

    /// The offered extension op called `name`, read again when it is not in
    /// the last list (an app installed since).
    fn app_op(&mut self, name: &str) -> Option<app_op_tools::AppOpTool> {
        if !self.app_ops.iter().any(|tool| tool.name == name) {
            self.refresh_app_ops();
        }
        self.app_ops.iter().find(|tool| tool.name == name).cloned()
    }

    fn tool_refusal(&self, name: &str) -> Option<Value> {
        if let Some(path) = &self.config
            && let Some(message) = refusal(path)
        {
            let error = json!({
                "code": "mcp.disabled",
                "message": message,
                "details": {},
                "retryable": false,
            });
            return Some(tool_error(envelope(error, "not_run", None)));
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
            return Some(tool_error(envelope(error, "not_run", None)));
        }
        if self.computer_use_only
            && let Some(error) = code_mode::computer_use::out_of_scope(name)
        {
            return Some(tool_error(envelope(error, "not_run", None)));
        }
        None
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
        if let Some(refusal) = self.tool_refusal(name) {
            return Ok(refusal);
        }
        if name == "cmux_workflow"
            && let Some(operation) = self.workflow_activity.take()
        {
            return Ok(workflow::internal_call(&self.backend, operation));
        }
        if name == workflow_tools::NAME {
            // A script's own call carries no `_meta`: it passes on the script's (`call_meta`).
            let meta = upstream::passed_meta(params).or_else(|| self.call_meta.clone());
            return Ok(workflow_tools::call(&self.backend, &arguments, meta));
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
            self.call_meta = upstream::passed_meta(params);
            let answered = code_mode::exec(&arguments, self.script_limits, &mut |request| {
                self.script_request(request, &mut tools, &mut images)
            });
            self.call_cap = None;
            self.call_meta = None;
            let mut result = answered.unwrap_or_else(|message| {
                tool_error(envelope(v2_tools::invalid(message), "not_run", None))
            });
            code_mode::computer_use::attach_images(&mut result, images);
            return Ok(result);
        }
        if let Some(mut job) = self.proxied_tool(name, &arguments) {
            // A script's own call carries no `_meta`: it passes on the script's (`call_meta`).
            job.meta = upstream::passed_meta(params).or(job.meta);
            return Ok(job.run(self.call_cap));
        }
        if let Some(result) = chat_tools::call(name, &arguments) {
            return Ok(result);
        }
        if let Some(result) = live_code_tools::call(name, &arguments) {
            return Ok(result);
        }
        if let Some(result) = cloud_repo_tools::call(&self.backend, name, &arguments) {
            return Ok(result);
        }
        if let Some(result) = cloud_tools::call(&self.backend, name, &arguments) {
            return Ok(result);
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
        if let Some(result) = self.call_video(name, &arguments) {
            return Ok(result);
        }
        if keys_tools::owns(name) {
            return Ok(self.call_keys(name, &arguments));
        }
        if name == open_tool::NAME {
            if !self.actions_loaded {
                self.refresh_actions();
            }
            return Ok(self.call_open(&arguments));
        }
        if name == slides_tool::NAME {
            if !self.actions_loaded {
                self.refresh_actions();
            }
            return Ok(self.call_slides(&arguments));
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
        if let Some(result) = automation_tools::call(&self.backend, name, &arguments) {
            return Ok(result);
        }
        if let Some(result) = customize_library_tool::call(&self.backend, name, &arguments) {
            return Ok(result);
        }
        if let Some(result) = customize_kit_tools::call(&self.backend, name, &arguments) {
            return Ok(result);
        }
        if let Some(result) = customize_tools::call(&self.backend, name, &arguments) {
            return Ok(result);
        }
        if let Some(result) = cloud_connect_tools::call(name, &arguments) {
            return Ok(result);
        }
        if let Some(result) = device_tools::call(name, &arguments) {
            return Ok(result);
        }
        if let Some(tool) = remote_tools::find(name) {
            return Ok(tool.call(&self.backend, &arguments));
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
        if !self.actions.iter().any(|tool| tool.name == name) {
            self.refresh_actions();
        }
        if !self.computer_use_only
            && !self.actions.iter().any(|tool| tool.name == name)
            && let Some(tool) = self.app_op(name)
        {
            return Ok(tool.call(&self.backend, &arguments));
        }
        let Some(tool) = self.actions.iter().find(|tool| tool.name == name) else {
            return Err((-32602, self.unknown_tool(name)));
        };
        Ok(self.call_action(tool, &arguments))
    }

    /// `unknown tool: NAME`, naming the nearest tool `tools/list` offers when
    /// one is close (`acpmux::mcp_hint`): in code mode only `cmux_exec`.
    fn unknown_tool(&self, name: &str) -> String {
        if self.code_mode && self.allowed.is_none() {
            return acpmux::mcp_hint::unknown_tool(name, [code_mode::EXEC]);
        }
        let listed = self.listed();
        acpmux::mcp_hint::unknown_tool(name, listed.iter().filter_map(|tool| tool["name"].as_str()))
    }

    /// A terminal tool called with a `tab` and no `terminal`, or a tab or pane given as
    /// `terminal`: the terminal that tab (or the pane's shown tab) shows, its `content_id`. Models name a terminal by the tab id they listed
    /// (tests/tool-evals: 39 "needs terminal" errors in one 9-model panel). Other calls
    /// pass unchanged.
    fn terminal_of_tab<'a>(
        &self,
        tool: &v2_tools::V2Tool,
        arguments: &'a Map<String, Value>,
    ) -> Result<std::borrow::Cow<'a, Map<String, Value>>, Value> {
        // Only a tool that needs a terminal: `terminal_list` takes `tab` as a filter.
        if !tool.needs_terminal() {
            return Ok(std::borrow::Cow::Borrowed(arguments));
        }
        // The tab that names the terminal: `tab`, or a `terminal` that is really a tab, by
        // its id (`tab_…`) or by a name with no scope above it (`terminal: "eval"` for the
        // tab named eval, which the daemon's terminal name selector cannot find without a
        // tab). tests/tool-evals m1: three models named a terminal by its tab.
        let terminal_arg = arguments.get("terminal").and_then(Value::as_str);
        let scoped =
            ["workspace", "screen", "pane", "tab"].iter().any(|key| arguments.contains_key(*key));
        let tab_like = terminal_arg.filter(|value| {
            let bare = value.rsplit_once(':').map_or(*value, |(_, id)| id);
            bare.starts_with("tab_")
                || bare.starts_with("pane_")
                || (!scoped
                    && !bare.starts_with("term_")
                    && !matches!(bare, "current" | "focused" | "caller"))
        });
        let tab = match (arguments.get("tab").and_then(Value::as_str), terminal_arg) {
            (Some(tab), None) => tab,
            (None, Some(_)) if tab_like.is_some() => tab_like.unwrap_or_default(),
            _ => return Ok(std::borrow::Cow::Borrowed(arguments)),
        };
        // A `<session>:tab_…` names another session: the terminal gets the same prefix.
        let session = tab.rsplit_once(':').map(|(session, _)| session.to_owned());
        let mut lookup = Map::new();
        for key in ["session", "workspace", "screen", "pane"] {
            if let Some(value) = arguments.get(key) {
                lookup.insert(key.into(), value.clone());
            }
        }
        lookup.insert("tab".into(), Value::String(tab.to_owned()));
        let Some(tab_get) = v2_tools::find("tab_get") else {
            return Ok(std::borrow::Cow::Borrowed(arguments));
        };
        // A `tab_…` id, or a name under a named workspace, screen or pane, resolves with
        // tab_get. A name with no scope does not: the daemon finds a tab name only under
        // its pane, so the session's tabs are listed and the name is used only when
        // exactly one tab has it.
        let bare = tab.rsplit_once(':').map_or(tab, |(_, id)| id);
        let under_scope =
            ["workspace", "screen", "pane"].iter().any(|key| arguments.contains_key(*key));
        let record = if bare.starts_with("pane_") {
            // A pane named where a terminal goes (`terminal: n.pane.id` after
            // pane_neighbor_get, tests/tool-evals m1): the terminal of the tab it shows.
            let Some(tab_list) = v2_tools::find("tab_list") else {
                return Ok(std::borrow::Cow::Borrowed(arguments));
            };
            let mut list = Map::new();
            if let Some(session) = arguments.get("session") {
                list.insert("session".into(), session.clone());
            }
            list.insert("pane".into(), Value::String(tab.to_owned()));
            let answer = self.call_v2(tab_list, &list);
            if answer.get("isError").and_then(Value::as_bool) == Some(true) {
                return Err(answer);
            }
            let items = answer
                .pointer("/structuredContent/items")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default();
            let shown = match items.as_slice() {
                [only] => Some(only),
                items => items.iter().find(|item| item["focused"] == true),
            };
            let Some(shown) = shown else {
                return Ok(std::borrow::Cow::Borrowed(arguments));
            };
            shown.clone()
        } else if bare.starts_with("tab_") || under_scope {
            let answer = self.call_v2(tab_get, &lookup);
            if answer.get("isError").and_then(Value::as_bool) == Some(true) {
                return Err(answer);
            }
            let record = answer.get("structuredContent").unwrap_or(&Value::Null);
            record.get("value").unwrap_or(record).clone()
        } else {
            let Some(tab_list) = v2_tools::find("tab_list") else {
                return Ok(std::borrow::Cow::Borrowed(arguments));
            };
            let mut list = Map::new();
            // The call's session, else the `<session>:` the name carried.
            if let Some(session) =
                arguments.get("session").cloned().or_else(|| session.clone().map(Value::String))
            {
                list.insert("session".into(), session);
            }
            list.insert("limit".into(), json!(500));
            let answer = self.call_v2(tab_list, &list);
            let items = answer
                .pointer("/structuredContent/items")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default();
            let named: Vec<Value> =
                items.into_iter().filter(|item| item["name"].as_str() == Some(bare)).collect();
            // No tab, or several, by that name: the daemon judges it as a terminal name.
            let [only] = named.as_slice() else {
                return Ok(std::borrow::Cow::Borrowed(arguments));
            };
            only.clone()
        };
        let record = &record;
        let Some(terminal) = record["content_id"].as_str().filter(|id| id.starts_with("term_"))
        else {
            return Err(tool_error(envelope(
                v2_tools::invalid(format!(
                    "{} needs terminal: that tab shows no terminal",
                    tool.name
                )),
                "not_run",
                None,
            )));
        };
        let terminal = match session {
            Some(session) => format!("{session}:{terminal}"),
            None => terminal.to_owned(),
        };
        let mut with_terminal = arguments.clone();
        for key in ["tab", "pane", "screen", "workspace"] {
            with_terminal.remove(key);
        }
        with_terminal.insert("terminal".into(), Value::String(terminal));
        Ok(std::borrow::Cow::Owned(with_terminal))
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
            code_mode::Request::ActivityStart { .. } | code_mode::Request::ActivityWait { .. } => {
                json!({"ok": false, "message": "workflow activities require a daemon-owned run"})
            }
            code_mode::Request::Call { name, .. } if name == code_mode::EXEC => {
                code_mode::script_answer(
                    Err((-32602, "a script cannot start another script".into())),
                    images,
                )
            }
            code_mode::Request::Call { name, mut arguments } => {
                code_mode::computer_use::script_arguments(&name, &mut arguments);
                let mut result = self.call(&json!({"name": name, "arguments": arguments}));
                // A guessed name (`context`, `terminal_send`) gets the tools
                // a docs search for it finds, so the next call can be right
                // (tests/tool-evals, 2026-10-27).
                if let Err((_, message)) = &mut result
                    && message.starts_with("unknown tool")
                    && !message.contains("; did you mean")
                {
                    let tools = tools.get_or_insert_with(|| self.list());
                    let near = code_mode::nearest_names(tools, &name);
                    if !near.is_empty() {
                        message.push_str(&format!("; did you mean {}?", near.join(", ")));
                    }
                }
                code_mode::computer_use::script_answer(&name, result, images)
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
        // `workspace_list {machine}`: one Cloud machine's workspaces, from the app.
        let mut arguments = std::borrow::Cow::Borrowed(arguments);
        let mut cloud = tool.wire == "workspace.list";
        if cloud && let Some(machine) = arguments.to_mut().remove("machine") {
            match machine.as_str().filter(|machine| !machine.is_empty()) {
                Some("current" | "local") => cloud = false,
                Some(machine) => return self.cloud_workspaces(machine, &arguments),
                None => {
                    return tool_error(envelope(
                        v2_tools::invalid("machine must be a non-empty string"),
                        "not_run",
                        None,
                    ));
                }
            }
        }
        let (arguments, mut call) = match self.plan_v2(tool, &arguments) {
            Ok(planned) => planned,
            Err(answer) => return answer,
        };
        let page = call.page;
        // History an agent reads is plain lines: `styled` (colors and attributes per run)
        // defaults to true in the daemon, and a 300-line read was 88k characters
        // (tests/tool-evals r13a). Asked for `styled`, the rows come as the daemon sends them.
        let plain_history =
            tool.wire == "terminal.history.read" && !arguments.contains_key("styled");
        if plain_history && let Some(params) = call.plan.params.as_object_mut() {
            params.insert("styled".into(), json!(false));
        }
        let typed = self.wait_past_typed(tool, &mut call);
        let wrote = (tool.wire == "terminal.input.write")
            .then(|| {
                typed_key(&call)
                    .zip(call.plan.params.get("text").and_then(Value::as_str).map(str::to_owned))
            })
            .flatten();
        let call_session = call.session.clone();
        // A terminal wait that ran out of time says `timed_out`, as the CLI's does.
        let wait = super::wire::wait_timeout::Wait::of(&call.plan);
        let answer = self.backend.resource(call.session.as_deref(), call.plan, &call.prefixes);
        match answer.map(|mut value| {
            if let Some(wait) = &wait {
                wait.mark(&mut value);
            }
            value
        }) {
            Ok(value) if typed.is_some() => success(
                {
                    let mut value = value;
                    if let (Some(note), Some(object)) = (typed, value.as_object_mut()) {
                        object.insert("note".into(), json!(note));
                    }
                    value
                },
                tool.mutation,
            ),
            Ok(value) if wrote.is_some() => {
                if let Some((key, text)) = wrote {
                    self.typed.borrow_mut().insert(key, text);
                }
                success(value, tool.mutation)
            }
            Ok(value) if plain_history => success(history_text(value), tool.mutation),
            // The session the app owns lists the app's Cloud workspaces too.
            Ok(value) if cloud && call_session.is_none() && self.backend.app_session() => success(
                {
                    let rows =
                        self.cloud_machines().map(|machines| cloud_workspaces::rows(&machines));
                    let value = cloud_workspaces::append(value, rows.unwrap_or_default());
                    match page {
                        Some(page) => v2_tools::paginate(value, page),
                        None => value,
                    }
                },
                tool.mutation,
            ),
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

    /// A v2 call's arguments as placed and resolved, and its request; `Err`: the answer
    /// that refuses it.
    fn plan_v2(
        &self,
        tool: &v2_tools::V2Tool,
        arguments: &Map<String, Value>,
    ) -> Result<(Map<String, Value>, v2_tools::CallPlan), Value> {
        let arguments = self.place_beside(tool, arguments)?;
        let arguments = self.terminal_of_tab(tool, &arguments)?;
        let arguments = self.tab_move_destination(tool, &arguments)?;
        let mut call =
            tool.plan(&arguments).map_err(|error| tool_error(envelope(error, "not_run", None)))?;
        self.place_caller(&mut call)
            .map_err(|error| tool_error(envelope(error, "not_run", None)))?;
        Ok((arguments.into_owned(), call))
    }

    /// A top-level wait call as a job for its own thread: `terminal_wait` and
    /// `terminal_wait_exit` planned here (their typed-command anchoring included), then
    /// sent from the job; `agents_wait` whole. `None`: any other call, a refused one, or a
    /// backend that answers on this thread only; [`Self::call`] answers it as before.
    /// The call's job when it runs off the server's thread: a proxied server's call, or a wait.
    fn detached_job(&mut self, params: &Value) -> Option<Box<dyn FnOnce() -> Value + Send>> {
        if let Some(job) = self.proxied_job(params) {
            return Some(Box::new(move || job.run(None)));
        }
        self.detached_wait(params)
    }

    fn detached_wait(&self, params: &Value) -> Option<Box<dyn FnOnce() -> Value + Send>> {
        let name = params["name"].as_str()?;
        let arguments = match params.get("arguments") {
            None | Some(Value::Null) => Map::new(),
            Some(Value::Object(arguments)) => arguments.clone(),
            Some(_) => return None,
        };
        if self.tool_refusal(name).is_some() {
            return None;
        }
        if name == agent_wait_tool::NAME {
            let job = self.backend.agent_wait_job()?;
            let progress = agent_wait_tool::Progress::requested(params, self.notes.as_ref());
            return Some(Box::new(move || job(arguments, progress)));
        }
        let tool = v2_tools::find(name)?;
        if !matches!(
            tool.operation,
            cmux_tui_core::resource::ResourceOperation::TerminalWait
                | cmux_tui_core::resource::ResourceOperation::TerminalWaitExit
        ) {
            return None;
        }
        // A refusal while planning is answered on this thread, as before.
        let (_, mut call) = self.plan_v2(tool, &arguments).ok()?;
        let job = self.backend.resource_job(call.session.as_deref())?;
        let typed = self.wait_past_typed(tool, &mut call);
        let wait = super::wire::wait_timeout::Wait::of(&call.plan);
        let mutation = tool.mutation;
        Some(Box::new(move || match job(call.plan, call.prefixes) {
            Ok(mut value) => {
                if let Some(wait) = &wait {
                    wait.mark(&mut value);
                }
                if let (Some(note), Some(object)) = (typed, value.as_object_mut()) {
                    object.insert("note".into(), json!(note));
                }
                success(value, mutation)
            }
            Err(failure) => failure_result(failure),
        }))
    }

    /// The app's Cloud machines (`cloud.machines`), or `None` when the app has
    /// none to give (no app, Cloud off, an older app): the list stands alone.
    fn cloud_machines(&self) -> Option<Vec<Value>> {
        let reply = self
            .backend
            .app("cloud.machines", json!({}), CLOUD_MACHINES_TIMEOUT, None, false)
            .ok()?;
        cloud_workspaces::machines_of(&reply)
    }

    /// `workspace_list {machine}` for a Cloud machine: its workspaces as the
    /// app's store has them, one page as the daemon's list pages.
    fn cloud_workspaces(&self, selector: &str, arguments: &Map<String, Value>) -> Value {
        let page = match cloud_page(arguments) {
            Ok(page) => page,
            Err(error) => return tool_error(envelope(error, "not_run", None)),
        };
        let machines = self.cloud_machines().unwrap_or_default();
        match cloud_workspaces::find(&machines, selector) {
            Ok(Some(machine)) => success(
                v2_tools::paginate(Value::Array(cloud_workspaces::machine_rows(machine)), page),
                false,
            ),
            Ok(None) => tool_error(envelope(
                json!({
                    "code": "selector.not_found",
                    "message": format!(
                        "no Cloud machine matches {selector:?}; `app_cloud_list_machines` (cmux cloud \
                         list-machines) lists their ids, and workspace_list without machine lists \
                         every machine's workspaces"
                    ),
                    "details": {"scope": "machine", "selector": selector},
                    "retryable": false,
                }),
                "rejected",
                None,
            )),
            Err(ambiguous) => tool_error(envelope(ambiguous, "rejected", None)),
        }
    }

    /// A `terminal_wait` whose pattern the command this server just typed there also
    /// matches waits for it at the start of a line: the typed command line stays on the
    /// screen after the prompt, so `pattern: "DONE"` after `cmd; echo DONE` matched at
    /// once, before the command ran (tests/tool-evals r3j: GLM models said "done" four
    /// seconds early). Answers the note the result then carries.
    fn wait_past_typed(
        &self,
        tool: &v2_tools::V2Tool,
        call: &mut v2_tools::CallPlan,
    ) -> Option<String> {
        if tool.wire != "terminal.wait" {
            return None;
        }
        let key = typed_key(call)?;
        let typed = self.typed.borrow().get(&key).cloned()?;
        let pattern = call.plan.params.get("pattern")?.as_str()?.to_owned();
        if pattern.starts_with('^') || pattern.starts_with("(?m)") {
            return None;
        }
        // On screen the typed line follows the prompt, so an output line is the one
        // that starts with the match.
        if !cmux_tui_core::wait_pattern::compile(&pattern).ok()?.is_match(&typed) {
            return None;
        }
        let anchored = format!("(?m)^\\s*(?:{pattern})");
        call.plan.params.set("pattern", json!(anchored));
        Some(format!(
            "pattern {pattern:?} is also in the command typed here, so this waited for it at \
             the start of an output line: {anchored:?}"
        ))
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
            Ok(snapshot) => success(json!({ "items": snapshot["topology"]["windows"] }), false),
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

/// In code mode the wrap-up and suggested-session steers are only in `cmux_exec`'s description,
/// which Claude Code always loads (`anthropic/alwaysLoad`), so the instructions do not repeat
/// them.
fn initialize(params: &Value, list_changed: bool, code_mode: bool) -> Value {
    json!({
        "protocolVersion": acpmux::secret_mcp::protocol_version(params),
        "capabilities": {"tools": {"listChanged": list_changed}},
        "serverInfo": {"name": "cmux", "title": "cmux", "version": env!("CARGO_PKG_VERSION")},
        "instructions": format!(
            "{} {}",
            if code_mode { code_mode::INSTRUCTIONS } else { INSTRUCTIONS },
            acpmux::agent_tools::ASKING_RULE,
        ),
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
        value.set("truncated", json!(true));
        value.set("returned", json!(keep));
        if let Some(offset) = value.get("offset").and_then(Value::as_u64) {
            value.set("next_offset", json!(offset + keep as u64));
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
        envelope.set("idempotency_key", json!(key));
    }
    envelope
}

pub(super) fn failure_result(failure: CallFailure) -> Value {
    // An owner that says whether the run started (the app's `busy` and
    // `timeout`) decides the state. So does one that says it decided the refusal
    // itself (`rejected`: a pane that cannot split): the app marks that `not_run`
    // too (nothing applied), and `not_run` alone would tell the agent to send it again.
    let data = failure.error.get("data").or_else(|| failure.error.get("details"));
    let owner_state = data.and_then(|data| {
        let said = data.get("state").and_then(Value::as_str);
        if said == Some("rejected") {
            return Some("rejected");
        }
        if data.get("not_run") == Some(&Value::Bool(true)) {
            return Some("not_run");
        }
        said.filter(|state| matches!(*state, "not_run" | "in_progress"))
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

/// How long `workspace_list` waits for the app's `cloud.machines`, a short
/// main-actor read (the CLI's `machine list` bound).
const CLOUD_MACHINES_TIMEOUT: Duration = Duration::from_secs(1);

/// The page `workspace_list {machine, offset, limit}` answers.
fn cloud_page(arguments: &Map<String, Value>) -> Result<v2_tools::Page, Value> {
    let count = |name: &str, maximum: usize| match arguments.get(name) {
        None => Ok(None),
        Some(value) => value
            .as_u64()
            .and_then(|value| usize::try_from(value).ok())
            .filter(|value| *value <= maximum)
            .map(Some)
            .ok_or_else(|| {
                v2_tools::invalid(format!("{name} must be an integer from 0 to {maximum}"))
            }),
    };
    if let Some(name) = arguments.keys().find(|name| !matches!(name.as_str(), "offset" | "limit")) {
        return Err(v2_tools::invalid(format!(
            "workspace_list with a Cloud machine has no argument {name:?}"
        )));
    }
    Ok(v2_tools::Page {
        offset: count("offset", usize::MAX)?.unwrap_or(0),
        limit: count("limit", v2_tools::MAX_PAGE)?.unwrap_or(v2_tools::DEFAULT_PAGE).max(1),
    })
}

fn tool_error(envelope: Value) -> Value {
    let text = serde_json::to_string(&envelope).unwrap_or_default();
    json!({
        "content": [{"type": "text", "text": text}],
        "structuredContent": envelope,
        "isError": true,
    })
}
