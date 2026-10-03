//! `cmux settings …`: the daemon's settings owner (`settings-v1`,
//! plans/cmux-next/settings-react.md section 3).
//!
//! `list [--section S]`, `get KEY`, `set KEY VALUE` (VALUE is JSON when it
//! parses as JSON, else the literal string), `reset KEY` (`unset`),
//! `reset-all`, `snapshot` and `schema` send the `settings.*` operations.
//! `--path-json '["a","b.c"]'` names a key path with dots in its parts,
//! `--if-revision N` refuses the write when the settings changed since N.
//! `open [KEY]` opens the app's Settings window (cli/app.rs).
//!
//! Exit codes: 0 done, 2 refused (the message names the accepted values or
//! range), 1 transport or daemon failure. A daemon without `settings-v1`
//! answers `get`, `set` and `reset` through the app socket's old methods.

use std::io::{BufReader, Write};

use cmux_tui_core::resource::ResourceOperation as Op;
use serde_json::{Map, Value, json};

use super::command::{CommandPlan, Flags, RequestPlan, WireOperation, routed_request};
use super::{GlobalArgs, OutputMode, UsageError};

const USAGE: &str = "settings list [--section S] | get KEY | set KEY VALUE | reset KEY | reset-all | snapshot | schema | open [KEY]";
const CAPABILITY: &str = "settings-v1";

/// Parses `settings <verb> …` into a `settings.*` request.
pub(super) fn parse(words: &[&str], flags: &mut Flags) -> Result<CommandPlan, UsageError> {
    let mut params = Map::new();
    let operation = match words {
        ["list"] => {
            if let Some(section) = flags.take("section") {
                params.insert("section".into(), json!(section));
            }
            Op::SettingsList
        }
        ["get", rest @ ..] if rest.len() <= 1 => {
            insert_target(&mut params, flags, rest.first().copied())?;
            Op::SettingsGet
        }
        ["snapshot"] => Op::SettingsSnapshot,
        ["schema"] => Op::SettingsSchema,
        ["set", rest @ ..] if !rest.is_empty() && rest.len() <= 2 => {
            let (key, value) = match rest {
                [key, value] => (Some(*key), *value),
                [value] => (None, *value),
                _ => unreachable!("guarded"),
            };
            insert_target(&mut params, flags, key)?;
            params.insert("value".into(), parse_value(value));
            write_flags(&mut params, flags)?;
            Op::SettingsSet
        }
        ["reset" | "unset", rest @ ..] if rest.len() <= 1 => {
            insert_target(&mut params, flags, rest.first().copied())?;
            write_flags(&mut params, flags)?;
            Op::SettingsReset
        }
        ["reset-all"] => {
            write_flags(&mut params, flags)?;
            Op::SettingsResetAll
        }
        _ => return Err(UsageError::new(format!("usage: cmux {USAGE}"))),
    };
    routed_request(operation, flags, params)
}

/// A JSON value when `text` parses as one, else the literal string.
pub(super) fn parse_value(text: &str) -> Value {
    serde_json::from_str(text).unwrap_or_else(|_| Value::String(text.to_owned()))
}

fn insert_target(
    params: &mut Map<String, Value>,
    flags: &mut Flags,
    key: Option<&str>,
) -> Result<(), UsageError> {
    match (key, flags.take("path-json")) {
        (Some(key), None) => {
            params.insert("key".into(), json!(key));
        }
        (None, Some(path)) => {
            let path: Vec<String> = serde_json::from_str(&path)
                .map_err(|_| UsageError::new("--path-json takes a JSON array of strings"))?;
            params.insert("path".into(), json!(path));
        }
        (Some(_), Some(_)) => return Err(UsageError::new("give a key or --path-json, not both")),
        (None, None) => return Err(UsageError::new(format!("usage: cmux {USAGE}"))),
    }
    Ok(())
}

fn write_flags(params: &mut Map<String, Value>, flags: &mut Flags) -> Result<(), UsageError> {
    if let Some(revision) = flags.take("if-revision") {
        if revision.is_empty() || !revision.bytes().all(|byte| byte.is_ascii_digit()) {
            return Err(UsageError::new("--if-revision takes a decimal revision"));
        }
        params.insert("if_revision".into(), json!(revision));
    }
    if let Some(origin) = flags.take("origin") {
        if !matches!(origin.as_str(), "user" | "cli" | "mcp" | "script" | "remote" | "app") {
            return Err(UsageError::new("--origin is user, cli, mcp, script, remote or app"));
        }
        params.insert("origin".into(), json!(origin));
    }
    Ok(())
}

