//! Routes an app's catalog op into this daemon's own `cmux.protocol/2`
//! dispatcher, the same validation and owner code every client goes
//! through, and bridges daemon change events to app subscriptions.
//!
//! Gap: the protocol has no actor field yet, so `actor = app:<id>` and the
//! call's origin are enforced here (scopes, gesture-gated focus ops) and not
//! stamped on the owner's records. When the dispatcher grows an actor, pass
//! `app` and `origin` through.

use std::sync::{Arc, OnceLock, Weak};

use serde_json::{Map, Value, json};

use super::mirror::Origin;
use super::supervisor::OpRouter;
use crate::mux::Mux;
use crate::{MuxEvent, resource_router};

const CATALOG_JSON: &str = include_str!("../../../../spec/resource-operations-v2.json");

fn catalog() -> &'static Value {
    static CATALOG: OnceLock<Value> = OnceLock::new();
    CATALOG.get_or_init(|| serde_json::from_str(CATALOG_JSON).expect("resource operation catalog"))
}

pub struct MuxRouter {
    mux: Weak<Mux>,
}

impl MuxRouter {
    pub fn new(mux: &Arc<Mux>) -> Self {
        Self { mux: Arc::downgrade(mux) }
    }
}

fn error(code: &str, message: impl Into<String>) -> Value {
    json!({ "code": code, "message": message.into(), "retryable": false })
}

/// Builds the protocol request: `machine`/`session` default to `current`
/// when the op takes them; everything else is the app's params as given.
pub(super) fn request(
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
        envelope["idempotency_key"] = Value::String(key);
    }
    Ok(envelope.to_string())
}

/// Response envelope to the ABI body: reads answer `{value}`, mutations
/// already answer a `MutationResult` (`{value, revision, replayed, …}`).
pub(super) fn answer(op: &str, response: Value) -> Result<Value, Value> {
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

impl OpRouter for MuxRouter {
    fn route(
        &self,
        _app: &str,
        op: &str,
        params: Value,
        idempotency_key: Option<String>,
        _origin: Origin,
    ) -> Result<Value, Value> {
        let mux = self
            .mux
            .upgrade()
            .ok_or_else(|| error("operation.failed", "the daemon is shutting down"))?;
        let message = request(op, params, idempotency_key)?;
        let parsed = resource_router::parse_resource_request(&message)
            .map_err(|e| answer(op, json!({ "ok": false, "error": e })).unwrap_err())?;
        if resource_router::requires_connection_context(parsed.envelope.operation) {
            return Err(error(
                "operation.unsupported",
                format!("{op} needs a client connection and is not available to apps"),
            ));
        }
        let response = resource_router::handle_parsed_resource_request(&mux, parsed)
            .map_err(|e| answer(op, json!({ "ok": false, "error": e })).unwrap_err())?;
        answer(op, response)
    }

    fn start_events(&self, publish: Box<dyn Fn(&str) + Send + Sync>) {
        let Some(mux) = self.mux.upgrade() else { return };
        let events = mux.subscribe();
        drop(mux);
        let _ = std::thread::Builder::new().name("cmux-apps-events".into()).spawn(move || {
            while let Ok(event) = events.recv() {
                for stream in streams(&event) {
                    publish(stream);
                }
            }
        });
    }
}

/// The app streams a daemon event invalidates (`cmux.live` re-reads on them).
fn streams(event: &MuxEvent) -> &'static [&'static str] {
    match event {
        MuxEvent::TreeChanged | MuxEvent::TreeSelectionChanged | MuxEvent::TreeDelta(_) => &[
            "workspace.changed",
            "screen.changed",
            "pane.changed",
            "tab.changed",
            "terminal.changed",
        ],
        MuxEvent::AgentChanged { .. } => &["agent.changed"],
        _ => &[],
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn requests_fill_current_selectors_only_where_the_op_takes_them() {
        let message: Value =
            serde_json::from_str(&request("workspace.list", json!({}), None).unwrap()).unwrap();
        assert_eq!(message["params"], json!({ "machine": "current", "session": "current" }));
        assert!(message.get("idempotency_key").is_none());
        let focus: Value = serde_json::from_str(
            &request("tab.focus", json!({ "tab": "tab_1" }), Some("k".into())).unwrap(),
        )
        .unwrap();
        assert_eq!(focus["idempotency_key"], "k");
        assert_eq!(
            request("made.up", json!({}), None).unwrap_err()["code"],
            "operation.unsupported"
        );
    }

    #[test]
    fn answers_wrap_reads_and_pass_mutation_results_through() {
        assert_eq!(
            answer("workspace.list", json!({ "ok": true, "result": [1] })).unwrap(),
            json!({ "value": [1] })
        );
        let mutation =
            json!({ "value": {}, "revision": "3", "replayed": false, "generation": "g" });
        assert_eq!(
            answer("tab.focus", json!({ "ok": true, "result": mutation.clone() })).unwrap(),
            mutation
        );
        let err = answer("tab.focus", json!({ "ok": false, "error": { "code": "selector.not_found", "message": "no tab", "retryable": false } })).unwrap_err();
        assert_eq!(err["code"], "selector.not_found");
    }
}
