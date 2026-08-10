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

const REQUEST_ID: u64 = 1;

type BuildFn = fn(&FlagMap) -> Result<Value, UsageError>;
type PrintFn = fn(&Value, &mut dyn Write) -> io::Result<()>;
type LocalFn = fn(&GlobalArgs, &FlagMap) -> i32;

#[derive(Debug)]
pub struct UsageError(String);

struct CliArgs {
    global: GlobalArgs,
    verb: &'static VerbSpec,
    flags: FlagMap,
}

#[derive(Default)]
struct GlobalArgs {
    session: Option<String>,
    socket: Option<PathBuf>,
    json: bool,
}

#[derive(Default)]
struct FlagMap {
    values: BTreeMap<String, String>,
    positionals: Vec<String>,
}

struct VerbSpec {
    name: &'static str,
    help: &'static str,
    allowed: &'static [&'static str],
    kind: VerbKind,
}

#[derive(Clone, Copy)]
enum VerbKind {
    Socket { build: BuildFn, print: PrintFn, stream: bool },
    Local(LocalFn),
}

const VERBS: &[VerbSpec] = &[
    VerbSpec {
        name: "identify",
        help: "Print session metadata.",
        allowed: &[],
        kind: socket(build_no_args, print_identify, false),
    },
    VerbSpec {
        name: "ping",
        help: "Check session liveness.",
        allowed: &[],
        kind: socket(build_no_args, print_ping, false),
    },
    VerbSpec {
        name: "set-client-info",
        help: "Label this control connection.",
        allowed: &["name", "kind"],
        kind: socket(build_set_client_info, print_empty, false),
    },
    VerbSpec {
        name: "list-clients",
        help: "List connected control clients.",
        allowed: &[],
        kind: socket(build_no_args, print_clients, false),
    },
    VerbSpec {
        name: "detach-client",
        help: "Detach a connected control client.",
        allowed: &["client"],
        kind: socket(build_detach_client, print_empty, false),
    },
    VerbSpec {
        name: "set-client-sizing",
        help: "Include or exclude a client from shared terminal sizing.",
        allowed: &["client", "enabled"],
        kind: socket(build_set_client_sizing, print_empty, false),
    },
    VerbSpec {
        name: "reload-config",
        help: "Ask a running TUI to reload its config file.",
        allowed: &[],
        kind: socket(build_no_args, print_empty, false),
    },
    VerbSpec {
        name: "set-window-title",
        help: "Set the host terminal window title.",
        allowed: &["title"],
        kind: socket(build_set_window_title, print_empty, false),
    },
    VerbSpec {
        name: "clear-window-title",
        help: "Clear the host terminal window title.",
        allowed: &[],
        kind: socket(build_no_args, print_empty, false),
    },
    VerbSpec {
        name: "list-workspaces",
        help: "List workspaces, screens, panes, and surfaces.",
        allowed: &[],
        kind: socket(build_no_args, print_tree, false),
    },
    VerbSpec {
        name: "topology-snapshot",
        help: "Print the canonical revisioned topology snapshot.",
        allowed: &[],
        kind: socket(build_no_args, print_json_data, false),
    },
    VerbSpec {
        name: "export-layout",
        help: "Export a screen layout.",
        allowed: &["screen"],
        kind: socket(build_export_layout, print_json_data, false),
    },
    VerbSpec {
        name: "apply-layout",
        help: "Apply a screen layout.",
        allowed: &["workspace", "name", "layout", "cols", "rows"],
        kind: socket(build_apply_layout, print_applied_layout, false),
    },
    VerbSpec {
        name: "send",
        help: "Send text or bytes to a surface.",
        allowed: &["surface", "text", "bytes", "paste"],
        kind: socket(build_send, print_empty, false),
    },
    VerbSpec {
        name: "read-screen",
        help: "Print visible screen text for a surface.",
        allowed: &["surface"],
        kind: socket(build_surface, print_read_screen, false),
    },
    VerbSpec {
        name: "read-scrollback",
        help: "Print a styled scrollback page as text.",
        allowed: &["surface", "start", "count"],
        kind: socket(build_read_scrollback, print_scrollback, false),
    },
    VerbSpec {
        name: "wait-for",
        help: "Wait for a regex in visible screen text.",
        allowed: &["surface", "pattern", "timeout-ms"],
        kind: socket(build_wait_for, print_empty, false),
    },
    VerbSpec {
        name: "run",
        help: "Run a command in a new or existing pane.",
        allowed: &["pane", "new-workspace", "cwd", "name", "command"],
        kind: socket(build_run, print_surface, false),
    },
    VerbSpec {
        name: "send-key",
        help: "Send encoded key names to a surface.",
        allowed: &["surface"],
        kind: socket(build_send_key, print_empty, false),
    },
    VerbSpec {
        name: "copy",
        help: "Copy text from a surface.",
        allowed: &["surface", "mode"],
        kind: socket(build_copy, print_read_screen, false),
    },
    VerbSpec {
        name: "ids",
        help: "List ids and short ids.",
        allowed: &["kind"],
        kind: socket(build_ids, print_ids, false),
    },
    VerbSpec {
        name: "notify",
        help: "Show a cmux notification.",
        allowed: &["title", "body", "level", "surface"],
        kind: socket(build_notify, print_notification, false),
    },
    VerbSpec {
        name: "list-agents",
        help: "List reported agent states.",
        allowed: &["surface", "state"],
        kind: socket(build_list_agents, print_agents, false),
    },
    VerbSpec {
        name: "report-agent",
        help: "Report an agent state.",
        allowed: &["surface", "state", "source", "session"],
        kind: socket(build_report_agent, print_empty, false),
    },
    VerbSpec {
        name: "vt-state",
        help: "Print base64 terminal state for a surface.",
        allowed: &["surface"],
        kind: socket(build_surface, print_vt_state, false),
    },
    VerbSpec {
        name: "new-tab",
        help: "Create a new tab.",
        allowed: &["pane", "cwd", "cols", "rows"],
        kind: socket(build_new_tab, print_surface, false),
    },
    VerbSpec {
        name: "new-browser-tab",
        help: "Create a browser tab.",
        allowed: &["url", "pane", "cols", "rows"],
        kind: socket(build_new_browser_tab, print_surface, false),
    },
    VerbSpec {
        name: "new-workspace",
        help: "Create a workspace.",
        allowed: &["name", "cols", "rows"],
        kind: socket(build_new_workspace, print_surface, false),
    },
    VerbSpec {
        name: "new-screen",
        help: "Create a screen.",
        allowed: &["workspace", "cols", "rows"],
        kind: socket(build_new_screen, print_surface, false),
    },
    VerbSpec {
        name: "split",
        help: "Split a pane.",
        allowed: &["pane", "dir", "cols", "rows"],
        kind: socket(build_split, print_surface, false),
    },
    VerbSpec {
        name: "set-ratio",
        help: "Set a split ratio.",
        allowed: &["pane", "dir", "ratio"],
        kind: socket(build_set_ratio, print_empty, false),
    },
    VerbSpec {
        name: "pane-neighbor",
        help: "Find a pane neighbor.",
        allowed: &["pane", "dir"],
        kind: socket(build_pane_direction, print_optional_pane, false),
    },
    VerbSpec {
        name: "focus-direction",
        help: "Focus a pane by direction.",
        allowed: &["pane", "dir"],
        kind: socket(build_optional_pane_direction, print_pane, false),
    },
    VerbSpec {
        name: "swap-pane",
        help: "Swap panes.",
        allowed: &["pane", "dir", "target"],
        kind: socket(build_swap_pane, print_empty, false),
    },
    VerbSpec {
        name: "zoom-pane",
        help: "Toggle or set pane zoom.",
        allowed: &["pane", "mode"],
        kind: socket(build_zoom_pane, print_zoom_state, false),
    },
    VerbSpec {
        name: "process-info",
        help: "Print process metadata for a surface.",
        allowed: &["surface"],
        kind: socket(build_surface, print_process_info, false),
    },
    VerbSpec {
        name: "set-default-colors",
        help: "Set default terminal colors.",
        allowed: &["fg", "bg"],
        kind: socket(build_set_default_colors, print_empty, false),
    },
    VerbSpec {
        name: "close-surface",
        help: "Close a surface.",
        allowed: &["surface"],
        kind: socket(build_surface, print_empty, false),
    },
    VerbSpec {
        name: "close-pane",
        help: "Close a pane.",
        allowed: &["pane"],
        kind: socket(build_pane, print_empty, false),
    },
    VerbSpec {
        name: "close-screen",
        help: "Close a screen.",
        allowed: &["screen"],
        kind: socket(build_screen, print_empty, false),
    },
    VerbSpec {
        name: "close-workspace",
        help: "Close a workspace.",
        allowed: &["workspace"],
        kind: socket(build_workspace, print_empty, false),
    },
    VerbSpec {
        name: "rename-pane",
        help: "Rename a pane.",
        allowed: &["pane", "name"],
        kind: socket(build_rename_pane, print_empty, false),
    },
    VerbSpec {
        name: "rename-surface",
        help: "Rename a surface.",
        allowed: &["surface", "name"],
        kind: socket(build_rename_surface, print_empty, false),
    },
    VerbSpec {
        name: "rename-screen",
        help: "Rename a screen.",
        allowed: &["screen", "name"],
        kind: socket(build_rename_screen, print_empty, false),
    },
    VerbSpec {
        name: "rename-workspace",
        help: "Rename a workspace.",
        allowed: &["workspace", "name"],
        kind: socket(build_rename_workspace, print_empty, false),
    },
    VerbSpec {
        name: "resize-surface",
        help: "Resize a surface PTY.",
        allowed: &["surface", "cols", "rows"],
        kind: socket(build_resize_surface, print_empty, false),
    },
    VerbSpec {
        name: "release-surface-size",
        help: "Stop this client from sizing a surface.",
        allowed: &["surface"],
        kind: socket(build_surface, print_empty, false),
    },
    VerbSpec {
        name: "focus-pane",
        help: "Focus a pane.",
        allowed: &["pane"],
        kind: socket(build_pane, print_empty, false),
    },
    VerbSpec {
        name: "select-tab",
        help: "Select a tab by index or delta.",
        allowed: &["pane", "index", "delta"],
        kind: socket(build_select_tab, print_empty, false),
    },
    VerbSpec {
        name: "select-screen",
        help: "Select a screen by index or delta.",
        allowed: &["index", "delta"],
        kind: socket(build_select_screen, print_empty, false),
    },
    VerbSpec {
        name: "select-workspace",
        help: "Select a workspace by index or delta.",
        allowed: &["index", "delta"],
        kind: socket(build_select_workspace, print_empty, false),
    },
    VerbSpec {
        name: "move-tab",
        help: "Move a tab to a pane and index.",
        allowed: &["surface", "pane", "index"],
        kind: socket(build_move_tab, print_empty, false),
    },
    VerbSpec {
        name: "move-workspace",
        help: "Move a workspace to an index.",
        allowed: &["workspace", "index"],
        kind: socket(build_move_workspace, print_empty, false),
    },
    VerbSpec {
        name: "scroll-surface",
        help: "Scroll a surface.",
        allowed: &["surface", "delta"],
        kind: socket(build_scroll_surface, print_empty, false),
    },
    VerbSpec {
        name: "subscribe",
        help: "Subscribe to session events.",
        allowed: &["tree-events"],
        kind: socket(build_subscribe, print_empty, true),
    },
    VerbSpec {
        name: "subscribe-topology",
        help: "Resume the canonical topology delta stream.",
        allowed: &["daemon-instance-id", "session-id", "revision"],
        kind: socket(build_subscribe_topology, print_empty, true),
    },
    VerbSpec {
        name: "attach-surface",
        help: "Attach to a surface stream.",
        allowed: &["surface", "mode"],
        kind: socket(build_attach_surface, print_empty, true),
    },
    VerbSpec {
        name: "plugin",
        help: "Manage installed sidebar plugins locally.",
        allowed: &["name", "force", "builtin"],
        kind: VerbKind::Local(run_plugin),
    },
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
            _ => return Err(UsageError(format!("unknown argument {arg:?}"))),
        }
    }

    let Some(verb) = verb else { return Err(UsageError("missing verb".to_string())) };
    Ok(Parsed::Command(CliArgs { global, verb, flags }))
}

