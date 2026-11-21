//! `cloud_connections`, `cloud_connect_chatgpt`, `cloud_connect_chatgpt_wait` and
//! `cloud_connect_chatgpt_cancel`: `cmux cloud connections` and `cmux cloud connect chatgpt` as
//! tools, so an agent can see which model connection a Cloud session can run on and start the
//! ChatGPT sign-in the person finishes in their browser. Each runs this CLI's own `cmux --json
//! cloud …` in a child process (as `chat_tools` does). A Claude setup token or an API key is
//! never a tool argument or result: the person adds one in a terminal with `cmux cloud connect
//! claude` or `cmux cloud connect api-key --provider anthropic|openai`, which put it straight into
//! the Keychain.

use cmux_process::{Command, Stdio};
use serde_json::{Map, Value, json};

use super::{envelope, success, tool_error, v2_tools};

pub(super) const LIST: &str = "cloud_connections";
pub(super) const CHATGPT: &str = "cloud_connect_chatgpt";
pub(super) const CHATGPT_WAIT: &str = "cloud_connect_chatgpt_wait";
pub(super) const CHATGPT_CANCEL: &str = "cloud_connect_chatgpt_cancel";

/// The longest one wait tool call blocks; call it again while it answers pending.
const MAX_WAIT_SECONDS: u64 = 110;

const SECRETS_NOTE: &str = "A Claude subscription or an API key is never a tool argument: ask the person to run `cmux cloud connect claude` (it runs claude setup-token; they open its link and paste the code back) or `cmux cloud connect api-key --provider anthropic|openai` in a terminal; the secret goes straight into this Mac's Keychain.";

