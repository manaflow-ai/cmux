//! Hand-designed noun-first command line for `cmux.protocol/2`.
//!
//! The public grammar lives here and in `cli/command.rs`. The wire transport
//! is deliberately isolated in `cli/wire.rs`, so public commands cannot
//! accidentally fall back to the private command protocol.

#[cfg(unix)]
mod action_hint;
mod agent_input_hint;
mod agent_message;
#[cfg(unix)]
mod agent_view;
#[cfg(unix)]
mod agents;
#[cfg(unix)]
mod agents_doctor;
#[cfg(unix)]
mod app;
#[cfg(unix)]
mod app_browser_route;
#[cfg(unix)]
mod app_focus;
#[cfg(unix)]
mod apps_run;
mod beside;
#[cfg(unix)]
mod billing;
mod capability_cache;
#[cfg(unix)]
mod chief;
mod chief_target;
#[cfg(unix)]
mod cloud_machines;
#[cfg(unix)]
mod cloud_secret;
mod code_mode;
#[cfg(unix)]
mod coderouter;
mod codex_app_server;
mod command;
#[cfg(unix)]
mod dev;
mod docs;
mod extra_help;
mod federation;
mod fix_command;
#[cfg(unix)]
mod frontend_browser;
#[cfg(unix)]
mod host_mount;
mod launch_credential;
mod lifecycle;
// Like the other scopes its dispatch is in (`run`, `#[cfg(unix)]`): Unix only.
#[cfg(unix)]
mod sandbox_run;
#[cfg(unix)]
mod vm;
#[cfg(unix)]
pub(crate) use chief::home_for_adopt as chief_home_for_adopt;
#[cfg(unix)]
#[cfg(unix)]
pub(crate) use host_mount::early_unix_scope;

/// `cmux host enable|disable|status|serve|allow|deny|list|dial` (remote
/// hosting, every platform), on the `cmux` surface only, like the other
/// `host` verbs.
pub(crate) fn remote_host_requested(raw_args: &[String]) -> bool {
    Surface::current() == Surface::Cmux && crate::remote_host::handles(raw_args)
}
mod machine_server;
#[cfg(test)]
use machine_server::ServerRoute;
pub(crate) use machine_server::is_lifecycle_scope;
#[cfg(unix)]
mod mcp;
mod raw;
mod resolve;
mod scope_help;
mod screen_help;
#[cfg(unix)]
mod script;
#[cfg(unix)]
mod setup;
mod shorthand;
#[cfg(unix)]
mod skew;
#[cfg(unix)]
mod status;
mod surface;
#[cfg(unix)]
mod terminal_talk;
mod topology_help;
mod wire;
use surface::MACHINE_CATALOG_HELP;
pub(super) use surface::{BIN, Surface};

use std::borrow::Cow;
use std::io::{self, Write};
use std::path::PathBuf;

use command::{CommandPlan, ParsedCommand};
use screen_help::SCREEN_HELP;
use topology_help::{PANE_HELP, TAB_HELP, TERMINAL_HELP, WORKSPACE_HELP};

const PUBLIC_SCOPES: &[&str] = &[
    "machine",
    "server",
    "session",
    "client",
    "workspace",
    "screen",
    "pane",
    "tab",
    "terminal",
    "browser",
    "notification",
    "attention",
    "agent",
    "room",
    "closed",
    "git",
    "conversation",
    "sidebar",
    "pairing",
    "projection",
    "provider",
    "raw",
];

/// Scopes only the `cmux-tui` name accepts. Cloud VM guest scripts
/// (`raw command`, `session current snapshot`), the app's daemon launcher and
/// SSH remotes run the binary as `cmux-tui`, so these keep working there.
const CMUX_TUI_ONLY_SCOPES: &[&str] =
    &["session", "client", "sidebar", "pairing", "projection", "provider", "raw", "conversation"];

const REMOTE_COMMANDS: &[&str] = &[
    "remote",
    "connect",
    "ssh",
    "forward",
    "browser-proxy",
    "rpc",
    "enroll",
    "known-daemons",
    "remote-probe",
    "remote-link",
    "remote-sidecar",
    "remote-stop",
    "remote-update-need",
    "install-self",
    "wg",
];

/// Maps the actions accepted after the `remote` noun to their direct command
/// aliases. Keeping this mapping with the remote command grammar prevents
/// startup normalization from drifting from the public CLI parser.
pub(super) fn remote_action_command(action: &str) -> Option<&'static str> {
    match action {
        "connect" => Some("connect"),
        "ssh" => Some("ssh"),
        "forward" => Some("forward"),
        "browser-proxy" => Some("browser-proxy"),
        "rpc" => Some("rpc"),
        "enroll" => Some("enroll"),
        "known-daemons" => Some("known-daemons"),
        "stop" => Some("remote-stop"),
        "update-need" => Some("remote-update-need"),
        _ => None,
    }
}

/// Returns whether argv selects the remote command family.
///
/// Keeping this classifier next to the public CLI grammar prevents startup
/// routing and the Unix remote implementation from maintaining separate lists.
pub(super) fn is_remote_invocation(args: &[String]) -> bool {
    let mut index = 0;
    while index < args.len() {
        match args[index].as_str() {
            "--" => return false,
            "--socket" | "--session" | "--machine" | "--app-socket" => {
                if args.get(index + 1).is_none_or(|value| value.starts_with("--")) {
                    return false;
                }
                index += 2;
            }
            "--json" | "--jsonl" | "--quiet" => index += 1,
            value
                if value.starts_with("--socket=")
                    || value.starts_with("--session=")
                    || value.starts_with("--machine=")
                    || value.starts_with("--app-socket=") =>
            {
                if value.split_once('=').is_some_and(|(_, value)| value.is_empty()) {
                    return false;
                }
                index += 1;
            }
            value if value.starts_with('-') => return false,
            "remote" => return remote_family_word(args.get(index + 1)),
            value => return REMOTE_COMMANDS.contains(&value),
        }
    }
    false
}

