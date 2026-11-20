//! `app_launch` and `app_list`: `cmux app launch|list --json` for agents (Leo, 2026-11-16: "it's
//! not like i can just easily say "launch this app" from my comuputer (maybe that should be a
//! feature)"). They open an app on this machine or a connected one, or list what can be opened
//! and what runs there. The app's arguments go as a list, one argv element each, never a shell.

use serde_json::{Map, Value, json};

use super::{envelope, success, tool_error, v2_tools};

pub(super) const LAUNCH: &str = "app_launch";
pub(super) const LIST: &str = "app_list";

pub(super) fn descriptors() -> Vec<Value> {
    let machine = json!({"type": "string", "minLength": 1, "description": "A connected machine's name (`cmux acp machine ls`); this machine when omitted."});
    vec![
        json!({
            "name": LAUNCH,
            "title": "Open an app on a machine",
            "description": "Open an app on this machine or a connected one, in its logged-in session, behind the window in front unless activate. app is a name (Safari, cmux), a bundle or desktop entry id, or an absolute path. args reach the app as they are, one argument each, never through a shell. Returns acpmux's answer: {ok: true, result: {app, pid, alreadyRunning, machine, ms}} or {ok: false, reason, error, next}.",
            "inputSchema": {
                "type": "object",
                "additionalProperties": false,
                "required": ["app"],
                "properties": {
                    "machine": machine,
                    "app": {"type": "string", "minLength": 1, "description": "The app: a name, an id or an absolute path."},
                    "args": {"type": "array", "items": {"type": "string"}, "description": "The app's arguments, each one argument."},
                    "activate": {"type": "boolean", "description": "Bring it to the front (default: it takes no focus)."}
                }
            },
            "annotations": {"readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": true},
        }),
        json!({
            "name": LIST,
            "title": "List the apps on a machine",
            "description": "The apps this machine or a connected one can open, the running ones first with their pids, and whether someone is logged in there. Returns {ok: true, result: {machine, apps, session}} or {ok: false, reason, error, next}.",
            "inputSchema": {
                "type": "object",
                "additionalProperties": false,
                "properties": {"machine": machine}
            },
            "annotations": {"readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": true},
        }),
    ]
}

/// The `cmux` words for a tool call (`--json app launch …`), or why the arguments are wrong.
pub(super) fn words(name: &str, arguments: &Map<String, Value>) -> Result<Vec<String>, String> {
    let text = |key: &str| arguments.get(key).and_then(Value::as_str).map(str::trim);
    let mut words: Vec<String> = vec!["--json".into(), "app".into()];
    let machine = match text("machine") {
        Some(m) if m.is_empty() || m.starts_with('-') => {
            return Err("machine must be a machine's name".into());
        }
        other => other,
    };
    let on = |words: &mut Vec<String>| {
        if let Some(machine) = machine {
            words.extend(["--on".into(), machine.to_owned()]);
        }
    };
    match name {
        LAUNCH => {
            let app = text("app").filter(|a| !a.is_empty()).ok_or("app is required")?;
            if app.starts_with('-') {
                return Err("app must be a name, an id or an absolute path".into());
            }
            let args = match arguments.get("args") {
                None | Some(Value::Null) => Vec::new(),
                Some(Value::Array(items)) => items
                    .iter()
                    .map(|a| a.as_str().map(str::to_owned))
                    .collect::<Option<Vec<_>>>()
                    .ok_or("args must be a list of strings")?,
                Some(_) => return Err("args must be a list of strings".into()),
            };
            words.push("launch".into());
            on(&mut words);
            if arguments.get("activate").and_then(Value::as_bool) == Some(true) {
                words.push("--activate".into());
            }
            words.push(app.to_owned());
            if !args.is_empty() {
                words.push("--".into());
                words.extend(args);
            }
        }
        LIST => {
            words.push("list".into());
            on(&mut words);
        }
        _ => return Err("unknown app tool".into()),
    }
    Ok(words)
}

/// Runs an app tool; `None` for any other tool name.
pub(super) fn call(name: &str, arguments: &Map<String, Value>) -> Option<Value> {
    if name != LAUNCH && name != LIST {
        return None;
    }
    let words = match words(name, arguments) {
        Ok(words) => words,
        Err(message) => {
            return Some(tool_error(envelope(v2_tools::invalid(message), "not_run", None)));
        }
    };
    // `cmux app launch|list` bounds itself (acpmux's deadline plus 30 s).
    let out = match crate::devices::cmux().and_then(|mut command| {
        Ok(command.args(&words).stdin(std::process::Stdio::null()).output()?)
    }) {
        Ok(out) => out,
        Err(error) => {
            return Some(tool_error(envelope(
                v2_tools::invalid(format!("{error:#}")),
                "not_run",
                None,
            )));
        }
    };
    let stdout = String::from_utf8_lossy(&out.stdout);
    // The whole answer (it may be pretty-printed), else its last JSON line.
    let answer = serde_json::from_str::<Value>(stdout.trim())
        .ok()
        .or_else(|| stdout.lines().rev().find_map(|line| serde_json::from_str::<Value>(line).ok()));
    Some(match answer {
        Some(answer) if out.status.success() => success(answer, name == LAUNCH),
        Some(answer) => tool_error(answer),
        None => {
            let stderr = String::from_utf8_lossy(&out.stderr);
            let error = stderr.lines().last().unwrap_or("no answer").to_owned();
            tool_error(json!({"ok": false, "reason": "app.failed", "error": error, "next": ""}))
        }
    })
}
