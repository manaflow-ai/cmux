use std::collections::BTreeMap;
use std::io::{self, BufRead, BufReader, Read, Write};
use std::path::PathBuf;
use std::time::Duration;

use mux_core::platform::transport;
use serde_json::{json, Value};

const REQUEST_ID: u64 = 1;

type BuildFn = fn(&FlagMap) -> Result<Value, UsageError>;
type PrintFn = fn(&Value, &mut dyn Write) -> io::Result<()>;

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
    allowed: &'static [&'static str],
    build: BuildFn,
    print: PrintFn,
    stream: bool,
}

const VERBS: &[VerbSpec] = &[
    VerbSpec {
        name: "identify",
        allowed: &[],
        build: build_no_args,
        print: print_identify,
        stream: false,
    },
    VerbSpec {
        name: "list-workspaces",
        allowed: &[],
        build: build_no_args,
        print: print_tree,
        stream: false,
    },
    VerbSpec {
        name: "export-layout",
        allowed: &["screen"],
        build: build_export_layout,
        print: print_json_data,
        stream: false,
    },
    VerbSpec {
        name: "apply-layout",
        allowed: &["workspace", "name", "layout"],
        build: build_apply_layout,
        print: print_applied_layout,
        stream: false,
    },
    VerbSpec {
        name: "send",
        allowed: &["surface", "text", "bytes"],
        build: build_send,
        print: print_empty,
        stream: false,
    },
    VerbSpec {
        name: "read-screen",
        allowed: &["surface"],
        build: build_surface,
        print: print_read_screen,
        stream: false,
    },
    VerbSpec {
        name: "wait-for",
        allowed: &["surface", "pattern", "timeout-ms"],
        build: build_wait_for,
        print: print_empty,
        stream: false,
    },
    VerbSpec {
        name: "run",
        allowed: &["pane", "new-workspace", "cwd", "name", "command"],
        build: build_run,
        print: print_surface,
        stream: false,
    },
    VerbSpec {
        name: "send-key",
        allowed: &["surface"],
        build: build_send_key,
        print: print_empty,
        stream: false,
    },
    VerbSpec {
        name: "copy",
        allowed: &["surface", "mode"],
        build: build_copy,
        print: print_read_screen,
        stream: false,
    },
    VerbSpec { name: "ids", allowed: &["kind"], build: build_ids, print: print_ids, stream: false },
    VerbSpec {
        name: "notify",
        allowed: &["title", "body", "level", "surface"],
        build: build_notify,
        print: print_notification,
        stream: false,
    },
    VerbSpec {
        name: "list-agents",
        allowed: &["surface", "state"],
        build: build_list_agents,
        print: print_agents,
        stream: false,
    },
    VerbSpec {
        name: "report-agent",
        allowed: &["surface", "state", "source", "session"],
        build: build_report_agent,
        print: print_empty,
        stream: false,
    },
    VerbSpec {
        name: "vt-state",
        allowed: &["surface"],
        build: build_surface,
        print: print_vt_state,
        stream: false,
    },
    VerbSpec {
        name: "new-tab",
        allowed: &["pane", "cwd", "cols", "rows"],
        build: build_new_tab,
        print: print_surface,
        stream: false,
    },
    VerbSpec {
        name: "new-browser-tab",
        allowed: &["url", "pane", "cols", "rows"],
        build: build_new_browser_tab,
        print: print_surface,
        stream: false,
    },
    VerbSpec {
        name: "new-workspace",
        allowed: &["name", "cols", "rows"],
        build: build_new_workspace,
        print: print_surface,
        stream: false,
    },
    VerbSpec {
        name: "new-screen",
        allowed: &["workspace", "cols", "rows"],
        build: build_new_screen,
        print: print_surface,
        stream: false,
    },
    VerbSpec {
        name: "split",
        allowed: &["pane", "dir", "cols", "rows"],
        build: build_split,
        print: print_surface,
        stream: false,
    },
    VerbSpec {
        name: "set-ratio",
        allowed: &["pane", "dir", "ratio"],
        build: build_set_ratio,
        print: print_empty,
        stream: false,
    },
    VerbSpec {
        name: "pane-neighbor",
        allowed: &["pane", "dir"],
        build: build_pane_direction,
        print: print_optional_pane,
        stream: false,
    },
    VerbSpec {
        name: "focus-direction",
        allowed: &["pane", "dir"],
        build: build_optional_pane_direction,
        print: print_pane,
        stream: false,
    },
    VerbSpec {
        name: "swap-pane",
        allowed: &["pane", "dir", "target"],
        build: build_swap_pane,
        print: print_empty,
        stream: false,
    },
    VerbSpec {
        name: "zoom-pane",
        allowed: &["pane", "mode"],
        build: build_zoom_pane,
        print: print_zoom_state,
        stream: false,
    },
    VerbSpec {
        name: "process-info",
        allowed: &["surface"],
        build: build_surface,
        print: print_process_info,
        stream: false,
    },
    VerbSpec {
        name: "set-default-colors",
        allowed: &["fg", "bg"],
        build: build_set_default_colors,
        print: print_empty,
        stream: false,
    },
    VerbSpec {
        name: "close-surface",
        allowed: &["surface"],
        build: build_surface,
        print: print_empty,
        stream: false,
    },
    VerbSpec {
        name: "close-pane",
        allowed: &["pane"],
        build: build_pane,
        print: print_empty,
        stream: false,
    },
    VerbSpec {
        name: "close-screen",
        allowed: &["screen"],
        build: build_screen,
        print: print_empty,
        stream: false,
    },
    VerbSpec {
        name: "close-workspace",
        allowed: &["workspace"],
        build: build_workspace,
        print: print_empty,
        stream: false,
    },
    VerbSpec {
        name: "rename-pane",
        allowed: &["pane", "name"],
        build: build_rename_pane,
        print: print_empty,
        stream: false,
    },
    VerbSpec {
        name: "rename-surface",
        allowed: &["surface", "name"],
        build: build_rename_surface,
        print: print_empty,
        stream: false,
    },
    VerbSpec {
        name: "rename-screen",
        allowed: &["screen", "name"],
        build: build_rename_screen,
        print: print_empty,
        stream: false,
    },
    VerbSpec {
        name: "rename-workspace",
        allowed: &["workspace", "name"],
        build: build_rename_workspace,
        print: print_empty,
        stream: false,
    },
    VerbSpec {
        name: "resize-surface",
        allowed: &["surface", "cols", "rows"],
        build: build_resize_surface,
        print: print_empty,
        stream: false,
    },
    VerbSpec {
        name: "focus-pane",
        allowed: &["pane"],
        build: build_pane,
        print: print_empty,
        stream: false,
    },
    VerbSpec {
        name: "select-tab",
        allowed: &["pane", "index", "delta"],
        build: build_select_tab,
        print: print_empty,
        stream: false,
    },
    VerbSpec {
        name: "select-screen",
        allowed: &["index", "delta"],
        build: build_select_screen,
        print: print_empty,
        stream: false,
    },
    VerbSpec {
        name: "select-workspace",
        allowed: &["index", "delta"],
        build: build_select_workspace,
        print: print_empty,
        stream: false,
    },
    VerbSpec {
        name: "move-tab",
        allowed: &["surface", "pane", "index"],
        build: build_move_tab,
        print: print_empty,
        stream: false,
    },
    VerbSpec {
        name: "move-workspace",
        allowed: &["workspace", "index"],
        build: build_move_workspace,
        print: print_empty,
        stream: false,
    },
    VerbSpec {
        name: "scroll-surface",
        allowed: &["surface", "delta"],
        build: build_scroll_surface,
        print: print_empty,
        stream: false,
    },
    VerbSpec {
        name: "subscribe",
        allowed: &[],
        build: build_no_args,
        print: print_empty,
        stream: true,
    },
    VerbSpec {
        name: "attach-surface",
        allowed: &["surface"],
        build: build_surface,
        print: print_empty,
        stream: true,
    },
];

