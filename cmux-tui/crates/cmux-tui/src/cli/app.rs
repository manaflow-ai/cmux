//! Scopes the cmux app owns: its windows, its action registry, its settings
//! and its event stream. They go to the app control socket (one JSON object
//! per line, `{"id","method","params"}`), never through the mux, because the
//! mux has no windows and no actions. Everything the mux owns stays in the
//! resource grammar (plans/cmux-next/cli.md, "Owners and routing").
//!
//! Every registered action is also a verb here: `cmux app new-window` or
//! `cmux workspace move-to-window --target ws_…` runs the action whose CLI
//! name is those words, so the app's registry, not this file, lists them.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::time::Duration;

use serde_json::{Map, Value, json};

use super::{GlobalArgs, OutputMode, UsageError};
use crate::app_identity::AppIdentity;

/// Scopes that belong to the app, whatever follows.
pub(super) const APP_SCOPES: &[&str] = &["app", "action", "settings", "window", "events"];

/// Control-plane requests answer within the app's own 2 s deadline; a run
/// that waits for its work may wait for a terminal to start (6 s).
const READ_TIMEOUT: Duration = Duration::from_secs(5);
const WAITING_RUN_TIMEOUT: Duration = Duration::from_secs(10);
const MAX_RESPONSE_BYTES: u64 = 16 << 20;

#[derive(Debug, PartialEq)]
pub(super) enum AppCommand {
    Call { method: &'static str, params: Value, timeout: Duration, pick: Option<&'static str> },
    Events { params: Value },
}

/// Parses an app scope. `Ok(None)` when `args` does not start with one.
pub(super) fn parse(args: &[String]) -> Result<Option<AppCommand>, UsageError> {
    let Some(scope) = args.first() else { return Ok(None) };
    if !APP_SCOPES.contains(&scope.as_str()) {
        return Ok(None);
    }
    let messages = &crate::localization::catalog().app_control;
    let rest = &args[1..];
    let call = |method, params| AppCommand::Call { method, params, timeout: READ_TIMEOUT, pick: None };
    let command = match (scope.as_str(), rest.first().map(String::as_str)) {
        ("app", Some("ping")) => call("system.ping", json!({})),
        ("app", Some("identify")) => call("system.identify", json!({})),
        ("app", Some("capabilities")) => call("system.capabilities", json!({})),
        ("window", Some("list")) => AppCommand::Call {
            method: "snapshot.get",
            params: json!({}),
            timeout: READ_TIMEOUT,
            pick: Some("windows"),
        },
        ("action", Some("list")) => {
            let options = Options::parse(&rest[1..], &["category", "noun"], &["available"])?;
            let mut params = Map::new();
            for key in ["category", "noun"] {
                if let Some(value) = options.value(key) {
                    params.insert(key.into(), json!(value));
                }
            }
            if options.flag("available") {
                params.insert("available_only".into(), json!(true));
            }
            call("action.list", Value::Object(params))
        }
        ("action", Some("describe")) => {
            let [id] = positional::<1>(&rest[1..], messages.action_describe_usage)?;
            call("action.describe", json!({ "action": id }))
        }
        ("action", Some("run")) => {
            let Some((id, tail)) = rest[1..].split_first() else {
                return Err(UsageError::new(messages.action_run_usage));
            };
            run_action(id, tail)?
        }
        ("settings", Some("get")) => match &rest[1..] {
            [] => call("settings.get", json!({})),
            [path] => call("settings.get", json!({ "path": path })),
            _ => return Err(UsageError::new(messages.settings_usage)),
        },
        ("settings", Some("set")) => {
            let [path, value] = positional::<2>(&rest[1..], messages.settings_usage)?;
            // A JSON value when it parses as one, else the literal string.
            let value = serde_json::from_str(&value).unwrap_or(Value::String(value));
            call("settings.set", json!({ "path": path, "value": value }))
        }
        ("settings", Some("unset")) => {
            let [path] = positional::<1>(&rest[1..], messages.settings_usage)?;
            call("settings.unset", json!({ "path": path }))
        }
        ("events", _) => {
            let options = Options::parse(rest, &["after", "name", "category"], &["no-heartbeats"])?;
            let mut params = Map::new();
            if let Some(after) = options.value("after") {
                let after: i64 = after
                    .parse()
                    .map_err(|_| UsageError::new(messages.events_after_invalid.replace("{value}", after)))?;
                params.insert("after_seq".into(), json!(after));
            }
            let names = options.values("name");
            if !names.is_empty() {
                params.insert("names".into(), json!(names));
            }
            let categories = options.values("category");
            if !categories.is_empty() {
                params.insert("categories".into(), json!(categories));
            }
            if options.flag("no-heartbeats") {
                params.insert("include_heartbeats".into(), json!(false));
            }
            AppCommand::Events { params: Value::Object(params) }
        }
        // Any other words name an action by its CLI name (`app new-window`).
        _ => {
            let words: Vec<&String> = args.iter().take_while(|arg| !arg.starts_with('-')).collect();
            if words.len() < 2 {
                return Err(UsageError::new(messages.scope_usage.replace("{scope}", scope)));
            }
            let name = words.iter().map(|word| word.as_str()).collect::<Vec<_>>().join(" ");
            run_action(&name, &args[words.len()..])?
        }
    };
    Ok(Some(command))
}