/// Whether the word after `remote` keeps argv in the remote command family:
/// none, a flag, `help` or one of its actions. Any other word is an app
/// action's CLI name (`remote new-group`, `remote reconnect`), which the app
/// action fallback runs.
fn remote_family_word(word: Option<&String>) -> bool {
    word.is_none_or(|word| {
        word.starts_with('-') || word == "help" || remote_action_command(word).is_some()
    })
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(super) enum OutputMode {
    #[default]
    Human,
    Json,
    JsonLines,
    Quiet,
}

#[derive(Clone, Debug, Default)]
pub(super) struct GlobalArgs {
    pub socket: Option<PathBuf>,
    pub session: Option<String>,
    pub machine: Option<String>,
    /// The cmux app's control socket, for the scopes the app owns.
    pub app_socket: Option<PathBuf>,
    /// `--idempotency-key`: the key a failed mutation printed, reused so a
    /// retry cannot apply the change twice.
    pub idempotency_key: Option<String>,
    /// `--all-sessions`: a list runs on every local session (cli/federation.rs).
    pub all_sessions: bool,
    pub output: OutputMode,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct UsageError(pub String);

#[derive(Debug)]
struct ParseFailure {
    error: UsageError,
    output: OutputMode,
}

impl UsageError {
    pub(super) fn new(message: impl Into<String>) -> Self {
        Self(message.into())
    }
}

impl std::fmt::Display for UsageError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl std::error::Error for UsageError {}

pub fn is_public_scope(value: &str) -> bool {
    PUBLIC_SCOPES.contains(&canonical_scope(value))
}

pub(super) fn canonical_scope(value: &str) -> &str {
    shorthand::scope(value)
}

/// Whether the removed `route` resource scope is the command after global
/// options have been stripped. This keeps the early refusal ahead of the
/// generic app-action fallback even for invocations such as
/// `cmux --json route list`.
pub(crate) fn removed_route_requested(args: &[String]) -> bool {
    // This mode consumes an arbitrary argv payload through `--` and never
    // enters the CLI dispatcher, so a literal `route` belongs to the provider
    // command rather than the removed cmux resource scope.
    if let Some(provider_index) = args.iter().position(|arg| arg == "--machine-provider-command")
        && args
            .iter()
            .position(|arg| arg == "route")
            .is_none_or(|route_index| provider_index < route_index)
    {
        return false;
    }
    scan_globals(args, MachineFlag::Global)
        .map(|(_, command)| {
            let mut words = command.iter().take_while(|word| *word != "--").peekable();
            let mut command_words = Vec::new();
            while let Some(word) = words.next() {
                if startup_value_option(word) {
                    let _ = words.next();
                } else if !word.starts_with('-') {
                    command_words.push(word.as_str());
                }
            }
            matches!(
                command_words.as_slice(),
                ["route", ..] | ["help", "route", ..] | ["acp", "route", ..]
            )
        })
        .unwrap_or(false)
}

/// Startup options that take a value: the one list in main.rs
/// (`STARTUP_VALUE_OPTIONS`), so a new option is skipped here too, plus the
/// provider command, whose payload this scanner must not read as words.
fn startup_value_option(value: &str) -> bool {
    value == "--machine-provider-command" || crate::STARTUP_VALUE_OPTIONS.contains(&value)
}

/// Rewrites a pre-D1 `cmux server <lifecycle verb>` to `cmux daemon <verb>`
/// (with the deprecation hint), so `main` routes `server start` to the
/// headless startup like `daemon start`. No-op elsewhere.
pub(crate) fn rewrite_deprecated_server_lifecycle(args: &mut Vec<String>) {
    if let Some(rewritten) = machine_server::deprecated_lifecycle(args, Surface::current()) {
        *args = rewritten;
    }
}

/// Scopes that print their own help (`cmux agents --help`) but route before
/// the parser whose `help <scope>` knows only its own scopes, so `cmux help
/// agents` answered "unknown resource scope".
pub(crate) const OWN_HELP_SCOPES: &[&str] = &[
    "agents", "chats", "harness", "remote", "script", "host", "github", "avatar", "chief", "setup",
    "device",
];

/// Rewrites `cmux help <scope>` to the scope's own help (`cmux <scope>
/// --help`; `cmux device help`, the one spelling `device` answers) for a
/// scope in [`OWN_HELP_SCOPES`] the parser's help does not take. Global
/// options change no help text and are dropped wherever they stood, so the
/// scope is the first word every early dispatch reads (`raw_args.first()`
/// for `chats` and `harness`). No-op elsewhere.
pub(crate) fn rewrite_help_word(args: &mut Vec<String>) {
    rewrite_help_word_on(args, Surface::current());
}

fn rewrite_help_word_on(args: &mut Vec<String>, surface: Surface) {
    let Ok((_, command_args)) = parse_globals(args) else {
        return;
    };
    let [help, scope] = command_args.as_slice() else {
        return;
    };
    if help != "help" || !OWN_HELP_SCOPES.contains(&scope.as_str()) || surface.accepts(scope) {
        return;
    }
    let own_help = if scope == "device" { "help" } else { "--help" };
    *args = vec![scope.clone(), own_help.to_string()];
}

/// The acpmux argv of `cmux acp …` (the words after `acp`) and of its
/// `harness`/`chats` aliases (the whole command line, alias first).
#[cfg_attr(not(unix), allow(dead_code))]
pub(crate) fn acp_scope_args(raw_args: &[String]) -> Vec<std::ffi::OsString> {
    let skip = usize::from(raw_args.first().is_some_and(|head| head == "acp"));
    raw_args.iter().skip(skip).map(std::ffi::OsString::from).collect()
}

/// The agent-caller refusal of a plan that writes a Chief by the raw or
/// typed protocol path (`cmux raw operation chief.profile.update`, a
/// `cmux raw command` frame naming one): the same refusal as
/// `cmux chief new|edit|delete` (chief/registry.rs).
#[cfg(unix)]
fn chief_write_refusal(plan: &CommandPlan) -> Option<serde_json::Value> {
    let operation = match plan {
        CommandPlan::Protocol(request) => request.operation.name().ok()?,
        CommandPlan::RawCommand(command) => {
            command.request.get("operation").and_then(serde_json::Value::as_str)?.to_owned()
        }
        _ => return None,
    };
    chief::registry::agent_operation_refusal(&operation)
}

#[cfg(not(unix))]
fn chief_write_refusal(_plan: &CommandPlan) -> Option<serde_json::Value> {
    None
}

pub fn run(args: &[String], startup_usage: &str) -> i32 {
    let surface = Surface::current();
    #[cfg(unix)]
    if let Some(code) = dev::run_if_requested(args, surface) {
        return code;
    }
    let lifecycle_args;
    let args = match machine_server::run_if_requested(args, surface) {
        Some(machine_server::Mount::Exit(code)) => return code,
        Some(machine_server::Mount::Lifecycle(rewritten)) => {
            lifecycle_args = rewritten;
            lifecycle_args.as_slice()
        }
        None => args,
    };
    #[cfg(unix)]
    if let Some(code) = mcp::run_if_requested(args)
        .or_else(|| agents::run_if_requested(args))
        .or_else(|| chief::run_if_requested(args))
        .or_else(|| chief::run_avatar_if_requested(args))
        .or_else(|| coderouter::run_if_requested(args))
        .or_else(|| billing::run_if_requested(args))
        .or_else(|| sandbox_run::run_if_requested(args))
        .or_else(|| vm::run_if_requested(args))
        .or_else(|| cloud_secret::run_if_requested(args))
        .or_else(|| apps_run::run_if_requested(args))
        .or_else(|| script::run_if_requested(args))
        .or_else(|| setup::run_if_requested(args))
        .or_else(|| status::run_args(args))
    {
        return code;
    }
    #[cfg(unix)]
    if let Some(code) = run_app_scope(args) {
        return code;
    }
    let parsed = parse(args, surface);
    if let Ok(ParsedCommand::Command { global, plan }) = &parsed
        && let Some(refusal) = chief_write_refusal(plan)
    {
        return wire::print_operation_error(&refusal, global.output);
    }
    match parsed {
        Ok(ParsedCommand::Help(scope)) => {
            if scope.as_deref() == Some("start") {
                let mut stdout = io::stdout().lock();
                let _ = stdout.write_all(startup_usage.as_bytes());
                let _ = stdout.flush();
            } else {
                print_scope_help(scope.as_deref(), surface);
            }
            0
        }
        Ok(ParsedCommand::Docs(plan)) => docs::run(plan),
        Ok(ParsedCommand::CodeMode(plan)) => code_mode::run(plan),
        Ok(ParsedCommand::Command { global, plan }) => match plan {
            CommandPlan::Server(server) => lifecycle::run(global, server),
            CommandPlan::AgentHooks(plan) => command::run_agent_hooks(global, plan),
            CommandPlan::Protocol(request) if global.all_sessions => {
                federation::run_all_sessions(&global, *request)
            }
            CommandPlan::Protocol(request) => wire::run(global, *request),
            CommandPlan::SessionResetState(plan) => command::run_session_reset_state(global, plan),
            CommandPlan::Plugin(plugin) => command::run_plugin(global, plugin),
            CommandPlan::ProviderAuthority(authority) => {
                command::run_provider_authority(global, authority)
            }
            CommandPlan::RawCommand(command) => raw::run(global, command),
            CommandPlan::AgentMessage(plan) => agent_message::run_message(global, *plan),
            CommandPlan::AgentInbox(plan) => agent_message::run_inbox(global, plan),
        },
        Err(failure) => {
            // Words the mux grammar does not know may name an app action
            // (`cmux workspace move-to-window …`). Only an action the app
            // reports replaces the usage error.
            #[cfg(unix)]
            if let Some(code) = run_app_action_fallback(args) {
                return code;
            }
            // A command this build does not know may be one the daemon's
            // build knows: run that daemon's CLI (cli/skew.rs).
            #[cfg(unix)]
            let skew = parse_globals(args)
                .ok()
                .and_then(|(global, _)| skew::reexec_at_dead_end(&global).err().flatten());
            #[cfg(not(unix))]
            let skew: Option<String> = None;
            let message = if matches!(failure.output, OutputMode::Quiet | OutputMode::Human) {
                format!("cmux: {}", failure.error)
            } else {
                failure.error.to_string()
            };
            let message = match skew {
                Some(skew) => format!("{message}\n{skew}"),
                None => message,
            };
            wire::print_local_error(
                &serde_json::json!({
                    "code":"usage.invalid",
                    "message":message,
                    "details":{},
                    "retryable":false,
                }),
                failure.output,
                2,
            )
        }
    }
}

/// The scopes the cmux app owns (`app`, `action`, `settings`, `window`,
/// `events`). `None` when `args` names a mux scope.
#[cfg(unix)]
fn run_app_scope(args: &[String]) -> Option<i32> {
    let (global, command_args) = parse_globals(args).ok()?;
    if has_help_option(&command_args) || command_args.first().is_some_and(|word| word == "help") {
        return extra_help::print(&command_args);
    }
    match app::parse(&command_args) {
        Ok(Some(_)) if global.all_sessions => Some(app::failure(
            "usage.invalid",
            "cmux: --all-sessions applies only to the session list commands",
            global.output,
            2,
        )),
        Ok(Some(command)) => Some(app::run(&global, command)),
        Ok(None) => None,
        Err(error) => Some(wire::print_local_error(
            &serde_json::json!({
                "code":"usage.invalid",
                "message":format!("cmux: {error}"),
                "details":{},
                "retryable":false,
            }),
            global.output,
            2,
        )),
    }
}

/// Runs `<noun> <verb…> [--flags]` as the app action with that CLI name when
/// the app marks one for the CLI. `None` when it does not, or no app answers.
#[cfg(unix)]
fn run_app_action_fallback(args: &[String]) -> Option<i32> {
    let (global, command_args) = parse_action_globals(args).ok()?;
    if let Some((name, action_args)) = agent_view::action(&command_args) {
        return app::run_cli_action(&global, &name, &action_args);
    }
    let words = command_args.iter().take_while(|arg| !arg.starts_with('-')).count();
    if words < 2 {
        return None;
    }
    let name = command_args[..words].join(" ");
    // `<noun> move-to-window --new` is `<noun> move-to-new-window`.
    let (name, rest) = app::new_window_spelling(&name, &command_args[words..])
        .unwrap_or_else(|| (name, command_args[words..].to_vec()));
    app::run_cli_action(&global, &name, &rest).or_else(|| action_hint::report(&name, global.output))
}

fn parse(args: &[String], surface: Surface) -> Result<ParsedCommand, ParseFailure> {
    let (global, command_args) =
        parse_globals(args).map_err(|(error, output)| ParseFailure { error, output })?;
    let output = global.output;
    parse_command(global, command_args, surface).map_err(|error| ParseFailure { error, output })
}

fn parse_command(
    mut global: GlobalArgs,
    command_args: Vec<String>,
    surface: Surface,
) -> Result<ParsedCommand, UsageError> {
    if let Some(decided) = machine_server::cmux_words(&command_args, surface) {
        return decided;
    }
    let mut command_args = shorthand::normalize(&command_args, surface)?;
    federation::apply_qualifiers(&mut global, &mut command_args)?;
    if command_args.is_empty() {
        return Err(UsageError::new("missing resource scope; use --help to list scopes"));
    }
    // `help <scope>` and `<scope> --help` name the scope too, so the check
    // covers every spelling (shorthands are already lowered).
    let named_scope = match command_args[0].as_str() {
        "help" => command_args.get(1).map(|scope| shorthand::scope(scope)),
        scope => Some(scope),
    };
    if let Some(scope) = named_scope
        && surface == Surface::Cmux
        && CMUX_TUI_ONLY_SCOPES.contains(&scope)
    {
        return Err(not_in_cmux(scope));
    }
    // Public resource parsing owns option values and forwarded payloads. The
    // pre-scan is only for startup grammar that reached this parser through a
    // help or routing flag, including the rewritten `server start` path.
    if !is_public_scope(&command_args[0])
        && command_args[0] != "help"
        && super::has_inline_relay_ticket_argument(&command_args)
    {
        return Err(UsageError::new(
            crate::localization::catalog().remote_client.inline_relay_ticket_rejected,
        ));
    }
    if let Some(error) = extra_help::own_options_scope(&command_args[0]) {
        return Err(error);
    }
    if command_args[0] == "help" {
        return match command_args.get(1) {
            None => Ok(ParsedCommand::Help(None)),
            Some(scope) if matches!(scope.as_str(), "start" | "shorthands" | "docs" | "run") => {
                Ok(ParsedCommand::Help(Some(scope.clone())))
            }
            Some(scope) if surface.accepts(shorthand::scope(scope)) => {
                Ok(ParsedCommand::Help(Some(shorthand::scope(scope).to_string())))
            }
            Some(scope) => Err(unknown_scope(scope, surface)),
        };
    }
    if let Some(command) = docs::command(&command_args, global.clone())? {
        return Ok(command);
    }
    if let Some(command) = code_mode::command(&command_args, global.clone())? {
        return Ok(command);
    }
    if has_help_option(&command_args) {
        let words = command_args
            .iter()
            .take_while(|value| value.as_str() != "--")
            .filter(|value| !value.starts_with('-'))
            .map(String::as_str)
            .collect::<Vec<_>>();
        let topic = match words.as_slice() {
            ["server", action, ..]
                if matches!(
                    *action,
                    "start" | "ensure" | "status" | "stats" | "stop" | "reload-config"
                ) =>
            {
                Some(format!("server {action}"))
            }
            [scope @ ("workspace" | "screen" | "pane" | "tab"), .., "rename"] => {
                Some(format!("{scope} rename"))
            }
            [scope, ..] if surface.accepts(scope) => Some((*scope).to_string()),
            _ => None,
        };
        return Ok(ParsedCommand::Help(topic));
    }
    if command_args.first().map(String::as_str) == Some("server")
        && command_args.get(1).map(String::as_str) == Some("start")
        && global.output != OutputMode::Human
    {
        return Err(UsageError::new(
            crate::localization::catalog().local_server.start_rejects_output_mode,
        ));
    }
    let mut plan = command::parse(&command_args, surface)?;
    apply_idempotency_key(&mut plan, global.idempotency_key.as_deref())?;
    if global.all_sessions {
        match &plan {
            CommandPlan::Protocol(request) => federation::validate_all_sessions(&global, request)?,
            _ => return Err(UsageError::new("--all-sessions applies only to list commands")),
        }
    }
    Ok(ParsedCommand::Command { global, plan })
}

fn unknown_scope(scope: &str, surface: Surface) -> UsageError {
    UsageError::new(
        crate::localization::catalog()
            .local_server
            .unknown_scope(scope, suggestion(scope, surface.scopes())),
    )
}

/// A `cmux-tui` scope named through `cmux`, which refuses it by name
/// instead of calling it unknown.
fn not_in_cmux(scope: &str) -> UsageError {
    UsageError::new(
        crate::localization::catalog().local_server.scope_not_in_cmux.replace("{scope}", scope),
    )
}

pub(super) fn suggestion<'a>(value: &str, candidates: &'a [&str]) -> Option<&'a str> {
    candidates
        .iter()
        .copied()
        .map(|candidate| (scope_help::edit_distance(value, candidate), candidate))
        .min_by_key(|(distance, _)| *distance)
        .filter(|(distance, candidate)| {
            *distance <= 2 || (*distance == 3 && candidate.len().max(value.len()) >= 8)
        })
        .map(|(_, candidate)| candidate)
}

