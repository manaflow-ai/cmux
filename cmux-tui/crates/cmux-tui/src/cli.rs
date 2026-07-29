//! Hand-designed noun-first command line for `cmux.protocol/1`.
//!
//! The public grammar lives here and in `cli/command.rs`. The wire transport
//! is deliberately isolated in `cli/wire.rs`, so public commands cannot
//! accidentally fall back to the pre-v1 command protocol.

mod command;
mod raw;
mod wire;

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
            CommandPlan::Plugin(plugin) => command::run_plugin(global, plugin),
            CommandPlan::ProviderAuthority(authority) => {
                command::run_provider_authority(global, authority)
            }
            CommandPlan::RawCommand(command) => raw::run(global, command),
        },
        Err(error) => {
            eprintln!("cmux-tui: {error}");
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
    let text = scope.map_or(ROOT_HELP, scope_help);
    let mut stdout = io::stdout().lock();
    let _ = stdout.write_all(text.as_bytes());
    let _ = stdout.flush();
}

fn scope_help(scope: &str) -> &'static str {
    match scope {
        "machine" => MACHINE_HELP,
        "session" => SESSION_HELP,
        "client" => CLIENT_HELP,
        "workspace" => WORKSPACE_HELP,
        "screen" => SCREEN_HELP,
        "pane" => PANE_HELP,
        "tab" => TAB_HELP,
        "terminal" => TERMINAL_HELP,
        "browser" => BROWSER_HELP,
        "notification" => NOTIFICATION_HELP,
        "agent" => AGENT_HELP,
        "sidebar" => SIDEBAR_HELP,
        "pairing" => PAIRING_HELP,
        "projection" => PROJECTION_HELP,
        "provider" => PROVIDER_HELP,
        "raw" => RAW_HELP,
        _ => ROOT_HELP,
    }
}

const ROOT_HELP: &str = "\
cmux-tui - terminal multiplexer and resource client

USAGE
  cmux-tui [START OPTIONS]
  cmux-tui attach [START OPTIONS]
  cmux-tui relay [ROUTING OPTIONS]
  cmux-tui [GLOBAL OPTIONS] <scope> <action>

GLOBAL OPTIONS
  --socket <path>    Connect to an exact local session socket
  --session <name>   Route through a named local session
  --machine <value>  Constrain machine-scoped requests
  --json             Print one JSON result
  --jsonl            Print one JSON value per result or event
  --quiet            Suppress successful output
  -h, --help         Show command help

PROCESS HELP
  cmux-tui help start
  cmux-tui attach --help
  cmux-tui relay --help

RESOURCE SCOPES
  machine       Discover machines and their sessions
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

Run `cmux-tui <scope> --help` for scope-specific paths.
";

const MACHINE_HELP: &str = "\
USAGE
  cmux-tui machine list
  cmux-tui machine <selector> show
  cmux-tui machine <selector> session list
  cmux-tui machine <selector> session <selector> open
";

const SESSION_HELP: &str = "\
USAGE
  cmux-tui session list
  cmux-tui session <selector> open|show|snapshot|ping|shutdown
  cmux-tui session <selector> creation <correlation-key> resolve
  cmux-tui session <selector> events [--generation <value> --revision <decimal>]
  cmux-tui session <selector> config reload
  cmux-tui session <selector> window title set --title <value>
  cmux-tui session <selector> window title clear
  cmux-tui session <selector> terminal defaults set [OPTIONS]
";

const CLIENT_HELP: &str = "\
USAGE
  cmux-tui client list
  cmux-tui client <selector> show|detach
  cmux-tui client <selector> label set [--name <value>] [--kind <value>]
  cmux-tui client <selector> sizing set --terminal <selector> --enabled <bool>
  cmux-tui client <selector> sizing release --terminal <selector>
  cmux-tui client <selector> cell pixels set --width-px <n> --height-px <n>
";

const WORKSPACE_HELP: &str = "\
USAGE
  cmux-tui workspace list
  cmux-tui workspace create [--name <value>] [--empty] [--correlation-key <value>]
  cmux-tui workspace <selector> show|rename|move|focus|close
  cmux-tui workspace <selector> run [--correlation-key <value>] -- <argv...>
  cmux-tui workspace <selector> run [--correlation-key <value>] shell <script>
  cmux-tui workspace <selector> layout apply [OPTIONS]
  cmux-tui workspace <selector> screen ...
  Nested panes support split --right or --down.
";

const SCREEN_HELP: &str = "\
USAGE
  cmux-tui screen list
  cmux-tui screen create [--correlation-key <value>]
  cmux-tui screen <selector> show|rename|focus|close
  cmux-tui screen <selector> layout export
  cmux-tui screen <selector> layout undo [--confirm-close]
    [--confirmation-token <value>]
  cmux-tui screen <selector> pane ...
