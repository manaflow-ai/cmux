//! Harness-agnostic agent dispatch tools.
//!
//! These are deliberately a thin MCP adapter over acpmux's dispatch surface.
//! The caller supplies a brief's text and a target; acpmux owns peer routing,
//! host placement, persistence, and sender attribution. No shell command,
//! remote binary path, or temporary file is exposed to an MCP client.

use std::time::Duration;

use serde_json::{Map, Value, json};

use super::{
    Backend, CallFailure, FailureKind, envelope, failure_result, success, tool_error, v2_tools,
};

pub(super) const DISPATCH: &str = "agent_dispatch";
pub(super) const STEER: &str = "agent_steer";
pub(super) const BRIEFS_LIST: &str = "agent_briefs_list";
pub(super) const REPORT: &str = "agent_report";

const DISPATCH_METHOD: &str = "_acpmux/dispatch";
const STEER_METHOD: &str = "_acpmux/steer";
const BRIEFS_LIST_METHOD: &str = "_acpmux/briefs";
const REPORT_METHOD: &str = "_acpmux/report";
const MAX_BRIEF_BYTES: usize = 128 * 1024;
const MAX_TITLE_BYTES: usize = 512;
const MAX_TEXT_BYTES: usize = 128 * 1024;
const DEFAULT_LIST_LIMIT: u64 = 50;
const MAX_LIST_LIMIT: u64 = 200;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Kind {
    Dispatch,
    Steer,
    BriefsList,
    Report,
}

pub(super) struct Tool {
    pub name: &'static str,
    kind: Kind,
    title: &'static str,
    description: &'static str,
}

const TOOLS: &[Tool] = &[
    Tool {
        name: DISPATCH,
        kind: Kind::Dispatch,
        title: "Dispatch agent brief",
        description: "Send a persisted brief to another agent through acpmux. The target is a host, or `auto` for the least-loaded connected host allowed by fleet placement. Dispatch works across Claude, Codex, OpenCode, Pi, and other harnesses; acpmux records sender attribution and the stop condition. Returns a brief record with briefId, title, from, to, target, host, stopCondition, status and optional sessionId. Load caps are warnings, never a reason to refuse a launch.",
    },
    Tool {
        name: STEER,
        kind: Kind::Steer,
        title: "Steer dispatched brief",
        description: "Send a follow-up to a dispatched brief through acpmux. The brief id keeps the message attributed to its original dispatch and returns the same brief record (briefId, title, from, to, target, host, stopCondition, status, sessionId).",
    },
    Tool {
        name: BRIEFS_LIST,
        kind: Kind::BriefsList,
        title: "List agent briefs",
        description: "List persisted agent briefs and their states (running, reported, or merged), including the linked session and host. Each item is a brief record with briefId, title, from, to, target, host, stopCondition, status and optional sessionId.",
    },
    Tool {
        name: REPORT,
        kind: Kind::Report,
        title: "Report dispatched work",
        description: "Attach an attributed report to a dispatched brief. The report remains linked to its brief for the transcript and brief list, and returns the updated brief record (briefId, title, from, to, target, host, stopCondition, status, sessionId).",
    },
];

pub(super) fn descriptors() -> Vec<Value> {
    TOOLS.iter().map(Tool::descriptor_json).collect()
}

pub(super) fn find(name: &str) -> Option<&'static Tool> {
    TOOLS.iter().find(|tool| tool.name == name)
}

impl Tool {
    fn mutation(&self) -> bool {
        !matches!(self.kind, Kind::BriefsList)
    }

