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

/// A paired optional size from validated request fields. The catalog checks
/// both fields; a request that still breaks the pairing or range is a
/// validation error, never a panic.
pub(super) fn paired_attach_size<T: TryFrom<u64>>(
    request: &crate::resource_router::ParsedResourceRequest,
    first: &str,
    second: &str,
) -> Result<Option<(T, T)>, ResourceError> {
    let number = |field: &str, value: &Value| {
        value.as_u64().and_then(|value| T::try_from(value).ok()).ok_or_else(|| {
            ResourceError::validation_invalid(Some(field), "expected an in-range integer")
        })
    };
    match (request.fields.get(first), request.fields.get(second)) {
        (Some(a), Some(b)) => Ok(Some((number(first, a)?, number(second, b)?))),
        (None, None) => Ok(None),
        (Some(_), None) => Err(ResourceError::validation_invalid(
            Some(second),
            format!("{second} is required with {first}"),
        )),
        (None, Some(_)) => Err(ResourceError::validation_invalid(
            Some(first),
            format!("{first} is required with {second}"),
        )),
    }
}

/// The lease every successful surface attach mints, or a typed error.
pub(super) fn minted_lease(
    operation: &str,
    lease: Option<String>,
) -> Result<String, ResourceError> {
    lease.ok_or_else(|| {
        ResourceError::operation_failed(operation, "resource attach minted no lease", json!({}))
    })
}
