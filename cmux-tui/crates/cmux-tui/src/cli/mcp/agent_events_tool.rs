//! `agents_events`: `cmux agents events` as a tool. A call builds the words
//! the CLI takes and runs the CLI's parser and `agents::execute`, so both
//! read the same events (`cli/agents/events.rs`) and answer the same shape.

use serde_json::{Map, Value, json};

use super::super::agents::{self, AgentFailure};
use super::{Backend, envelope, failure_result, success, tool_error, v2_tools};
use crate::cli::json_fields::JsonFields;

pub(super) const NAME: &str = "agents_events";

const DESCRIPTION: &str = "Long-poll what changes in cmux instead of polling agents_snapshot \
    (`cmux agents events`): dialogs (a permission or question dialog opened or closed), \
    notifications (created, read, cleared), tabs and workspaces (changed or closed) and agents \
    (a terminal agent's or agent chat's state). Answers {events: [{seq, kind, at, change, id, \
    ...}], next_after, timed_out}. Without after it starts from now and returns nothing old; \
    pass next_after as after on the next call to continue with no gaps or duplicates. It \
    answers at once when events newer than after exist, else waits up to timeout_seconds \
    (default 30, at most 60) for the first one; an empty answer is timed_out true, not an \
    error. The server answers one call at a time, so a wait holds this connection's other \
    calls. Tab, workspace, notification and terminal agent events come from the daemon's \
    journal; dialogs and agent chat states are read from the app every second, so one \
    that opens and resolves between two reads is missed, and their baseline is the first \
    app read that answers. A kind reset says the daemon restarted, the cursor expired or \
    grew too large: read agents_snapshot again. \
    Events carry ids, states and short titles only (no terminal text, chat text or tool \
    input); notification text is cut (truncated true). Changes nothing.";

pub(super) fn descriptor() -> Value {
    json!({
        "name": NAME,
        "title": "Agent events",
        "description": DESCRIPTION,
        "inputSchema": input_schema(),
        "annotations": {
            "readOnlyHint": true,
            "destructiveHint": false,
            "idempotentHint": true,
            "openWorldHint": false,
        },
    })
}

fn input_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "after": {
                "type": "string",
                "minLength": 1,
                "description": "next_after from a previous call; omit to start from now.",
            },
            "kinds": {
                "type": "array",
                "items": {"type": "string", "enum": agents::EVENT_KINDS},
                "minItems": 1,
                "uniqueItems": true,
                "description": "Only these kinds (default all).",
            },
            "timeout_seconds": {
                "type": "number",
                "minimum": 0,
                "maximum": agents::MAX_EVENTS_SECONDS,
                "default": agents::DEFAULT_EVENTS_SECONDS,
            },
            "limit": {
                "type": "integer",
                "minimum": 1,
                "maximum": agents::MAX_EVENTS_LIMIT,
                "default": agents::DEFAULT_EVENTS_LIMIT,
            },
            "session": {
                "type": "string",
                "minLength": 1,
                "description": "The named cmux session to use, as `cmux --session`.",
            },
        },
        "additionalProperties": false,
    })
}

pub(super) fn call<B: Backend>(backend: &B, arguments: &Map<String, Value>) -> Value {
    let not_run =
        |message: String| tool_error(envelope(v2_tools::invalid(message), "not_run", None));
    let (words, session) = match words(arguments) {
        Ok(call) => call,
        Err(message) => return not_run(message),
    };
    let command = match agents::command(&words) {
        Ok(command) => command,
        Err(error) => return not_run(error.0),
    };
    match agents::execute(backend, session.as_deref(), &command, None, "mcp") {
        Ok(answer) => success(answer, false),
        Err(AgentFailure::Usage(message)) => not_run(message),
        Err(AgentFailure::Owner(failure)) => failure_result(failure),
    }
}

/// The `cmux agents events` words these arguments name, and the session.
fn words(arguments: &Map<String, Value>) -> Result<(Vec<String>, Option<String>), String> {
    let schema = input_schema();
    if let Some(name) =
        arguments.keys().find(|name| schema.field("properties").get(*name).is_none())
    {
        return Err(format!("{NAME} has no argument {name:?}"));
    }
    let text = |name: &str| match arguments.get(name) {
        None => Ok(None),
        Some(Value::String(value)) if !value.is_empty() => Ok(Some(value.clone())),
        Some(_) => Err(format!("{NAME}: {name} must be a nonempty string")),
    };
    let mut words = vec!["events".to_owned()];
    if let Some(after) = text("after")? {
        // Inline, so a value is never read as a flag.
        words.push(format!("--after={after}"));
    }
    match arguments.get("kinds") {
        None => {}
        Some(Value::Array(kinds)) if !kinds.is_empty() => {
            for kind in kinds {
                let kind = kind
                    .as_str()
                    .filter(|kind| !kind.is_empty() && !kind.contains(','))
                    .ok_or_else(|| format!("{NAME}: kinds holds kind names"))?;
                words.push(format!("--kind={kind}"));
            }
        }
        Some(_) => return Err(format!("{NAME}: kinds must be a nonempty array")),
    }
    match arguments.get("timeout_seconds") {
        None => {}
        Some(Value::Number(seconds)) => {
            let seconds = seconds.as_f64().unwrap_or(f64::NAN);
            words.push(format!("--timeout={seconds}"));
        }
        Some(_) => return Err(format!("{NAME}: timeout_seconds must be a number")),
    }
    match arguments.get("limit") {
        None => {}
        Some(Value::Number(limit)) if limit.is_u64() => words.push(format!("--limit={limit}")),
        Some(_) => return Err(format!("{NAME}: limit must be a positive integer")),
    }
    Ok((words, text("session")?))
}
