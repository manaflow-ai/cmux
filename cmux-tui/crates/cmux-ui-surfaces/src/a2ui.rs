//! A2UI 1.0 wire messages (a2ui specification/v1_0, `agent_to_renderer.json`
//! and `renderer_to_agent.json`). Every message is `{"version":"1.0"}` plus
//! exactly one message key. Parsing is strict; the store turns a refused
//! message into an error, never a panic.

use crate::Refusal;
use serde_json::{Map, Value};

pub const VERSION: &str = "1.0";
pub const MIME: &str = "application/a2ui+json";

#[derive(Clone, Debug, PartialEq)]
pub enum Message {
    CreateSurface {
        surface_id: String,
        catalog_id: Option<String>,
        send_data_model: bool,
        components: Vec<Value>,
        data_model: Option<Value>,
    },
    UpdateComponents {
        surface_id: String,
        components: Vec<Value>,
    },
    UpdateDataModel {
        surface_id: String,
        path: Option<String>,
        value: Value,
    },
    DeleteSurface {
        surface_id: String,
    },
    CallRendererFunction {
        surface_id: Option<String>,
        function_call_id: String,
        /// `{@call, catalogId, args?}`
        call: Map<String, Value>,
    },
    AgentFunctionResponse(Value),
}

impl Message {
    pub fn surface_id(&self) -> Option<&str> {
        match self {
            Self::CreateSurface { surface_id, .. }
            | Self::UpdateComponents { surface_id, .. }
            | Self::UpdateDataModel { surface_id, .. }
            | Self::DeleteSurface { surface_id } => Some(surface_id),
            Self::CallRendererFunction { surface_id, .. } => surface_id.as_deref(),
            Self::AgentFunctionResponse(_) => None,
        }
    }
}

fn envelope<'a>(v: &'a Value, keys: &[&str]) -> Result<(&'a str, &'a Map<String, Value>), Refusal> {
    let obj = v.as_object().ok_or_else(|| Refusal::new("an A2UI message must be a JSON object"))?;
    match obj.get("version").and_then(Value::as_str) {
        Some(VERSION) => {}
        Some(other) => {
            return Err(Refusal::new(format!("unsupported A2UI version {other:?} (only 1.0)")));
        }
        None => return Err(Refusal::new("an A2UI message needs \"version\": \"1.0\"")),
    }
    let mut found = obj.keys().filter(|k| k.as_str() != "version");
    let (Some(key), None) = (found.next(), found.next()) else {
        return Err(Refusal::new("an A2UI message has exactly one message key besides version"));
    };
    if !keys.contains(&key.as_str()) {
        return Err(Refusal::new(format!("unknown A2UI message {key:?}")));
    }
    let body = obj[key.as_str()]
        .as_object()
        .ok_or_else(|| Refusal::new(format!("{key} must be an object")))?;
    Ok((key.as_str(), body))
}

fn req_str(body: &Map<String, Value>, key: &str, msg: &str) -> Result<String, Refusal> {
    match body.get(key).and_then(Value::as_str) {
        Some(s) if !s.is_empty() => Ok(s.to_string()),
        _ => Err(Refusal::new(format!("{msg} needs a non-empty string {key:?}"))),
    }
}

fn components(body: &Map<String, Value>, msg: &str, required: bool) -> Result<Vec<Value>, Refusal> {
    match body.get("components") {
        None if !required => Ok(Vec::new()),
        Some(Value::Array(items)) if !(required && items.is_empty()) => Ok(items.clone()),
        _ => Err(Refusal::new(format!("{msg} needs a non-empty \"components\" array"))),
    }
}

/// A value an argument may hold: a literal, `{"@path"}` or `{"@call"}`.
/// A plain nested object is not a dynamic value.
fn dynamic_arg_ok(v: &Value) -> bool {
    match v {
        Value::Object(m) => m.contains_key("@path") || m.contains_key("@call"),
        Value::Array(items) => items.iter().all(dynamic_arg_ok),
        _ => true,
    }
}

