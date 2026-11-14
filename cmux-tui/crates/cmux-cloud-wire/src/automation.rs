//! The Cloud automation relay's rules (docs/automations-platonic-ideal.md,
//! Cloud slice): which ops the app forwards for `cmux automation --target
//! cloud`, the Automations page and the Chief's automation tool, where each
//! goes, and how the owner's answer reads. `cmux cloud automation-relay`
//! (cmux-tui `cli/cloud_automation_relay.rs`) does the one POST.
//!
//! Reads go to `/v1/read`; mutations to `/v1/ops` with the caller's
//! idempotency key, so a retried command applies once. The answer is always
//! one JSON object, `{ok: true, value}` or `{ok: false, error: {code,
//! message, details?}}`: a refusal by the owner keeps its `details` (a plan
//! refusal's checkout link), and a request refused here has the same shape.

use serde_json::{Map, Value, json};

/// Reads, answered from `/v1/read`.
pub const READS: [&str; 8] = [
    "automation.list",
    "automation.get",
    "automation.runs.list",
    "automation.webhook.get",
    "run.list",
    "run.get",
    "chief.list",
    "automation.audit.list",
];

/// Mutations, sent to `/v1/ops`, with the teleport steps
/// (docs/automations-teleport-teams.md). `automation.deploy` and
/// `automation.settings.set` stay out.
pub const MUTATIONS: [&str; 8] = [
    "automation.create",
    "automation.update",
    "automation.delete",
    "automation.run",
    "automation.import",
    "automation.teleport.begin",
    "automation.teleport.complete",
    "automation.teleport.abort",
];

/// The longest idempotency key forwarded.
pub const MAX_KEY_CHARS: usize = 200;

/// Where one request goes.
#[derive(Debug, Clone, PartialEq)]
pub struct Routed {
    /// `/v1/read` or `/v1/ops`.
    pub path: &'static str,
    pub body: Value,
}

/// `{ok: false, error: {code, message}}`.
pub fn refusal(code: &str, message: &str) -> Value {
    json!({ "ok": false, "error": { "code": code, "message": message } })
}

/// Where `request` (`{op, params?, idempotency_key?}`) goes, or the refusal answer.
pub fn route(request: &Value) -> Result<Routed, Value> {
    let Some(request) = request.as_object() else {
        return Err(refusal("invalid_params", "the request is not a JSON object"));
    };
    let op = match request.get("op").and_then(Value::as_str) {
        Some(op) if !op.is_empty() => op,
        _ => return Err(refusal("invalid_params", "cloud.automation needs `op`")),
    };
    let params = request.get("params").cloned().unwrap_or_else(|| Value::Object(Map::new()));
    if !params.is_object() {
        return Err(refusal("invalid_params", "`params` must be an object"));
    }
    let mut body = Map::new();
    body.insert("op".into(), json!(op));
    body.insert("params".into(), params);
    let path = if READS.contains(&op) {
        "/v1/read"
    } else if MUTATIONS.contains(&op) {
        let key = request.get("idempotency_key").and_then(Value::as_str).unwrap_or_default();
        if key.is_empty() || key.chars().count() > MAX_KEY_CHARS {
            return Err(refusal(
                "invalid_params",
                &format!(
                    "{op} needs `idempotency_key` (at most {MAX_KEY_CHARS} characters), so a retry applies once"
                ),
            ));
        }
        body.insert("idempotency_key".into(), json!(key));
        body.insert("origin".into(), json!("cli"));
        "/v1/ops"
    } else {
        return Err(refusal(
            "automation.op_not_allowed",
            &format!("cloud.automation forwards only automation ops; {op} is not one"),
        ));
    };
    Ok(Routed { path, body: Value::Object(body) })
}

/// The answer for the owner's reply (`status`, `body`): its value, or the
/// refusal (the owner's error object, a plain error string, or only the HTTP
/// status). A failure is never reported as success.
pub fn answer(status: u16, body: &[u8]) -> Value {
    let reply = serde_json::from_slice::<Value>(body).ok().filter(Value::is_object);
    let success = (200..300).contains(&status);
    if let Some(reply) = &reply
        && success
        && reply.get("error").is_none()
        && reply.get("ok").and_then(Value::as_bool) != Some(false)
    {
        return json!({ "ok": true, "value": reply.get("value").cloned().unwrap_or(Value::Null) });
    }
    if reply.is_none() && success {
        return refusal(
            "owner.bad_reply",
            "cmux Cloud answered something that is not a JSON object",
        );
    }
    let mut error = Map::new();
    error.insert("code".into(), json!(format!("http_{status}")));
    error.insert("message".into(), json!(format!("cmux Cloud answered HTTP {status}")));
    match reply.as_ref().and_then(|reply| reply.get("error")) {
        Some(Value::Object(owner)) => {
            if let Some(code) = owner.get("code").and_then(Value::as_str) {
                error.insert("code".into(), json!(code));
            }
            let message = owner.get("message").and_then(Value::as_str).unwrap_or_default();
            error.insert("message".into(), json!(message));
            if let Some(details) = owner.get("details") {
                error.insert("details".into(), details.clone());
            }
        }
        Some(Value::String(text)) => {
            error.insert("message".into(), json!(text));
        }
        _ => {}
    }
    json!({ "ok": false, "error": error })
}

#[cfg(test)]
mod tests;