    fn method(&self) -> &'static str {
        match self.kind {
            Kind::Dispatch => DISPATCH_METHOD,
            Kind::Steer => STEER_METHOD,
            Kind::BriefsList => BRIEFS_LIST_METHOD,
            Kind::Report => REPORT_METHOD,
        }
    }

    fn descriptor_json(&self) -> Value {
        json!({
            "name": self.name,
            "title": self.title,
            "description": self.description,
            "inputSchema": self.input_schema(),
            "annotations": {
                "readOnlyHint": !self.mutation(),
                "destructiveHint": false,
                "idempotentHint": !matches!(self.kind, Kind::Dispatch | Kind::Steer),
                "openWorldHint": false,
            },
        })
    }

    fn input_schema(&self) -> Value {
        let mut properties = Map::new();
        let mut required = Vec::new();
        match self.kind {
            Kind::Dispatch => {
                properties.insert(
                    "brief_id".into(),
                    id_schema("Optional stable id for retrying the same dispatch."),
                );
                properties.insert(
                    "title".into(),
                    json!({
                        "type": "string", "minLength": 1, "maxLength": MAX_TITLE_BYTES,
                        "description": "A short human-readable title for the brief.",
                    }),
                );
                properties.insert("brief".into(), json!({
                    "type": "string", "minLength": 1, "maxLength": MAX_BRIEF_BYTES,
                    "description": "The complete brief text. It is shipped over acpmux; do not use a remote path or shell command.",
                }));
                properties.insert("target".into(), json!({
                    "type": "string", "minLength": 1,
                    "description": "Host target; `auto` selects the least-loaded connected host allowed by fleet placement (load caps only warn).",
                }));
                properties.insert("host".into(), json!({
                    "type": "string", "minLength": 1,
                    "description": "Optional explicit host. Fleet placement rejects disallowed hosts; load caps only produce a warning.",
                }));
                properties.insert(
                    "stop_condition".into(),
                    json!({
                        "type": "string", "minLength": 1, "maxLength": MAX_TITLE_BYTES,
                        "description": "The condition that ends the dispatched work.",
                    }),
                );
                properties.insert("harness".into(), json!({
                    "type": "string", "minLength": 1,
                    "description": "Optional harness name (claude, codex, opencode, pi, or another registered harness).",
                }));
                properties.insert(
                    "model".into(),
                    json!({
                        "type": "string", "minLength": 1,
                        "description": "Optional model name understood by the target harness.",
                    }),
                );
                properties.insert(
                    "preset".into(),
                    json!({
                        "type": "string", "minLength": 1,
                        "description": "Optional approved session preset.",
                    }),
                );
                properties.insert("policy".into(), json!({
                    "type": "string", "minLength": 1,
                    "description": "Optional approved permission policy, such as approve-all when the person's preset permits it.",
                }));
                properties.insert("idempotency_key".into(), idempotency_schema());
                required.extend(["title", "brief", "target"]);
            }
            Kind::Steer => {
                properties.insert(
                    "brief_id".into(),
                    id_schema("The brief id returned by agent_dispatch."),
                );
                properties.insert(
                    "text".into(),
                    json!({
                        "type": "string", "minLength": 1, "maxLength": MAX_TEXT_BYTES,
                        "description": "The follow-up message.",
                    }),
                );
                properties.insert("idempotency_key".into(), idempotency_schema());
                required.extend(["brief_id", "text"]);
            }
            Kind::BriefsList => {
                properties.insert(
                    "status".into(),
                    json!({
                        "type": "string", "enum": ["running", "reported", "merged"],
                        "description": "Filter by brief state.",
                    }),
                );
                properties.insert(
                    "limit".into(),
                    json!({
                        "type": "integer", "minimum": 1, "maximum": MAX_LIST_LIMIT,
                        "default": DEFAULT_LIST_LIMIT,
                    }),
                );
            }
            Kind::Report => {
                properties.insert(
                    "brief_id".into(),
                    id_schema("The brief id returned by agent_dispatch."),
                );
                properties.insert(
                    "summary".into(),
                    json!({
                        "type": "string", "minLength": 1, "maxLength": MAX_TEXT_BYTES,
                        "description": "The attributed report text.",
                    }),
                );
                properties.insert(
                    "status".into(),
                    json!({"type": "string", "enum": ["running", "reported", "merged"], "description": "Resulting brief state (default: reported)."}),
                );
                properties.insert(
                    "details".into(),
                    json!({
                        "type": "string", "maxLength": MAX_TEXT_BYTES,
                        "description": "Optional additional report details.",
                    }),
                );
                properties.insert("idempotency_key".into(), idempotency_schema());
                required.extend(["brief_id", "summary"]);
            }
        }
        json!({"type": "object", "properties": properties, "required": required, "additionalProperties": false})
    }

    pub(super) fn call<B: Backend>(&self, backend: &B, arguments: &Map<String, Value>) -> Value {
        let parsed = match self.params(arguments) {
            Ok(params) => params,
            Err(message) => return invalid(message),
        };
        // Owned: `parsed` moves into the request below.
        let key = parsed
            .get("idempotencyKey")
            .and_then(Value::as_str)
            .or_else(|| arguments.get("idempotency_key").and_then(Value::as_str))
            .map(str::to_owned);
        match backend.acpmux(
            self.method(),
            parsed,
            dispatch_timeout(self.kind),
            key.as_deref(),
            self.mutation(),
        ) {
            Ok(value) => success(normalize_result(value), self.mutation()),
            Err(failure) => failure_result(failure),
        }
    }

    fn params(&self, arguments: &Map<String, Value>) -> Result<Value, String> {
        let allowed = match self.kind {
            Kind::Dispatch => &[
                "title",
                "brief",
                "target",
                "host",
                "stop_condition",
                "harness",
                "model",
                "preset",
                "policy",
                "brief_id",
                "idempotency_key",
            ][..],
            Kind::Steer => &["brief_id", "text", "idempotency_key"][..],
            Kind::BriefsList => &["status", "limit"][..],
            Kind::Report => &["brief_id", "summary", "status", "details", "idempotency_key"][..],
        };
        if let Some(name) = arguments.keys().find(|name| !allowed.contains(&name.as_str())) {
            return Err(format!("{} has no argument {name:?}", self.name));
        }
        let mut params = Map::new();
        match self.kind {
            Kind::Dispatch => {
                let title = required_text(arguments, self.name, "title", MAX_TITLE_BYTES)?;
                let brief = required_text(arguments, self.name, "brief", MAX_BRIEF_BYTES)?;
                let target = required_text(arguments, self.name, "target", MAX_TEXT_BYTES)?;
                copy_text(arguments, &mut params, "brief_id", "briefId", MAX_TEXT_BYTES)?;
                params.insert("title".into(), Value::String(title));
                params.insert("brief".into(), Value::String(brief));
                params.insert("target".into(), Value::String(target));
                copy_text(arguments, &mut params, "host", "host", MAX_TEXT_BYTES)?;
                copy_text(
                    arguments,
                    &mut params,
                    "stop_condition",
                    "stopCondition",
                    MAX_TITLE_BYTES,
                )?;
                copy_text(arguments, &mut params, "preset", "preset", MAX_TEXT_BYTES)?;
                copy_text(arguments, &mut params, "policy", "policy", MAX_TEXT_BYTES)?;
                combine_model(arguments, &mut params)?;
            }
            Kind::Steer => {
                let brief_id = required_text(arguments, self.name, "brief_id", MAX_TEXT_BYTES)?;
                let text = required_text(arguments, self.name, "text", MAX_TEXT_BYTES)?;
                params.insert("briefId".into(), Value::String(brief_id));
                params.insert("text".into(), Value::String(text));
            }
            Kind::BriefsList => {
                copy_text(arguments, &mut params, "status", "status", MAX_TEXT_BYTES)?;
                let limit = match arguments.get("limit") {
                    None => DEFAULT_LIST_LIMIT,
                    Some(Value::Number(value)) => value
                        .as_u64()
                        .filter(|n| (1..=MAX_LIST_LIMIT).contains(n))
                        .ok_or_else(|| {
                            format!(
                                "{}: limit must be an integer from 1 to {MAX_LIST_LIMIT}",
                                self.name
                            )
                        })?,
                    Some(_) => return Err(format!("{}: limit must be an integer", self.name)),
                };
                params.insert("limit".into(), json!(limit));
            }
            Kind::Report => {
                let brief_id = required_text(arguments, self.name, "brief_id", MAX_TEXT_BYTES)?;
                let summary = required_text(arguments, self.name, "summary", MAX_TEXT_BYTES)?;
                params.insert("briefId".into(), Value::String(brief_id));
                params.insert("summary".into(), Value::String(summary));
                copy_text(arguments, &mut params, "status", "status", MAX_TEXT_BYTES)?;
                copy_text(arguments, &mut params, "details", "details", MAX_TEXT_BYTES)?;
            }
        }
        if self.mutation() {
            let key = match arguments.get("idempotency_key") {
                Some(value) => value
                    .as_str()
                    .filter(|key| !key.is_empty())
                    .ok_or_else(|| {
                        format!("{}: idempotency_key must be a nonempty string", self.name)
                    })?
                    .to_owned(),
                None => super::super::wire::random_idempotency_key().map_err(|error| {
                    format!("{}: cannot create idempotency key: {}", self.name, error.0)
                })?,
            };
            params.insert("idempotencyKey".into(), Value::String(key));
        }
        Ok(Value::Object(params))
    }
}

