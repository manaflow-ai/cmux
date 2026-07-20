use std::collections::BTreeMap;
use std::io::{self, BufRead, BufReader, Read, Write};
use std::path::PathBuf;
use std::time::{Duration, Instant};

use cmux_tui_core::platform::transport;
use serde_json::{Value, json};

const REQUEST_ID: u64 = 1;
const CAPABILITY_REQUEST_ID: u64 = 0;
const ATTACH_INITIAL_SIZE_CAPABILITY: &str = "attach-initial-size";

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
        name: "new-pane",
        help: "Create a pane with automatic distribution.",
        allowed: &["pane", "cols", "rows"],
        kind: socket(build_new_pane, print_surface, false),
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
        name: "set-split-ratio",
        help: "Set a split ratio by stable split id.",
        allowed: &["split", "ratio"],
        kind: socket(build_set_split_ratio, print_empty, false),
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
        name: "attach-surface",
        help: "Attach to a surface stream.",
        allowed: &["surface", "mode", "cols", "rows"],
        kind: socket(build_attach_surface, print_empty, true),
    },
    VerbSpec {
        name: "plugin",
        help: "Manage installed sidebar plugins locally.",
        allowed: &["name", "force", "builtin"],
        kind: VerbKind::Local(run_plugin),
    },
];

const fn socket(build: BuildFn, print: PrintFn, stream: bool) -> VerbKind {
    VerbKind::Socket { build, print, stream }
}

pub fn is_cli_invocation(args: &[String]) -> bool {
    matches!(first_command_arg(args), FirstCommand::Help | FirstCommand::Verb)
}

pub fn run(args: &[String], usage: &str) -> i32 {
    match parse(args) {
        Ok(Parsed::Help) => {
            print_help(usage);
            0
        }
        Ok(Parsed::Command(args)) => run_command(args),
        Err(err) => {
            eprintln!("cmux-tui: {}", err.0);
            2
        }
    }
}

pub fn print_help(usage: &str) {
    print!("{usage}");
    println!();
    println!("VERB HELP");
    for verb in VERBS {
        println!("  {:<18} {}", verb.name, verb.help);
    }
}

enum FirstCommand {
    None,
    Help,
    Verb,
}

enum Parsed {
    Help,
    Command(CliArgs),
}

fn first_command_arg(args: &[String]) -> FirstCommand {
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--socket" | "--session" => i += 2,
            "--json" => i += 1,
            "-h" | "--help" => return FirstCommand::Help,
            arg if arg.starts_with("--") => return FirstCommand::None,
            "help" => return FirstCommand::Help,
            arg if verb_by_name(arg).is_some() => return FirstCommand::Verb,
            _ => return FirstCommand::None,
        }
    }
    FirstCommand::None
}

