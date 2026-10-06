//! ResourceError, the cmux.protocol/2 error value, and its check against the catalog's error contracts.

use super::*;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ResourceError {
    pub code: String,
    pub message: String,
    pub details: Value,
    pub retryable: bool,
}

impl ResourceError {
    pub fn new(
        code: impl Into<String>,
        message: impl Into<String>,
        details: Value,
        retryable: bool,
    ) -> Self {
        let code = code.into();
        assert!(
            is_catalog_error_code(&code),
            "resource error code {code:?} is absent from spec/resource-operations-v2.json"
        );
        assert!(
            catalog_error_contract_matches(&code, &details, retryable),
            "resource error {code:?} violates its catalog details or retryable contract: {details}"
        );
        Self { code, message: message.into(), details, retryable }
    }

    pub fn operation_failed(
        operation: impl Into<String>,
        reason: impl Into<String>,
        extra: Value,
    ) -> Self {
        let operation = operation.into();
        let reason = reason.into();
        assert!(extra.is_object(), "operation.failed extra must be an object");
        let mut details = json!({
            "operation":operation,
            "reason":reason,
        });
        if extra.as_object().is_some_and(|extra| !extra.is_empty()) {
            details["extra"] = extra;
        }
        Self::new("operation.failed", reason, details, false)
    }

    pub(super) fn invalid_id(kind: &str, value: &str) -> Self {
        let scope = canonical_resource_scope(kind);
        Self::new(
            "selector.invalid",
            format!("invalid {kind} {value:?}"),
            json!({
                "scope":scope,
                "selector":value,
                "reason":format!("invalid {kind} resource identity"),
            }),
            false,
        )
    }

    pub fn not_found(kind: &str, selector: &str) -> Self {
        let scope = canonical_resource_scope(kind);
        Self::new(
            "selector.not_found",
            format!("no {kind} matches {selector:?}"),
            json!({"scope":scope,"selector":selector}),
            false,
        )
    }

    pub fn ambiguous(kind: &str, selector: &str, candidates: Vec<String>) -> Self {
        let scope = canonical_resource_scope(kind);
        Self::new(
            "selector.ambiguous",
            format!("more than one {kind} is named {selector:?}"),
            json!({"scope":scope,"selector":selector,"candidates":candidates}),
            false,
        )
    }

    pub fn allocation(kind: &str) -> Self {
        Self::operation_failed(
            "resource.allocate",
            format!("could not allocate {kind} identity"),
            json!({"kind":kind}),
        )
    }

    pub fn selector_invalid(scope: &str, selector: &str, reason: impl Into<String>) -> Self {
        let reason = reason.into();
        Self::new(
            "selector.invalid",
            reason.clone(),
            json!({
                "scope":canonical_resource_scope(scope),
                "selector":selector,
                "reason":reason,
            }),
            false,
        )
    }

    pub fn validation_invalid(field: Option<&str>, reason: impl Into<String>) -> Self {
        let reason = reason.into();
        let mut details = json!({"reason":reason});
        if let Some(field) = field {
            details["field"] = json!(field);
        }
        Self::new("validation.invalid", reason, details, false)
    }

    pub fn transport_closed(reason: impl Into<String>) -> Self {
        let reason = reason.into();
        Self::new("transport.closed", reason.clone(), json!({"reason":reason}), true)
    }

    pub fn terminal_closed(terminal_id: &TerminalPublicId) -> Self {
        Self::new(
            "terminal.closed",
            format!("terminal {terminal_id} is closed"),
            json!({"terminal_id":terminal_id}),
            false,
        )
    }

    pub fn idempotency_conflict(idempotency_key: &str, committed_operation: &str) -> Self {
        Self::new(
            "idempotency.conflict",
            "the idempotency key was already committed with different input",
            json!({
                "idempotency_key":idempotency_key,
                "committed_operation":committed_operation,
            }),
            false,
        )
    }

    pub fn creation_conflict(
        correlation_key: &str,
        existing_operation: &str,
        requested_operation: &str,
        existing_fingerprint: &str,
        requested_fingerprint: &str,
    ) -> Self {
        Self::new(
            "creation.conflict",
            "the creation correlation key is bound to different semantics",
            json!({
                "correlation_key":correlation_key,
                "existing_operation":existing_operation,
                "requested_operation":requested_operation,
                "existing_fingerprint":existing_fingerprint,
                "requested_fingerprint":requested_fingerprint,
            }),
            false,
        )
    }

    pub fn revision_conflict(expected: u64, actual: u64) -> Self {
        Self::new(
            "revision.conflict",
            "the resource revision changed",
            json!({
                "expected":expected.to_string(),
                "actual":actual.to_string(),
            }),
            true,
        )
    }
}

