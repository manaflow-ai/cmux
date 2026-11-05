//! `live_code_status`, `live_code_apply`, `live_code_undo` and `live_code_log`:
//! `cmux live-code …` as tools, so an agent session (acpmux or any harness)
//! can read what a running live code build has applied and repair it: undo a
//! patch that broke it, apply one again, or learn it must relaunch (exit 4).
//! Each call runs this CLI's own `cmux --json live-code …` in a child process;
//! the CLI works through the app's live folder, never its UI (live_code.rs).

use cmux_process::{Command, Stdio};
use serde_json::{Map, Value, json};

use super::{envelope, success, tool_error, v2_tools};

pub(super) const STATUS: &str = "live_code_status";
pub(super) const APPLY: &str = "live_code_apply";
pub(super) const UNDO: &str = "live_code_undo";
pub(super) const LOG: &str = "live_code_log";

const DIR: &str = "The live folder (default: CMUX_LIVE_CODE_DIR, else ~/Library/Caches/cmux-next/live-code).";

pub(super) fn descriptors() -> [Value; 4] {
    let read_only = json!({"readOnlyHint": true, "destructiveHint": false,
        "idempotentHint": true, "openWorldHint": false});
    let dir = json!({"type": "string", "minLength": 1, "description": DIR});
    let timeout = json!({"type": "integer", "minimum": 1, "maximum": 600, "default": 20});
    [
        json!({
            "name": STATUS,
            "title": "Live code status",
            "description": "What the running cmux live code build has applied, as `cmux live-code status`: \
                its pid and whether it still runs (watching), each patch newest first with its commit, \
                files and functions, and the last error. Changes nothing.",
            "inputSchema": {"type": "object", "properties": {"dir": &dir}, "additionalProperties": false},
            "annotations": &read_only,
        }),
        json!({
            "name": APPLY,
            "title": "Apply a live code patch",
            "description": "Apply a patch dylib to the running cmux live code build, as `cmux live-code apply`, \
                and wait for the app's answer. Outside Debug the app loads only patches signed by its own team.",
            "inputSchema": {
                "type": "object",
                "properties": {"patch": {"type": "string", "minLength": 1}, "dir": &dir, "timeout_seconds": &timeout},
                "required": ["patch"],
                "additionalProperties": false,
            },
            "annotations": {"readOnlyHint": false, "destructiveHint": false,
                            "idempotentHint": false, "openWorldHint": false},
        }),
        json!({
            "name": UNDO,
            "title": "Undo live code",
            "description": "Undo the newest live code patch (all true: every patch, back to the code as built), \
                as `cmux live-code undo`. Works when the app's UI is stuck. If the app does not answer, relaunch it.",
            "inputSchema": {
                "type": "object",
                "properties": {"all": {"type": "boolean", "default": false}, "dir": &dir, "timeout_seconds": &timeout},
                "additionalProperties": false,
            },
            "annotations": {"readOnlyHint": false, "destructiveHint": true,
                            "idempotentHint": false, "openWorldHint": false},
        }),
        json!({
            "name": LOG,
            "title": "Live code log",
            "description": "The last lines of the app's live code log, as `cmux live-code log`. Changes nothing.",
            "inputSchema": {
                "type": "object",
                "properties": {"lines": {"type": "integer", "minimum": 1, "maximum": 10000, "default": 40}, "dir": &dir},
                "additionalProperties": false,
            },
            "annotations": read_only,
        }),
    ]
}

/// The CLI words a call runs (after `cmux --json`), or the error for bad arguments.
pub(super) fn words(name: &str, arguments: &Map<String, Value>) -> Option<Result<Vec<String>, String>> {
    let allowed: &[&str] = match name {
        STATUS => &["dir"],
        APPLY => &["patch", "dir", "timeout_seconds"],
        UNDO => &["all", "dir", "timeout_seconds"],
        LOG => &["lines", "dir"],
        _ => return None,
    };
    if let Some(key) = arguments.keys().find(|k| !allowed.contains(&k.as_str())) {
        return Some(Err(format!("{name} has no argument {key:?}")));
    }
    let verb = match name {
        STATUS => "status",
        APPLY => "apply",
        UNDO => "undo",
        _ => "log",
    };
    let mut words = vec!["live-code".to_owned(), verb.to_owned()];
    if name == APPLY {
        let Some(patch) = arguments.get("patch").and_then(Value::as_str) else {
            return Some(Err(format!("{name} needs patch")));
        };
        words.push(patch.to_owned());
    }
    if name == UNDO && arguments.get("all").and_then(Value::as_bool) == Some(true) {
        words.push("--all".to_owned());
    }
    if let Some(seconds) = arguments.get("timeout_seconds").and_then(Value::as_u64) {
        words.extend(["--timeout".to_owned(), seconds.clamp(1, 600).to_string()]);
    }
    if let Some(lines) = arguments.get("lines").and_then(Value::as_u64) {
        words.extend(["-n".to_owned(), lines.clamp(1, 10_000).to_string()]);
    }
    if let Some(dir) = arguments.get("dir").and_then(Value::as_str) {
        words.extend(["--dir".to_owned(), dir.to_owned()]);
    }
    Some(Ok(words))
}