fn parse_globals(args: &[String]) -> Result<(GlobalArgs, Vec<String>), (UsageError, OutputMode)> {
    scan_globals(args, MachineFlag::Global)
}

/// Who owns a `--machine` that follows the command's first word.
#[derive(Clone, Copy, PartialEq, Eq)]
enum MachineFlag {
    /// The global option anywhere before `--` (the mux grammar's routing:
    /// `cmux workspace list --machine m` lists on machine `m`).
    Global,
    /// The command's own argument once a command word came: an app action
    /// run by its CLI name (`cmux workspace new-on-machine --machine m`)
    /// gets it as its `machine` argument. Before the first command word it
    /// is still the global option.
    #[cfg_attr(not(unix), allow(dead_code))]
    Command,
}

/// [`parse_globals`] for an app action run by its CLI name: a `--machine`
/// after the action's words is the action's own argument
/// (`workspace.newOnMachine`'s `machine`), which the global option
/// swallowed, so the app answered "requires --machine".
#[cfg(unix)]
fn parse_action_globals(
    args: &[String],
) -> Result<(GlobalArgs, Vec<String>), (UsageError, OutputMode)> {
    scan_globals(args, MachineFlag::Command)
}

fn scan_globals(
    args: &[String],
    machine_flag: MachineFlag,
) -> Result<(GlobalArgs, Vec<String>), (UsageError, OutputMode)> {
    let mut global = GlobalArgs::default();
    let mut command = Vec::new();
    let mut index = 0;
    let mut after_separator = false;
    while index < args.len() {
        let value = &args[index];
        if after_separator {
            command.push(value.clone());
            index += 1;
            continue;
        }
        if value == "--" {
            after_separator = true;
            command.push(value.clone());
            index += 1;
            continue;
        }
        // After `action run <id>`, `--session` and `--machine` are the
        // action's arguments (`agent.openSessionWorkspace --session`): they
        // name a daemon, which an app action never reaches.
        if command.len() >= 3
            && command[..2] == ["action", "run"]
            && ["--session", "--machine"].iter().any(|flag| {
                value == flag || value.strip_prefix(flag).is_some_and(|rest| rest.starts_with('='))
            })
        {
            command.push(value.clone());
            index += 1;
            continue;
        }
        if machine_flag == MachineFlag::Command
            && !command.is_empty()
            && (value == "--machine" || value.starts_with("--machine="))
        {
            command.push(value.clone());
            if value == "--machine"
                && let Some(next) = args.get(index + 1)
            {
                command.push(next.clone());
                index += 1;
            }
            index += 1;
            continue;
        }
        // Match clap's standard long-option form, where an option value can
        // follow an equals sign (for example, `--socket=/tmp/cmux.sock`).
        // This keeps one-token invocations convenient without changing the
        // existing separated-value grammar.
        if let Some((flag, inline_value)) = value.split_once('=')
            && matches!(
                flag,
                "--socket" | "--session" | "--machine" | "--app-socket" | "--idempotency-key"
            )
        {
            if inline_value.is_empty() {
                return Err((UsageError::new(format!("{flag} needs a value")), global.output));
            }
            match flag {
                "--socket" => global.socket = Some(PathBuf::from(inline_value)),
                "--session" => global.session = Some(inline_value.to_owned()),
                "--machine" => global.machine = Some(inline_value.to_owned()),
                "--app-socket" => global.app_socket = Some(PathBuf::from(inline_value)),
                "--idempotency-key" => {
                    global.idempotency_key = Some(
                        idempotency_key(inline_value).map_err(|error| (error, global.output))?,
                    );
                }
                _ => unreachable!(),
            }
            index += 1;
            continue;
        }
        match value.as_str() {
            "--socket" => {
                global.socket = Some(PathBuf::from(
                    global_value(args, index, value).map_err(|error| (error, global.output))?,
                ));
                index += 2;
            }
            "--session" => {
                global.session =
                    Some(global_value(args, index, value).map_err(|error| (error, global.output))?);
                index += 2;
            }
            "--machine" => {
                global.machine =
                    Some(global_value(args, index, value).map_err(|error| (error, global.output))?);
                index += 2;
            }
            "--app-socket" => {
                global.app_socket = Some(PathBuf::from(
                    global_value(args, index, value).map_err(|error| (error, global.output))?,
                ));
                index += 2;
            }
            "--idempotency-key" => {
                let key =
                    global_value(args, index, value).map_err(|error| (error, global.output))?;
                global.idempotency_key =
                    Some(idempotency_key(&key).map_err(|error| (error, global.output))?);
                index += 2;
            }
            "--all-sessions" => {
                global.all_sessions = true;
                index += 1;
            }
            "--json" | "--jsonl" | "--quiet" => {
                let output = match value.as_str() {
                    "--json" => OutputMode::Json,
                    "--jsonl" => OutputMode::JsonLines,
                    "--quiet" => OutputMode::Quiet,
                    _ => unreachable!(),
                };
                set_output_mode(&mut global, output, value)
                    .map_err(|error| (error, global.output))?;
                index += 1;
            }
            _ => {
                command.push(value.clone());
                if option_takes_value(value)
                    && let Some(next) = args.get(index + 1)
                {
                    command.push(next.clone());
                    index += 1;
                }
                index += 1;
            }
        }
    }
    Ok((global, command))
}