fn value_after(args: &[String], index: usize, flag: &str) -> Result<String, UsageError> {
    args.get(index + 1).cloned().ok_or_else(|| UsageError(format!("{flag} needs a value")))
}

fn verb_by_name(name: &str) -> Option<&'static VerbSpec> {
    VERBS.iter().find(|verb| verb.name == name)
}

fn run_command(args: CliArgs) -> i32 {
    let (build, print, stream_mode) = match args.verb.kind {
        VerbKind::Socket { build, print, stream } => (build, print, stream),
        VerbKind::Local(run) => return run(&args.global, &args.flags),
    };
    let request = match build(&args.flags) {
        Ok(mut value) => {
            value["cmd"] = json!(args.verb.name);
            value["id"] = json!(REQUEST_ID);
            value
        }
        Err(err) => {
            eprintln!("cmux-tui: {}", err.0);
            return 2;
        }
    };
    let socket_path = resolve_socket(&args.global);
    let stream = match transport::connect(&socket_path) {
        Ok(stream) => stream,
        Err(err) => {
            eprintln!("cannot connect to session socket {}: {err}", socket_path.display());
            return 3;
        }
    };
    let _ = stream.set_read_timeout(Some(Duration::from_secs(10)));
    let mut registration_writer = match stream.try_clone_box() {
        Ok(writer) => writer,
        Err(err) => {
            eprintln!("cannot clone session socket {}: {err}", socket_path.display());
            return 3;
        }
    };
    let mut reader = BufReader::new(stream);
    if let Err(error) = crate::client_registration::register_trusted_automation(
        &mut registration_writer,
        &mut reader,
    ) {
        eprintln!("cannot register trusted local CLI connection: {error}");
        return 3;
    }
    drop(registration_writer);
    if stream_mode {
        let _ = reader.get_ref().set_read_timeout(Some(Duration::from_millis(250)));
    }

    let mut line = match serde_json::to_vec(&request) {
        Ok(line) => line,
        Err(err) => {
            eprintln!("failed to encode request: {err}");
            return 2;
        }
    };
    line.push(b'\n');
    if let Err(err) = reader.get_mut().write_all(&line) {
        eprintln!("transport error: {err}");
        return 3;
    }

    if stream_mode {
        run_stream(reader)
    } else {
        run_one_response(&mut reader, args.global.json, print)
    }
}

