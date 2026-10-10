//! Scopes the cmux app owns: its windows, its action registry, its settings
//! and its event stream. They go to the app control socket (one JSON object
//! per line, `{"id","method","params"}`), never through the mux, because the
//! mux has no windows and no actions. Everything the mux owns stays in the
//! resource grammar (plans/cmux-next/cli.md, "Owners and routing").
//!
//! An action the app marks for the CLI (`cli: true` in `action.list`) is also
//! a verb here: `cmux app new-window` or `cmux workspace move-to-window
//! --target ws_…` runs the action whose CLI name is those words, so the app's
//! registry, not this file, lists them. `cmux action run <id>` runs any action.
//!
//! `action.run` carries an idempotency key and waits for its work by default
//! (plans/cmux-next/state-ownership.md, section 4).

use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::time::Duration;

use serde_json::{Map, Value, json};

use super::{GlobalArgs, OutputMode, UsageError};
use crate::app_identity::AppIdentity;
use open::{OpenRequest, parse_open};
#[cfg(test)]
use open::{is_web_url, parse_open_with};
pub(super) use run::{action_run_params, insert_run_key, request_with_retry};

mod call;
mod keybinding;
mod open;
mod run;
mod settings;
mod skew;

/// Scopes that belong to the app, whatever follows.
pub(super) const APP_SCOPES: &[&str] = &[
    "app",
    "action",
    "settings",
    "window",
    "events",
    "history",
    "bookmark",
    "accounts",
    "open",
    "keybinding",
    "ghostty",
];

/// Control-plane requests answer within the app's own 2 s deadline. A run
/// that waits for its work may wait for a terminal to start (6 s) or for a
/// network action the app bounds itself (`ActionDescriptor.resultDeadline`,
/// 40 s, Connect to CodeRouter), so the CLI gives the app longer than that.
pub(super) const READ_TIMEOUT: Duration = Duration::from_secs(5);
pub(super) const WAITING_RUN_TIMEOUT: Duration = Duration::from_secs(45);
const MAX_RESPONSE_BYTES: u64 = 16 << 20;
/// A `busy` app that says the run never started is asked again this many
/// times, after the delay it names (`retry_after_ms`, else this default).
const BUSY_RETRIES: u32 = 3;
const BUSY_RETRY_DELAY: Duration = Duration::from_millis(100);
const MAX_BUSY_RETRY_DELAY: Duration = Duration::from_secs(1);

/// How `action.run` names its action.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum ActionName {
    /// `cmux action run`: any action id, alias or CLI name.
    Any,
    /// `cmux <noun> <verb>`: only a CLI name the app marks for the CLI; the
    /// app answers `not_found` for anything else and runs nothing.
    Cli,
}

#[derive(Debug, PartialEq)]
pub(super) enum AppCommand {
    /// `timeout: None` waits until the app answers (a person at a sheet).
    Call {
        method: &'static str,
        params: Value,
        timeout: Option<Duration>,
        pick: Option<&'static str>,
    },
    Open {
        requests: Vec<OpenRequest>,
        /// `open -`: the first failed request ends the command, so a refused
        /// URL is never followed by the next one.
        stop_on_failure: bool,
    },
    /// `app call`: one method of a debug build (app/call.rs).
    DebugCall {
        method: String,
        params: Map<String, Value>,
    },
    Events {
        params: Value,
    },
}

/// The classic CLI's top-level discovery verbs: `cmux identify`, `cmux ping`
/// and `cmux capabilities`, with the classic `--id-format <refs|uuids|both>`
/// before or after the verb (ignored: these answers carry no refs). Skills,
/// prompts and agent habits written for both apps still run them (cx-4w47
/// D1); they are this app's `app identify|ping|capabilities`, the same
/// `system.*` methods the classic CLI sends.
fn classic_system_method(args: &[String]) -> Option<&'static str> {
    let words = args.iter().map(String::as_str).collect::<Vec<_>>();
    let verb = match words.as_slice() {
        [verb] => *verb,
        ["--id-format", format, verb] | [verb, "--id-format", format]
            if matches!(*format, "refs" | "uuids" | "both") =>
        {
            *verb
        }
        _ => return None,
    };
    match verb {
        "identify" => Some("system.identify"),
        "ping" => Some("system.ping"),
        "capabilities" => Some("system.capabilities"),
        _ => None,
    }
}