/// Option arity is shared with resource tokenization. Values such as --help or
/// --json are payloads when owned by a preceding option, never global switches.
fn option_takes_value(value: &str) -> bool {
    shorthand::short_value_option(value)
        || (value.starts_with("--")
            && !value.contains('=')
            && !matches!(
                value,
                "--help"
                    | "--json"
                    | "--jsonl"
                    | "--quiet"
                    | "--literal"
                    | "--print"
                    | "--all-sessions"
            )
            && !command::is_boolean_flag(value.trim_start_matches("--")))
}

fn has_help_option(args: &[String]) -> bool {
    let mut index = 0;
    while index < args.len() {
        let value = args[index].as_str();
        if value == "--" {
            break;
        }
        if matches!(value, "-h" | "--help") {
            return true;
        }
        index += if option_takes_value(value) { 2 } else { 1 };
    }
    false
}

fn idempotency_key(value: &str) -> Result<String, UsageError> {
    cmux_tui_core::resource::validate_idempotency_key(value)
        .map_err(|error| UsageError::new(error.message))?;
    Ok(value.to_owned())
}

/// Moves a global `--idempotency-key` onto the one daemon mutation the
/// command sends. Anything else has no key to reuse.
fn apply_idempotency_key(plan: &mut CommandPlan, key: Option<&str>) -> Result<(), UsageError> {
    let Some(key) = key else { return Ok(()) };
    match plan {
        CommandPlan::Protocol(request)
            if request.operation.class() == cmux_tui_core::resource::OperationClass::Mutation =>
        {
            request.idempotency_key = Some(key.to_owned());
            Ok(())
        }
        CommandPlan::AgentMessage(message) => {
            message.idempotency_key = Some(key.to_owned());
            Ok(())
        }
        _ => Err(UsageError::new("--idempotency-key is accepted only for mutations")),
    }
}