pub(super) fn descriptors() -> Vec<Value> {
    let attempt =
        json!({"type": "string", "minLength": 1, "maxLength": 128, "pattern": "^[A-Za-z0-9_.-]+$"});
    vec![
        json!({
            "name": LIST,
            "title": "List model connections",
            "description": format!("The model connections on this Mac (cmux cloud connections): each one's id, kind, label, sign-in state and serves_cloud, whether a Cloud session can run on it (Codex's and Claude Code's own logins cannot). Never a secret. Add ChatGPT with {CHATGPT}. {SECRETS_NOTE}"),
            "inputSchema": {"type": "object", "additionalProperties": false, "properties": {}},
            "annotations": {"readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false},
        }),
        json!({
            "name": CHATGPT,
            "title": "Start a ChatGPT sign-in",
            "description": format!("Start signing in to ChatGPT as a model connection (cmux cloud connect chatgpt --no-wait). Answers {{attempt, url}}: give the person the url to open in a browser on this Mac (it returns to localhost:1455), then call {CHATGPT_WAIT} with the attempt. id signs an existing ChatGPT connection in again."),
            "inputSchema": {
                "type": "object",
                "additionalProperties": false,
                "properties": {"id": {"type": "string", "minLength": 1, "maxLength": 128, "pattern": "^[A-Za-z0-9_.-]+$"}},
            },
            "annotations": {"readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": true},
        }),
        json!({
            "name": CHATGPT_WAIT,
            "title": "Wait for a ChatGPT sign-in",
            "description": format!("Wait up to timeout_seconds (default 60, at most {MAX_WAIT_SECONDS}) for the ChatGPT sign-in attempt to finish. Answers status done with the connection, or pending (the attempt still runs: call again). A failed or cancelled sign-in is an error."),
            "inputSchema": {
                "type": "object",
                "additionalProperties": false,
                "required": ["attempt"],
                "properties": {
                    "attempt": attempt,
                    "timeout_seconds": {"type": "integer", "minimum": 1, "maximum": MAX_WAIT_SECONDS},
                },
            },
            "annotations": {"readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false},
        }),
        json!({
            "name": CHATGPT_CANCEL,
            "title": "Cancel a ChatGPT sign-in",
            "description": "End a ChatGPT sign-in attempt that has not finished.",
            "inputSchema": {
                "type": "object",
                "additionalProperties": false,
                "required": ["attempt"],
                "properties": {"attempt": attempt},
            },
            "annotations": {"readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false},
        }),
    ]
}

/// A safe word for an attempt or connection id: never a flag.
fn word(arguments: &Map<String, Value>, key: &str) -> Result<Option<String>, String> {
    match arguments.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(text))
            if !text.is_empty()
                && text.len() <= 128
                && !text.starts_with('-')
                && text.chars().all(|c| c.is_ascii_alphanumeric() || "_.-".contains(c)) =>
        {
            Ok(Some(text.clone()))
        }
        Some(_) => Err(format!("{key} must be an id from an earlier answer")),
    }
}

/// The `cmux cloud …` words for a tool, `None` for any other tool name.
pub(super) fn words(
    name: &str,
    arguments: &Map<String, Value>,
) -> Option<Result<Vec<String>, String>> {
    let base = |rest: &[&str]| -> Vec<String> {
        ["cloud"].iter().chain(rest).map(|s| (*s).to_owned()).collect()
    };
    Some(match name {
        LIST => Ok(base(&["connections"])),
        CHATGPT => word(arguments, "id").map(|id| {
            let mut words = base(&["connect", "chatgpt", "--no-wait"]);
            if let Some(id) = id {
                words.extend(["--id".to_owned(), id]);
            }
            words
        }),
        CHATGPT_WAIT | CHATGPT_CANCEL => match word(arguments, "attempt") {
            Ok(Some(attempt)) if name == CHATGPT_CANCEL => {
                Ok([base(&["connect", "chatgpt", "--cancel"]), vec![attempt]].concat())
            }
            Ok(Some(attempt)) => {
                let seconds = match arguments.get("timeout_seconds") {
                    None | Some(Value::Null) => Ok(60),
                    Some(value) => value
                        .as_u64()
                        .filter(|s| (1..=MAX_WAIT_SECONDS).contains(s))
                        .ok_or_else(|| format!("timeout_seconds must be 1 to {MAX_WAIT_SECONDS}")),
                };
                seconds.map(|seconds| {
                    let mut words = base(&["connect", "chatgpt", "--wait"]);
                    words.extend([
                        attempt,
                        "--keep".into(),
                        "--timeout".into(),
                        seconds.to_string(),
                    ]);
                    words
                })
            }
            Ok(None) => Err("attempt is required".into()),
            Err(message) => Err(message),
        },
        _ => return None,
    })
}

/// Runs a cloud connection tool; `None` for any other tool name.
pub(super) fn call(name: &str, arguments: &Map<String, Value>) -> Option<Value> {
    let words = match words(name, arguments)? {
        Ok(words) => words,
        Err(message) => {
            return Some(tool_error(envelope(v2_tools::invalid(message), "not_run", None)));
        }
    };
    Some(run(&words, name == CHATGPT || name == CHATGPT_CANCEL))
}

fn run(words: &[String], applied: bool) -> Value {
    let program = match std::env::current_exe() {
        Ok(program) => program,
        Err(error) => return failed(&format!("this cmux has no path: {error}")),
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
        Err(error) => return failed(&format!("cmux cloud did not start: {error}")),
    };
    let stdout = String::from_utf8_lossy(&output.stdout);
    let last =
        stdout.lines().rev().find_map(|line| serde_json::from_str::<Value>(line.trim()).ok());
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        // `--json` errors are one `{code, message, ...}` line on stderr (wire::print_local_error).
        let message = stderr
            .lines()
            .rev()
            .find_map(|line| serde_json::from_str::<Value>(line.trim()).ok())
            .and_then(|v| v.pointer("/error/message").or_else(|| v.get("message")).cloned())
            .and_then(|m| m.as_str().map(str::to_owned))
            .unwrap_or_else(|| stderr.trim().to_owned());
        return failed(message.trim_start_matches("cmux: "));
    }
    success(last.unwrap_or_else(|| json!({"output": stdout.trim()})), applied)
}

fn failed(message: &str) -> Value {
    let error = json!({"code": "cloud_connect.failed", "message": message, "details": {}, "retryable": false});
    tool_error(envelope(error, "rejected", None))
}