fn id_schema(description: &str) -> Value {
    json!({"type": "string", "minLength": 1, "pattern": "^[^-]", "description": description})
}

fn idempotency_schema() -> Value {
    json!({"type": "string", "minLength": 1, "description": "Retry key for an uncertain mutation."})
}

fn required_text(
    arguments: &Map<String, Value>,
    tool: &str,
    name: &str,
    max: usize,
) -> Result<String, String> {
    match arguments.get(name) {
        Some(Value::String(value)) if !value.trim().is_empty() && value.len() <= max => {
            Ok(value.clone())
        }
        Some(Value::String(_)) => {
            Err(format!("{tool}: {name} must be nonempty and at most {max} bytes"))
        }
        Some(_) => Err(format!("{tool}: {name} must be a string")),
        None => Err(format!("{tool}: {name} is required")),
    }
}

fn copy_text(
    arguments: &Map<String, Value>,
    output: &mut Map<String, Value>,
    input: &str,
    wire: &str,
    max: usize,
) -> Result<(), String> {
    if let Some(value) = arguments.get(input) {
        let value = value
            .as_str()
            .filter(|value| !value.trim().is_empty() && value.len() <= max)
            .ok_or_else(|| {
            format!("{input} must be a nonempty string of at most {max} bytes")
        })?;
        output.insert(wire.to_owned(), Value::String(value.to_owned()));
    }
    Ok(())
}

