//! `agents_terminal_list` and `agents_terminal_send`: `cmux terminal list
//! --agents` and `cmux terminal <t> send` as tools, so the Chief talks to
//! Claude Code, Codex and other agents in cmux terminals in one call
//! instead of a write, an Enter and a screen read loop. Both run the CLI's
//! code (`cli/terminal_talk`).

use std::time::Duration;

use serde_json::{Map, Value, json};

use super::super::terminal_talk::{self, roster, send};
use super::agent_wait_tool::{Progress, Ticker};
use super::{Backend, envelope, failure_result, success, tool_error, v2_tools};

pub(super) const LIST: &str = "agents_terminal_list";
pub(super) const SEND: &str = "agents_terminal_send";

/// A send's wait may hold the server this long at most (it answers one
/// call at a time).
const MAX_SEND_SECONDS: f64 = 900.0;
const DEFAULT_SEND_SECONDS: f64 = 300.0;

const LIST_DESCRIPTION: &str = "The terminals in cmux that run a coding agent (Claude Code, \
    Codex, or any program that reports OSC 7501 status), as `cmux terminal list --agents`: \
    {items: [{terminal, harness, state, title, workspace_id, workspace, cwd, updated_at_ms, \
    age_ms, source}]}. state is busy, idle, waiting-for-input (a permission dialog or a \
    question waits) or ended. Waiting first, then busy, idle, ended; newest first. A shell \
    without an agent is not listed. Changes nothing.";

const SEND_DESCRIPTION: &str = "Send a message to the agent (or shell) in a cmux terminal and \
    get its answer, as `cmux terminal <t> send`: types text as one bracketed paste (a \
    multi-line message stays one message), presses Enter, waits, and answers {terminal, \
    harness, state, timed_out, waited_ms, anchored, output}. output is only what the terminal \
    printed after the message, less the harness's input box. wait idle (default): until no \
    fresh hook or status says working and the screen has been still for settle_seconds \
    (default 3); state is idle, or waiting-for-input when the agent stopped on a dialog. wait \
    prompt: until the shell shows its prompt. wait none: send and answer at once. A wait that \
    passes timeout_seconds (default 300, at most 900) answers timed_out true with the output \
    so far. An agent that already waits on a dialog is refused unless force is true, since \
    the text would answer the dialog. target is a term_ id (or unique prefix), a tab_ id or \
    an exact terminal title; agents_terminal_list names them. Optional idempotency_key \
    identifies the complete paste-and-Enter send: a lost reply reports its \
    phase and the same key for a safe retry.";

pub(super) fn descriptors() -> [Value; 2] {
    [
        json!({
            "name": LIST,
            "title": "Terminal agents",
            "description": LIST_DESCRIPTION,
            "inputSchema": {
                "type": "object",
                "properties": {"session": session_schema()},
                "additionalProperties": false,
            },
            "annotations": {"readOnlyHint": true, "destructiveHint": false,
                            "idempotentHint": true, "openWorldHint": false},
        }),
        json!({
            "name": SEND,
            "title": "Send to a terminal agent",
            "description": SEND_DESCRIPTION,
            "inputSchema": send_schema(),
            "annotations": {"readOnlyHint": false, "destructiveHint": false,
                            "idempotentHint": false, "openWorldHint": false},
        }),
    ]
}

fn session_schema() -> Value {
    json!({"type": "string", "minLength": 1,
           "description": "The named cmux session to use, as `cmux --session`."})
}

fn send_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "target": {"type": "string", "minLength": 1,
                       "description": "A term_ id or unique prefix, a tab_ id, or an exact title."},
            "text": {"type": "string", "minLength": 1, "description": "The message."},
            "wait": {"type": "string", "enum": ["idle", "prompt", "none"], "default": "idle"},
            "timeout_seconds": {"type": "number", "minimum": 0, "maximum": MAX_SEND_SECONDS,
                                "default": DEFAULT_SEND_SECONDS},
            "settle_seconds": {"type": "number", "minimum": 0.2, "maximum": 60, "default": 3},
            "force": {"type": "boolean", "default": false,
                      "description": "Type even when the agent waits on a dialog."},
            "idempotency_key": {"type": "string", "minLength": 1, "maxLength": 128,
                      "description": "Stable send identity for retries; reuse after an uncertain result."},
            "session": session_schema(),
        },
        "required": ["target", "text"],
        "additionalProperties": false,
    })
}

fn not_run(message: String) -> Value {
    tool_error(envelope(v2_tools::invalid(message), "not_run", None))
}

fn seconds(
    arguments: &Map<String, Value>,
    name: &str,
    max: f64,
) -> Result<Option<Duration>, String> {
    match arguments.get(name) {
        None => Ok(None),
        Some(value) => match value.as_f64() {
            Some(seconds) if (0.0..=max).contains(&seconds) => {
                Ok(Some(Duration::from_secs_f64(seconds)))
            }
            _ => Err(format!("{SEND}: {name} must be a number from 0 to {max}")),
        },
    }
}

fn string(arguments: &Map<String, Value>, name: &str) -> Result<Option<String>, String> {
    match arguments.get(name) {
        None => Ok(None),
        Some(Value::String(value)) if !value.is_empty() => Ok(Some(value.clone())),
        Some(_) => Err(format!("{name} must be a nonempty string")),
    }
}