pub fn parse_message(v: &Value) -> Result<Message, Refusal> {
    let (key, body) = envelope(
        v,
        &[
            "createSurface",
            "updateComponents",
            "updateDataModel",
            "deleteSurface",
            "callRendererFunction",
            "agentFunctionResponse",
        ],
    )?;
    Ok(match key {
        "createSurface" => Message::CreateSurface {
            surface_id: req_str(body, "surfaceId", key)?,
            catalog_id: body.get("catalogId").and_then(Value::as_str).map(str::to_string),
            send_data_model: body.get("sendDataModel").and_then(Value::as_bool).unwrap_or(false),
            components: components(body, key, false)?,
            data_model: match body.get("dataModel") {
                None => None,
                Some(v @ Value::Object(_)) => Some(v.clone()),
                Some(_) => return Err(Refusal::new("createSurface dataModel must be an object")),
            },
        },
        "updateComponents" => Message::UpdateComponents {
            surface_id: req_str(body, "surfaceId", key)?,
            components: components(body, key, true)?,
        },
        "updateDataModel" => Message::UpdateDataModel {
            surface_id: req_str(body, "surfaceId", key)?,
            path: body.get("path").and_then(Value::as_str).map(str::to_string),
            // `value` absent is the same as null (delete) in practice; the
            // samples omit path but always send value.
            value: body.get("value").cloned().unwrap_or(Value::Null),
        },
        "deleteSurface" => Message::DeleteSurface { surface_id: req_str(body, "surfaceId", key)? },
        "callRendererFunction" => {
            let function_call_id = req_str(body, "functionCallId", key)?;
            let call = body
                .get("callFunction")
                .and_then(Value::as_object)
                .ok_or_else(|| Refusal::new("callRendererFunction needs callFunction"))?;
            req_str(call, "@call", "callFunction")?;
            req_str(call, "catalogId", "callFunction")?;
            if let Some(args) = call.get("args") {
                let ok = args.as_object().is_some_and(|m| m.values().all(dynamic_arg_ok));
                if !ok {
                    return Err(Refusal::new(
                        "callFunction args must be literals, @path or @call values",
                    ));
                }
            }
            Message::CallRendererFunction {
                surface_id: body.get("surfaceId").and_then(Value::as_str).map(str::to_string),
                function_call_id,
                call: call.clone(),
            }
        }
        _ => Message::AgentFunctionResponse(Value::Object(body.clone())),
    })
}

/// Validate a renderer-to-agent message (what this host sends back): `action`,
/// `callAgentFunction`, `rendererFunctionResponse` or `error`.
pub fn validate_client_message(v: &Value) -> Result<(), Refusal> {
    let (key, body) =
        envelope(v, &["action", "callAgentFunction", "rendererFunctionResponse", "error"])?;
    match key {
        "action" => {
            for k in ["name", "surfaceId", "sourceComponentId", "timestamp"] {
                req_str(body, k, key)?;
            }
            if !body.get("context").is_some_and(Value::is_object) {
                return Err(Refusal::new("action needs a context object"));
            }
        }
        "callAgentFunction" => {
            req_str(body, "surfaceId", key)?;
            req_str(body, "functionCallId", key)?;
            let call = body
                .get("callFunction")
                .and_then(Value::as_object)
                .ok_or_else(|| Refusal::new("callAgentFunction needs callFunction"))?;
            req_str(call, "@call", "callFunction")?;
        }
        "rendererFunctionResponse" => {
            req_str(body, "functionCallId", key)?;
            if body.contains_key("value") == body.contains_key("error") {
                return Err(Refusal::new(
                    "rendererFunctionResponse has exactly one of value and error",
                ));
            }
        }
        _ => {
            req_str(body, "code", key)?;
            req_str(body, "message", key)?;
        }
    }
    Ok(())
}

/// Messages from a JSON value: one message, an array of them, or an object
/// with a `messages` array (the sample file shape).
pub fn parse_value(input: &Value) -> Vec<Result<Message, Refusal>> {
    match input {
        Value::Array(items) => items.iter().map(parse_message).collect(),
        Value::Object(m) if m.get("messages").is_some_and(Value::is_array) => {
            parse_value(&m["messages"])
        }
        other => vec![parse_message(other)],
    }
}

/// Messages from JSONL. With `complete == false` (input still streaming) a
/// last line that does not parse yet is skipped, not refused.
pub fn parse_jsonl(text: &str, complete: bool) -> Vec<Result<Message, Refusal>> {
    let lines: Vec<&str> = text.lines().filter(|l| !l.trim().is_empty()).collect();
    let mut out = Vec::with_capacity(lines.len());
    for (i, line) in lines.iter().enumerate() {
        match serde_json::from_str::<Value>(line) {
            Ok(v) => out.push(parse_message(&v)),
            Err(_) if !complete && i + 1 == lines.len() => {}
            Err(e) => out.push(Err(Refusal::new(format!("line {} is not JSON: {e}", i + 1)))),
        }
    }
    out
}