/// Parses an app scope. `Ok(None)` when `args` does not start with one.
pub(super) fn parse(args: &[String]) -> Result<Option<AppCommand>, UsageError> {
    let Some(scope) = args.first() else { return Ok(None) };
    if let Some(method) = classic_system_method(args) {
        return Ok(Some(AppCommand::Call {
            method,
            params: json!({}),
            timeout: Some(READ_TIMEOUT),
            pick: None,
        }));
    }
    if scope == "browser"
        && let Some(target) = args.get(1)
        && (target == "page" || target.starts_with("tab_"))
    {
        return parse_page(target, &args[2..]).map(Some);
    }
    if !APP_SCOPES.contains(&scope.as_str()) {
        return Ok(None);
    }
    let messages = &crate::localization::catalog().app_control;
    let rest = &args[1..];
    let call = |method, params| AppCommand::Call {
        method,
        params,
        timeout: Some(READ_TIMEOUT),
        pick: None,
    };
    let command = match (scope.as_str(), rest.first().map(String::as_str)) {
        ("open", _) => parse_open(rest)?,
        ("keybinding", _) => keybinding::parse(rest)?,
        ("app", Some("call")) => call::parse(rest)?,
        ("app", Some("ping")) => call("system.ping", json!({})),
        ("app", Some("identify")) => call("system.identify", json!({})),
        ("app", Some("capabilities")) => call("system.capabilities", json!({})),
        ("window", Some("list")) => AppCommand::Call {
            method: "snapshot.get",
            params: json!({}),
            timeout: Some(READ_TIMEOUT),
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
            run_action(id, tail, ActionName::Any)?
        }
        ("settings", Some("get" | "set" | "reset" | "unset")) => settings::parse(rest)?,
        // The app's durable page, location, closed and agent history
        // (plans/cmux-next/history.md): `history list|search`.
        ("history", Some(verb @ ("list" | "search"))) => {
            let (text, tail) = read_text(verb, &rest[1..], scope)?;
            let options = Options::parse(tail, &["kind", "range", "limit"], &[])?;
            let mut params = read_query(&options, text, &["kind", "range"]);
            if let Some(limit) = options.value("limit") {
                params.insert("limit".into(), json!(parse_limit(limit, scope)?));
            }
            call("history.list", Value::Object(params))
        }
        // The app's AI provider accounts, no secrets (`accounts.list`); the
        // other `accounts` verbs are app actions.
        ("accounts", Some("list")) => {
            if rest.len() > 1 {
                return Err(UsageError::new(messages.scope_usage.replace("{scope}", scope)));
            }
            call("accounts.list", json!({}))
        }
        // The Ghostty config keys and keybind actions cmux does not apply
        // (R92 diagnostics): the same report as Settings > Terminal.
        ("ghostty", Some("diagnostics")) => {
            if rest.len() > 1 {
                return Err(UsageError::new(messages.scope_usage.replace("{scope}", scope)));
            }
            call("ghostty.diagnostics", json!({}))
        }
        // Bookmarks of a browser profile (plans/cmux-next/bookmarks.md).
        ("bookmark", Some(verb @ ("list" | "search"))) => {
            let (text, tail) = read_text(verb, &rest[1..], scope)?;
            let options = Options::parse(tail, &["folder", "profile", "limit"], &[])?;
            let mut params = read_query(&options, text, &["folder", "profile"]);
            if let Some(limit) = options.value("limit") {
                params.insert("limit".into(), json!(parse_limit(limit, scope)?));
            }
            call("bookmark.list", Value::Object(params))
        }
        ("events", _) => {
            let options = Options::parse(rest, &["after", "name", "category"], &["no-heartbeats"])?;
            let mut params = Map::new();
            if let Some(after) = options.value("after") {
                let after: i64 = after.parse().map_err(|_| {
                    UsageError::new(messages.events_after_invalid.replace("{value}", after))
                })?;
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
            run_action(&name, &args[words.len()..], ActionName::Cli)?
        }
    };
    Ok(Some(command))
}

/// `cli` when a person runs the command at a terminal, else `script`.
pub(super) fn action_origin() -> &'static str {
    use std::io::IsTerminal;
    if std::io::stdin().is_terminal() && std::io::stdout().is_terminal() { "cli" } else { "script" }
}