/// The send these arguments ask for, and its session.
pub(super) fn send_request(
    arguments: &Map<String, Value>,
) -> Result<(send::SendRequest, Option<String>), String> {
    let schema = send_schema();
    if let Some(name) = arguments.keys().find(|name| schema["properties"].get(*name).is_none()) {
        return Err(format!("{SEND} has no argument {name:?}"));
    }
    let target =
        string(arguments, "target")?.ok_or_else(|| format!("{SEND}: target is required"))?;
    let text = string(arguments, "text")?.ok_or_else(|| format!("{SEND}: text is required"))?;
    let mut request = send::SendRequest::new(target, text);
    request.timeout = Duration::from_secs_f64(DEFAULT_SEND_SECONDS);
    if let Some(key) = string(arguments, "idempotency_key")? {
        cmux_tui_core::resource::validate_idempotency_key(&key)
            .map_err(|error| format!("{SEND}: {}", error.message))?;
        request.idempotency_key = Some(key);
    }
    if let Some(wait) = string(arguments, "wait")? {
        request.wait = send::Wait::parse(&wait)
            .ok_or_else(|| format!("{SEND}: wait is idle, prompt or none, not {wait:?}"))?;
    }
    if let Some(timeout) = seconds(arguments, "timeout_seconds", MAX_SEND_SECONDS)? {
        request.timeout = timeout;
    }
    if let Some(settle) = seconds(arguments, "settle_seconds", 60.0)? {
        request.settle = settle.max(Duration::from_millis(200));
    }
    match arguments.get("force") {
        None => {}
        Some(Value::Bool(force)) => request.force = *force,
        Some(_) => return Err(format!("{SEND}: force must be true or false")),
    }
    Ok((request, string(arguments, "session")?))
}

pub(super) fn call_list<B: Backend>(backend: &B, arguments: &Map<String, Value>) -> Value {
    if let Some(name) = arguments.keys().find(|name| name.as_str() != "session") {
        return not_run(format!("{LIST} has no argument {name:?}"));
    }
    let session = match string(arguments, "session") {
        Ok(session) => session,
        Err(message) => return not_run(message),
    };
    match send::snapshot(backend, session.as_deref()) {
        Ok(snapshot) => {
            let now = terminal_talk::now_ms();
            let rows = roster::agent_rows(&snapshot);
            success(
                json!({"items": rows.iter().map(|row| row.to_json(now)).collect::<Vec<_>>()}),
                false,
            )
        }
        Err(failure) => failure_result(failure),
    }
}

pub(super) fn call_send<B: Backend>(
    backend: &B,
    arguments: &Map<String, Value>,
    progress: Option<Progress>,
) -> Value {
    let (request, session) = match send_request(arguments) {
        Ok(call) => call,
        Err(message) => return not_run(message),
    };
    let ticker = Ticker::start(progress, request.timeout);
    let outcome = send::run(backend, session.as_deref(), &request);
    drop(ticker);
    match outcome {
        Ok(receipt) => success(receipt, true),
        Err(failure) if failure.exit == 2 => {
            not_run(failure.failure.error["message"].as_str().unwrap_or_default().to_owned())
        }
        Err(failure) => failure_result(failure.failure),
    }
}

#[cfg(test)]
mod tests {
    use serde_json::{Map, Value, json};

    use super::super::super::terminal_talk::send::Wait;
    use super::{LIST, SEND, descriptors, send_request};

    fn arguments(value: Value) -> Map<String, Value> {
        value.as_object().cloned().expect("an object")
    }

    #[test]
    fn descriptors_name_both_tools_and_send_requires_target_and_text() {
        let [list, send] = descriptors();
        assert_eq!((list["name"].as_str(), send["name"].as_str()), (Some(LIST), Some(SEND)));
        assert_eq!(send["inputSchema"]["required"], json!(["target", "text"]));
        assert_eq!(list["annotations"]["readOnlyHint"], true);
        assert_eq!(send["annotations"]["readOnlyHint"], false);
        assert_eq!(
            send["inputSchema"]["properties"]["idempotency_key"]["maxLength"],
            128,
            "a composed send needs a stable retry identity: {send}"
        );
    }

    #[test]
    fn send_arguments_become_the_cli_request() {
        let (request, session) = send_request(&arguments(json!({
            "target": "term_a", "text": "hi\nthere", "wait": "prompt",
            "timeout_seconds": 20, "settle_seconds": 0.5, "force": true, "session": "work",
            "idempotency_key": "repeatable-send",
        })))
        .expect("valid");
        assert_eq!(request.target, "term_a");
        assert_eq!(request.text, "hi\nthere");
        assert_eq!(request.wait, Wait::Prompt);
        assert_eq!(request.timeout.as_secs(), 20);
        assert_eq!(request.settle.as_millis(), 500);
        assert!(request.force);
        assert_eq!(request.idempotency_key.as_deref(), Some("repeatable-send"));
        assert_eq!(session.as_deref(), Some("work"));
        let (defaults, _) =
            send_request(&arguments(json!({"target": "t", "text": "x"}))).expect("valid");
        assert_eq!((defaults.wait, defaults.timeout.as_secs()), (Wait::Idle, 300));
    }

    #[test]
    fn send_arguments_refuse_unknown_names_and_bad_values() {
        for bad in [
            json!({"target": "t"}),
            json!({"target": "t", "text": "x", "colour": "red"}),
            json!({"target": "t", "text": "x", "wait": "later"}),
            json!({"target": "t", "text": "x", "timeout_seconds": 5000}),
            json!({"target": "t", "text": "x", "force": "yes"}),
            json!({"target": "t", "text": "x", "idempotency_key": ""}),
            json!({"target": "t", "text": "x", "idempotency_key": "x".repeat(129)}),
        ] {
            assert!(send_request(&arguments(bad.clone())).is_err(), "{bad}");
        }
    }
}