fn global_value(args: &[String], index: usize, flag: &str) -> Result<String, UsageError> {
    match args.get(index + 1) {
        Some(value) if !value.starts_with("--") => Ok(value.clone()),
        _ => Err(UsageError::new(format!("{flag} needs a value"))),
    }
}

fn set_output_mode(
    global: &mut GlobalArgs,
    output: OutputMode,
    flag: &str,
) -> Result<(), UsageError> {
    if global.output != OutputMode::Human {
        return Err(UsageError::new(format!("{flag} cannot be combined with another output mode")));
    }
    global.output = output;
    Ok(())
}

fn print_scope_help(scope: Option<&str>, surface: Surface) {
    let catalog = crate::localization::catalog();
    let text = match (scope, surface) {
        (Some("machine"), Surface::Cmux) => Cow::Borrowed(MACHINE_CATALOG_HELP),
        (Some(scope), _) => scope_help(scope),
        (None, Surface::Cmux) => {
            let root = catalog.local_server.cmux_root_help;
            let cloud = if root.contains("SCOPES") {
                "  cloud         Run Cloud machine actions (`cmux cloud --help`)\n"
            } else {
                "  cloud         Cloud マシンのアクション (`cmux cloud --help`)\n"
            };
            Cow::Owned(root.replacen("  room", &format!("{cloud}  room"), 1))
        }
        (None, Surface::CmuxTui) => Cow::Owned(root_help(&catalog.local_server)),
    };
    let mut stdout = io::stdout().lock();
    let _ = stdout.write_all(text.as_bytes());
    let _ = stdout.flush();
}

