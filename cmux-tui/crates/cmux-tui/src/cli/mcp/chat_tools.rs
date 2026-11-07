//! `chat_send`, `chat_read` and `chat_list`: `cmux chat send|read|list` as
//! tools (u19922, Nov 3: other coding agents message the Chief, any Chief or a
//! person in a cmux chat over MCP). Each call runs this CLI's own `cmux --json
//! chat …` in a child process with the server's environment, so the sender is
//! the agent this server serves (`chief/caller.rs`: its acpmux session, or
//! its harness, session and host), never the owner, and the routing is the
//! CLI's (`chief/chat_scope.rs`). The app's `app_chat_send` (Send Message
//! To…) takes the same path, so no MCP send writes as the owner.

use std::sync::OnceLock;

use cmux_process::{Command, Stdio};

use serde_json::{Map, Value, json};

use super::{envelope, success, tool_error, v2_tools};

pub(super) const SEND: &str = "chat_send";
pub(super) const READ: &str = "chat_read";
pub(super) const LIST: &str = "chat_list";
/// The app action tool that `chat_send` stands in for.
pub(super) const APP_SEND: &str = "app_chat_send";

/// The MCP client's name from `initialize` (`clientInfo.title`, else `name`): the
/// sender's app when no harness environment says (chief/caller.rs).
static CLIENT: OnceLock<String> = OnceLock::new();

/// Keeps the client's name from an `initialize` request's params.
pub(super) fn remember_client(params: &Value) {
    let info = params.get("clientInfo");
    let name = ["title", "name"]
        .iter()
        .find_map(|key| info.and_then(|i| i.get(*key)).and_then(Value::as_str))
        .map(str::trim)
        .filter(|name| !name.is_empty());
    if let Some(name) = name {
        let _ = CLIENT.set(name.to_owned());
    }
}

/// The longest a `chat_send` waits for a Chief's reply.
const MAX_WAIT_SECONDS: u64 = 1800;
const DEFAULT_WAIT_SECONDS: u64 = 600;

const SEND_DESCRIPTION: &str = "Message your Chief, another Chief, a person or a group chat in \
    cmux, as `cmux chat send`. to: `chief` (your Chief), a Chief's name or id (`codex` is \
    \"Codex Chief\"; chat_list names them), or a person's name or a group chat's title in Home. \
    Say who you are in from, as APP or APP › PERSONA (\"Grok bot › Ada\", \"Muse\", \"Codex › \
    reviewer\"): the chat shows it, with that app's icon (a monogram for an unknown app), so \
    the user sees who sent what. Without it cmux names you by your harness and session \
    (\"Claude Code › 3fa9c1d2@mini-7\"). The message is yours as an agent, never the user's, \
    and a Chief reads it as an agent's words. wait true (Chiefs only) answers with the Chief's replies when its turn ends \
    ({id, seq, conversation, replies}); timeout_seconds bounds it (default 600, at most 1800). \
    class says what you ask: question, block, blocker, action, result (default) or fyi.";

const READ_DESCRIPTION: &str = "Read a Chief's chat, as `cmux chat read`: the last messages, \
    oldest first, with author, seq and text. to names the chat as in chat_send (default: your \
    Chief). Changes nothing.";

const LIST_DESCRIPTION: &str = "The Chief chats you can message, as `cmux chat list`: id, \
    title, chief, last_seq, unread. A person or a group chat is named by its Home name in \
    chat_send. Changes nothing.";

pub(super) fn descriptors() -> [Value; 3] {
    let read_only = json!({"readOnlyHint": true, "destructiveHint": false,
        "idempotentHint": true, "openWorldHint": false});
    [
        json!({
            "name": SEND,
            "title": "Message a Chief or a person",
            "description": SEND_DESCRIPTION,
            "inputSchema": {
                "type": "object",
                "properties": {
                    "to": {"type": "string", "minLength": 1},
                    "text": {"type": "string", "minLength": 1},
                    "wait": {"type": "boolean", "default": false},
                    "timeout_seconds": {"type": "integer", "minimum": 1,
                                        "maximum": MAX_WAIT_SECONDS, "default": DEFAULT_WAIT_SECONDS},
                    "from": {"type": "string", "minLength": 1, "description": "Who you are, as APP or APP › PERSONA (\"Grok bot › Ada\", \"Muse\", \"Claude Code › reviewer\"). Always say it: the chat shows it with your icon. Default: your harness and session."},
                    "as": {"type": "string", "minLength": 1, "description": "Old name of from."},
                    "class": {"type": "string",
                              "enum": ["question", "block", "blocker", "action", "result", "fyi"]},
                },
                "required": ["to", "text"],
                "additionalProperties": false,
            },
            "annotations": {"readOnlyHint": false, "destructiveHint": false,
                            "idempotentHint": false, "openWorldHint": true},
        }),
        json!({
            "name": READ,
            "title": "Read a Chief's chat",
            "description": READ_DESCRIPTION,
            "inputSchema": {
                "type": "object",
                "properties": {
                    "to": {"type": "string", "minLength": 1},
                    "last": {"type": "integer", "minimum": 1, "maximum": 500, "default": 20},
                },
                "additionalProperties": false,
            },
            "annotations": &read_only,
        }),
        json!({
            "name": LIST,
            "title": "Chief chats",
            "description": LIST_DESCRIPTION,
            "inputSchema": {"type": "object", "properties": {}, "additionalProperties": false},
            "annotations": read_only,
        }),
    ]
}