fn is_boolean_flag(spec: &VerbSpec, name: &str) -> bool {
    (spec.name == "run" && name == "new-workspace")
        || (spec.name == "send" && name == "paste")
        || (spec.name == "plugin" && matches!(name, "force" | "builtin"))
}

fn run_plugin(global: &GlobalArgs, flags: &FlagMap) -> i32 {
    crate::plugin_manager::run(
        &flags.positionals,
        crate::plugin_manager::CliOptions {
            json: global.json,
            socket: global.socket.clone(),
            session: global.session.clone(),
            name: flags.optional("name"),
            force: flags.optional("force").is_some(),
            builtin: flags.optional("builtin").is_some(),
        },
    )
}

fn resolve_socket(global: &GlobalArgs) -> PathBuf {
    if let Some(path) = &global.socket {
        return path.clone();
    }
    for name in ["CMUX_TUI_SOCKET", "CMUX_MUX_SOCKET"] {
        if let Some(path) = std::env::var_os(name)
            && !path.is_empty()
        {
            return PathBuf::from(path);
        }
    }
    let session = global.session.as_deref().unwrap_or("main");
    cmux_tui_core::server::default_socket_path(session)
}

fn run_one_response(
    reader: &mut BufReader<Box<dyn transport::Stream>>,
    json_output: bool,
    print_human: PrintFn,
) -> i32 {
    loop {
        let mut line = String::new();
        match reader.read_line(&mut line) {
            Ok(0) => {
                eprintln!("transport closed before response");
                return 3;
            }
            Ok(_) => {}
            Err(err) => {
                eprintln!("transport error: {err}");
                return 3;
            }
        }
    }
    Ok((global, command))
}