fn scope_help(scope: &str) -> Cow<'static, str> {
    scope_help_for(scope, crate::localization::catalog())
}

fn scope_help_for(
    scope: &str,
    catalog: &'static crate::localization::Catalog,
) -> Cow<'static, str> {
    let text = code_mode::scope_help(scope).unwrap_or_else(|| match scope {
        "shorthands" => Cow::Owned(shorthand::help(&catalog.local_server)),
        machine_server::HELP_TOPIC => Cow::Owned(machine_server::help()),
        "docs" => Cow::Borrowed(docs::help()),
        "server" => Cow::Borrowed(catalog.local_server.help),
        "server start" => Cow::Borrowed(catalog.local_server.start_help),
        "server ensure" => Cow::Borrowed(catalog.local_server.ensure_help),
        "server status" => Cow::Borrowed(catalog.local_server.status_help),
        "server stats" => Cow::Borrowed(catalog.local_server.stats_help),
        "server stop" => Cow::Borrowed(catalog.local_server.stop_help),
        "server reload-config" => Cow::Borrowed(catalog.local_server.reload_config_help),
        "machine" => Cow::Borrowed(MACHINE_HELP),
        "session" => Cow::Owned(session_help(&catalog.session_reset, &catalog.local_server)),
        "client" => Cow::Borrowed(CLIENT_HELP),
        "workspace" => Cow::Borrowed(WORKSPACE_HELP),
        "screen" => Cow::Borrowed(SCREEN_HELP),
        "pane" => Cow::Borrowed(PANE_HELP),
        "tab" => Cow::Borrowed(TAB_HELP),
        "terminal" => Cow::Borrowed(TERMINAL_HELP),
        "workspace rename" | "screen rename" | "pane rename" | "tab rename" => {
            Cow::Owned(topology_help::rename_help(scope))
        }
        "browser" => Cow::Borrowed(scope_help::BROWSER_HELP),
        "notification" => Cow::Borrowed(scope_help::NOTIFICATION_HELP),
        "attention" => Cow::Borrowed(scope_help::ATTENTION_HELP),
        "agent" => Cow::Borrowed(AGENT_HELP),
        "agent open" => Cow::Borrowed(crate::localization::catalog().app_control.agent_open_usage),
        "agent open-tab" => {
            Cow::Borrowed(crate::localization::catalog().app_control.agent_open_tab_usage)
        }
        "cloud" => Cow::Borrowed(CLOUD_HELP),
        "room" => Cow::Borrowed(scope_help::ROOM_HELP),
        "closed" => Cow::Borrowed(scope_help::CLOSED_HELP),
        "git" => Cow::Borrowed(scope_help::GIT_HELP),
        "conversation" => Cow::Borrowed(scope_help::CONVERSATION_HELP),
        "sidebar" => Cow::Borrowed(SIDEBAR_HELP),
        "pairing" => Cow::Borrowed(PAIRING_HELP),
        "projection" => Cow::Borrowed(PROJECTION_HELP),
        "provider" => Cow::Borrowed(PROVIDER_HELP),
        "raw" => Cow::Borrowed(RAW_HELP),
        _ => Cow::Owned(root_help(&catalog.local_server)),
    });
    docs::append_scope_help(scope, text)
}