/// Whether `plan` is a settings request this module runs.
pub(super) fn handles(plan: &RequestPlan) -> bool {
    matches!(
        plan.operation,
        WireOperation::Typed(
            Op::SettingsList
                | Op::SettingsGet
                | Op::SettingsSnapshot
                | Op::SettingsSchema
                | Op::SettingsSet
                | Op::SettingsReset
                | Op::SettingsResetAll
        )
    )
}

/// What the daemon answered.
enum Answer {
    Result(Value),
    Error(Value),
    /// The daemon does not serve `settings-v1`.
    Unsupported,
}

pub(super) fn run(global: GlobalArgs, mut plan: RequestPlan) -> i32 {
    if let Err(error) = super::resolve::apply_global_route(&global, &mut plan.params) {
        eprintln!("cmux: {error}");
        return 2;
    }
    match send(&global, &plan) {
        Ok(Answer::Result(result)) => print_result(&plan, &result, global.output),
        Ok(Answer::Error(error)) => print_refusal(&error, global.output),
        Ok(Answer::Unsupported) => legacy(&global, &plan),
        Err(message) => {
            eprintln!("cmux: {message}");
            1
        }
    }
}

/// One `identify` (for the capability) and the request, on one connection.
fn send(global: &GlobalArgs, plan: &RequestPlan) -> Result<Answer, String> {
    let request = super::wire::request_value(plan).map_err(|error| error.to_string())?;
    let (socket, derived) = super::wire::resolve_socket_with_origin(global)
        .map_err(|_| crate::localization::catalog().startup.invalid_session_name.to_owned())?;
    let stream = cmux_tui_core::server::connect_session_socket(&socket, derived)
        .map_err(|error| format!("cannot connect to session socket {}: {error}", socket.display()))?;
    let _ = stream.set_read_timeout(Some(super::wire::SERVER_PREFLIGHT_TIMEOUT));
    let mut reader = BufReader::new(stream);
    let identify = json!({"id": super::wire::random_request_id().map_err(|e| e.to_string())?, "cmd": "identify"});
    let identity = exchange(&mut reader, &identify)?;
    let supported = crate::session::parse_identity_capabilities(&identity["data"])
        .is_ok_and(|capabilities| capabilities.contains(CAPABILITY));
    if !supported {
        return Ok(Answer::Unsupported);
    }
    let response = exchange(&mut reader, &request)?;
    if response["ok"] == Value::Bool(true) {
        return Ok(Answer::Result(response["result"].clone()));
    }
    Ok(Answer::Error(response["error"].clone()))
}

fn exchange(
    reader: &mut BufReader<Box<dyn cmux_tui_core::platform::transport::Stream>>,
    request: &Value,
) -> Result<Value, String> {
    let mut line = serde_json::to_vec(request).map_err(|error| error.to_string())?;
    line.push(b'\n');
    reader
        .get_mut()
        .write_all(&line)
        .and_then(|()| reader.get_mut().flush())
        .map_err(|error| format!("transport error: {error}"))?;
    loop {
        let response = super::wire::read_envelope(reader, false)?
            .ok_or_else(|| "transport closed before response".to_owned())?;
        if response.get("id") == request.get("id") {
            return Ok(response);
        }
    }
}

fn print_result(plan: &RequestPlan, result: &Value, output: OutputMode) -> i32 {
    let text = match output {
        OutputMode::Json | OutputMode::JsonLines => {
            serde_json::to_string(result).unwrap_or_default() + "\n"
        }
        OutputMode::Quiet => String::new(),
        OutputMode::Human => human(plan, result),
    };
    let _ = std::io::stdout().lock().write_all(text.as_bytes());
    0
}