pub fn is_cli_invocation(args: &[String]) -> bool {
    matches!(first_command_arg(args), FirstCommand::Help | FirstCommand::Verb)
}

pub fn run(args: &[String], usage: &str) -> i32 {
    match parse(args) {
        Ok(Parsed::Help) => {
            print!("{usage}");
            0
        }
        Ok(Parsed::Command(args)) => run_command(args),
        Err(err) => {
            eprintln!("cmux-mux: {}", err.0);
            2
        }
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
                if spec.name == "run" && name == "new-workspace" {
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
                if spec.name == "send-key" {
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
    let request = match (args.verb.build)(&args.flags) {
        Ok(mut value) => {
            value["cmd"] = json!(args.verb.name);
            value["id"] = json!(REQUEST_ID);
            value
        }
        Err(err) => {
            eprintln!("cmux-mux: {}", err.0);
            return 2;
        }
    };
    let socket_path = resolve_socket(&args.global);
    let mut stream = match transport::connect(&socket_path) {
        Ok(stream) => stream,
        Err(err) => {
            eprintln!("cannot connect to session socket {}: {err}", socket_path.display());
            return 3;
        }
    };
    if args.verb.stream {
        let _ = stream.set_read_timeout(Some(Duration::from_millis(250)));
    } else {
        let _ = stream.set_read_timeout(Some(Duration::from_secs(10)));
    }
    let mut line = match serde_json::to_vec(&request) {
        Ok(line) => line,
        Err(err) => {
            eprintln!("failed to encode request: {err}");
            return 2;
        }
    };
    line.push(b'\n');
    if let Err(err) = stream.write_all(&line) {
        eprintln!("transport error: {err}");
        return 3;
    }

    let mut reader = BufReader::new(stream);
    if args.verb.stream {
        run_stream(reader)
    } else {
        run_one_response(&mut reader, args.global.json, args.verb.print)
    }
}

fn resolve_socket(global: &GlobalArgs) -> PathBuf {
    if let Some(path) = &global.socket {
        return path.clone();
    }
    if let Some(path) = std::env::var_os("CMUX_MUX_SOCKET") {
        if !path.is_empty() {
            return PathBuf::from(path);
        }
    }
    let session = global.session.as_deref().unwrap_or("main");
    mux_core::server::default_socket_path(session)
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
    if value.get("text").is_none() && value.get("bytes").is_none() {
        let mut text = String::new();
        io::stdin()
            .read_to_string(&mut text)
            .map_err(|err| UsageError(format!("failed to read stdin: {err}")))?;
        value["text"] = json!(text);
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
        "cmux-mux session={} protocol={} pid={}",
        data.get("session").and_then(Value::as_str).unwrap_or(""),
        data.get("protocol").and_then(Value::as_u64).unwrap_or(0),
        data.get("pid").and_then(Value::as_u64).unwrap_or(0)
    )
}

fn print_read_screen(data: &Value, out: &mut dyn Write) -> io::Result<()> {
    write!(out, "{}", data.get("text").and_then(Value::as_str).unwrap_or(""))
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
                    writeln!(out, "pane id={} screen={} dead=true", pane_id, screen_id)?;
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