/// An action argument's name from its flag: the catalog names arguments in
/// camelCase (`--keep-sessions` is `keepSessions`).
fn argument_name(flag: &str) -> String {
    let mut name = String::with_capacity(flag.len());
    let mut upper = false;
    for character in flag.chars() {
        if character == '-' || character == '_' {
            upper = true;
        } else if upper {
            name.extend(character.to_uppercase());
            upper = false;
        } else {
            name.push(character);
        }
    }
    name
}

/// The text of a `search <text>` read (none for `list`) and the options
/// after it.
fn read_text<'a>(
    verb: &str,
    args: &'a [String],
    scope: &str,
) -> Result<(Option<&'a String>, &'a [String]), UsageError> {
    if verb == "list" {
        return Ok((None, args));
    }
    let messages = &crate::localization::catalog().app_control;
    match args.split_first() {
        Some((text, tail)) if !text.starts_with("--") => Ok((Some(text), tail)),
        _ => Err(UsageError::new(messages.search_text_usage.replace("{scope}", scope))),
    }
}

/// The params of a `list` or `search` read: the named options and the text.
fn read_query(options: &Options, text: Option<&String>, keys: &[&str]) -> Map<String, Value> {
    let mut params = Map::new();
    for key in keys {
        if let Some(value) = options.value(key) {
            params.insert((*key).into(), json!(value));
        }
    }
    if let Some(text) = text {
        params.insert("text".into(), json!(text));
    }
    params
}

fn parse_limit(value: &str, scope: &str) -> Result<u64, UsageError> {
    let messages = &crate::localization::catalog().app_control;
    value
        .parse::<u64>()
        .ok()
        .filter(|limit| *limit > 0)
        .ok_or_else(|| UsageError::new(messages.scope_usage.replace("{scope}", scope)))
}

/// `cmux browser <tab_…|page> <verb> …`: page commands for a browser tab the
/// app hosts (`page` is the focused tab). A daemon browser (`browser_…`) is
/// the mux grammar's.
fn parse_page(target: &str, args: &[String]) -> Result<AppCommand, UsageError> {
    let messages = &crate::localization::catalog().app_control;
    let usage = || UsageError::new(messages.browser_page_usage);
    let Some((verb, rest)) = args.split_first() else { return Err(usage()) };
    let mut params = Map::new();
    if target != "page" {
        params.insert("tab".into(), json!(target));
    }
    let words: Vec<&String> = rest.iter().filter(|arg| !arg.starts_with("--")).collect();
    let method = match (verb.as_str(), words.as_slice()) {
        ("navigate" | "goto" | "open", [url]) => {
            params.insert("url".into(), json!(url));
            "browser.page.navigate"
        }
        ("back", []) => "browser.page.back",
        ("forward", []) => "browser.page.forward",
        ("reload", []) => "browser.page.reload",
        ("state" | "url" | "title", []) => "browser.page.state",
        ("eval", [script]) => {
            params.insert("script".into(), json!(script));
            "browser.page.eval"
        }
        ("snapshot", _) => {
            let options = Options::parse(rest, &["selector", "max-depth"], &["interactive"])?;
            if let Some(selector) = options.value("selector") {
                params.insert("selector".into(), json!(selector));
            }
            if let Some(depth) = options.value("max-depth") {
                let depth: u32 = depth.parse().map_err(|_| usage())?;
                params.insert("max_depth".into(), json!(depth));
            }
            if options.flag("interactive") {
                params.insert("interactive".into(), json!(true));
            }
            "browser.page.snapshot"
        }
        ("click" | "focus" | "text" | "value", [selector]) => {
            params.insert("selector".into(), json!(selector));
            match verb.as_str() {
                "click" => "browser.page.click",
                "focus" => "browser.page.focus",
                "text" => "browser.page.text",
                _ => "browser.page.value",
            }
        }
        ("fill" | "type", [selector, text]) => {
            params.insert("selector".into(), json!(selector));
            params.insert("text".into(), json!(text));
            if verb == "fill" { "browser.page.fill" } else { "browser.page.type" }
        }
        _ => return Err(usage()),
    };
    if verb != "snapshot" && words.len() != rest.len() {
        return Err(usage());
    }
    Ok(AppCommand::Call {
        method,
        params: Value::Object(params),
        timeout: Some(READ_TIMEOUT),
        pick: None,
    })
}