fn parse(args: &[String]) -> Result<Parsed, UsageError> {
    if matches!(first_command_arg(args), FirstCommand::Help) {
        return Ok(Parsed::Help);
    }

    let mut global = GlobalArgs::default();
    let mut flags = FlagMap::default();
    let mut verb: Option<&'static VerbSpec> = None;
    let mut i = 0;
    while i < args.len() {
        let arg = args[i].as_str();
        match arg {
            "-h" | "--help" | "help" => return Ok(Parsed::Help),
            "--json" => {
                global.json = true;
                i += 1;
            }
            "--socket" => {
                global.socket = Some(PathBuf::from(value_after(args, i, "--socket")?));
                i += 2;
            }
            "--session" => {
                if verb.is_some_and(|spec| spec.allowed.contains(&"session")) {
                    let value = value_after(args, i, "--session")?;
                    if flags.values.insert("session".to_string(), value).is_some() {
                        return Err(UsageError(format!("duplicate flag {arg:?}")));
                    }
                    i += 2;
                } else {
                    global.session = Some(value_after(args, i, "--session")?);
                    i += 2;
                }
            }
            _ if verb.is_none() && verb_by_name(arg).is_some() => {
                verb = verb_by_name(arg);
                i += 1;
            }
            "--" => {
                let Some(spec) = verb else {
                    return Err(UsageError("missing verb before --".to_string()));
                };
                if spec.name != "run" {
                    return Err(UsageError(format!("unexpected argument {arg:?}")));
                }
                flags.positionals.extend(args[i + 1..].iter().cloned());
                break;
            }
            _ if arg.starts_with("--") => {
                let Some(spec) = verb else {
                    return Err(UsageError(format!("unknown global flag {arg:?}")));
                };
                let name = arg.trim_start_matches("--");
                if !spec.allowed.contains(&name) {
                    return Err(UsageError(format!("unknown flag {arg:?} for {}", spec.name)));
                }
                if is_boolean_flag(spec, name) {
                    if flags.values.insert(name.to_string(), "true".to_string()).is_some() {
                        return Err(UsageError(format!("duplicate flag {arg:?}")));
                    }
                    i += 1;
                    continue;
                }
                let value = value_after(args, i, arg)?;
                if flags.values.insert(name.to_string(), value).is_some() {
                    return Err(UsageError(format!("duplicate flag {arg:?}")));
                }
                i += 2;
            }
            _ if verb.is_some() => {
                let spec = verb.unwrap();
                if spec.name == "send-key" || matches!(spec.kind, VerbKind::Local(_)) {
                    flags.positionals.push(arg.to_string());
                    i += 1;
                } else {
                    return Err(UsageError(format!("unexpected argument {arg:?}")));
                }
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
    if stream_mode {
        let _ = stream.set_read_timeout(Some(Duration::from_millis(250)));
    } else {
        let _ = stream.set_read_timeout(Some(Duration::from_secs(10)));
    }
    let mut reader = BufReader::new(stream);
    if request.get("cmd").and_then(Value::as_str) == Some("attach-surface")
        && request.get("cols").is_some()
    {
        match server_supports_capability(&mut reader, ATTACH_INITIAL_SIZE_CAPABILITY) {
            Ok(true) => {}
            Ok(false) => {
                eprintln!("initial attach sizing is not supported by this server");
                return 1;
            }
            Err(err) => {
                eprintln!("{err}");
                return 3;
            }
        }
    }
    if let Err(err) = write_json_line(reader.get_mut(), &request) {
        eprintln!("transport error: {err}");
        return 3;
    }
    if stream_mode {
        run_stream(reader)
    } else {
        run_one_response(&mut reader, args.global.json, print)
    }
}

fn write_json_line(writer: &mut dyn Write, value: &Value) -> io::Result<()> {
    serde_json::to_writer(&mut *writer, value).map_err(io::Error::other)?;
    writer.write_all(b"\n")
}

fn server_supports_capability(
    reader: &mut BufReader<Box<dyn transport::Stream>>,
    capability: &str,
) -> Result<bool, String> {
    write_json_line(reader.get_mut(), &json!({"id": CAPABILITY_REQUEST_ID, "cmd": "identify"}))
        .map_err(|err| format!("transport error: {err}"))?;
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut line = String::new();

    loop {
        match reader.read_line(&mut line) {
            Ok(0) => return Err("transport closed before identify response".to_string()),
            Ok(_) => {}
            Err(err)
                if matches!(err.kind(), io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut)
                    && Instant::now() < deadline =>
            {
                continue;
            }
            Err(err)
                if matches!(err.kind(), io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut) =>
            {
                return Err("timed out waiting for identify response".to_string());
            }
            Err(err) => return Err(format!("transport error: {err}")),
        }
        let value: Value =
            serde_json::from_str(&line).map_err(|err| format!("bad identify response: {err}"))?;
        if value.get("event").is_some()
            || value.get("id").and_then(Value::as_u64) != Some(CAPABILITY_REQUEST_ID)
        {
            line.clear();
            continue;
        }
        if value.get("ok").and_then(Value::as_bool) != Some(true) {
            return Err(value
                .get("error")
                .and_then(Value::as_str)
                .unwrap_or("identify failed")
                .to_string());
        }
        return Ok(value
            .pointer("/data/capabilities")
            .and_then(Value::as_array)
            .is_some_and(|values| values.iter().any(|value| value.as_str() == Some(capability))));
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
        let value = match serde_json::from_str::<Value>(&line) {
            Ok(value) => value,
            Err(err) => {
                eprintln!("bad response: {err}");
                return 3;
            }
        };
        if value.get("event").is_some() {
            continue;
        }
        return print_response(&value, json_output, print_human);
    }
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

fn build_attach_surface(flags: &FlagMap) -> Result<Value, UsageError> {
    let mut value = json!({ "surface": flags.required_u64("surface")? });
    if let Some(mode) = flags.optional("mode") {
        if !matches!(mode.as_str(), "bytes" | "render") {
            return Err(UsageError("--mode must be bytes or render".to_string()));
        }
        value["mode"] = json!(mode);
    }
    flags.insert_optional_size(&mut value)?;
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

fn build_new_pane(flags: &FlagMap) -> Result<Value, UsageError> {
    let mut value = json!({ "pane": flags.required_u64("pane")? });
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

fn build_set_split_ratio(flags: &FlagMap) -> Result<Value, UsageError> {
    Ok(json!({
        "split": flags.required_u64("split")?,
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

fn print_identify(data: &Value, out: &mut dyn Write) -> io::Result<()> {
    writeln!(
        out,
        "cmux-tui session={} protocol={} pid={}",
        data.get("session").and_then(Value::as_str).unwrap_or(""),
        data.get("protocol").and_then(Value::as_u64).unwrap_or(0),
        data.get("pid").and_then(Value::as_u64).unwrap_or(0)
    )
}

fn print_ping(data: &Value, out: &mut dyn Write) -> io::Result<()> {
    writeln!(
        out,
        "cmux-tui version={} protocol={}",
        data.get("version").and_then(Value::as_str).unwrap_or(""),
        data.get("protocol").and_then(Value::as_u64).unwrap_or(0)
    )
}

fn print_clients(data: &Value, out: &mut dyn Write) -> io::Result<()> {
    let Some(clients) = data.as_array() else { return Ok(()) };
    for client in clients {
        let attached = client
            .get("attached")
            .and_then(Value::as_array)
            .map(|surfaces| {
                surfaces
                    .iter()
                    .filter_map(Value::as_u64)
                    .map(|surface| surface.to_string())
                    .collect::<Vec<_>>()
                    .join(",")
            })
            .filter(|value| !value.is_empty())
            .unwrap_or_else(|| "-".to_string());
        let sizes = client
            .get("sizes")
            .and_then(Value::as_array)
            .map(|sizes| {
                sizes
                    .iter()
                    .map(|size| {
                        let surface = size.get("surface").and_then(Value::as_u64).unwrap_or(0);
                        match (
                            size.get("cols").and_then(Value::as_u64),
                            size.get("rows").and_then(Value::as_u64),
                        ) {
                            (Some(cols), Some(rows)) => format!("{surface}:{cols}x{rows}"),
                            _ => format!("{surface}:null"),
                        }
                    })
                    .collect::<Vec<_>>()
                    .join(",")
            })
            .filter(|value| !value.is_empty())
            .unwrap_or_else(|| "-".to_string());
        writeln!(
            out,
            "{} {} {} {} connected={}s attached={} sizes={} self={} sizing={}",
            client.get("client").and_then(Value::as_u64).unwrap_or(0),
            client.get("transport").and_then(Value::as_str).unwrap_or(""),
            client.get("name").and_then(Value::as_str).unwrap_or("-"),
            client.get("kind").and_then(Value::as_str).unwrap_or("-"),
            client.get("connected_seconds").and_then(Value::as_u64).unwrap_or(0),
            attached,
            sizes,
            client.get("self").and_then(Value::as_bool).unwrap_or(false),
            client.get("size_participating").and_then(Value::as_bool).unwrap_or(true),
        )?;
    }
    Ok(())
}

fn print_read_screen(data: &Value, out: &mut dyn Write) -> io::Result<()> {
    write!(out, "{}", data.get("text").and_then(Value::as_str).unwrap_or(""))
}

fn print_scrollback(data: &Value, out: &mut dyn Write) -> io::Result<()> {
    let Some(rows) = data.get("rows").and_then(Value::as_array) else { return Ok(()) };
    for row in rows {
        if let Some(runs) = row.get("runs").and_then(Value::as_array) {
            for run in runs {
                write!(out, "{}", run.get("text").and_then(Value::as_str).unwrap_or(""))?;
            }
        }
        writeln!(out)?;
    }
    Ok(())
}

fn print_vt_state(data: &Value, out: &mut dyn Write) -> io::Result<()> {
    writeln!(
        out,
        "cols={} rows={} data={}",
        data.get("cols").and_then(Value::as_u64).unwrap_or(0),
        data.get("rows").and_then(Value::as_u64).unwrap_or(0),
        data.get("data").and_then(Value::as_str).unwrap_or("")
    )
}

fn print_surface(data: &Value, out: &mut dyn Write) -> io::Result<()> {
    writeln!(out, "{}", data.get("surface").and_then(Value::as_u64).unwrap_or(0))
}

fn print_notification(data: &Value, out: &mut dyn Write) -> io::Result<()> {
    writeln!(out, "{}", data.get("notification").and_then(Value::as_u64).unwrap_or(0))
}

fn print_ids(data: &Value, out: &mut dyn Write) -> io::Result<()> {
    let Some(ids) = data.get("ids").and_then(Value::as_array) else { return Ok(()) };
    for item in ids {
        writeln!(
            out,
            "{} {} {}",
            item.get("kind").and_then(Value::as_str).unwrap_or(""),
            item.get("id").and_then(Value::as_u64).unwrap_or(0),
            item.get("short_id").and_then(Value::as_str).unwrap_or("")
        )?;
    }
    Ok(())
}

fn print_pane(data: &Value, out: &mut dyn Write) -> io::Result<()> {
    writeln!(out, "{}", data.get("pane").and_then(Value::as_u64).unwrap_or(0))
}

fn print_optional_pane(data: &Value, out: &mut dyn Write) -> io::Result<()> {
    match data.get("pane").and_then(Value::as_u64) {
        Some(pane) => writeln!(out, "{pane}"),
        None => writeln!(out, "null"),
    }
}

fn print_json_data(data: &Value, out: &mut dyn Write) -> io::Result<()> {
    serde_json::to_writer(&mut *out, data).map_err(io::Error::other)?;
    writeln!(out)
}

fn print_applied_layout(data: &Value, out: &mut dyn Write) -> io::Result<()> {
    writeln!(out, "screen={}", data.get("screen").and_then(Value::as_u64).unwrap_or(0))?;
    if let Some(panes) = data.get("panes").and_then(Value::as_array) {
        for pane in panes {
            writeln!(
                out,
                "pane={} surface={}",
                pane.get("pane").and_then(Value::as_u64).unwrap_or(0),
                pane.get("surface").and_then(Value::as_u64).unwrap_or(0)
            )?;
        }
    }
    Ok(())
}

fn print_agents(data: &Value, out: &mut dyn Write) -> io::Result<()> {
    let Some(agents) = data.get("agents").and_then(Value::as_array) else { return Ok(()) };
    for agent in agents {
        writeln!(
            out,
            "{} {} {} {}",
            agent.get("surface").and_then(Value::as_u64).unwrap_or(0),
            agent.get("state").and_then(Value::as_str).unwrap_or(""),
            agent.get("source").and_then(Value::as_str).unwrap_or(""),
            agent.get("session").and_then(Value::as_str).unwrap_or("-")
        )?;
    }
    Ok(())
}

fn print_zoom_state(data: &Value, out: &mut dyn Write) -> io::Result<()> {
    writeln!(
        out,
        "pane={} zoomed={} zoomed_pane={}",
        data.get("pane").and_then(Value::as_u64).unwrap_or(0),
        data.get("zoomed").and_then(Value::as_bool).unwrap_or(false),
        atom(data.get("zoomed_pane"))
    )
}

fn print_process_info(data: &Value, out: &mut dyn Write) -> io::Result<()> {
    writeln!(
        out,
        "pid={} command={} cwd={}",
        atom(data.get("pid")),
        atom(data.get("command")),
        atom(data.get("cwd"))
    )
}

fn print_tree(data: &Value, out: &mut dyn Write) -> io::Result<()> {
    let Some(workspaces) = data.get("workspaces").and_then(Value::as_array) else {
        return Ok(());
    };
    for workspace in workspaces {
        let workspace_id = id_field(workspace, "id");
        writeln!(
            out,
            "workspace id={} name={} active={}",
            workspace_id,
            atom(workspace.get("name")),
            bool_field(workspace, "active")
        )?;
        let Some(screens) = workspace.get("screens").and_then(Value::as_array) else {
            continue;
        };
        for screen in screens {
            let screen_id = id_field(screen, "id");
            writeln!(
                out,
                "screen id={} workspace={} name={} active={} active_pane={}",
                screen_id,
                workspace_id,
                atom(screen.get("name")),
                bool_field(screen, "active"),
                id_field(screen, "active_pane")
            )?;
            let Some(panes) = screen.get("panes").and_then(Value::as_array) else {
                continue;
            };
            for pane in panes {
                let pane_id = id_field(pane, "id");
                if bool_field(pane, "dead") {
                    writeln!(out, "pane id={pane_id} screen={screen_id} dead=true")?;
                    continue;
                }
                writeln!(
                    out,
                    "pane id={} screen={} name={} active_tab={}",
                    pane_id,
                    screen_id,
                    atom(pane.get("name")),
                    id_field(pane, "active_tab")
                )?;
                let Some(tabs) = pane.get("tabs").and_then(Value::as_array) else {
                    continue;
                };
                for tab in tabs {
                    let size = tab.get("size");
                    let (cols, rows) = match size {
                        Some(size) if size.is_object() => {
                            (id_field(size, "cols"), id_field(size, "rows"))
                        }
                        _ => (0, 0),
                    };
                    writeln!(
                        out,
                        "tab surface={} pane={} kind={} browser_source={} name={} title={} dead={} cols={} rows={}",
                        id_field(tab, "surface"),
                        pane_id,
                        tab.get("kind").and_then(Value::as_str).unwrap_or(""),
                        atom(tab.get("browser_source")),
                        atom(tab.get("name")),
                        atom(tab.get("title")),
                        bool_field(tab, "dead"),
                        cols,
                        rows
                    )?;
                }
            }
        }
    }
    Ok(())
}

fn id_field(value: &Value, key: &str) -> u64 {
    value.get(key).and_then(Value::as_u64).unwrap_or(0)
}

fn bool_field(value: &Value, key: &str) -> bool {
    value.get(key).and_then(Value::as_bool).unwrap_or(false)
}

fn atom(value: Option<&Value>) -> String {
    match value {
        Some(Value::String(text)) => serde_json::to_string(text).unwrap_or_default(),
        Some(Value::Null) | None => "null".to_string(),
        Some(value) => value.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use std::collections::VecDeque;
    use std::net::Shutdown;

    use super::*;

    struct ScriptedStream {
        reads: VecDeque<Result<Vec<u8>, io::ErrorKind>>,
        current: io::Cursor<Vec<u8>>,
        writes: Vec<u8>,
    }

    impl Read for ScriptedStream {
        fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
            if self.current.position() < self.current.get_ref().len() as u64 {
                return self.current.read(buf);
            }
            match self.reads.pop_front() {
                Some(Ok(bytes)) => {
                    self.current = io::Cursor::new(bytes);
                    self.current.read(buf)
                }
                Some(Err(kind)) => Err(io::Error::from(kind)),
                None => Ok(0),
            }
        }
    }

    impl Write for ScriptedStream {
        fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
            self.writes.extend_from_slice(buf);
            Ok(buf.len())
        }

        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    impl transport::Stream for ScriptedStream {
        fn try_clone_box(&self) -> io::Result<Box<dyn transport::Stream>> {
            Err(io::Error::new(io::ErrorKind::Unsupported, "test stream is not cloneable"))
        }

        fn set_read_timeout(&self, _timeout: Option<Duration>) -> io::Result<()> {
            Ok(())
        }

        fn set_write_timeout(&self, _timeout: Option<Duration>) -> io::Result<()> {
            Ok(())
        }

        fn shutdown(&self, _how: Shutdown) -> io::Result<()> {
            Ok(())
        }
    }

    #[test]
    fn capability_probe_tolerates_polling_timeouts() {
        let stream = ScriptedStream {
            reads: VecDeque::from([
                Err(io::ErrorKind::WouldBlock),
                Err(io::ErrorKind::TimedOut),
                Ok(b"{\"id\":0,\"ok\":true,\"data\":{\"capabilities\":[\"attach-initial-size\"]}}\n"
                    .to_vec()),
            ]),
            current: io::Cursor::new(Vec::new()),
            writes: Vec::new(),
        };
        let mut reader = BufReader::new(Box::new(stream) as Box<dyn transport::Stream>);

        assert_eq!(
            server_supports_capability(&mut reader, ATTACH_INITIAL_SIZE_CAPABILITY),
            Ok(true)
        );
    }

    #[test]
    fn capability_probe_preserves_partial_line_across_timeout() {
        let stream = ScriptedStream {
            reads: VecDeque::from([
                Ok(b"{\"id\":0,\"ok\":true,\"data\":".to_vec()),
                Err(io::ErrorKind::TimedOut),
                Ok(b"{\"capabilities\":[\"attach-initial-size\"]}}\n".to_vec()),
            ]),
            current: io::Cursor::new(Vec::new()),
            writes: Vec::new(),
        };
        let mut reader = BufReader::new(Box::new(stream) as Box<dyn transport::Stream>);

        assert_eq!(
            server_supports_capability(&mut reader, ATTACH_INITIAL_SIZE_CAPABILITY),
            Ok(true)
        );
    }

    #[test]
    fn plugin_verb_is_registered_as_local_with_help() {
        let plugin = verb_by_name("plugin").expect("plugin verb registered");
        assert!(matches!(plugin.kind, VerbKind::Local(_)));
        assert!(plugin.allowed.contains(&"name"));
        assert!(plugin.allowed.contains(&"force"));
        assert!(plugin.allowed.contains(&"builtin"));
        assert!(plugin.help.contains("sidebar plugins"));
    }

    #[test]
    fn registered_verbs_have_help_text() {
        assert!(VERBS.iter().all(|verb| !verb.help.is_empty()));
    }

    #[test]
    fn protocol_v7_cli_builders_emit_render_tree_paste_and_scrollback_fields() {
        let attach = VERBS.iter().find(|verb| verb.name == "attach-surface").unwrap();
        assert!(attach.allowed.contains(&"cols"));
        assert!(attach.allowed.contains(&"rows"));

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
                ("cols".to_string(), "120".to_string()),
                ("rows".to_string(), "40".to_string()),
            ]),
            ..Default::default()
        };
        assert_eq!(
            build_attach_surface(&flags).unwrap(),
            json!({"surface": 9, "mode": "render", "cols": 120, "rows": 40})
        );

        let flags = FlagMap {
            values: BTreeMap::from([
                ("surface".to_string(), "9".to_string()),
                ("cols".to_string(), "120".to_string()),
            ]),
            ..Default::default()
        };
        assert_eq!(
            build_attach_surface(&flags).unwrap_err().0,
            "--cols and --rows must be supplied together"
        );

        let flags = FlagMap {
            values: BTreeMap::from([("tree-events".to_string(), "deltas".to_string())]),
            ..Default::default()
        };
        assert_eq!(build_subscribe(&flags).unwrap(), json!({"tree_events": "deltas"}));

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
    fn scrollback_human_output_flattens_runs_one_row_per_line() {
        let data = json!({
            "rows": [
                {"row": 0, "runs": [{"text": "car"}, {"text": "go"}]},
                {"row": 1, "runs": [{"text": "ok"}]},
            ],
            "start": 0,
            "total": 2,
        });
        let mut output = Vec::new();
        print_scrollback(&data, &mut output).unwrap();
        assert_eq!(output, b"cargo\nok\n");
    }
}
