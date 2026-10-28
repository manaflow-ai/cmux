//! The JSON-RPC and tool result shapes `cmux mcp serve` answers with: a
//! tool's success, a failed call's envelope and its `state`, and a result
//! cut to `MAX_RESULT_BYTES`.

use serde_json::{Value, json};

use super::MAX_RESULT_BYTES;
use super::transport::{CallFailure, FailureKind};
use crate::cli::json_fields::JsonFields;

pub(super) fn error_response(id: Value, code: i64, message: &str) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}})
}

/// A successful tool result: the owner's value as structured content (an
/// array as `{items}`), cut to `MAX_RESULT_BYTES`. A change (`applied`)
/// whose result does not fit still reports success, so a client never
/// retries a change that applied.
pub(super) fn success(value: Value, applied: bool) -> Value {
    let value = match value {
        Value::Object(_) => value,
        Value::Array(items) => json!({ "items": items }),
        other => json!({ "result": other }),
    };
    match fit(value) {
        Ok(value) => {
            let text = serde_json::to_string(&value).unwrap_or_default();
            json!({
                "content": [{"type": "text", "text": text}],
                "structuredContent": value,
                "isError": false,
            })
        }
        Err(_) if applied => {
            let value = json!({
                "applied": true,
                "truncated": true,
                "message": format!(
                    "the change applied; its result is larger than {} KiB, so read the object \
                     with a get or list tool",
                    MAX_RESULT_BYTES >> 10
                ),
            });
            let text = serde_json::to_string(&value).unwrap_or_default();
            json!({
                "content": [{"type": "text", "text": text}],
                "structuredContent": value,
                "isError": false,
            })
        }
        Err(error) => tool_error(envelope(error, "rejected", None)),
    }
}

/// `value` when it serializes within `MAX_RESULT_BYTES`; else its `items`
/// halved until it does (`truncated`, `next_offset`), else an error.
fn fit(mut value: Value) -> Result<Value, Value> {
    let size = |value: &Value| serde_json::to_vec(value).map(|bytes| bytes.len()).unwrap_or(0);
    if size(&value) <= MAX_RESULT_BYTES {
        return Ok(value);
    }
    while let Some(items) = value.get_mut("items").and_then(Value::as_array_mut)
        && items.len() > 1
    {
        let keep = items.len() / 2;
        items.truncate(keep);
        value.insert("truncated", json!(true));
        value.insert("returned", json!(keep));
        if let Some(offset) = value.get("offset").and_then(Value::as_u64) {
            value.insert("next_offset", json!(offset + keep as u64));
        }
        if size(&value) <= MAX_RESULT_BYTES {
            return Ok(value);
        }
    }
    Err(json!({
        "code": "result.too_large",
        "message": format!(
            "the result is larger than {} KiB; ask for less (limit, max_bytes, or a narrower \
             selector)",
            MAX_RESULT_BYTES >> 10
        ),
        "details": {},
        "retryable": false,
    }))
}

/// The error a failed call reports: the owner's error unchanged, its
/// `state` (`rejected`, `not_run`, `in_progress`) and the idempotency key
/// to retry with.
pub(super) fn envelope(error: Value, state: &str, idempotency_key: Option<&str>) -> Value {
    let mut envelope = json!({ "error": error, "state": state });
    if let Some(key) = idempotency_key {
        envelope.insert("idempotency_key", json!(key));
    }
    envelope
}

pub(in crate::cli) fn failure_result(failure: CallFailure) -> Value {
    // An owner that says whether the run started (the app's `busy` and
    // `timeout`) decides the state.
    let data = failure.error.get("data").or_else(|| failure.error.get("details"));
    let owner_state = data.and_then(|data| {
        if data.get("not_run") == Some(&Value::Bool(true)) {
            return Some("not_run");
        }
        data.get("state")
            .and_then(Value::as_str)
            .filter(|state| matches!(*state, "not_run" | "in_progress"))
    });
    // The app's queue deadline (`timeout`) says nothing about whether the
    // run started; a retry with the same key is safe either way.
    let timed_out =
        failure.kind == FailureKind::Rejected && failure.error.field("code") == "timeout";
    let state = owner_state
        .or(timed_out.then_some("in_progress"))
        .unwrap_or(failure.kind.state())
        .to_owned();
    tool_error(envelope(failure.error, &state, failure.idempotency_key.as_deref()))
}

pub(super) fn tool_error(envelope: Value) -> Value {
    let text = serde_json::to_string(&envelope).unwrap_or_default();
    json!({
        "content": [{"type": "text", "text": text}],
        "structuredContent": envelope,
        "isError": true,
    })
}
