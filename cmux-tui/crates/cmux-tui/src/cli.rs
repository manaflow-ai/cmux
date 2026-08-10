//! Hand-designed noun-first command line for `cmux.protocol/2`.
//!
//! The public grammar lives here and in `cli/command.rs`. The wire transport
//! is deliberately isolated in `cli/wire.rs`, so public commands cannot
//! accidentally fall back to the private command protocol.

mod command;
mod raw;
mod wire;

use std::borrow::Cow;
use std::io::{self, Write};
use std::path::PathBuf;

use command::{CommandPlan, ParsedCommand};

const PUBLIC_SCOPES: &[&str] = &[
    "machine",
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

pub fn is_cli_invocation(args: &[String]) -> bool {
    let mut index = 0;
    while index < args.len() {
        match args[index].as_str() {
            "--socket" | "--session" | "--machine" => index += 2,
            "--json" | "--jsonl" | "--quiet" => index += 1,
            "-h" | "--help" | "help" => return true,
            value if PUBLIC_SCOPES.contains(&value) => return true,
            value if value.starts_with('-') => index += 1,
            _ => return false,
        }
    }
    false
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
            CommandPlan::Protocol(request) => wire::run(global, request),
            CommandPlan::SessionResetState(plan) => command::run_session_reset_state(global, plan),
            CommandPlan::Plugin(plugin) => command::run_plugin(global, plugin),
            CommandPlan::ProviderAuthority(authority) => {
                command::run_provider_authority(global, authority)
            }
            CommandPlan::RawCommand(command) => raw::run(global, command),
        },
        Err(error) => {
            eprintln!("cmux: {error}");
            2
        }
    }
}

fn parse(args: &[String]) -> Result<ParsedCommand, UsageError> {
    let (global, command_args) = parse_globals(args)?;
    if command_args.is_empty() {
        return Err(UsageError::new("missing resource scope; use --help to list scopes"));
    }
    if command_args[0] == "help" {
        return match command_args.get(1) {
            None => Ok(ParsedCommand::Help(None)),
            Some(scope) if scope == "start" => Ok(ParsedCommand::Help(Some(scope.clone()))),
            Some(scope) if PUBLIC_SCOPES.contains(&scope.as_str()) => {
                Ok(ParsedCommand::Help(Some(scope.clone())))
            }
            Some(scope) => Err(UsageError::new(format!("unknown resource scope {scope:?}"))),
        };
    }
    if command_args
        .iter()
        .take_while(|value| value.as_str() != "--")
        .any(|value| matches!(value.as_str(), "-h" | "--help"))
    {
        let scope =
            command_args.iter().find(|value| PUBLIC_SCOPES.contains(&value.as_str())).cloned();
        return Ok(ParsedCommand::Help(scope));
    }
    let plan = command::parse(&command_args)?;
    Ok(ParsedCommand::Command { global, plan })
}

fn parse_globals(args: &[String]) -> Result<(GlobalArgs, Vec<String>), UsageError> {
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
        match value.as_str() {
            "--socket" => {
                global.socket = Some(PathBuf::from(global_value(args, index, value)?));
                index += 2;
            }
            "--session" => {
                global.session = Some(global_value(args, index, value)?);
                index += 2;
            }
            "--machine" => {
                global.machine = Some(global_value(args, index, value)?);
                index += 2;
            }
            "--json" => {
                set_output_mode(&mut global, OutputMode::Json, value)?;
                index += 1;
            }
            "--jsonl" => {
                set_output_mode(&mut global, OutputMode::JsonLines, value)?;
                index += 1;
            }
            "--quiet" => {
                set_output_mode(&mut global, OutputMode::Quiet, value)?;
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
    let text = scope.map(scope_help).unwrap_or(Cow::Borrowed(ROOT_HELP));
    let mut stdout = io::stdout().lock();
    let _ = stdout.write_all(text.as_bytes());
    let _ = stdout.flush();
}

fn scope_help(scope: &str) -> Cow<'static, str> {
    match scope {
        "machine" => Cow::Borrowed(MACHINE_HELP),
        "session" => Cow::Owned(session_help(&crate::localization::catalog().session_reset)),
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
        _ => Cow::Borrowed(ROOT_HELP),
    }
}

const ROOT_HELP: &str = "\
cmux - terminal multiplexer and resource client

USAGE
  cmux [START OPTIONS]
  cmux attach [START OPTIONS]
  cmux relay [ROUTING OPTIONS]
  cmux machine-agent [OPTIONS]
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
  cmux session <selector> config reload
  cmux session <selector> window title set --title <value>
  cmux session <selector> window title clear
  cmux session <selector> terminal defaults set [OPTIONS]
";

fn session_help(messages: &crate::localization::SessionResetMessages) -> String {
    format!("{SESSION_HELP_PREFIX}{}\n{SESSION_HELP_SUFFIX}", messages.help)
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
  cmux workspace create [--name <value>] [--empty] [--correlation-key <value>]
  cmux workspace <selector> show|rename|move|focus|close
  cmux workspace <selector> run [--correlation-key <value>] -- <argv...>
  cmux workspace <selector> run [--correlation-key <value>] shell <script>
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
  cmux pane <selector> split [--right|--down] [--correlation-key <value>]
  cmux pane <selector> focus direction <left|right|up|down>
  cmux pane <selector> neighbor <left|right|up|down>
  cmux pane <selector> swap --other-workspace <selector>
    --other-screen <selector> --other-pane <selector>
  cmux pane <selector> zoom [--enabled <bool>]
  cmux pane <selector> split ratio set --split <id> --ratio <value>
  cmux pane <selector> viewport width set --columns <value>
  cmux pane <selector> run [--correlation-key <value>] -- <argv...>
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
        assert!(error.0.contains("another output mode"));
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
    fn every_scope_has_dedicated_help() {
        for scope in PUBLIC_SCOPES {
            let help = scope_help(scope);
            assert!(help.contains("USAGE"));
            assert!(help.contains(scope));
        }
        let english =
            session_help(&crate::localization::catalog_for_locale("en_US.UTF-8").session_reset);
        let japanese =
            session_help(&crate::localization::catalog_for_locale("ja_JP.UTF-8").session_reset);
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
        assert!(ROOT_HELP.contains("cmux help start"));
        assert!(ROOT_HELP.starts_with("cmux - "));
        assert!(!ROOT_HELP.contains("cmux-tui"));
        assert!(matches!(
            parse(&strings(&["help", "start"])).unwrap(),
            ParsedCommand::Help(Some(scope)) if scope == "start"
        ));
    }
}