fn run_stream(mut reader: BufReader<Box<dyn transport::Stream>>) -> i32 {
    let mut line = String::new();
    loop {
        if crate::shutdown_requested() {
            return 0;
        }
        match reader.read_line(&mut line) {
            Ok(0) => {
                if line.is_empty() {
                    return 0;
                }
                eprintln!("transport closed with partial stream line");
                return 3;
            }
            Ok(_) if !line.ends_with('\n') => {
                eprintln!("transport closed with partial stream line");
                return 3;
            }
            Ok(_) => {}
            Err(err)
                if matches!(err.kind(), io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut) =>
            {
                continue;
            }
            Err(err) => {
                eprintln!("transport error: {err}");
                return 3;
            }
        }
        let value = match serde_json::from_str::<Value>(&line) {
            Ok(value) => value,
            Err(err) => {
                eprintln!("bad stream line: {err}");
                return 3;
            }
        };
        if value.get("event").is_some() {
            print!("{}", line.trim_end_matches(['\r', '\n']));
            println!();
            line.clear();
            if io::stdout().flush().is_err() {
                return 3;
            }
            continue;
        }
        if value.get("id").and_then(Value::as_u64) != Some(REQUEST_ID) {
            line.clear();
            continue;
        }
        if value.get("ok").and_then(Value::as_bool) == Some(true) {
            if value.pointer("/data/status").and_then(Value::as_str) == Some("resnapshot-required")
            {
                if let Some(data) = value.get("data") {
                    println!("{data}");
                }
                return 1;
            }
            line.clear();
            continue;
        }
        let error = value.get("error").and_then(Value::as_str).unwrap_or("unknown error");
        eprintln!("{error}");
        return 1;
    }
}

fn print_response(value: &Value, json_output: bool, print_human: PrintFn) -> i32 {
    if value.get("ok").and_then(Value::as_bool) != Some(true) {
        let error = value.get("error").and_then(Value::as_str).unwrap_or("unknown error");
        eprintln!("{error}");
        return 1;
    }
    let data = value.get("data").unwrap_or(&Value::Null);
    let mut stdout = io::stdout();
    let result = if json_output {
        serde_json::to_writer(&mut stdout, data)
            .and_then(|_| stdout.write_all(b"\n").map_err(serde_json::Error::io))
            .map_err(io::Error::other)
    } else {
        print_human(data, &mut stdout)
    };
    match result.and_then(|_| stdout.flush()) {
        Ok(()) => 0,
        Err(err) => {
            eprintln!("stdout error: {err}");
            3
        }
    }
}

fn build_no_args(flags: &FlagMap) -> Result<Value, UsageError> {
    flags.reject_remaining()?;
    Ok(json!({}))
}

fn build_set_client_info(flags: &FlagMap) -> Result<Value, UsageError> {
    let mut value = json!({});
    flags.insert_optional_string(&mut value, "name");
    flags.insert_optional_string(&mut value, "kind");
    Ok(value)
}

fn build_detach_client(flags: &FlagMap) -> Result<Value, UsageError> {
    Ok(json!({ "client": flags.required_u64("client")? }))
}

fn build_set_client_sizing(flags: &FlagMap) -> Result<Value, UsageError> {
    let enabled_value = flags.required("enabled")?;
    let enabled = match enabled_value.as_str() {
        "true" => true,
        "false" => false,
        _ => return Err(UsageError("--enabled must be true or false".to_string())),
    };
    Ok(json!({ "client": flags.required_u64("client")?, "enabled": enabled }))
}

fn build_surface(flags: &FlagMap) -> Result<Value, UsageError> {
    Ok(json!({ "surface": flags.required_u64("surface")? }))
}

fn build_pane(flags: &FlagMap) -> Result<Value, UsageError> {
    Ok(json!({ "pane": flags.required_u64("pane")? }))
}

