//! Pure values used by native control frames; kept outside the dispatcher.
use super::*;

/// `machine-usage` result and `machine-usage-changed` payload body: `usage`
/// is the readout object or null when the daemon has none.
pub(super) fn machine_usage_json(usage: Option<&MachineUsage>) -> Value {
    json!({
        "usage": usage.map(|usage| json!({
            "vm_id": usage.vm_id,
            "period_days": usage.period_days,
            "total_tokens": usage.total_tokens,
            "api_equivalent_usd": usage.api_equivalent_usd,
            "as_of": usage.as_of,
        })),
    })
}

pub(super) fn json_line_payload_len(line: &str) -> usize {
    line.strip_suffix('\n').map_or(line.len(), str::len)
}

pub(super) fn default_renderer_capability_ttl_ms() -> u64 {
    30_000
}

/// Panic-free stand-ins for serde_json's `value[key]` read and write.
pub(crate) trait JsonFields {
    /// `value[key]` without the index operator: Null when the key is absent
    /// or the value is not an object.
    fn field(&self, key: &str) -> &Value;
    /// `value[key] = field` without the panic: Null becomes an object (as
    /// `IndexMut` does); any other non-object value is left unchanged.
    fn set_field(&mut self, key: &str, field: Value);
}

static JSON_NULL: Value = Value::Null;

impl JsonFields for Value {
    fn field(&self, key: &str) -> &Value {
        self.get(key).unwrap_or(&JSON_NULL)
    }

    fn set_field(&mut self, key: &str, field: Value) {
        if self.is_null() {
            *self = Value::Object(serde_json::Map::new());
        }
        if let Some(object) = self.as_object_mut() {
            object.insert(key.to_owned(), field);
        }
    }
}

/// The idempotency key the catalog requires on a mutation, or a typed
/// validation error when a request reaches the handler without one.
pub(crate) fn required_idempotency_key(
    request: &crate::resource_router::ParsedResourceRequest,
) -> Result<&str, ResourceError> {
    request.envelope.idempotency_key.as_deref().ok_or_else(|| {
        ResourceError::validation_invalid(
            Some("idempotency_key"),
            "this operation requires an idempotency key",
        )
    })
}

/// A handler that the router reached with an operation it does not serve:
/// a typed failure for that request, never a panic.
pub(crate) fn unrouted_operation(handler: &str, operation: ResourceOperation) -> ResourceError {
    ResourceError::operation_failed(
        operation.wire_name(),
        format!("the {handler} handler does not serve this operation"),
        json!({}),
    )
}