/// `action.run` for an action id or CLI name: `--target ID`, `--wait`,
/// `--interactive`, and `--<argument> VALUE` for each schema argument
/// (`--arg name=value` also works).
pub(super) fn run_action(action: &str, args: &[String]) -> Result<AppCommand, UsageError> {
    let messages = &crate::localization::catalog().app_control;
    let mut params = Map::new();
    let mut arguments = Map::new();
    params.insert("action".into(), json!(action));
    let mut index = 0;
    while index < args.len() {
        let flag = args[index].as_str();
        let Some(name) = flag.strip_prefix("--") else {
            return Err(UsageError::new(messages.unexpected_argument.replace("{value}", flag)));
        };
        match name {
            "wait" | "interactive" => {
                params.insert(name.into(), json!(true));
                index += 1;
                continue;
            }
            _ => {}
        }
        let (name, value) = match name.split_once('=') {
            Some((name, value)) => (name.to_owned(), value.to_owned()),
            None => {
                let value = args
                    .get(index + 1)
                    .ok_or_else(|| UsageError::new(messages.missing_value.replace("{flag}", flag)))?;
                index += 1;
                (name.to_owned(), value.clone())
            }
        };
        index += 1;
        match name.as_str() {
            "target" => {
                params.insert("target".into(), json!(value));
            }
            "arg" => {
                let (key, value) = value
                    .split_once('=')
                    .ok_or_else(|| UsageError::new(messages.arg_shape.replace("{value}", &value)))?;
                arguments.insert(key.into(), json!(value));
            }
            _ => {
                arguments.insert(name.replace('-', "_"), json!(value));
            }
        }
    }
    if !arguments.is_empty() {
        params.insert("args".into(), Value::Object(arguments));
    }
    let wait = params.get("wait").and_then(Value::as_bool) == Some(true);
    Ok(AppCommand::Call {
        method: "action.run",
        params: Value::Object(params),
        timeout: if wait { WAITING_RUN_TIMEOUT } else { READ_TIMEOUT },
        pick: None,
    })
}

pub(super) fn run(global: &GlobalArgs, command: AppCommand) -> i32 {
    let socket = match socket_path(global) {
        Ok(socket) => socket,
        Err(error) => return failure("app.not_found", &error, global.output, 3),
    };
    let mut stream = match connect(&socket) {
        Ok(stream) => stream,
        Err(error) => return failure("app.unreachable", &error, global.output, 3),
    };
    match command {
        AppCommand::Call { method, params, timeout, pick } => {
            let response = match request(&mut stream, method, params, timeout) {
                Ok(response) => response,
                Err(error) => return failure("app.transport", &error, global.output, 3),
            };
            match response {
                Ok(result) => {
                    let value = match pick {
                        Some(key) => result.get("topology").and_then(|topology| topology.get(key)).cloned(),
                        None => None,
                    }
                    .unwrap_or(result);
                    super::wire::print_local_success(&value, global.output)
                }
                Err(error) => super::wire::print_local_error(&error, global.output, 1),
            }
        }
        AppCommand::Events { params } => stream_events(&mut stream, params, global.output),
    }
}

/// Whether a reachable app has an action with this id or CLI name.
pub(super) fn has_action(global: &GlobalArgs, name: &str) -> bool {
    let Ok(socket) = socket_path(global) else { return false };
    let Ok(mut stream) = connect(&socket) else { return false };
    matches!(request(&mut stream, "action.describe", json!({ "action": name }), READ_TIMEOUT), Ok(Ok(_)))
}