fn build_screen(flags: &FlagMap) -> Result<Value, UsageError> {
    Ok(json!({ "screen": flags.required_u64("screen")? }))
}

fn build_workspace(flags: &FlagMap) -> Result<Value, UsageError> {
    Ok(json!({ "workspace": flags.required_u64("workspace")? }))
}

fn build_send(flags: &FlagMap) -> Result<Value, UsageError> {
    let mut value = json!({ "surface": flags.required_u64("surface")? });
    if let Some(text) = flags.optional("text") {
        value["text"] = json!(text);
    }
    if let Some(bytes) = flags.optional("bytes") {
        value["bytes"] = json!(bytes);
    }
    if flags.optional("paste").is_some() {
        value["paste"] = json!(true);
    }
    if value.get("text").is_none() && value.get("bytes").is_none() {
        let mut text = String::new();
        io::stdin()
            .read_to_string(&mut text)
            .map_err(|err| UsageError(format!("failed to read stdin: {err}")))?;
        value["text"] = json!(text);
    }
    Ok(value)
}

fn build_read_scrollback(flags: &FlagMap) -> Result<Value, UsageError> {
    let count = flags.required_u32("count")?;
    if count > u32::from(u16::MAX) {
        return Err(UsageError("--count must be at most 65535".to_string()));
    }
    Ok(json!({
        "surface": flags.required_u64("surface")?,
        "start": flags.required_u32("start")?,
        "count": count,
    }))
}

fn build_subscribe(flags: &FlagMap) -> Result<Value, UsageError> {
    let mut value = json!({});
    if let Some(tree_events) = flags.optional("tree-events") {
        if !matches!(tree_events.as_str(), "coarse" | "deltas") {
            return Err(UsageError("--tree-events must be coarse or deltas".to_string()));
        }
        value["tree_events"] = json!(tree_events);
    }
    Ok(value)
}

fn build_subscribe_topology(flags: &FlagMap) -> Result<Value, UsageError> {
    let daemon_instance_id = flags.required("daemon-instance-id")?;
    daemon_instance_id
        .parse::<cmux_tui_core::DaemonInstanceId>()
        .map_err(|_| UsageError("--daemon-instance-id must be a UUID".to_string()))?;
    let session_id = flags.required("session-id")?;
    session_id
        .parse::<cmux_tui_core::SessionId>()
        .map_err(|_| UsageError("--session-id must be a UUID".to_string()))?;
    Ok(json!({
        "daemon_instance_id": daemon_instance_id,
        "session_id": session_id,
        "revision": flags.required_u64("revision")?,
    }))
}

fn build_attach_surface(flags: &FlagMap) -> Result<Value, UsageError> {
    let mut value = json!({ "surface": flags.required_u64("surface")? });
    if let Some(mode) = flags.optional("mode") {
        if !matches!(mode.as_str(), "bytes" | "render") {
            return Err(UsageError("--mode must be bytes or render".to_string()));
        }
        value["mode"] = json!(mode);
    }
    Ok(value)
}

fn build_wait_for(flags: &FlagMap) -> Result<Value, UsageError> {
    Ok(json!({
        "surface": flags.required_u64("surface")?,
        "pattern": flags.required("pattern")?,
        "timeout_ms": flags.required_u64("timeout-ms")?,
    }))
}

fn build_run(flags: &FlagMap) -> Result<Value, UsageError> {
    let mut value = json!({});
    flags.insert_optional_u64(&mut value, "pane")?;
    flags.insert_optional_string(&mut value, "cwd");
    flags.insert_optional_string(&mut value, "name");
    if flags.optional("new-workspace").is_some() {
        value["new_workspace"] = json!(true);
    }
    match (flags.optional("command"), flags.positionals.is_empty()) {
        (Some(command), true) => value["command"] = json!(command),
        (Some(_), false) => {
            return Err(UsageError("--command and argv are mutually exclusive".to_string()));
        }
        (None, false) => value["argv"] = json!(flags.positionals),
        (None, true) => return Err(UsageError("argv or --command is required".to_string())),
    }
    Ok(value)
}

fn build_send_key(flags: &FlagMap) -> Result<Value, UsageError> {
    if flags.positionals.is_empty() {
        return Err(UsageError("at least one key is required".to_string()));
    }
    Ok(json!({
        "surface": flags.required_u64("surface")?,
        "keys": flags.positionals,
    }))
}

fn build_copy(flags: &FlagMap) -> Result<Value, UsageError> {
    let mode = flags.required("mode")?;
    if !matches!(mode.as_str(), "screen" | "selection" | "scrollback") {
        return Err(UsageError("--mode must be screen, selection, or scrollback".to_string()));
    }
    Ok(json!({ "surface": flags.required_u64("surface")?, "mode": mode }))
}

fn build_ids(flags: &FlagMap) -> Result<Value, UsageError> {
    let mut value = json!({});
    if let Some(kind) = flags.optional("kind") {
        if !matches!(kind.as_str(), "workspace" | "screen" | "pane" | "surface") {
            return Err(UsageError(
                "--kind must be workspace, screen, pane, or surface".to_string(),
            ));
        }
        value["kind"] = json!(kind);
    }
    Ok(value)
}

