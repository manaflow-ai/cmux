//! Native code-mode workflow lifecycle tool.
//!
//! This is a thin MCP adapter over acpmux's daemon-owned run service.  It does
//! not execute JavaScript or dispatch activities itself: the daemon pins the
//! source, owns the journal and starts the verified runner.  Keeping the
//! lifecycle here means `cmux_workflow` is subject to the normal MCP catalog,
//! allowlist and Server::call gates just like every other tool.

use std::time::Duration;

use serde_json::{Map, Value, json};

use super::{Backend, envelope, failure_result, success, tool_error, v2_tools};

pub(super) const NAME: &str = "cmux_workflow";
const METHOD: &str = "_acpmux/workflow";
const MAX_NAME_BYTES: usize = 256;
const MAX_RUN_ID_BYTES: usize = 256;

pub(super) fn descriptor() -> Value {
    json!({
        "name": NAME,
        "title": "Run a native workflow",
        "description": "Start and control a daemon-owned cmux NEXT code-mode workflow. A start pins the supplied JavaScript source and arguments for durable journal replay; status, pause and resume operate on that run. Workflow activities still pass through the normal Server::call catalog and permission gates.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "action": {"type": "string", "enum": ["start", "status", "pause", "resume"]},
                "name": {"type": "string", "minLength": 1, "maxLength": MAX_NAME_BYTES},
                "source": {"type": "string", "minLength": 1},
                "args": {"description": "JSON arguments made available as the workflow's global `args`."},
                "run_id": {"type": "string", "minLength": 1, "maxLength": MAX_RUN_ID_BYTES, "pattern": "^[^-]"},
                "session_id": {"type": "string", "minLength": 1, "maxLength": MAX_RUN_ID_BYTES},
                "idempotency_key": {"type": "string", "minLength": 1, "maxLength": 128},
            },
            "required": ["action"],
            "additionalProperties": false,
        },
        "annotations": {
            "readOnlyHint": false,
            "destructiveHint": false,
            "idempotentHint": false,
            "openWorldHint": false,
        },
    })
}

pub(super) fn call<B: Backend>(backend: &B, arguments: &Map<String, Value>) -> Value {
    let request = match request(arguments) {
        Ok(request) => request,
        Err(message) => {
            return tool_error(envelope(v2_tools::invalid(message), "not_run", None));
        }
    };
    let Some(action) = request.get("action").and_then(Value::as_str) else {
        return tool_error(envelope(
            v2_tools::invalid("workflow action is required"),
            "not_run",
            None,
        ));
    };
    let mutation = action != "status";
    let key = arguments.get("idempotency_key").and_then(Value::as_str);
    match backend.acpmux(METHOD, Value::Object(request), Duration::from_secs(60), key, mutation) {
        Ok(value) => success(value, mutation),
        Err(failure) => failure_result(failure),
    }
}

fn request(arguments: &Map<String, Value>) -> Result<Map<String, Value>, String> {
    const ALLOWED: &[&str] =
        &["action", "name", "source", "args", "run_id", "session_id", "idempotency_key"];
    if let Some(name) = arguments.keys().find(|name| !ALLOWED.contains(&name.as_str())) {
        return Err(format!("{NAME} has no argument {name:?}"));
    }
    let action = text(arguments, "action")?.ok_or_else(|| format!("{NAME}: action is required"))?;
    if !matches!(action.as_str(), "start" | "status" | "pause" | "resume") {
        return Err(format!("{NAME}: action must be start, status, pause or resume"));
    }
    let mut output = Map::new();
    output.insert("action".into(), Value::String(action.clone()));
    match action.as_str() {
        "start" => {
            let name = text(arguments, "name")?
                .ok_or_else(|| format!("{NAME}: name is required for start"))?;
            let source = text(arguments, "source")?
                .ok_or_else(|| format!("{NAME}: source is required for start"))?;
            output.insert("name".into(), Value::String(name));
            output.insert("source".into(), Value::String(source));
            if let Some(args) = arguments.get("args") {
                output.insert("args".into(), args.clone());
            } else {
                output.insert("args".into(), json!([]));
            }
            if let Some(session) = text(arguments, "session_id")? {
                output.insert("sessionId".into(), Value::String(session));
            } else if let Ok(session) = std::env::var("CMUX_AGENT_SESSION")
                && !session.is_empty()
            {
                output.insert("sessionId".into(), json!(session));
            }
            output.insert(
                "cwd".into(),
                json!(std::env::current_dir().map_err(|error| error.to_string())?),
            );
        }
        "status" => {
            if let Some(run_id) = text(arguments, "run_id")? {
                output.insert("runId".into(), Value::String(run_id));
            }
        }
        "pause" | "resume" => {
            let run_id = text(arguments, "run_id")?
                .ok_or_else(|| format!("{NAME}: run_id is required for {action}"))?;
            output.insert("runId".into(), Value::String(run_id));
        }
        _ => return Err(format!("{NAME}: unsupported action {action:?}")),
    }
    // Idempotency keys are consumed by the transport/daemon; don't pass the
    // snake-case MCP spelling into the daemon request body.
    Ok(output)
}

fn text(arguments: &Map<String, Value>, name: &str) -> Result<Option<String>, String> {
    match arguments.get(name) {
        None => Ok(None),
        Some(Value::String(value)) if !value.trim().is_empty() => {
            let max = match name {
                "name" => MAX_NAME_BYTES,
                "run_id" | "session_id" => MAX_RUN_ID_BYTES,
                "action" => 16,
                _ => MAX_RUN_ID_BYTES,
            };
            if name != "source" && value.len() > max {
                Err(format!("{NAME}: {name} exceeds {max} bytes"))
            } else {
                Ok(Some(value.clone()))
            }
        }
        Some(Value::String(_)) => Err(format!("{NAME}: {name} must be nonempty")),
        Some(_) => Err(format!("{NAME}: {name} must be a string")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn descriptor_requires_only_action_and_rejects_extra_fields() {
        let schema = descriptor()["inputSchema"].clone();
        assert_eq!(schema["required"], json!(["action"]));
        assert_eq!(schema["additionalProperties"], false);
        let mut args = Map::new();
        args.insert("action".into(), json!("status"));
        args.insert("extra".into(), json!(true));
        assert!(request(&args).is_err());
    }

    #[test]
    fn start_pins_source_and_defaults_args_without_accepting_file_paths() {
        let mut args = Map::new();
        args.insert("action".into(), json!("start"));
        args.insert("name".into(), json!("nightly"));
        args.insert("source".into(), json!("return await pipeline([], async x => x);"));
        let request = request(&args).unwrap();
        assert_eq!(request["args"], json!([]));
        assert!(request.get("file").is_none());
    }

    #[test]
    fn pause_and_resume_require_a_run_id() {
        for action in ["pause", "resume"] {
            let mut args = Map::new();
            args.insert("action".into(), json!(action));
            assert!(request(&args).is_err());
        }
    }
}