/// The CLI words a call runs (after `cmux --json`), or the error for bad arguments.
pub(super) fn words(
    name: &str,
    arguments: &Map<String, Value>,
) -> Option<Result<Vec<String>, String>> {
    let text = |key: &str| arguments.get(key).and_then(Value::as_str).map(str::to_owned);
    let allowed: &[&str] = match name {
        SEND | APP_SEND => {
            &["to", "text", "wait", "timeout_seconds", "from", "as", "class", "focus"]
        }
        READ => &["to", "last"],
        LIST => &[],
        _ => return None,
    };
    if let Some(key) = arguments.keys().find(|k| !allowed.contains(&k.as_str())) {
        return Some(Err(format!("{name} has no argument {key:?}")));
    }
    Some(match name {
        LIST => Ok(vec!["chat".into(), "list".into()]),
        READ => {
            let mut words = vec!["chat".to_owned(), "read".to_owned()];
            if let Some(to) = text("to") {
                words.extend(["--to".to_owned(), to]);
            }
            let last = arguments.get("last").and_then(Value::as_u64).unwrap_or(20).clamp(1, 500);
            words.extend(["--last".to_owned(), last.to_string()]);
            Ok(words)
        }
        _ => {
            let (Some(to), Some(body)) = (text("to"), text("text")) else {
                return Some(Err(format!("{name} needs to and text")));
            };
            let mut words = vec!["chat".to_owned(), "send".to_owned(), "--to".to_owned(), to];
            words.extend(["--text".to_owned(), body]);
            if arguments.get("wait").and_then(Value::as_bool) == Some(true) {
                let secs = arguments
                    .get("timeout_seconds")
                    .and_then(Value::as_u64)
                    .unwrap_or(DEFAULT_WAIT_SECONDS)
                    .clamp(1, MAX_WAIT_SECONDS);
                words.extend(["--wait".to_owned(), "--timeout".to_owned(), secs.to_string()]);
            }
            if let Some(from) = text("from").or_else(|| text("as")) {
                words.extend(["--from".to_owned(), from]);
            }
            if let Some(class) = text("class") {
                words.extend(["--class".to_owned(), class]);
            }
            Ok(words)
        }
    })
}

/// Runs a chat tool; None when `name` is none of them.
pub(super) fn call(name: &str, arguments: &Map<String, Value>) -> Option<Value> {
    let words = match words(name, arguments)? {
        Ok(words) => words,
        Err(message) => {
            return Some(tool_error(envelope(v2_tools::invalid(message), "not_run", None)));
        }
    };
    Some(run(&words, name == SEND || name == APP_SEND))
}

fn run(words: &[String], applied: bool) -> Value {
    let program = match std::env::current_exe() {
        Ok(program) => program,
        Err(error) => return failed(&format!("this cmux has no path: {error}"), "not_run"),
    };
    let mut command = Command::new(program);
    command.arg("--json").args(words).stdin(Stdio::null()).stdout(Stdio::piped());
    command.stderr(Stdio::piped());
    if let Some(name) = CLIENT.get() {
        command.env(super::super::chief::caller::SENDER_APP_ENV, name);
    }
    let output = command.output();
    let output = match output {
        Ok(output) => output,
        Err(error) => return failed(&format!("cmux chat did not start: {error}"), "not_run"),
    };
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    if !output.status.success() {
        let message = stderr.trim().trim_start_matches("cmux: ");
        let message = if message.is_empty() { stdout.trim() } else { message };
        let state = match output.status.code() {
            Some(2) => "not_run",
            Some(124) => "in_progress",
            _ => "rejected",
        };
        return failed(message, state);
    }
    let value = stdout
        .lines()
        .rev()
        .find_map(|line| serde_json::from_str::<Value>(line.trim()).ok())
        .unwrap_or_else(|| json!({"output": stdout.trim()}));
    success(value, applied)
}

fn failed(message: &str, state: &str) -> Value {
    let error =
        json!({"code": "chat.failed", "message": message, "details": {}, "retryable": false});
    tool_error(envelope(error, state, None))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(value: Value) -> Map<String, Value> {
        value.as_object().cloned().unwrap_or_default()
    }

    #[test]
    fn a_send_is_the_clis_chat_send_with_its_wait_and_sender() {
        let words = words(
            SEND,
            &args(json!({"to": "codex", "text": "status?", "wait": true,
            "timeout_seconds": 99_999, "class": "question"})),
        );
        assert_eq!(
            words,
            Some(Ok([
                "chat",
                "send",
                "--to",
                "codex",
                "--text",
                "status?",
                "--wait",
                "--timeout",
                "1800",
                "--class",
                "question"
            ]
            .map(str::to_owned)
            .to_vec()))
        );
        // The app's Send Message To… takes the same path.
        let app = words_of(APP_SEND, json!({"to": "Austin", "text": "hi"}));
        assert_eq!(
            app,
            ["chat", "send", "--to", "Austin", "--text", "hi"].map(str::to_owned).to_vec()
        );
    }

    fn words_of(name: &str, value: Value) -> Vec<String> {
        words(name, &args(value)).and_then(Result::ok).unwrap_or_default()
    }

    #[test]
    fn read_and_list_are_the_clis_and_bad_arguments_are_refused() {
        assert_eq!(
            words_of(READ, json!({"to": "muse", "last": 5})),
            ["chat", "read", "--to", "muse", "--last", "5"].map(str::to_owned).to_vec()
        );
        assert_eq!(words_of(LIST, json!({})), ["chat", "list"].map(str::to_owned).to_vec());
        assert!(matches!(words(SEND, &args(json!({"to": "chief"}))), Some(Err(_))));
        assert!(matches!(words(LIST, &args(json!({"x": 1}))), Some(Err(_))));
        assert_eq!(words("agents_snapshot", &args(json!({}))), None);
    }
}