fn build_notify(flags: &FlagMap) -> Result<Value, UsageError> {
    let mut value = json!({
        "title": flags.required("title")?,
        "body": flags.required("body")?,
    });
    if let Some(level) = flags.optional("level") {
        if !matches!(level.as_str(), "info" | "warning" | "error") {
            return Err(UsageError("--level must be info, warning, or error".to_string()));
        }
        value["level"] = json!(level);
    }
    flags.insert_optional_u64(&mut value, "surface")?;
    Ok(value)
}

fn build_list_agents(flags: &FlagMap) -> Result<Value, UsageError> {
    let mut value = json!({});
    flags.insert_optional_u64(&mut value, "surface")?;
    if let Some(state) = flags.optional("state") {
        if !matches!(state.as_str(), "working" | "blocked" | "idle" | "done" | "unknown") {
            return Err(UsageError(
                "--state must be working, blocked, idle, done, or unknown".to_string(),
            ));
        }
        value["state"] = json!(state);
    }
    Ok(value)
}

fn build_report_agent(flags: &FlagMap) -> Result<Value, UsageError> {
    let state = flags.required("state")?;
    if !matches!(state.as_str(), "working" | "blocked" | "idle" | "done" | "unknown") {
        return Err(UsageError(
            "--state must be working, blocked, idle, done, or unknown".to_string(),
        ));
    }
    let source = flags.required("source")?;
    if !matches!(source.as_str(), "socket" | "hook") {
        return Err(UsageError("--source must be socket or hook".to_string()));
    }
    let mut value = json!({
        "surface": flags.required_u64("surface")?,
        "state": state,
        "source": source,
    });
    flags.insert_optional_string(&mut value, "session");
    Ok(value)
}

fn build_new_tab(flags: &FlagMap) -> Result<Value, UsageError> {
    let mut value = json!({});
    flags.insert_optional_u64(&mut value, "pane")?;
    flags.insert_optional_string(&mut value, "cwd");
    flags.insert_optional_size(&mut value)?;
    Ok(value)
}

fn build_new_browser_tab(flags: &FlagMap) -> Result<Value, UsageError> {
    let mut value = json!({ "url": flags.required("url")? });
    flags.insert_optional_u64(&mut value, "pane")?;
    flags.insert_optional_size(&mut value)?;
    Ok(value)
}

fn build_new_workspace(flags: &FlagMap) -> Result<Value, UsageError> {
    let mut value = json!({});
    flags.insert_optional_string(&mut value, "name");
    flags.insert_optional_size(&mut value)?;
    Ok(value)
}

fn build_new_screen(flags: &FlagMap) -> Result<Value, UsageError> {
    let mut value = json!({});
    flags.insert_optional_u64(&mut value, "workspace")?;
    flags.insert_optional_size(&mut value)?;
    Ok(value)
}

fn build_export_layout(flags: &FlagMap) -> Result<Value, UsageError> {
    let mut value = json!({});
    flags.insert_optional_u64(&mut value, "screen")?;
    Ok(value)
}

fn build_apply_layout(flags: &FlagMap) -> Result<Value, UsageError> {
    let layout = flags.required_json("layout")?;
    let mut value = json!({ "layout": layout });
    flags.insert_optional_u64(&mut value, "workspace")?;
    flags.insert_optional_string(&mut value, "name");
    flags.insert_optional_size(&mut value)?;
    Ok(value)
}

fn build_split(flags: &FlagMap) -> Result<Value, UsageError> {
    let mut value = json!({ "pane": flags.required_u64("pane")?, "dir": flags.required_dir()? });
    flags.insert_optional_size(&mut value)?;
    Ok(value)
}

fn build_set_ratio(flags: &FlagMap) -> Result<Value, UsageError> {
    Ok(json!({
        "pane": flags.required_u64("pane")?,
        "dir": flags.required_dir()?,
        "ratio": flags.required_f32("ratio")?,
    }))
}

fn build_pane_direction(flags: &FlagMap) -> Result<Value, UsageError> {
    Ok(json!({ "pane": flags.required_u64("pane")?, "dir": flags.required_direction()? }))
}

fn build_optional_pane_direction(flags: &FlagMap) -> Result<Value, UsageError> {
    let mut value = json!({ "dir": flags.required_direction()? });
    flags.insert_optional_u64(&mut value, "pane")?;
    Ok(value)
}

fn build_swap_pane(flags: &FlagMap) -> Result<Value, UsageError> {
    let mut value = json!({ "pane": flags.required_u64("pane")? });
    match (flags.optional("dir"), flags.optional("target")) {
        (Some(dir), None) => value["dir"] = json!(parse_direction("dir", &dir)?),
        (None, Some(target)) => value["target"] = json!(parse_u64("target", &target)?),
        (Some(_), Some(_)) => {
            return Err(UsageError("use only one of --dir or --target".to_string()));
        }
        (None, None) => {
            return Err(UsageError("one of --dir or --target is required".to_string()));
        }
    }
    Ok(value)
}