/// `action.run` for an action id or CLI name: `--target ID`, `--no-wait`
/// (`--wait` is the default), `--interactive`, and `--<argument> VALUE` for
/// each schema argument (`--arg name=value` also works).
pub(super) fn run_action(
    action: &str,
    args: &[String],
    name: ActionName,
) -> Result<AppCommand, UsageError> {
    let messages = &crate::localization::catalog().app_control;
    let mut params = action_run_params(action, name, action_origin());
    let mut arguments = Map::new();
    let mut index = 0;
    while index < args.len() {
        let flag = args[index].as_str();
        let Some(name) = flag.strip_prefix("--") else {
            return Err(UsageError::new(messages.unexpected_argument.replace("{value}", flag)));
        };
        match name {
            "wait" | "no-wait" | "interactive" => {
                let key = if name == "interactive" { "interactive" } else { "wait" };
                params.insert(key.into(), json!(name != "no-wait"));
                index += 1;
                continue;
            }
            "focus" => {
                params.insert("focus".into(), json!(true));
                index += 1;
                continue;
            }
            _ => {}
        }
        // `--name value`, `--name=value`, or a bare `--name` (true) when no
        // value follows (`cmux app quit --keep-sessions`).
        let (name, value) = match name.split_once('=') {
            Some((name, value)) => (name.to_owned(), json!(value)),
            None => match args.get(index + 1) {
                Some(value) if !value.starts_with("--") => {
                    index += 1;
                    (name.to_owned(), json!(value))
                }
                _ if name == "target" || name == "arg" => {
                    return Err(UsageError::new(messages.missing_value.replace("{flag}", flag)));
                }
                _ => (name.to_owned(), json!(true)),
            },
        };
        index += 1;
        match name.as_str() {
            "target" => {
                params.insert("target".into(), value);
            }
            "arg" => {
                let text = value.as_str().unwrap_or_default();
                let (key, value) = text
                    .split_once('=')
                    .ok_or_else(|| UsageError::new(messages.arg_shape.replace("{value}", text)))?;
                arguments.insert(key.into(), json!(value));
            }
            _ => {
                arguments.insert(argument_name(&name), value);
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
        timeout: Some(if wait { WAITING_RUN_TIMEOUT } else { READ_TIMEOUT }),
        pick: None,
    })
}

pub(super) fn run(global: &GlobalArgs, command: AppCommand) -> i32 {
    match run_command(global, command) {
        Ran::Done(code) => code,
        Ran::NoSuchCliAction { name, .. }
            if super::action_hint::non_verb_action(&name).is_some() =>
        {
            super::action_hint::report(&name, global.output)
                .unwrap_or(super::action_hint::EXIT_CODE)
        }
        Ran::NoSuchCliAction { scope, .. } => {
            let messages = &crate::localization::catalog().app_control;
            failure(
                "usage.invalid",
                &messages.scope_usage.replace("{scope}", &scope),
                global.output,
                2,
            )
        }
    }
}

/// Runs `<noun> <verb…> [--flags]` as the app action with that CLI name.
/// `None` when no app answers or the app has no CLI action by that name, so
/// the caller reports its own usage error. One connection, one `action.run`.
pub(super) fn run_cli_action(global: &GlobalArgs, name: &str, args: &[String]) -> Option<i32> {
    let command = run_action(name, args, ActionName::Cli).ok()?;
    // A named socket that is missing or not an app (a daemon's `--socket`)
    // has no CLI action; the caller reports its own usage error.
    let mut stream = connect_command(global).ok()?;
    match call(global, &mut stream, command) {
        Ran::Done(code) => Some(code),
        Ran::NoSuchCliAction { .. } => None,
    }
}

enum Ran {
    Done(i32),
    /// The app ran nothing: no action marked for the CLI has this name
    /// (`scope` is its first word).
    NoSuchCliAction {
        scope: String,
        name: String,
    },
}

fn run_command(global: &GlobalArgs, command: AppCommand) -> Ran {
    let mut stream = match connect_command(global) {
        Ok(stream) => stream,
        Err(error) => return Ran::Done(super::wire::print_local_error(&error, global.output, 3)),
    };
    call(global, &mut stream, command)
}

/// The app control connection of an app command ([`command_socket`]). A
/// named socket that is missing or refuses is `socket.unreachable`, and one
/// that does not answer as the cmux app is `socket.wrong_kind`; neither
/// tries another socket.
pub(super) fn connect_command(global: &GlobalArgs) -> Result<UnixStream, Value> {
    let socket = command_socket(global)?;
    let Some(flag) = socket.named_by else {
        return connect(&socket.path).map_err(|message| typed("app.unreachable", message, None));
    };
    let messages = &crate::localization::catalog().app_control;
    let path = socket.path.display().to_string();
    let mut stream = UnixStream::connect(&socket.path).map_err(|error| {
        let message = messages
            .explicit_unreachable
            .replace("{path}", &path)
            .replace("{flag}", flag)
            .replace("{error}", &error.to_string());
        typed("socket.unreachable", message, Some(&socket))
    })?;
    // `--socket` may name a daemon's socket: the app answers `system.ping`
    // with `pong`, anything else is another kind of socket, and no app
    // request runs there. `--app-socket` names the app socket itself.
    if flag == "--socket" {
        // An app's refusal is an object with a code (a classic app in
        // password mode refuses ping before `auth.login`); a daemon's
        // refusal of the unknown line is a plain string.
        let pong = exchange(&mut stream, "system.ping", json!({}), READ_TIMEOUT);
        let is_app = match &pong {
            Ok(Ok(result)) => result.get("pong") == Some(&Value::Bool(true)),
            Ok(Err(error)) => error.get("code").is_some_and(Value::is_string),
            Err(_) => false,
        };
        if !is_app {
            let message = messages.wrong_kind.replace("{path}", &path);
            return Err(typed("socket.wrong_kind", message, Some(&socket)));
        }
    }
    Ok(stream)
}

fn typed(code: &str, message: String, socket: Option<&AppSocket>) -> Value {
    let details = match socket {
        Some(socket) => json!({
            "socket": socket.path.display().to_string(),
            "flag": socket.named_by,
        }),
        None => json!({}),
    };
    json!({ "code": code, "message": message, "details": details, "retryable": false })
}

fn call(global: &GlobalArgs, stream: &mut UnixStream, command: AppCommand) -> Ran {
    let (method, mut params, timeout, pick) = match command {
        AppCommand::Call { method, params, timeout, pick } => (method, params, timeout, pick),
        AppCommand::Events { params } => {
            return Ran::Done(stream_events(stream, params, global.output));
        }
        AppCommand::DebugCall { method, params } => {
            return Ran::Done(call::run(global, stream, &method, params));
        }
        AppCommand::Open { requests, stop_on_failure } => {
            let mut status = 0;
            for request in requests {
                let timeout = Some(request.timeout());
                if let Ran::Done(code) = call(
                    global,
                    stream,
                    AppCommand::Call {
                        method: request.method,
                        params: request.params,
                        timeout,
                        pick: None,
                    },
                ) {
                    status = status.max(code);
                }
                if stop_on_failure && status != 0 {
                    break;
                }
            }
            return Ran::Done(status);
        }
    };
    let cli_name = params.get("cli") == Some(&Value::Bool(true));
    let key = if method == "action.run" {
        match insert_run_key(&mut params, global.idempotency_key.as_deref()) {
            Ok(key) => Some(key),
            Err(error) => return Ran::Done(failure("app.transport", &error, global.output, 3)),
        }
    } else if global.idempotency_key.is_some() {
        let message = "--idempotency-key is accepted only for mutations";
        return Ran::Done(failure("usage.invalid", message, global.output, 2));
    } else {
        None
    };
    let report = super::wire::KeyReport::new(key.as_deref());
    // An open-ended wait ends on Ctrl-C: the CLI's signal handlers would only
    // set a flag that a blocking read never sees, so give SIGINT, SIGTERM and
    // SIGHUP their default action back (the app's own deadline still ends it).
    #[cfg(unix)]
    if timeout.is_none() && crate::restore_default_termination_signals().is_err() {
        return Ran::Done(130);
    }
    if output_shows_notes(global.output)
        && let Some(note) = settings::waiting_note(method, &params)
    {
        eprintln!("{note}");
    }
    let response = match request_with_retry(stream, method, &params, timeout) {
        Ok(response) => response,
        Err(error) => {
            let code = failure("app.transport", &error, global.output, 3);
            report.finish(global.output);
            return Ran::Done(code);
        }
    };
    match response {
        Ok(result) => {
            let value = match pick {
                Some(key) => result.get("topology").and_then(|topology| topology.get(key)).cloned(),
                None => None,
            }
            .unwrap_or(result);
            warn_unstable_handles(method, &value, global.output);
            Ran::Done(super::wire::print_local_success(&value, global.output))
        }
        Err(error) if cli_name && error_code(&error) == Some("not_found") => {
            let name = params["action"].as_str().unwrap_or_default().to_owned();
            let scope = name.split(' ').next().unwrap_or_default().to_owned();
            Ran::NoSuchCliAction { scope, name }
        }
        Err(mut error) => {
            if error_code(&error) == Some("method_not_found") {
                skew::annotate(stream, method, &mut error);
            }
            settings::explain_refusal(method, &params, &mut error);
            report.annotate(&mut error, global.output);
            let code = super::wire::print_local_error(&error, global.output, 1);
            report.finish(global.output);
            Ran::Done(code)
        }
    }
}

/// Progress notes go to stderr for a person, never in JSON or quiet output.
fn output_shows_notes(output: OutputMode) -> bool {
    output == OutputMode::Human
}

fn error_code(error: &Value) -> Option<&str> {
    error.get("code").and_then(Value::as_str)
}

/// A `busy` answer is safe to retry only when the app says the request
/// never ran; one that may have started (`in_progress`) is reported.
fn busy_before_running(error: &Value) -> bool {
    let data = error.get("data").unwrap_or(&Value::Null);
    error_code(error) == Some("busy")
        && (data.get("not_run") == Some(&Value::Bool(true))
            || data.get("state").and_then(Value::as_str) == Some("not_run"))
}

fn busy_retry_delay(error: &Value) -> Duration {
    error
        .get("data")
        .and_then(|data| data.get("retry_after_ms"))
        .and_then(Value::as_u64)
        .map_or(BUSY_RETRY_DELAY, Duration::from_millis)
        .min(MAX_BUSY_RETRY_DELAY)
}

/// The app control socket of a command the app serves (`cmux identify`,
/// `cmux app …`, `cmux window list`, action verbs, `cmux coderouter …`).
///
/// This is the one owner of the explicit-socket rule for the app (cx-siev):
/// a socket the caller names is the only socket tried, never a default
/// path and never the app the inherited environment names. `--app-socket`
/// names the app socket. Else `--socket` is the target, as in the classic
/// CLI, where it names the app socket; a daemon there is
/// `socket.wrong_kind` ([`connect_command`]). Else `--session` reaches only the
/// app that owns that session. With no explicit route, the app the
/// environment (`CMUX_SOCKET_PATH`, which is itself never replaced) or the
/// bundle names.
pub(super) fn command_socket(global: &GlobalArgs) -> Result<AppSocket, Value> {
    if let Some(path) = &global.app_socket {
        return Ok(AppSocket { path: path.clone(), named_by: Some("--app-socket") });
    }
    if let Some(path) = &global.socket {
        return Ok(AppSocket { path: path.clone(), named_by: Some("--socket") });
    }
    let path = socket_path(global).map_err(|message| {
        let code =
            if explicit_daemon_route(global).is_some() { "socket.no_app" } else { "app.not_found" };
        json!({ "code": code, "message": message, "details": {}, "retryable": false })
    })?;
    Ok(AppSocket { path, named_by: None })
}

/// An app control socket and the flag that named it (`None`: discovered).
#[derive(Debug)]
pub(super) struct AppSocket {
    pub path: PathBuf,
    pub named_by: Option<&'static str>,
}

/// The app half of a daemon command (focus follow, a browser tab the app
/// renders, the agent snapshot, MCP app tools). With an explicit daemon
/// route (`--socket`, `--session`) only the app that owns that daemon is
/// reached, or `--app-socket` (cx-siev): never the app that the inherited
/// environment names for some other session. With no explicit route, the
/// app the environment or the bundle names.
pub(super) fn socket_path(global: &GlobalArgs) -> Result<PathBuf, String> {
    let messages = &crate::localization::catalog().app_control;
    if let Some(path) = &global.app_socket {
        return Ok(path.clone());
    }
    let exe = std::env::current_exe().ok();
    let identity = AppIdentity::detect(|key| std::env::var(key).ok(), exe.as_deref());
    let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default();
    let Some(flag) = explicit_daemon_route(global) else {
        return identity
            .map(|identity| identity.control_socket(&home))
            .ok_or_else(|| messages.no_app.to_owned());
    };
    let no_app = || messages.explicit_no_app.replace("{flag}", flag);
    let (daemon, _) = super::wire::resolve_socket_with_origin(global)
        .map_err(|error| super::wire::resolve_failure_message(&error))?;
    match identity {
        Some(identity) if app_owns_daemon(&identity, &daemon) => Ok(identity.control_socket(&home)),
        _ => Err(no_app()),
    }
}

/// The route that names a daemon explicitly while nothing names the app:
/// `--socket`, `--session`, or `CMUX_TUI_SOCKET`/`CMUX_MUX_SOCKET` without
/// `CMUX_SOCKET_PATH` (an app terminal sets both, so its app stays named).
/// `None`: the app the environment or the bundle names may serve.
fn explicit_daemon_route(global: &GlobalArgs) -> Option<&'static str> {
    if global.socket.is_some() {
        return Some("--socket");
    }
    if global.session.is_some() {
        return Some("--session");
    }
    let set = |key: &str| std::env::var(key).is_ok_and(|value| !value.trim().is_empty());
    if set("CMUX_SOCKET_PATH") {
        return None;
    }
    ["CMUX_TUI_SOCKET", "CMUX_MUX_SOCKET"].into_iter().find(|key| set(key))
}