pub(crate) const RESOURCE_ERROR_CODES: &[&str] = &[
    "confirmation.required",
    "creation.conflict",
    "cursor.gap",
    "cursor.invalid",
    "home.not_closable",
    "home.pinned_first",
    "idempotency.conflict",
    "local.io",
    "mutation.indeterminate",
    "operation.failed",
    "operation.unsupported",
    "origin.forbidden",
    "resource.not_found",
    "revision.conflict",
    "selector.ambiguous",
    "selector.invalid",
    "selector.not_found",
    "selector.wrong_parent",
    "terminal.closed",
    "terminal_host.unavailable",
    "transport.closed",
    "validation.invalid",
];

pub(crate) fn is_catalog_error_code(code: &str) -> bool {
    RESOURCE_ERROR_CODES.contains(&code)
}

pub(super) fn error_catalog() -> &'static Value {
    static CATALOG: OnceLock<Value> = OnceLock::new();
    CATALOG.get_or_init(|| {
        serde_json::from_str(include_str!("../../../../spec/resource-operations-v2.json"))
            .expect("checked-in resource operation catalog")
    })
}

pub(super) fn catalog_error_contract_matches(code: &str, details: &Value, retryable: bool) -> bool {
    let Some(error) = error_catalog()["errors"].get(code) else { return false };
    error["retryable"].as_bool() == Some(retryable)
        && catalog_value_matches(details, &error["details"])
}

pub(super) fn catalog_value_matches(value: &Value, descriptor: &Value) -> bool {
    match descriptor["kind"].as_str() {
        Some("primitive") => match descriptor["name"].as_str() {
            Some("json") => true,
            Some("string") => {
                let Some(value) = value.as_str() else { return false };
                descriptor["min_length"]
                    .as_u64()
                    .is_none_or(|minimum| value.len() >= minimum as usize)
                    && descriptor["max_length"]
                        .as_u64()
                        .is_none_or(|maximum| value.len() <= maximum as usize)
            }
            Some("decimal") => value.as_str().is_some_and(|value| {
                value == "0"
                    || (!value.starts_with('0')
                        && value.len() <= 20
                        && value.bytes().all(|byte| byte.is_ascii_digit())
                        && value.parse::<u64>().is_ok())
            }),
            Some("boolean") => value.is_boolean(),
            Some("uint32") => value.as_u64().is_some_and(|value| u32::try_from(value).is_ok()),
            Some("uint64") => value.is_u64(),
            _ => false,
        },
        Some("resource_id") => {
            let Some(value) = value.as_str() else { return false };
            let Some(resource) = descriptor["resource"].as_str() else { return false };
            resource_id_has_kind(value, resource)
        }
        Some("enum") => {
            descriptor["values"].as_array().is_some_and(|values| values.contains(value))
        }
        Some("array") => {
            let Some(values) = value.as_array() else { return false };
            descriptor["min_items"].as_u64().is_none_or(|minimum| values.len() >= minimum as usize)
                && descriptor["max_items"]
                    .as_u64()
                    .is_none_or(|maximum| values.len() <= maximum as usize)
                && values.iter().all(|value| catalog_value_matches(value, &descriptor["items"]))
        }
        Some("map") => value.as_object().is_some_and(|values| {
            values.values().all(|value| catalog_value_matches(value, &descriptor["values"]))
        }),
        Some("object") => {
            let Some(value) = value.as_object() else { return false };
            let Some(fields) = descriptor["fields"].as_object() else { return false };
            if descriptor["extra"] == Value::Bool(false)
                && value.keys().any(|name| !fields.contains_key(name))
            {
                return false;
            }
            fields.iter().all(|(name, field)| match value.get(name) {
                Some(value) => catalog_value_matches(value, &field["type"]),
                None => field["required"] != Value::Bool(true),
            })
        }
        Some("ref") => descriptor["name"]
            .as_str()
            .and_then(|name| error_catalog()["types"].get(name))
            .is_some_and(|descriptor| catalog_value_matches(value, descriptor)),
        _ => false,
    }
}

pub(super) fn resource_id_has_kind(value: &str, kind: &str) -> bool {
    let prefix = match kind {
        "machine" => "machine_",
        "session" => "session_",
        "client" => "client_",
        "workspace" => "ws_",
        "screen" => "screen_",
        "pane" => "pane_",
        "split" => "split_",
        "tab" => "tab_",
        "terminal" => "term_",
        "browser" => "browser_",
        "notification" => "notification_",
        "agent" => "agent_",
        "frontend_projection" => "projection_",
        "pairing_request" => "pairing_",
        "sidebar_view" => "sidebar_view_",
        "stream" => "stream_",
        _ => return false,
    };
    value.strip_prefix(prefix).is_some_and(is_lower_hex_128)
}

pub(super) fn is_lower_hex_128(value: &str) -> bool {
    value.len() == 32
        && value.bytes().all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

impl fmt::Display for ResourceError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for ResourceError {}