";

const PANE_HELP: &str = "\
USAGE
  cmux-tui pane list
  cmux-tui pane create [--correlation-key <value>]
  cmux-tui pane <selector> show|rename|focus|close
  cmux-tui pane <selector> split [--right|--down] [--correlation-key <value>]
  cmux-tui pane <selector> focus direction <left|right|up|down>
  cmux-tui pane <selector> neighbor <left|right|up|down>
  cmux-tui pane <selector> swap --other-workspace <selector>
    --other-screen <selector> --other-pane <selector>
  cmux-tui pane <selector> zoom [--enabled <bool>]
  cmux-tui pane <selector> split ratio set --split <id> --ratio <value>
  cmux-tui pane <selector> viewport width set --columns <value>
  cmux-tui pane <selector> run [--correlation-key <value>] -- <argv...>
  cmux-tui pane <selector> tab ...
";

const TAB_HELP: &str = "\
USAGE
  cmux-tui tab list
  cmux-tui tab <selector> show|rename|move|focus|close
  cmux-tui tab create terminal [--correlation-key <value>] [OPTIONS]
  cmux-tui tab create browser --url <value> [--correlation-key <value>] [OPTIONS]
  cmux-tui tab <selector> terminal|browser ...
";

const TERMINAL_HELP: &str = "\
USAGE
  cmux-tui terminal list
  cmux-tui terminal <selector> show
  cmux-tui terminal <selector> write [--text <value>|--bytes-base64 <base64>]
  cmux-tui terminal <selector> keys <key...>
  cmux-tui terminal <selector> mouse <kind> [OPTIONS]
  cmux-tui terminal <selector> focus <in|out>
  cmux-tui terminal <selector> screen read
  cmux-tui terminal <selector> screen wait --pattern <regex> [--timeout-ms <n>]
  cmux-tui terminal <selector> state read
  cmux-tui terminal <selector> history read|clear
  cmux-tui terminal <selector> copy|process show [OPTIONS]
  cmux-tui terminal <selector> process wait [--timeout-ms <n>]
  cmux-tui terminal <selector> viewport scroll --delta-rows <n>
  cmux-tui terminal <selector> move|attach|close [OPTIONS]
";

const BROWSER_HELP: &str = "\
USAGE
  cmux-tui browser list
  cmux-tui browser <selector> show|navigate|back|forward|reload|activate
  cmux-tui browser <selector> key|text|mouse|wheel [OPTIONS]
  cmux-tui browser <selector> attach|close [OPTIONS]
";

const NOTIFICATION_HELP: &str = "\
USAGE
  cmux-tui notification list
  cmux-tui notification create --title <value> --body <value> [OPTIONS]
";

const AGENT_HELP: &str = "\
USAGE
  cmux-tui agent list [OPTIONS]
  cmux-tui agent report --terminal <selector> --state <value> --source <value>
";

const SIDEBAR_HELP: &str = "\
USAGE
  cmux-tui sidebar view show|attach|input|reload [OPTIONS]
  cmux-tui sidebar view ensure|resize --cols <n> --rows <n> [OPTIONS]
  cmux-tui sidebar plugin list
  cmux-tui sidebar plugin install <git-url> [--name <value>] [--force]
  cmux-tui sidebar plugin use <name-or-id>
  cmux-tui sidebar plugin use --builtin
  cmux-tui sidebar plugin update|remove <name-or-id>
";

const PAIRING_HELP: &str = "\
USAGE
  cmux-tui pairing request list
  cmux-tui pairing request <selector> respond <accept|reject>
";

const PROJECTION_HELP: &str = "\
USAGE
  cmux-tui projection show [--projection-id <selector>]
  cmux-tui projection put --projection <json> [--projection-id <selector>]
";

const PROVIDER_HELP: &str = "\
USAGE
  cmux-tui --socket <path> provider authority install
    --generation <decimal> --authority-file <root-private-path>
";

const RAW_HELP: &str = "\
USAGE
  cmux-tui raw operation <dotted.name> [--params-json <object>]
    [--mutation --idempotency-key <value>] [--stream]
  cmux-tui raw command --request-json <full-object>

`raw operation` uses cmux.protocol/1. `raw command` is an unsafe internal
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
        assert!(SESSION_HELP.contains("creation <correlation-key> resolve"));
        assert!(TERMINAL_HELP.contains("screen wait --pattern <regex>"));
        assert!(TERMINAL_HELP.contains("process wait [--timeout-ms <n>]"));
    }

    #[test]
    fn startup_help_is_explicitly_discoverable() {
        assert!(ROOT_HELP.contains("cmux-tui help start"));
        assert!(matches!(
            parse(&strings(&["help", "start"])).unwrap(),
            ParsedCommand::Help(Some(scope)) if scope == "start"
        ));
    }
}