/// Whether `daemon` is the own session socket of the app `identity` names
/// (`DaemonLauncher`'s session, macOS only).
#[cfg_attr(not(target_os = "macos"), allow(unused_variables))]
pub(super) fn app_owns_daemon(identity: &AppIdentity, daemon: &std::path::Path) -> bool {
    #[cfg(target_os = "macos")]
    if let Some(own) = crate::app_identity::app_daemon_socket(identity) {
        let canonical = |path: &std::path::Path| {
            std::fs::canonicalize(path).unwrap_or_else(|_| path.to_owned())
        };
        // Two spellings of one socket (`/var` is `/private/var` on macOS).
        return own == daemon || canonical(&own) == canonical(daemon);
    }
    false
}

/// No app listens at `socket` (no file, or a stale one): the command needs
/// the app, which a Chief without the app must hear plainly (E17).
pub(super) fn connect(socket: &PathBuf) -> Result<UnixStream, String> {
    let messages = &crate::localization::catalog().app_control;
    UnixStream::connect(socket).map_err(|error| {
        let template = match error.kind() {
            std::io::ErrorKind::NotFound | std::io::ErrorKind::ConnectionRefused => {
                messages.needs_app
            }
            _ => messages.unreachable,
        };
        template
            .replace("{path}", &socket.display().to_string())
            .replace("{error}", &error.to_string())
    })
}