/// One row per key: key, value, and `*` (customized) or `managed (source)`.
pub(super) fn human(plan: &RequestPlan, result: &Value) -> String {
    match plan.operation {
        WireOperation::Typed(Op::SettingsList) => {
            let rows = result.as_array().map(Vec::as_slice).unwrap_or_default();
            let width = rows.iter().filter_map(|row| row["key"].as_str()).map(str::len).max();
            rows.iter().map(|row| row_line(row, width.unwrap_or(0))).collect()
        }
        WireOperation::Typed(Op::SettingsGet) => {
            let mut line = row_line(
                &json!({
                    "key": result["key"],
                    "value": result["value"],
                    "customized": result["row"]["customized"],
                    "managed": result["managed"],
                }),
                0,
            );
            if result["row"].is_null() && result["value"].is_null() {
                line = format!("{} is not set\n", result["key"].as_str().unwrap_or_default());
            }
            line
        }
        WireOperation::Typed(Op::SettingsSet | Op::SettingsReset | Op::SettingsResetAll) => {
            let keys = result["value"]["keys"].as_array().map(Vec::as_slice).unwrap_or_default();
            let keys = keys.iter().filter_map(Value::as_str).collect::<Vec<_>>();
            let changed = if keys.is_empty() { "no change".to_owned() } else { keys.join(", ") };
            let replay = if result["replayed"] == Value::Bool(true) { " (replayed)" } else { "" };
            format!("revision {}: {changed}{replay}\n", result["revision"].as_str().unwrap_or("?"))
        }
        _ => serde_json::to_string_pretty(result).unwrap_or_default() + "\n",
    }
}

fn row_line(row: &Value, width: usize) -> String {
    let key = row["key"].as_str().unwrap_or_default();
    let value = if row["value"].is_null() { "-".to_owned() } else { row["value"].to_string() };
    let marker = match &row["managed"] {
        Value::Object(managed) => {
            format!("  managed ({})", managed.get("source").and_then(Value::as_str).unwrap_or("?"))
        }
        _ if row["customized"] == Value::Bool(true) => "  *".to_owned(),
        _ => String::new(),
    };
    format!("{key:<width$}  {value}{marker}\n")
}

/// Exit 2 with the message and what the key accepts.
pub(super) fn print_refusal(error: &Value, output: OutputMode) -> i32 {
    match output {
        OutputMode::Json | OutputMode::JsonLines => {
            let _ = writeln!(std::io::stderr(), "{error}");
        }
        OutputMode::Quiet | OutputMode::Human => {
            let _ = std::io::stderr().write_all(refusal_text(error).as_bytes());
        }
    }
    if is_refusal(error) { 2 } else { 1 }
}

/// The owner refused the request (as opposed to failing to run it).
pub(super) fn is_refusal(error: &Value) -> bool {
    error["code"].as_str().is_some_and(|code| {
        code.starts_with("settings.")
            || matches!(code, "validation.invalid" | "revision.conflict" | "idempotency.conflict")
    })
}

pub(super) fn refusal_text(error: &Value) -> String {
    let message = error["message"].as_str().unwrap_or("settings refused the request");
    let accepted = &error["details"]["accepted"];
    let hint = if let Some(choices) = accepted["choices"].as_array() {
        let choices = choices.iter().filter_map(Value::as_str).collect::<Vec<_>>().join(", ");
        match accepted["range"].as_object() {
            Some(range) => format!(" (accepted: {choices}, or {} to {})", range["min"], range["max"]),
            None => format!(" (accepted: {choices})"),
        }
    } else if let Some(range) = accepted["range"].as_object() {
        format!(" (accepted: {} to {})", range["min"], range["max"])
    } else if let Some(shape) = accepted["shape"].as_str() {
        format!(" (accepted: {shape})")
    } else if let Some(values) = accepted["values"].as_array() {
        let values = values.iter().filter_map(Value::as_str).collect::<Vec<_>>().join(", ");
        format!(" (accepted: {values})")
    } else {
        String::new()
    };
    format!("cmux: {message}{hint}\n")
}

/// An old daemon: `get`, `set` and `reset` through the app socket.
#[cfg(unix)]
fn legacy(global: &GlobalArgs, plan: &RequestPlan) -> i32 {
    let path = plan.params.get("key").cloned().or_else(|| plan.params.get("path").cloned());
    let command = match (&plan.operation, path) {
        (WireOperation::Typed(Op::SettingsGet), Some(path)) => {
            super::app::legacy_settings_call("settings.get", json!({"path": path}))
        }
        (WireOperation::Typed(Op::SettingsSet), Some(path)) => super::app::legacy_settings_call(
            "settings.set",
            json!({"path": path, "value": plan.params["value"]}),
        ),
        (WireOperation::Typed(Op::SettingsReset), Some(path)) => {
            super::app::legacy_settings_call("settings.unset", json!({"path": path}))
        }
        _ => return unsupported(),
    };
    super::app::run(global, command)
}

#[cfg(not(unix))]
fn legacy(_global: &GlobalArgs, _plan: &RequestPlan) -> i32 {
    unsupported()
}

fn unsupported() -> i32 {
    eprintln!("cmux: the session daemon does not serve {CAPABILITY}; restart it with this cmux");
    1
}

#[cfg(test)]
#[path = "settings_tests.rs"]
mod tests;