fn socket_path(global: &GlobalArgs) -> Result<PathBuf, String> {
    let messages = &crate::localization::catalog().app_control;
    if let Some(path) = &global.app_socket {
        return Ok(path.clone());
    }
    let exe = std::env::current_exe().ok();
    let identity = AppIdentity::detect(|key| std::env::var(key).ok(), exe.as_deref())
        .ok_or_else(|| messages.no_app.to_owned())?;
    let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default();
    Ok(identity.control_socket(&home))
}

fn connect(socket: &PathBuf) -> Result<UnixStream, String> {
    let messages = &crate::localization::catalog().app_control;
    UnixStream::connect(socket).map_err(|error| {
        messages.unreachable.replace("{path}", &socket.display().to_string()).replace("{error}", &error.to_string())
    })
}

/// One request and its response. The outer error is transport; the inner
/// one is the app's `{"ok":false,"error":…}`.
fn request(
    stream: &mut UnixStream,
    method: &str,
    params: Value,
    timeout: Duration,
) -> Result<Result<Value, Value>, String> {
    let line = json!({ "id": 1, "method": method, "params": params });
    send_line(stream, &line)?;
    stream.set_read_timeout(Some(timeout)).map_err(|error| error.to_string())?;
    let mut reader = BufReader::new(stream.try_clone().map_err(|error| error.to_string())?.take(MAX_RESPONSE_BYTES));
    let mut response = String::new();
    reader.read_line(&mut response).map_err(|error| read_error(&error, timeout))?;
    parse_response(&response)
}

fn send_line(stream: &mut UnixStream, value: &Value) -> Result<(), String> {
    let mut bytes = serde_json::to_vec(value).map_err(|error| error.to_string())?;
    bytes.push(b'\n');
    stream.write_all(&bytes).map_err(|error| error.to_string())
}

fn read_error(error: &std::io::Error, timeout: Duration) -> String {
    let messages = &crate::localization::catalog().app_control;
    match error.kind() {
        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut => {
            messages.timeout.replace("{seconds}", &timeout.as_secs().to_string())
        }
        _ => error.to_string(),
    }
}

pub(super) fn parse_response(line: &str) -> Result<Result<Value, Value>, String> {
    let messages = &crate::localization::catalog().app_control;
    let line = line.trim();
    if line.is_empty() {
        return Err(messages.closed.to_owned());
    }
    // A socket in cmux-only mode answers a process it did not start with
    // one plain-text line.
    if !line.starts_with('{') {
        return Err(line.to_owned());
    }
    let value: Value = serde_json::from_str(line).map_err(|_| messages.invalid_response.to_owned())?;
    match value.get("ok").and_then(Value::as_bool) {
        Some(true) => Ok(Ok(value.get("result").cloned().unwrap_or(Value::Null))),
        Some(false) => Ok(Err(value.get("error").cloned().unwrap_or(Value::Null))),
        None => Err(messages.invalid_response.to_owned()),
    }
}

/// `events.stream`: one JSON event per line until the app closes the
/// stream or this process is interrupted. Blocking reads, no polling.
fn stream_events(stream: &mut UnixStream, params: Value, output: OutputMode) -> i32 {
    if let Err(error) = send_line(stream, &json!({ "id": 1, "method": "events.stream", "params": params })) {
        return failure("app.transport", &error, output, 3);
    }
    let reader = match stream.try_clone() {
        Ok(reader) => BufReader::new(reader),
        Err(error) => return failure("app.transport", &error.to_string(), output, 3),
    };
    let mut stdout = std::io::stdout().lock();
    for line in reader.lines() {
        let Ok(line) = line else { return 3 };
        let Ok(value) = serde_json::from_str::<Value>(&line) else { continue };
        if value.get("ok").and_then(Value::as_bool) == Some(false) {
            let error = value.get("error").cloned().unwrap_or(Value::Null);
            return super::wire::print_local_error(&error, output, 1);
        }
        let written = match output {
            OutputMode::Quiet => Ok(()),
            _ => writeln!(stdout, "{line}").and_then(|()| stdout.flush()),
        };
        if written.is_err() {
            return 0;
        }
    }
    0
}

fn failure(code: &str, message: &str, output: OutputMode, exit_code: i32) -> i32 {
    super::wire::print_local_error(
        &json!({ "code": code, "message": message, "details": {}, "retryable": false }),
        output,
        exit_code,
    )
}

