//! Hand-designed noun-first command line for `cmux.protocol/2`.
//!
//! The public grammar lives here and in `cli/command.rs`. The wire transport
//! is deliberately isolated in `cli/wire.rs`, so public commands cannot
//! accidentally fall back to the private command protocol.

mod command;
mod lifecycle;
mod raw;
mod wire;

use std::borrow::Cow;
use std::io::{self, Write};
use std::path::PathBuf;

use command::{CommandPlan, ParsedCommand};

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
    "sidebar",
    "pairing",
    "projection",
    "provider",
    "raw",
];

const REMOTE_COMMANDS: &[&str] = &[
    "remote",
    "connect",
    "ssh",
    "forward",
    "rpc",
    "enroll",
    "known-daemons",
    "remote-probe",
    "remote-link",
    "remote-sidecar",
    "remote-stop",
    "install-self",
];

/// Maps the actions accepted after the `remote` noun to their direct command
/// aliases. Keeping this mapping with the remote command grammar prevents
/// startup normalization from drifting from the public CLI parser.
pub(super) fn remote_action_command(action: &str) -> Option<&'static str> {
    match action {
        "connect" => Some("connect"),
        "ssh" => Some("ssh"),
        "forward" => Some("forward"),
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
            "--socket" | "--session" | "--machine" => index += 2,
            "--json" | "--jsonl" | "--quiet" => index += 1,
            value
                if value.starts_with("--socket=")
                    || value.starts_with("--session=")
                    || value.starts_with("--machine=") =>
            {
                index += 1
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
    PUBLIC_SCOPES.contains(&value)
}

pub fn run(args: &[String], startup_usage: &str) -> i32 {
    match parse(args) {
        Ok(ParsedCommand::Help(scope)) => {
            if scope.as_deref() == Some("start") {
                let mut stdout = io::stdout().lock();
                let _ = stdout.write_all(startup_usage.as_bytes());
                let _ = stdout.flush();
            } else {
                print_scope_help(scope.as_deref());
            }
            0
        }
        Ok(ParsedCommand::Command { global, plan }) => match plan {
            CommandPlan::Server(server) => lifecycle::run(global, server),
            CommandPlan::AgentHooks(plan) => command::run_agent_hooks(global, plan),
            CommandPlan::Protocol(request) => wire::run(global, request),
            CommandPlan::SessionResetState(plan) => command::run_session_reset_state(global, plan),
            CommandPlan::Plugin(plugin) => command::run_plugin(global, plugin),
            CommandPlan::ProviderAuthority(authority) => {
                command::run_provider_authority(global, authority)
            }
            CommandPlan::RawCommand(command) => raw::run(global, command),
        },
        Err(failure) => {
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

fn parse(args: &[String]) -> Result<ParsedCommand, ParseFailure> {
    let (global, command_args) =
        parse_globals(args).map_err(|(error, output)| ParseFailure { error, output })?;
    let output = global.output;
    parse_command(global, command_args).map_err(|error| ParseFailure { error, output })
}

fn parse_command(
    global: GlobalArgs,
    command_args: Vec<String>,
) -> Result<ParsedCommand, UsageError> {
    if command_args.is_empty() {
        return Err(UsageError::new("missing resource scope; use --help to list scopes"));
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
            Some(scope) if scope == "start" => Ok(ParsedCommand::Help(Some(scope.clone()))),
            Some(scope) if PUBLIC_SCOPES.contains(&scope.as_str()) => {
                Ok(ParsedCommand::Help(Some(scope.clone())))
            }
            Some(scope) => Err(unknown_scope(scope)),
        };
    }
    if command_args
        .iter()
        .take_while(|value| value.as_str() != "--")
        .any(|value| matches!(value.as_str(), "-h" | "--help"))
    {
        let words = command_args
            .iter()
            .take_while(|value| value.as_str() != "--")
            .filter(|value| !value.starts_with('-'))
            .map(String::as_str)
            .collect::<Vec<_>>();
        let topic = match words.as_slice() {
            ["server", action, ..]
                if matches!(*action, "start" | "ensure" | "status" | "stop" | "reload-config") =>
            {
                Some(format!("server {action}"))
            }
            [scope, ..] if PUBLIC_SCOPES.contains(scope) => Some((*scope).to_string()),
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
    let plan = command::parse(&command_args)?;
    Ok(ParsedCommand::Command { global, plan })
}

fn unknown_scope(scope: &str) -> UsageError {
    UsageError::new(
        crate::localization::catalog()
            .local_server
            .unknown_scope(scope, suggestion(scope, PUBLIC_SCOPES)),
    )
}

pub(super) fn suggestion<'a>(value: &str, candidates: &'a [&str]) -> Option<&'a str> {
    candidates
        .iter()
        .copied()
        .map(|candidate| (edit_distance(value, candidate), candidate))
        .min_by_key(|(distance, _)| *distance)
        .filter(|(distance, candidate)| {
            *distance <= 2 || (*distance == 3 && candidate.len().max(value.len()) >= 8)
        })
        .map(|(_, candidate)| candidate)
}

fn edit_distance(left: &str, right: &str) -> usize {
    let right = right.chars().collect::<Vec<_>>();
    let mut previous = (0..=right.len()).collect::<Vec<_>>();
    for (row, left) in left.chars().enumerate() {
        let mut current = vec![row + 1];
        for (column, right) in right.iter().enumerate() {
            current.push(
                (current[column] + 1)
                    .min(previous[column + 1] + 1)
                    .min(previous[column] + usize::from(left != *right)),
            );
        }
        previous = current;
    }
    previous[right.len()]
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
            && matches!(flag, "--socket" | "--session" | "--machine")
        {
            if inline_value.is_empty() {
                return Err((UsageError::new(format!("{flag} needs a value")), global.output));
            }
            match flag {
                "--socket" => global.socket = Some(PathBuf::from(inline_value)),
                "--session" => global.session = Some(inline_value.to_owned()),
                "--machine" => global.machine = Some(inline_value.to_owned()),
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
                index += 1;
            }
        }
    }
    Ok((global, command))
}

fn global_value(args: &[String], index: usize, flag: &str) -> Result<String, UsageError> {
    args.get(index + 1).cloned().ok_or_else(|| UsageError::new(format!("{flag} needs a value")))
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

fn print_scope_help(scope: Option<&str>) {
    let text = scope
        .map(scope_help)
        .unwrap_or_else(|| Cow::Owned(root_help(&crate::localization::catalog().local_server)));
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
    match scope {
        "server" => Cow::Borrowed(catalog.local_server.help),
        "server start" => Cow::Borrowed(catalog.local_server.start_help),
        "server ensure" => Cow::Borrowed(catalog.local_server.ensure_help),
        "server status" => Cow::Borrowed(catalog.local_server.status_help),
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
        "sidebar" => Cow::Borrowed(SIDEBAR_HELP),
        "pairing" => Cow::Borrowed(PAIRING_HELP),
        "projection" => Cow::Borrowed(PROJECTION_HELP),
        "provider" => Cow::Borrowed(PROVIDER_HELP),
        "raw" => Cow::Borrowed(RAW_HELP),
        _ => Cow::Owned(root_help(&catalog.local_server)),
    }
}

const ROOT_HELP_PROCESS_PREFIX: &str = "\
cmux - terminal multiplexer and resource client

USAGE
  cmux [START OPTIONS]
  cmux attach [START OPTIONS]
  cmux relay [ROUTING OPTIONS]
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
  cmux attach --help
  cmux relay --help
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
  sidebar       Manage sidebar views and local plugins
  pairing       Resolve pairing requests
  projection    Read and update frontend projections
  provider      Install private provider authority
  raw           Send an explicit low-level operation

Run `cmux <scope> --help` for scope-specific paths.
";

fn root_help(messages: &crate::localization::LocalServerMessages) -> String {
    format!(
        "{ROOT_HELP_PROCESS_PREFIX}{}\n{ROOT_HELP_PROCESS_SUFFIX}{}\n{ROOT_HELP_GLOBALS}{}\n{ROOT_HELP_SCOPES_SUFFIX}",
        messages.root_remote_usage, messages.root_server_usage, messages.root_server_scope,
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
  cmux workspace list
  cmux workspace create [--name <value>] [--empty] [--correlation-key <value>] [--expected-revision <revision>]
  cmux workspace <selector> show|rename|move|focus|close
  cmux workspace <selector> run [--on-exit <close|keep>] [--correlation-key <value>] -- <argv...>
  cmux workspace <selector> run [--on-exit <close|keep>] [--correlation-key <value>] shell <script>
  cmux workspace <selector> layout apply [OPTIONS]
  cmux workspace <selector> screen ...
  Nested panes support split --right or --down.
";

const SCREEN_HELP: &str = "\
USAGE
  cmux screen list
  cmux screen create [--correlation-key <value>]
  cmux screen <selector> show|rename|focus|close
  cmux screen <selector> layout export
  cmux screen <selector> layout undo [--confirm-close]
    [--confirmation-token <value>]
  cmux screen <selector> pane ...
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
  cmux tab create terminal [--correlation-key <value>] [OPTIONS]
  cmux tab create browser --url <value> [--correlation-key <value>] [OPTIONS]
  cmux tab <selector> terminal|browser ...
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
mod tests {
    use super::*;

    fn strings(values: &[&str]) -> Vec<String> {
        values.iter().map(|value| (*value).to_string()).collect()
    }

    #[test]
    fn global_modes_are_mutually_exclusive() {
        let error =
            parse_globals(&strings(&["--json", "--quiet", "workspace", "list"])).unwrap_err();
        assert!(error.0.0.contains("another output mode"));
        assert_eq!(error.1, OutputMode::Json);
    }

    #[test]
    fn separator_stops_global_flag_extraction() {
        let (global, command) = parse_globals(&strings(&[
            "--json",
            "workspace",
            "current",
            "run",
            "--",
            "tool",
            "--session",
            "literal",
        ]))
        .unwrap();
        assert_eq!(global.output, OutputMode::Json);
        assert_eq!(
            command,
            strings(&["workspace", "current", "run", "--", "tool", "--session", "literal",])
        );
    }

    #[test]
    fn global_value_options_accept_inline_equals_values() {
        let (global, command) = parse_globals(&strings(&[
            "--socket=/tmp/review.sock",
            "--session=review-session",
            "--machine=builder",
            "workspace",
            "list",
        ]))
        .unwrap();
        assert_eq!(global.socket, Some(PathBuf::from("/tmp/review.sock")));
        assert_eq!(global.session.as_deref(), Some("review-session"));
        assert_eq!(global.machine.as_deref(), Some("builder"));
        assert_eq!(command, strings(&["workspace", "list"]));
    }

    #[test]
    fn global_value_options_reject_empty_inline_values() {
        let error = parse_globals(&strings(&["--socket=", "workspace", "list"])).unwrap_err();
        assert!(error.0.0.contains("--socket needs a value"));
    }

    #[test]
    fn server_lifecycle_routing_flags_follow_action() {
        let ParsedCommand::Command { global, plan: CommandPlan::Server(plan) } =
            parse(&strings(&["server", "status", "--session", "review-session"])).unwrap()
        else {
            panic!("server status must produce a server plan");
        };
        assert_eq!(global.session.as_deref(), Some("review-session"));
        assert!(global.socket.is_none());
        assert!(matches!(plan.action, lifecycle::ServerAction::Status));

        let ParsedCommand::Command { global, plan: CommandPlan::Server(plan) } =
            parse(&strings(&["server", "stop", "--socket", "/tmp/review.sock", "--force"]))
                .unwrap()
        else {
            panic!("server stop must produce a server plan");
        };
        assert_eq!(global.socket, Some(PathBuf::from("/tmp/review.sock")));
        assert!(global.session.is_none());
        assert!(matches!(plan.action, lifecycle::ServerAction::Stop { force: true }));

        let ParsedCommand::Command { global, plan: CommandPlan::Server(plan) } =
            parse(&strings(&[
                "server",
                "reload-config",
                "--session",
                "review-session",
                "--socket",
                "/tmp/review.sock",
            ]))
            .unwrap()
        else {
            panic!("server reload-config must produce a server plan");
        };
        assert_eq!(global.session.as_deref(), Some("review-session"));
        assert_eq!(global.socket, Some(PathBuf::from("/tmp/review.sock")));
        assert!(matches!(plan.action, lifecycle::ServerAction::ReloadConfig));
    }

    #[test]
    fn every_scope_has_dedicated_help() {
        let english_catalog = crate::localization::catalog_for_locale("en_US.UTF-8");
        for scope in PUBLIC_SCOPES {
            let help = scope_help_for(scope, english_catalog);
            assert!(help.contains("USAGE"));
            assert!(help.contains(scope));
        }
        let japanese_catalog = crate::localization::catalog_for_locale("ja_JP.UTF-8");
        let english = session_help(&english_catalog.session_reset, &english_catalog.local_server);
        let japanese =
            session_help(&japanese_catalog.session_reset, &japanese_catalog.local_server);
        assert!(english.contains("creation <correlation-key> resolve"));
        assert!(english.contains("session <name> reset-state"));
        assert!(japanese.contains("session <name> reset-state"));
        assert!(japanese.contains("保存状態のリセット"));
        assert!(TERMINAL_HELP.contains("screen wait --pattern <regex>"));
        assert!(TERMINAL_HELP.contains("process wait [--timeout-ms <n>]"));
        assert!(TERMINAL_HELP.contains("move|project|attach|close"));
    }

    #[test]
    fn startup_help_is_explicitly_discoverable() {
        let help = root_help(&crate::localization::catalog_for_locale("en_US.UTF-8").local_server);
        assert!(help.contains("cmux help start"));
        assert!(help.starts_with("cmux - "));
        assert!(!help.contains("cmux-tui"));
        assert!(matches!(
            parse(&strings(&["help", "start"])).unwrap(),
            ParsedCommand::Help(Some(scope)) if scope == "start"
        ));
    }

    #[test]
    fn remote_invocation_allows_leading_global_options() {
        assert!(is_remote_invocation(&strings(&["remote", "connect"])));
        assert!(is_remote_invocation(&strings(&["--json", "remote", "connect"])));
        assert!(is_remote_invocation(&strings(&[
            "--session",
            "dev",
            "--socket",
            "/tmp/cmux.sock",
            "remote",
            "rpc",
        ])));
        assert!(!is_remote_invocation(&strings(&["--session", "remote", "workspace", "list"])));
    }

    #[test]
    fn remote_invocation_rejects_missing_global_option_values_and_terminator() {
        assert!(!is_remote_invocation(&strings(&["--session"])));
        assert!(!is_remote_invocation(&strings(&["--socket"])));
        assert!(!is_remote_invocation(&strings(&["--", "remote", "connect"])));
    }
}