/// One request and its response. The outer error is transport; the inner
/// one is the app's `{"ok":false,"error":…}`.
/// Every app request first lets the app catch up with the daemon
/// (`after: "sync"`, one daemon round trip), so it sees what an earlier
/// `cmux` call wrote to the daemon (plans/cmux-next/state-ownership.md 4).
fn with_read_barrier(mut params: Value) -> Value {
    if let Some(object) = params.as_object_mut() {
        object.entry("after").or_insert_with(|| json!("sync"));
    }
    params
}

/// `timeout: None` reads until the app answers or closes the connection.
pub(super) fn request(
    stream: &mut UnixStream,
    method: &str,
    params: Value,
    timeout: impl Into<Option<Duration>>,
) -> Result<Result<Value, Value>, String> {
    exchange(stream, method, with_read_barrier(params), timeout)
}

/// One request with exactly `params` (no read barrier) and its response.
fn exchange(
    stream: &mut UnixStream,
    method: &str,
    params: Value,
    timeout: impl Into<Option<Duration>>,
) -> Result<Result<Value, Value>, String> {
    let timeout = timeout.into();
    let line = json!({ "id": 1, "method": method, "params": params });
    send_line(stream, &line)?;
    stream.set_read_timeout(timeout).map_err(|error| error.to_string())?;
    let mut reader = BufReader::new(
        stream.try_clone().map_err(|error| error.to_string())?.take(MAX_RESPONSE_BYTES),
    );
    let mut response = String::new();
    reader.read_line(&mut response).map_err(|error| read_error(&error, timeout))?;
    parse_response(&response)
}