const ROOT_HELP_PROCESS_PREFIX: &str = "\
cmux - terminal multiplexer and resource client

USAGE
  cmux [START OPTIONS]
  cmux attach [START OPTIONS]
  cmux relay [ROUTING OPTIONS]
  cmux wg hub --config <wg-quick file> --socket <unix socket>
  cmux wg dial --hub <unix socket> <host> <port>
";

const ROOT_HELP_PROCESS_SUFFIX: &str = "\
  cmux machine-agent [OPTIONS]
";

const ROOT_HELP_GLOBALS: &str = "\
  cmux [GLOBAL OPTIONS] <scope> <action>

GLOBAL OPTIONS
  --socket <path>    Connect to an exact local session socket
  --session <name>   Route through a named local session
  --machine <value>  Constrain machine-scoped requests
  --json             Print one JSON result
  --jsonl            Print one JSON value per result or event
  --quiet            Suppress successful output
  -h, --help         Show command help

PROCESS HELP
  cmux help start
  cmux help shorthands
  cmux attach --help
  cmux relay --help
  cmux wg hub --help
  cmux machine-agent --help

RESOURCE SCOPES
";

const ROOT_HELP_SCOPES_SUFFIX: &str = "\
  machine       Inspect the local machine and session route
  session       Inspect and control a session
  client        Inspect connected clients
  workspace     Create and organize workspaces
  screen        Create and organize screens
  pane          Split, focus, and organize panes
  tab           Create and organize terminal or browser tabs
  terminal      Read, write, and attach to terminals
  browser       Navigate and attach to browsers
  notification  List and create notifications
  attention     Mark the tab where the person must act (no focus change)
  agent         List and report agent state
  room          Organize workspaces into rooms
  closed        List and reopen closed tabs, screens, workspaces
  git           Read a repository's status and changes; capture checkpoints
  status        Show loading indicators for scripts and agents
  setup         Set up cmux from an agent: list tasks, trust, machines, harnesses (JSON)
  sidebar       Manage sidebar views and local plugins
  pairing       Resolve pairing requests
  projection    Read and update frontend projections
  provider      Install private provider authority
  raw           Send an explicit low-level operation

Run `cmux <scope> --help` for scope-specific paths.
";

fn root_help(messages: &crate::localization::LocalServerMessages) -> String {
    format!(
        "{ROOT_HELP_PROCESS_PREFIX}{}\n{ROOT_HELP_PROCESS_SUFFIX}{}\n{ROOT_HELP_GLOBALS}{}\n{}\n{ROOT_HELP_SCOPES_SUFFIX}\n{}",
        messages.root_remote_usage,
        messages.root_server_usage,
        messages.root_server_scope,
        messages.root_acp_scope,
        crate::localization::catalog().app_control.root_scopes,
    )
}

const MACHINE_HELP: &str = "\
USAGE
  cmux machine list
  cmux machine <selector> show
  cmux machine <selector> session list
  cmux machine <selector> session <selector> open
";

const SESSION_HELP_PREFIX: &str = "\
USAGE
  cmux session list
  cmux session <selector> open|show|snapshot|ping|shutdown
";

const SESSION_HELP_SUFFIX: &str = "\
  cmux session <selector> creation <correlation-key> resolve
  cmux session <selector> events [--generation <value> --revision <decimal>]
  cmux session <selector> journal subscribe [--from tail|beginning] [FILTERS]
    [--cursor-session <session-id> --sequence <decimal>]
    [--kinds <kind[,kind...]>] [--classes <class[,class...]>]
    [--subjects <kind:id[,kind:id...]>] [--max-sensitivity public|metadata|sensitive]
    [--regex <pattern>] [--regex-field kind|subjects|payload|record|terminal_output] [--ignore-case]
  cmux session <selector> journal read [--from beginning] [FILTERS]
  cmux session <selector> journal producer list
  cmux session <selector> journal producer put --manifest-json <json> --idempotency-key <key>
  cmux session <selector> journal append --event-json <json> --idempotency-key <key>
  cmux session <selector> journal hook list
  cmux session <selector> journal hook put --manifest-json <json> --idempotency-key <key>
  cmux session <selector> journal checkpoint create --idempotency-key <key>
  cmux session <selector> journal checkpoint list
  cmux session <selector> journal restore preview [--checkpoint latest|<checkpoint-id>]
  cmux session <selector> journal segment list
  cmux session <selector> journal segment seal --through <sequence> --idempotency-key <key>
  cmux session <selector> config reload
  cmux session <selector> window title set --title <value>
  cmux session <selector> window title clear
  cmux session <selector> terminal defaults set [OPTIONS]
";