/// Runs a live code tool; None when `name` is none of them.
pub(super) fn call(name: &str, arguments: &Map<String, Value>) -> Option<Value> {
    let words = match words(name, arguments)? {
        Ok(words) => words,
        Err(message) => return Some(tool_error(envelope(v2_tools::invalid(message), "not_run", None))),
    };
    Some(run(&words, name == APPLY || name == UNDO))
}

fn run(words: &[String], changes: bool) -> Value {
    let program = match std::env::current_exe() {
        Ok(program) => program,
        Err(error) => return failed("live_code.failed", &format!("this cmux has no path: {error}"), "not_run"),
    };
    let output = Command::new(program)
        .arg("--json")
        .args(words)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output();
    let output = match output {
        Ok(output) => output,
        Err(error) => return failed("live_code.failed", &format!("cmux live-code did not start: {error}"), "not_run"),
    };
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    let last_json = |text: &str| text.lines().rev().find_map(|line| serde_json::from_str::<Value>(line.trim()).ok());
    if !output.status.success() {
        // The CLI's own error (code and message), with what to do next for an agent.
        let error = last_json(&stdout).or_else(|| last_json(&stderr));
        let message = error
            .as_ref()
            .and_then(|e| e.pointer("/error/message").or_else(|| e.get("message")))
            .and_then(Value::as_str)
            .map(str::to_owned)
            .unwrap_or_else(|| stderr.trim().trim_start_matches("cmux: ").to_owned());
        let (code, state) = match output.status.code() {
            Some(2) => ("live_code.usage", "not_run"),
            Some(3) => ("live_code.not_watching", "not_run"),
            Some(4) => ("live_code.no_answer", "unknown"),
            _ => ("live_code.refused", "rejected"),
        };
        return failed(code, &message, state);
    }
    success(last_json(&stdout).unwrap_or_else(|| json!({"output": stdout.trim()})), changes)
}

fn failed(code: &str, message: &str, state: &str) -> Value {
    // No answer means the app may be stuck: the next step is a relaunch.
    let next = if code == "live_code.no_answer" { json!({"next": "relaunch the app"}) } else { json!({}) };
    let error = json!({"code": code, "message": message, "details": next, "retryable": false});
    tool_error(envelope(error, state, None))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn words_of(name: &str, value: Value) -> Option<Result<Vec<String>, String>> {
        words(name, &value.as_object().cloned().unwrap_or_default())
    }

    fn ok(list: &[&str]) -> Option<Result<Vec<String>, String>> {
        Some(Ok(list.iter().map(|word| (*word).to_owned()).collect()))
    }

    #[test]
    fn each_tool_is_the_clis_live_code_verb() {
        assert_eq!(words_of(STATUS, json!({})), ok(&["live-code", "status"]));
        assert_eq!(
            words_of(APPLY, json!({"patch": "/tmp/p.dylib", "timeout_seconds": 9999})),
            ok(&["live-code", "apply", "/tmp/p.dylib", "--timeout", "600"])
        );
        assert_eq!(
            words_of(UNDO, json!({"all": true, "dir": "/tmp/live"})),
            ok(&["live-code", "undo", "--all", "--dir", "/tmp/live"])
        );
        assert_eq!(words_of(LOG, json!({"lines": 5})), ok(&["live-code", "log", "-n", "5"]));
    }

    #[test]
    fn bad_arguments_are_refused_and_other_tools_are_not_ours() {
        assert!(matches!(words_of(APPLY, json!({})), Some(Err(_))));
        assert!(matches!(words_of(UNDO, json!({"patch": "x"})), Some(Err(_))));
        assert_eq!(words_of("chat_send", json!({})), None);
        let names: Vec<String> = descriptors()
            .iter()
            .filter_map(|tool| tool.get("name").and_then(Value::as_str).map(str::to_owned))
            .collect();
        assert_eq!(names, [STATUS, APPLY, UNDO, LOG]);
    }
}
