//! The daemon-op envelope an app's catalog op (apps::routing) and a cloud-forwarded host op
//! (server::cloud_host_replica) both go through: the `cmux.protocol/2` request for an op and
//! the answer from its response. Pure JSON over the resource operation catalog, so it builds on
//! every platform; the routing itself (app supervisor, mirror) is unix-only.

use std::sync::OnceLock;

use cmux_json::JsonSet as _;
use serde_json::{Map, Value, json};

const CATALOG_JSON: &str = include_str!("../../../../spec/resource-operations-v2.json");

pub(crate) fn catalog() -> &'static Value {
    static CATALOG: OnceLock<Value> = OnceLock::new();
    // crash-allow: compiled-in catalog JSON (include_str!); a parse failure fails every catalog test
    CATALOG.get_or_init(|| serde_json::from_str(CATALOG_JSON).expect("resource operation catalog"))
}

pub(crate) fn error(code: &str, message: impl Into<String>) -> Value {
    json!({ "code": code, "message": message.into(), "retryable": false })
}

/// True when this daemon's own dispatcher owns `op`.
#[cfg_attr(not(unix), allow(dead_code))] // only app routing (unix) asks
pub(crate) fn is_daemon_op(op: &str) -> bool {
    catalog()["operations"].get(op).is_some()
}

/// Builds the protocol request: `machine`/`session` default to `current`
/// when the op takes them; everything else is the app's params as given.
pub(crate) fn request(
    op: &str,
    params: Value,
    idempotency_key: Option<String>,
) -> Result<String, Value> {
    let descriptor = catalog()["operations"]
        .get(op)
        .ok_or_else(|| error("operation.unsupported", format!("{op} is not a daemon operation")))?;
    let mut fields: Map<String, Value> = match params {
        Value::Object(map) => map,
        Value::Null => Map::new(),
        _ => return Err(error("validation.invalid", "params must be an object")),
    };
    let selectors = descriptor.pointer("/params/selectors").and_then(Value::as_object);
    for name in ["machine", "session"] {
        if selectors.is_some_and(|s| s.contains_key(name)) {
            fields.entry(name).or_insert_with(|| json!("current"));
        }
    }
    let mut envelope = json!({
        "protocol": crate::resource::PROTOCOL,
        "type": "request",
        "id": "app",
        "operation": op,
        "params": fields,
    });
    if descriptor["class"] == "mutation" {
        let key = idempotency_key
            .filter(|k| !k.is_empty())
            .ok_or_else(|| error("validation.invalid", "a mutation needs an idempotency key"))?;
        envelope.set("idempotency_key", Value::String(key));
    }
    Ok(envelope.to_string())
}

/// Response envelope to the ABI body: reads answer `{value}`, mutations
/// already answer a `MutationResult` (`{value, revision, replayed, …}`).
pub(crate) fn answer(op: &str, response: Value) -> Result<Value, Value> {
    if response["ok"] == true {
        let result = response.get("result").cloned().unwrap_or(Value::Null);
        let mutation = catalog()["operations"][op]["class"] == "mutation";
        return Ok(if mutation && result.get("value").is_some() {
            result
        } else {
            json!({ "value": result })
        });
    }
    let error = response.get("error").cloned().unwrap_or_else(|| json!({}));
    Err(json!({
        "code": error["code"].as_str().unwrap_or("operation.failed"),
        "message": error["message"].as_str().unwrap_or("operation failed"),
        "details": error.get("details").cloned().unwrap_or(Value::Null),
        "retryable": error["retryable"].as_bool().unwrap_or(false),
    }))
}