pub(super) fn send_line(stream: &mut UnixStream, value: &Value) -> Result<(), String> {
    let mut bytes = serde_json::to_vec(value).map_err(|error| error.to_string())?;
    bytes.push(b'\n');
    stream.write_all(&bytes).map_err(|error| error.to_string())
}

fn read_error(error: &std::io::Error, timeout: Option<Duration>) -> String {
    let messages = &crate::localization::catalog().app_control;
    match (error.kind(), timeout) {
        (std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut, Some(timeout)) => {
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
    let value: Value =
        serde_json::from_str(line).map_err(|_| messages.invalid_response.to_owned())?;
    match value.get("ok").and_then(Value::as_bool) {
        Some(true) => Ok(Ok(value.get("result").cloned().unwrap_or(Value::Null))),
        Some(false) => Ok(Err(value.get("error").cloned().unwrap_or(Value::Null))),
        None => Err(messages.invalid_response.to_owned()),
    }
}

/// `events.stream`: one JSON event per line until the app closes the
/// stream or this process is interrupted. Blocking reads, no polling.
fn stream_events(stream: &mut UnixStream, params: Value, output: OutputMode) -> i32 {
    if let Err(error) =
        send_line(stream, &json!({ "id": 1, "method": "events.stream", "params": params }))
    {
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

/// `accounts.list` with `handles_stable: false`: the Keychain salt failed,
/// so the `acct_…` handles last only for this app launch.
fn warn_unstable_handles(method: &str, value: &Value, output: OutputMode) {
    if method == "accounts.list"
        && output == OutputMode::Human
        && value.get("handles_stable") == Some(&Value::Bool(false))
    {
        eprintln!("{}", crate::localization::catalog().app_control.handles_unstable);
    }
}

pub(super) fn failure(code: &str, message: &str, output: OutputMode, exit_code: i32) -> i32 {
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
                let value = args.get(index + 1).ok_or_else(|| {
                    UsageError::new(messages.missing_value.replace("{flag}", arg))
                })?;
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
        self.values
            .iter()
            .filter(|(name, _)| name == key)
            .map(|(_, value)| value.as_str())
            .collect()
    }

    fn flag(&self, key: &str) -> bool {
        self.flags.iter().any(|flag| flag == key)
    }
}

#[cfg(test)]
mod tests;