/// acpmux's session launcher takes one harness/model selector. Keep the MCP
/// fields useful to agents while preserving the pair in that selector.
fn combine_model(
    arguments: &Map<String, Value>,
    output: &mut Map<String, Value>,
) -> Result<(), String> {
    let harness = arguments
        .get("harness")
        .map(|value| {
            value
                .as_str()
                .filter(|value| !value.trim().is_empty() && value.len() <= MAX_TEXT_BYTES)
                .ok_or_else(|| {
                    format!("harness must be a nonempty string of at most {MAX_TEXT_BYTES} bytes")
                })
        })
        .transpose()?;
    let model = arguments
        .get("model")
        .map(|value| {
            value
                .as_str()
                .filter(|value| !value.trim().is_empty() && value.len() <= MAX_TEXT_BYTES)
                .ok_or_else(|| {
                    format!("model must be a nonempty string of at most {MAX_TEXT_BYTES} bytes")
                })
        })
        .transpose()?;
    let selector = match (harness, model) {
        (Some(harness), Some(model)) => Some(format!("{harness}/{model}")),
        (Some(harness), None) => Some(harness.to_owned()),
        (None, Some(model)) => Some(model.to_owned()),
        (None, None) => None,
    };
    if let Some(selector) = selector {
        output.insert("model".into(), Value::String(selector));
    }
    Ok(())
}

/// The daemon returns `{brief, event}` so the transcript can render a card.
/// MCP callers consume the durable brief directly; keep the event alongside
/// it for clients that want to render the same compact card.
fn normalize_result(value: Value) -> Value {
    let Some(object) = value.as_object() else { return value };
    let Some(brief) = object.get("brief").and_then(Value::as_object) else { return value };
    let mut record = brief.clone();
    for (key, value) in object {
        if key != "brief" {
            record.insert(key.clone(), value.clone());
        }
    }
    Value::Object(record)
}

fn dispatch_timeout(kind: Kind) -> Duration {
    match kind {
        Kind::BriefsList => Duration::from_secs(10),
        _ => Duration::from_secs(60),
    }
}

fn invalid(message: String) -> Value {
    tool_error(envelope(v2_tools::invalid(message), "not_run", None))
}

