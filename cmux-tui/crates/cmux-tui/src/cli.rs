//! Hand-designed noun-first command line for `cmux.protocol/2`.
//!
//! The public grammar lives here and in `cli/command.rs`. The wire transport
//! is deliberately isolated in `cli/wire.rs`, so public commands cannot
//! accidentally fall back to the private command protocol.

#[cfg(unix)]
mod action_hint;
#[cfg(unix)]
mod app;
#[cfg(unix)]
mod apps_run;
mod code_mode;
#[cfg(unix)]
mod coderouter;
mod command;
mod docs;
mod federation;
mod lifecycle;
#[cfg(unix)]
mod mcp;
mod raw;
mod resolve;
mod scope_help;
mod screen_help;
mod shorthand;
mod surface;
mod wire;
pub(super) use surface::Surface;

use std::borrow::Cow;
use std::io::{self, Write};
use std::path::PathBuf;

use command::{CommandPlan, ParsedCommand};
use screen_help::SCREEN_HELP;

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
    "agent",
    "room",
    "closed",
    "git",
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
    &["machine", "session", "client", "sidebar", "pairing", "projection", "provider", "raw"];

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
            value => return REMOTE_COMMANDS.contains(&value),
        }
    }
    false
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

pub fn run(args: &[String], startup_usage: &str) -> i32 {
    let surface = Surface::current();
    #[cfg(unix)]
    if let Some(code) = mcp::run_if_requested(args)
        .or_else(|| coderouter::run_if_requested(args))
        .or_else(|| apps_run::run_if_requested(args))
    {
        return code;
    }
    #[cfg(unix)]
    if let Some(code) = run_app_scope(args) {
        return code;
    }
    match parse(args, surface) {
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
        },
        Err(failure) => {
            // Words the mux grammar does not know may name an app action
            // (`cmux workspace move-to-window …`). Only an action the app
            // reports replaces the usage error.
            #[cfg(unix)]
            if let Some(code) = run_app_action_fallback(args) {
                return code;
            }
            let message = if matches!(failure.output, OutputMode::Quiet | OutputMode::Human) {
                format!("cmux: {}", failure.error)
            } else {
                failure.error.to_string()
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
    if has_help_option(&command_args) {
        return None;
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
    let (global, command_args) = parse_globals(args).ok()?;
    let words = command_args.iter().take_while(|arg| !arg.starts_with('-')).count();
    if words < 2 {
        return None;
    }
    let name = command_args[..words].join(" ");
    app::run_cli_action(&global, &name, &command_args[words..])
        .or_else(|| action_hint::report(&name, global.output))
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
    let mut command_args = shorthand::normalize(&command_args)?;
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
    if command_args[0] == "daemon" {
        return Err(UsageError::new(crate::localization::catalog().local_server.daemon_removed));
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
        (Some(scope), _) => scope_help(scope),
        (None, Surface::Cmux) => Cow::Borrowed(catalog.local_server.cmux_root_help),
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
        "browser" => Cow::Borrowed(BROWSER_HELP),
        "notification" => Cow::Borrowed(NOTIFICATION_HELP),
        "agent" => Cow::Borrowed(AGENT_HELP),
        "room" => Cow::Borrowed(ROOM_HELP),
        "closed" => Cow::Borrowed(scope_help::CLOSED_HELP),
        "git" => Cow::Borrowed(scope_help::GIT_HELP),
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
  agent         List and report agent state
  room          Organize workspaces into rooms
  closed        List and reopen closed tabs, screens, workspaces
  git           Read a repository's status and changes; capture checkpoints
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

const WORKSPACE_HELP: &str = "\
USAGE
  cmux workspace list [--order session|personal]
  cmux workspace create [--name <value>] [--empty] [--ephemeral] [--correlation-key <value>]
    [--expected-revision <revision>]
  cmux workspace <selector> show|rename|move|focus|close
  cmux workspace <selector> update [--title <value>|--clear-title] [--color <value>|--clear-color]
    [--icon <value>|--clear-icon]
  cmux workspace <selector> run [--on-exit <close|keep>] [--correlation-key <value>] -- <argv...>
  cmux workspace <selector> run [--on-exit <close|keep>] [--correlation-key <value>] shell <script>
  cmux workspace <selector> layout apply [OPTIONS]
  cmux workspace <selector> screen ...
  cmux workspace [<selector>] status list
  cmux workspace status list --all
  cmux workspace [<selector>] status set <key> <text> [--icon <value>] [--color <value>]
  cmux workspace [<selector>] status clear [<key>]
  cmux workspace [<selector>] progress set <0..1>|--indeterminate [--label <value>]
  cmux workspace [<selector>] progress clear
  cmux workspace [<selector>] log append <text> [--level <level>] [--source <value>]
  cmux workspace [<selector>] log list [--limit <1..200>]
  cmux workspace [<selector>] log clear
  cmux workspace placement list
  cmux workspace group list [--room <room>]
  cmux workspace group create --name <value> [--color <value>] [--room <room>] [--index <n>] [--collapse]
  cmux workspace group <group> update [--name <value>] [--color <value>|--clear-color]
    [--room <room>] [--collapse|--expand] [--top-index <n>|--clear-top-index]
  cmux workspace group <group> delete
  cmux workspace group <group> move --index <n>
  cmux workspace group <group> add --workspace <selector> [--index <n>]
  cmux workspace group remove --workspace <selector>

Nested panes support split --right or --down. Without a selector, status,
progress and log target the caller's workspace inside a cmux terminal, else
the current one. Levels: info, progress, success, warning, error. Text that
starts with a dash goes after --. --ephemeral creates an incognito workspace
the session closes at its next start. Workspace groups and rooms are
personal: they live in this Mac's home session. A group or room is named by
its id or exact name. list --order personal gives the sidebar order: loose
workspaces, and each group's workspaces where the group shows. --top-index
puts a group right before the workspace at that placement index;
--clear-top-index puts it after every loose workspace.
";

const PANE_HELP: &str = "\
USAGE
  cmux pane list
  cmux pane create [--correlation-key <value>]
  cmux pane <selector> show|rename|focus|close
  cmux pane <selector> split [--right|--down] [--ratio <value>]
    [--viewport-width <fraction>] [--correlation-key <value>]
  cmux pane <selector> focus direction <left|right|up|down>
  cmux pane <selector> neighbor <left|right|up|down>
  cmux pane <selector> swap --other-workspace <selector>
    --other-screen <selector> --other-pane <selector>
  cmux pane <selector> zoom [--enabled <bool>]
  cmux pane <selector> split ratio set --split <id> --ratio <value>
  cmux pane <selector> viewport width set --columns <value>
  cmux pane <selector> run [--on-exit <close|keep>] [--correlation-key <value>] -- <argv...>
  cmux pane <selector> tab ...
";

const TAB_HELP: &str = "\
USAGE
  cmux tab list
  cmux tab <selector> show|rename|move|focus|close
  cmux tab <selector> pin|unpin
  cmux tab <selector> zoom <0.25..5>|reset|in|out
  cmux tab <selector> update --zoom <0.25..5>|--clear-zoom
  cmux tab create terminal [--correlation-key <value>] [OPTIONS]
  cmux tab create browser --url <value> [--correlation-key <value>] [OPTIONS]
  cmux tab <selector> terminal|browser ...
  cmux tab group list [--pane <pane_…>]
  cmux tab group create --tabs <tab_…,...> [--name <value>] [--color <color>]
  cmux tab group <group> show|ungroup|close
  cmux tab group <group> update [--name <value>] [--color <color>] [--collapse|--expand]
  cmux tab group <group> add --tabs <tab_…,...> [--index <n>]
  cmux tab group remove --tabs <tab_…,...>
  cmux tab group <group> move [--pane <pane_…>] [--index <n>]
  cmux tab group <group> save [--room <room>]
  cmux tab group <group> split --pane <id> --edge <left|right|top|bottom> [--ratio <r>]
  cmux tab group <group> column [--pane <id>|--screen <id>] [--after-column <id>] [--width <w>]
  cmux tab group <group> new-workspace [--workspace-group <id>] [--index <n>]
  cmux tab group <group> unsave
  cmux tab group saved list [--room <room>]
  cmux tab group saved <saved> reopen [--pane <pane_…>]
  cmux tab group saved <saved> delete

Zoom is a browser page zoom or a terminal font scale. Pinned tabs sort first
and leave their group. A group or saved group is named by its id or exact
name. Group colors: grey, blue, red, yellow, green, pink, purple, cyan, orange.
";

const TERMINAL_HELP: &str = "\
USAGE
  cmux terminal list
  cmux terminal <selector> show
  cmux terminal <selector> write [--text <value>|--bytes-base64 <base64>]
  cmux terminal <selector> keys <key...>
  cmux terminal <selector> mouse <kind> [OPTIONS]
  cmux terminal <selector> focus <in|out>
  cmux terminal <selector> screen read
  cmux terminal <selector> screen wait --pattern <regex> [--timeout-ms <n>]
  cmux terminal <selector> state read
  cmux terminal <selector> history read|clear
  cmux terminal <selector> output read [--after <offset>] [--max-bytes <n>]
  cmux terminal <selector> copy|process show [OPTIONS]
  cmux terminal <selector> process wait [--timeout-ms <n>]
  cmux terminal <selector> viewport scroll --delta-rows <n>
  cmux terminal <selector> move|project|attach|close [OPTIONS]
  cmux terminal <term_id> keep on|off

screen wait prints its result either way and exits 1 when the timeout
passes without a match. keep on stops the owner from ending the terminal
when it has no tab; keep off lets it end after the reap grace period.
";

const BROWSER_HELP: &str = "\
USAGE
  cmux browser list
  cmux browser <selector> show|navigate|back|forward|reload|activate
  cmux browser <selector> key|text [OPTIONS]
  cmux browser <selector> mouse|wheel --pointer-frame-seq <decimal> [OPTIONS]
  cmux browser <selector> attach|close [OPTIONS]
";

const NOTIFICATION_HELP: &str = "\
USAGE
  cmux notification list
  cmux notification create --title <value> --body <value> [OPTIONS]
";

const AGENT_HELP: &str = "\
USAGE
  cmux agent list [OPTIONS]
  cmux agent report --terminal <selector> --state <value> --source <value>
  cmux agent hook install|uninstall|status [provider...]
  cmux agent hook emit --source <agent> --event <native-event> [--terminal <id>]
  cmux agent plugin list
  cmux agent plugin install <git-url> [--name <value>] [--force]
  cmux agent plugin use|update|remove <name-or-id>
  cmux agent plugin use --builtin
";

const ROOM_HELP: &str = "\
USAGE
  cmux room list
  cmux room create --name <value> [--color <value>] [--icon <value>] [--theme <value>] [--index <n>]
  cmux room <room> update [--name <value>] [--color <value>|--clear-color]
    [--icon <value>|--clear-icon] [--theme <value>|--clear-theme]
    [--browser-profile <id>|--clear-browser-profile]
    [--default-session <id>|--clear-default-session]
  cmux room <room> delete [--move-to <room>]
  cmux room <room> move --index <n>
  cmux room <room> follow --sessions <session,...>
  cmux room <room> pin --workspace <selector>
  cmux room unpin --workspace <selector>

Rooms are personal views of this Mac's home session. A room shows the
workspaces pinned to it and the unpinned workspaces of the sessions it
follows; --sessions is the complete follow set (\"\" follows none). A
workspace is pinned to at most one room. A room is named by its id or exact
name.
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
";

const PAIRING_HELP: &str = "\
USAGE
  cmux pairing request list
  cmux pairing request <selector> respond <accept|reject>
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