fn build_zoom_pane(flags: &FlagMap) -> Result<Value, UsageError> {
    let mut value = json!({});
    flags.insert_optional_u64(&mut value, "pane")?;
    if let Some(mode) = flags.optional("mode") {
        value["mode"] = json!(parse_zoom_mode(&mode)?);
    }
    Ok(value)
}

fn build_set_default_colors(flags: &FlagMap) -> Result<Value, UsageError> {
    let mut value = json!({});
    flags.insert_optional_string(&mut value, "fg");
    flags.insert_optional_string(&mut value, "bg");
    Ok(value)
}

fn build_set_window_title(flags: &FlagMap) -> Result<Value, UsageError> {
    Ok(json!({ "title": flags.required("title")? }))
}

fn build_rename_pane(flags: &FlagMap) -> Result<Value, UsageError> {
    Ok(json!({ "pane": flags.required_u64("pane")?, "name": flags.required("name")? }))
}

fn build_rename_surface(flags: &FlagMap) -> Result<Value, UsageError> {
    Ok(json!({ "surface": flags.required_u64("surface")?, "name": flags.required("name")? }))
}

fn build_rename_screen(flags: &FlagMap) -> Result<Value, UsageError> {
    Ok(json!({ "screen": flags.required_u64("screen")?, "name": flags.required("name")? }))
}

fn build_rename_workspace(flags: &FlagMap) -> Result<Value, UsageError> {
    Ok(json!({ "workspace": flags.required_u64("workspace")?, "name": flags.required("name")? }))
}

fn build_resize_surface(flags: &FlagMap) -> Result<Value, UsageError> {
    Ok(json!({
        "surface": flags.required_u64("surface")?,
        "cols": flags.required_u16("cols")?,
        "rows": flags.required_u16("rows")?,
    }))
}

fn build_select_tab(flags: &FlagMap) -> Result<Value, UsageError> {
    let mut value = selector_request(flags)?;
    flags.insert_optional_u64(&mut value, "pane")?;
    Ok(value)
}

fn build_select_screen(flags: &FlagMap) -> Result<Value, UsageError> {
    selector_request(flags)
}

fn build_select_workspace(flags: &FlagMap) -> Result<Value, UsageError> {
    selector_request(flags)
}

fn build_move_tab(flags: &FlagMap) -> Result<Value, UsageError> {
    Ok(json!({
        "surface": flags.required_u64("surface")?,
        "pane": flags.required_u64("pane")?,
        "index": flags.required_usize("index")?,
    }))
}

fn build_move_workspace(flags: &FlagMap) -> Result<Value, UsageError> {
    Ok(json!({
        "workspace": flags.required_u64("workspace")?,
        "index": flags.required_usize("index")?,
    }))
}

fn build_scroll_surface(flags: &FlagMap) -> Result<Value, UsageError> {
    Ok(json!({
        "surface": flags.required_u64("surface")?,
        "delta": flags.required_isize("delta")?,
    }))
}

fn selector_request(flags: &FlagMap) -> Result<Value, UsageError> {
    match (flags.optional("index"), flags.optional("delta")) {
        (Some(_), Some(_)) => Err(UsageError("use only one of --index or --delta".to_string())),
        (Some(index), None) => Ok(json!({ "index": parse_usize("index", &index)? })),
        (None, Some(delta)) => Ok(json!({ "delta": parse_isize("delta", &delta)? })),
        (None, None) => Err(UsageError("one of --index or --delta is required".to_string())),
    }
}

impl FlagMap {
    fn reject_remaining(&self) -> Result<(), UsageError> {
        if let Some(name) = self.values.keys().next() {
            return Err(UsageError(format!("unexpected --{name}")));
        }
        Ok(())
    }

    fn optional(&self, name: &str) -> Option<String> {
        self.values.get(name).cloned()
    }

    fn required(&self, name: &str) -> Result<String, UsageError> {
        self.optional(name).ok_or_else(|| UsageError(format!("--{name} is required")))
    }

    fn required_u64(&self, name: &str) -> Result<u64, UsageError> {
        parse_u64(name, &self.required(name)?)
    }

    fn required_u16(&self, name: &str) -> Result<u16, UsageError> {
        parse_u16(name, &self.required(name)?)
    }

    fn required_u32(&self, name: &str) -> Result<u32, UsageError> {
        parse_u32(name, &self.required(name)?)
    }

    fn required_usize(&self, name: &str) -> Result<usize, UsageError> {
        parse_usize(name, &self.required(name)?)
    }

    fn required_isize(&self, name: &str) -> Result<isize, UsageError> {
        parse_isize(name, &self.required(name)?)
    }

    fn required_f32(&self, name: &str) -> Result<f32, UsageError> {
        self.required(name)?
            .parse::<f32>()
            .map_err(|_| UsageError(format!("--{name} must be a number")))
    }

    fn required_dir(&self) -> Result<String, UsageError> {
        let dir = self.required("dir")?;
        if dir == "right" || dir == "down" {
            Ok(dir)
        } else {
            Err(UsageError("--dir must be right or down".to_string()))
        }
    }

    fn required_direction(&self) -> Result<String, UsageError> {
        parse_direction("dir", &self.required("dir")?)
    }