/// Bridge to the linked acpmux daemon. Its request methods carry opaque JSON,
/// so this adapter stays compatible with every registered harness.
pub(super) fn acpmux_request(
    method: &str,
    params: Value,
    timeout: Duration,
    idempotency_key: Option<&str>,
    mutation: bool,
) -> Result<Value, CallFailure> {
    #[cfg(unix)]
    {
        enum RequestError {
            Owner(acpmux::rpc::RpcError),
            Transport { message: String, sent: bool },
        }

        crate::acp::configure_home();
        let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().map_err(
            |error| {
                CallFailure::local(FailureKind::NotRun, "acpmux.unavailable", error.to_string())
            },
        )?;
        let result = runtime.block_on(async {
            let client = acpmux::deliver::connect().await.map_err(|error| {
                RequestError::Transport { message: error.to_string(), sent: false }
            })?;
            let answer = tokio::time::timeout(timeout, client.request(method, params))
                .await
                .map_err(|_| RequestError::Transport {
                    message: format!("{method} timed out after {} seconds", timeout.as_secs()),
                    sent: true,
                })?
                .map_err(|error| {
                    if let Some(owner) = error.downcast_ref::<acpmux::client::DaemonError>() {
                        RequestError::Owner(owner.0.clone())
                    } else {
                        RequestError::Transport { message: error.to_string(), sent: true }
                    }
                })?;
            Ok::<Value, RequestError>(answer)
        });
        result.map_err(|error| match error {
            RequestError::Owner(error) => CallFailure {
                kind: FailureKind::Rejected,
                // Preserve the daemon's error object and numeric RPC code so
                // callers can distinguish invalid params, policy refusals,
                // not-found and internal failures without guessing.
                error: serde_json::to_value(error).unwrap_or_else(|_| {
                    json!({
                        "code": -32603,
                        "message": "acpmux returned an unserializable error",
                    })
                }),
                idempotency_key: idempotency_key.map(str::to_owned),
            },
            RequestError::Transport { message, sent } => CallFailure {
                kind: if sent && mutation { FailureKind::InProgress } else { FailureKind::NotRun },
                error: json!({
                    "code": "acpmux.transport",
                    "message": message,
                    "details": {"sent": sent},
                    "retryable": sent && mutation,
                }),
                idempotency_key: (sent && mutation)
                    .then(|| idempotency_key.map(str::to_owned))
                    .flatten(),
            },
        })
    }
    #[cfg(not(unix))]
    {
        let _ = (method, params, timeout, mutation);
        Err(CallFailure::local(
            FailureKind::NotRun,
            "acpmux.unavailable",
            "agent dispatch is unavailable on this platform",
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn descriptors_are_harness_agnostic_and_do_not_offer_shell_or_paths() {
        let tools = descriptors();
        assert_eq!(tools.len(), 4);
        for tool in &tools {
            let text = tool["description"].as_str().unwrap();
            assert!(!text.contains("scp"), "{text}");
            assert!(!text.contains("ssh"), "{text}");
            assert!(!text.contains("remote path"), "{text}");
            assert_eq!(tool["inputSchema"]["additionalProperties"], false);
        }
        let dispatch = find(DISPATCH).unwrap();
        assert_eq!(dispatch.input_schema()["properties"]["harness"]["type"], "string");
        assert!(dispatch.input_schema()["properties"].get("cwd").is_none());
        assert!(
            dispatch.input_schema()["properties"]["target"]["description"]
                .as_str()
                .unwrap()
                .contains("auto")
        );
    }

    #[test]
    fn dispatch_params_keep_non_claude_harness_names_and_wire_camel_case() {
        let tool = find(DISPATCH).unwrap();
        let args = serde_json::from_value::<Map<String, Value>>(json!({
            "title": "Qwen task",
            "brief": "Inspect the fixture and report the result.",
            "target": "auto",
            "harness": "qwen",
            "stop_condition": "Report findings",
            "idempotency_key": "dispatch-qwen-1"
        }))
        .unwrap();
        let params = tool.params(&args).unwrap();
        assert_eq!(params["model"], "qwen");
        assert_eq!(params["stopCondition"], "Report findings");
        assert_eq!(params["idempotencyKey"], "dispatch-qwen-1");
        assert_eq!(params["target"], "auto");

        let args = serde_json::from_value::<Map<String, Value>>(json!({
            "title": "DeepSeek task",
            "brief": "Inspect the fixture and report the result.",
            "target": "auto",
            "harness": "opencode",
            "model": "deepseek",
        }))
        .unwrap();
        assert_eq!(tool.params(&args).unwrap()["model"], "opencode/deepseek");

        let generated = serde_json::from_value::<Map<String, Value>>(json!({
            "title": "Generated key",
            "brief": "Retry this safely.",
            "target": "auto",
        }))
        .unwrap();
        assert!(
            tool.params(&generated).unwrap()["idempotencyKey"]
                .as_str()
                .is_some_and(|key| key.starts_with("mutation_"))
        );
    }

    #[test]
    fn list_rejects_unknown_fields_and_out_of_range_limits() {
        let tool = find(BRIEFS_LIST).unwrap();
        let bad = serde_json::from_value::<Map<String, Value>>(json!({"limit": 0})).unwrap();
        assert!(tool.params(&bad).is_err());
        let unknown =
            serde_json::from_value::<Map<String, Value>>(json!({"shell": "ssh"})).unwrap();
        assert!(tool.params(&unknown).is_err());
        assert!(tool.params(&Map::new()).unwrap().get("idempotencyKey").is_none());
    }
}