fn positional<const N: usize>(args: &[String], usage: &str) -> Result<[String; N], UsageError> {
    <[String; N]>::try_from(args.to_vec()).map_err(|_| UsageError::new(usage))
}

/// `--key value` / `--key=value` options (repeatable) and boolean flags.
struct Options {
    values: Vec<(String, String)>,
    flags: Vec<String>,
}

impl Options {
    fn parse(args: &[String], valued: &[&str], flags: &[&str]) -> Result<Self, UsageError> {
        let messages = &crate::localization::catalog().app_control;
        let mut options = Options { values: Vec::new(), flags: Vec::new() };
        let mut index = 0;
        while index < args.len() {
            let arg = args[index].as_str();
            let Some(name) = arg.strip_prefix("--") else {
                return Err(UsageError::new(messages.unexpected_argument.replace("{value}", arg)));
            };
            if let Some((name, value)) = name.split_once('=')
                && valued.contains(&name)
            {
                options.values.push((name.into(), value.into()));
            } else if valued.contains(&name) {
                let value = args
                    .get(index + 1)
                    .ok_or_else(|| UsageError::new(messages.missing_value.replace("{flag}", arg)))?;
                options.values.push((name.into(), value.clone()));
                index += 1;
            } else if flags.contains(&name) {
                options.flags.push(name.into());
            } else {
                return Err(UsageError::new(messages.unexpected_argument.replace("{value}", arg)));
            }
            index += 1;
        }
        Ok(options)
    }

    fn value(&self, key: &str) -> Option<&str> {
        self.values.iter().rev().find(|(name, _)| name == key).map(|(_, value)| value.as_str())
    }

    fn values(&self, key: &str) -> Vec<&str> {
        self.values.iter().filter(|(name, _)| name == key).map(|(_, value)| value.as_str()).collect()
    }

    fn flag(&self, key: &str) -> bool {
        self.flags.iter().any(|flag| flag == key)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(words: &[&str]) -> Vec<String> {
        words.iter().map(|word| (*word).to_owned()).collect()
    }

    fn call(command: AppCommand) -> (&'static str, Value) {
        match command {
            AppCommand::Call { method, params, .. } => (method, params),
            AppCommand::Events { .. } => panic!("expected a call"),
        }
    }

    #[test]
    fn non_app_scopes_are_left_to_the_resource_grammar() {
        assert_eq!(parse(&args(&["workspace", "list"])).unwrap(), None);
        assert_eq!(parse(&args(&[])).unwrap(), None);
    }

    #[test]
    fn unknown_words_run_the_action_with_that_cli_name() {
        let (method, params) =
            call(parse(&args(&["app", "new-window"])).unwrap().unwrap());
        assert_eq!(method, "action.run");
        assert_eq!(params, json!({ "action": "app new-window" }));
    }

    #[test]
    fn action_run_maps_flags_to_target_and_arguments() {
        let (_, params) = call(
            parse(&args(&[
                "action", "run", "tab.rename", "--target", "tab_0123", "--title", "Build",
                "--arg", "keep_case=true", "--wait",
            ]))
            .unwrap()
            .unwrap(),
        );
        assert_eq!(
            params,
            json!({
                "action": "tab.rename",
                "target": "tab_0123",
                "wait": true,
                "args": { "title": "Build", "keep_case": "true" },
            })
        );
    }

    #[test]
    fn settings_set_takes_json_or_a_plain_string() {
        let (_, params) = call(parse(&args(&["settings", "set", "layout.panePadding", "4"])).unwrap().unwrap());
        assert_eq!(params, json!({ "path": "layout.panePadding", "value": 4 }));
        let (_, params) = call(parse(&args(&["settings", "set", "window.titlebar", "minimal"])).unwrap().unwrap());
        assert_eq!(params, json!({ "path": "window.titlebar", "value": "minimal" }));
    }

    #[test]
    fn responses_split_transport_from_app_errors() {
        assert_eq!(parse_response(r#"{"id":1,"ok":true,"result":{"pong":true}}"#), Ok(Ok(json!({"pong":true}))));
        assert_eq!(
            parse_response(r#"{"id":1,"ok":false,"error":{"code":"not_found"}}"#),
            Ok(Err(json!({"code":"not_found"})))
        );
        assert!(parse_response("ERROR: Access denied - only processes started inside cmux can connect").is_err());
        assert!(parse_response("").is_err());
    }
}