    fn required_json(&self, name: &str) -> Result<Value, UsageError> {
        serde_json::from_str(&self.required(name)?)
            .map_err(|err| UsageError(format!("--{name} must be JSON: {err}")))
    }

    fn insert_optional_string(&self, value: &mut Value, name: &str) {
        if let Some(text) = self.optional(name) {
            value[name] = json!(text);
        }
    }

    fn insert_optional_u64(&self, value: &mut Value, name: &str) -> Result<(), UsageError> {
        if let Some(raw) = self.optional(name) {
            value[name] = json!(parse_u64(name, &raw)?);
        }
        Ok(())
    }

    fn insert_optional_size(&self, value: &mut Value) -> Result<(), UsageError> {
        match (self.optional("cols"), self.optional("rows")) {
            (Some(cols), Some(rows)) => {
                value["cols"] = json!(parse_u16("cols", &cols)?);
                value["rows"] = json!(parse_u16("rows", &rows)?);
                Ok(())
            }
            (None, None) => Ok(()),
            _ => Err(UsageError("--cols and --rows must be supplied together".to_string())),
        }
    }
}

fn parse_u64(name: &str, value: &str) -> Result<u64, UsageError> {
    value.parse::<u64>().map_err(|_| UsageError(format!("--{name} must be a uint64")))
}

fn parse_u16(name: &str, value: &str) -> Result<u16, UsageError> {
    value.parse::<u16>().map_err(|_| UsageError(format!("--{name} must be a uint16")))
}

fn parse_u32(name: &str, value: &str) -> Result<u32, UsageError> {
    value.parse::<u32>().map_err(|_| UsageError(format!("--{name} must be a uint32")))
}

fn parse_usize(name: &str, value: &str) -> Result<usize, UsageError> {
    value.parse::<usize>().map_err(|_| UsageError(format!("--{name} must be a usize")))
}

fn parse_isize(name: &str, value: &str) -> Result<isize, UsageError> {
    value.parse::<isize>().map_err(|_| UsageError(format!("--{name} must be an isize")))
}

fn parse_direction(name: &str, value: &str) -> Result<String, UsageError> {
    match value {
        "left" | "right" | "up" | "down" => Ok(value.to_string()),
        _ => Err(UsageError(format!("--{name} must be left, right, up, or down"))),
    }
}

fn parse_zoom_mode(value: &str) -> Result<String, UsageError> {
    match value {
        "toggle" | "on" | "off" => Ok(value.to_string()),
        _ => Err(UsageError("--mode must be toggle, on, or off".to_string())),
    }
}

fn print_empty(_: &Value, _: &mut dyn Write) -> io::Result<()> {
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

fn print_process_info(data: &Value, out: &mut dyn Write) -> io::Result<()> {
    writeln!(
        out,
        "pid={} command={} cwd={} tty={}",
        atom(data.get("pid")),
        atom(data.get("command")),
        atom(data.get("cwd")),
        atom(data.get("tty"))
    )
}

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
    fn protocol_v7_and_v8_cli_builders_emit_versioned_fields() {
        let flags = FlagMap {
            values: BTreeMap::from([
                ("surface".to_string(), "9".to_string()),
                ("text".to_string(), "hello".to_string()),
                ("paste".to_string(), "true".to_string()),
            ]),
            ..Default::default()
        };
        assert_eq!(
            build_send(&flags).unwrap(),
            json!({"surface": 9, "text": "hello", "paste": true})
        );

        let flags = FlagMap {
            values: BTreeMap::from([
                ("surface".to_string(), "9".to_string()),
                ("mode".to_string(), "render".to_string()),
            ]),
            ..Default::default()
        };
        assert_eq!(build_attach_surface(&flags).unwrap(), json!({"surface": 9, "mode": "render"}));

        let flags = FlagMap {
            values: BTreeMap::from([("tree-events".to_string(), "deltas".to_string())]),
            ..Default::default()
        };
        assert_eq!(build_subscribe(&flags).unwrap(), json!({"tree_events": "deltas"}));

        let daemon_instance_id = cmux_tui_core::DaemonInstanceId::new();
        let session_id = cmux_tui_core::SessionId::new();
        let flags = FlagMap {
            values: BTreeMap::from([
                ("daemon-instance-id".to_string(), daemon_instance_id.to_string()),
                ("session-id".to_string(), session_id.to_string()),
                ("revision".to_string(), "42".to_string()),
            ]),
            ..Default::default()
        };
        assert_eq!(
            build_subscribe_topology(&flags).unwrap(),
            json!({
                "daemon_instance_id": daemon_instance_id,
                "session_id": session_id,
                "revision": 42,
            })
        );

        let flags = FlagMap {
            values: BTreeMap::from([
                ("surface".to_string(), "9".to_string()),
                ("start".to_string(), "40".to_string()),
                ("count".to_string(), "2".to_string()),
            ]),
            ..Default::default()
        };
        assert_eq!(
            build_read_scrollback(&flags).unwrap(),
            json!({"surface": 9, "start": 40, "count": 2})
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