fn session_help(
    messages: &crate::localization::SessionResetMessages,
    local_server: &crate::localization::LocalServerMessages,
) -> String {
    format!(
        "{SESSION_HELP_PREFIX}{}\n{}\n{SESSION_HELP_SUFFIX}",
        local_server.session_stop_help, messages.help,
    )
}

const CLIENT_HELP: &str = "\
USAGE
  cmux client list
  cmux client <selector> show|detach
  cmux client <selector> label set [--name <value>] [--kind <value>]
  cmux client <selector> sizing set --terminal <selector> --enabled <bool>
  cmux client <selector> sizing release --terminal <selector>
  cmux client <selector> cell pixels set --width-px <n> --height-px <n>
";

const AGENT_HELP: &str = "\
USAGE
  cmux agent open <session id> [--name NAME] [--key UUID] [--cwd DIR] [--host HOST] [--group GROUP] [--focus]
  cmux agent open-tab <session id> [--target PANE_OR_TAB] [--host HOST] [--focus]
  cmux agent message <agent> [--from <name>] [--thread <id>] [--] <text...|->
  cmux agent message --reply-to <message-id> [--from <name>] [--] <text...|->
  cmux agent message release <message-id> --recipient <agent> --approve|--decline
  cmux agent message unsend <message-id> [--recipient <agent>]
  cmux agent inbox [<agent>] [--state <state>] [--limit <n>] [--ack]
  cmux agent list [--needs-me] [--state <state>] [--terminal <id>]
                  [--sort needs-me|recent|none] [--limit <n>] [--counts]
  cmux agent <agent> focus
  cmux agent report --terminal <selector> --state <value> --source <value>
  cmux agent hook install|uninstall|status [provider...]
  cmux agent hook emit --source <agent> --event <native-event> [--terminal <id>]
  cmux agent plugin list
  cmux agent plugin install <git-url> [--name <value>] [--force]
  cmux agent plugin use|update|remove <name-or-id>
  cmux agent plugin use --builtin
";

const CLOUD_HELP: &str = "\
USAGE
  cmux cloud <action> [--target machine:MACHINE_ID] [--<argument> VALUE]...

CLI actions (the live action catalog is authoritative):
  new-workspace             new-machine
  fork-machine              snapshot-machine
  restore-machine           promote-machine-to-template
  machine-status            machine-ports
  hand-off-machine          move
  bring-back                ssh
  exec                      setup-github
  files-list                file-read
  file-write                file-mkdir
  file-remove               file-stat
  prepare-scp               tunnel-attach
  tunnel-detach             tunnel-rotate-key
  network-list              firewall-list
  firewall-get              firewall-create
  firewall-delete            domain-list
  publication-list           list-machines
  new-terminal-on-machine    rename-machine
  kill-machine               pause-machine
  resume-machine             resize-machine
  set-idle-pause             delete-snapshot
  diagnostics               sign-in
  sign-out                  open-mobile-pairing
  open-browser              port-list
  port-forward              port-close
  machine-link              enroll-machine
  open-desktop              apply-machine-config
  deliver-secrets           start-session

Run `cmux action list --category cloud --json` for the current catalog and
`cmux action describe <action> --json` for an action's arguments.
";

const CLOUD_HELP_JA: &str = "\
使い方
  cmux cloud <アクション> [--target machine:MACHINE_ID] [--<引数> VALUE]...

CLI アクション（現在の一覧はアクションカタログを参照）:
  new-workspace             new-machine
  fork-machine              snapshot-machine
  restore-machine           promote-machine-to-template
  machine-status            machine-ports
  hand-off-machine          move
  bring-back                ssh
  exec                      setup-github
  files-list                file-read
  file-write                file-mkdir
  file-remove               file-stat
  prepare-scp               tunnel-attach
  tunnel-detach             tunnel-rotate-key
  network-list              firewall-list
  firewall-get              firewall-create
  firewall-delete            domain-list
  publication-list           list-machines
  new-terminal-on-machine    rename-machine
  kill-machine               pause-machine
  resume-machine             resize-machine
  set-idle-pause             delete-snapshot
  diagnostics               sign-in
  sign-out                  open-mobile-pairing
  open-browser              port-list
  port-forward              port-close
  machine-link              enroll-machine
  open-desktop              apply-machine-config
  deliver-secrets           start-session

現在のカタログは `cmux action list --category cloud --json`、引数は
`cmux action describe <action> --json` で確認できます。
";

const SIDEBAR_HELP: &str = "\
USAGE
  cmux sidebar view show|attach|input|reload [OPTIONS]
  cmux sidebar view ensure|resize --cols <n> --rows <n> [OPTIONS]
  cmux sidebar plugin list
  cmux sidebar plugin install <git-url> [--name <value>] [--force]
  cmux sidebar plugin use <name-or-id>
  cmux sidebar plugin use --builtin
  cmux sidebar plugin update|remove <name-or-id>
  cmux sidebar section-scroll <section> fixed|flow
  cmux sidebar section-max-rows <section> <1-50>|none
";

const PAIRING_HELP: &str = "\
USAGE
  cmux pairing request list
  cmux pairing request <selector> respond <accept|reject>

  accept works only from the cmux app or the TUI that runs the daemon.
";

const PROJECTION_HELP: &str = "\
USAGE
  cmux projection show [--projection-id <selector>]
  cmux projection put --projection <json> [--projection-id <selector>]
";

const PROVIDER_HELP: &str = "\
USAGE
  cmux --socket <path> provider authority install
    --generation <decimal> --authority-file <root-private-path>
";

const RAW_HELP: &str = "\
USAGE
  cmux raw operation <dotted.name> [--params-json <object>]
    [--mutation --idempotency-key <value>] [--stream]
  cmux raw command --request-json <full-object>

`raw operation` uses cmux.protocol/2. `raw command` is an unsafe internal
escape for the legacy control protocol and provides no compatibility promise.
";

#[cfg(test)]
mod tests;
