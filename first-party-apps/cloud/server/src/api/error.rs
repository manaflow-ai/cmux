//! Typed op errors. Codes are `cmux.cloud.<reason>`; `message` is display
//! text. A backend error keeps its `cmux.wire/1` code in `upstream_code`
//! and its `details` (for example `{limit, used}` of a quota).

use super::control_plane::WireError;
use serde::Serialize;
use serde_json::Value;

/// Every error code the server answers.
pub mod codes {
    pub const AUTH_REQUIRED: &str = "cmux.cloud.auth_required";
    pub const FORBIDDEN: &str = "cmux.cloud.forbidden";
    pub const NOT_FOUND: &str = "cmux.cloud.not_found";
    pub const CONFLICT: &str = "cmux.cloud.conflict";
    /// `cloud.plan.required`: the op needs a paid plan.
    pub const PLAN_REQUIRED: &str = "cmux.cloud.plan_required";
    /// `cloud.quota.exceeded`: `details` carries `{limit, used}`.
    pub const QUOTA_EXCEEDED: &str = "cmux.cloud.quota_exceeded";
    /// `cloud.size.locked`: the size needs another plan.
    pub const SIZE_LOCKED: &str = "cmux.cloud.size_locked";
    /// `cloud.provider.unavailable` (retryable).
    pub const PROVIDER_UNAVAILABLE: &str = "cmux.cloud.provider_unavailable";
    /// `cloud.machine.not_bound`: still provisioning, no host yet.
    pub const NOT_BOUND: &str = "cmux.cloud.not_bound";
    /// `cloud.machine.paused`.
    pub const MACHINE_PAUSED: &str = "cmux.cloud.machine_paused";
    /// `cloud.migration.unavailable`.
    pub const MIGRATION_UNAVAILABLE: &str = "cmux.cloud.migration_unavailable";
    /// `cloud.machine.not_classic`.
    pub const NOT_CLASSIC: &str = "cmux.cloud.not_classic";
    /// `cloud.upgrade.failed`: the classic machine still works.
    pub const UPGRADE_FAILED: &str = "cmux.cloud.upgrade_failed";
    /// `mutation.indeterminate`: the backend cannot tell whether the call
    /// acted. Retry with the SAME key; never make a new one.
    pub const INDETERMINATE: &str = "cmux.cloud.indeterminate";
    /// `cloud.no_snapshot_configured`: no machine image is configured for
    /// this deployment yet, so create and restore cannot run.
    pub const NO_SNAPSHOT_CONFIGURED: &str = "cmux.cloud.no_snapshot_configured";
    /// `cloud.rate_limited`: the team's create or delete budget is spent.
    pub const RATE_LIMITED: &str = "cmux.cloud.rate_limited";
    pub const UNSUPPORTED: &str = "cmux.cloud.unsupported";
    pub const UPSTREAM: &str = "cmux.cloud.upstream_error";
    pub const BAD_RESPONSE: &str = "cmux.cloud.bad_response";
    pub const INVALID_ARGS: &str = "cmux.cloud.invalid_args";
    pub const UNKNOWN_OP: &str = "cmux.cloud.unknown_op";
    pub const ORIGIN_REFUSED: &str = "cmux.cloud.origin_refused";
    pub const IDEMPOTENCY_KEY_REQUIRED: &str = "cmux.cloud.idempotency_key_required";
    pub const IDEMPOTENCY_KEY_FORBIDDEN: &str = "cmux.cloud.idempotency_key_forbidden";
    pub const IDEMPOTENCY_CONFLICT: &str = "cmux.cloud.idempotency_conflict";
    pub const RELAY_UNAVAILABLE: &str = "cmux.cloud.relay_unavailable";
    /// An op line arrived while a relay call waited and the queue of
    /// waiting lines was full (`api::RELAY_QUEUE_LINES`): retry it.
    pub const RELAY_BUSY: &str = "cmux.cloud.relay_busy";
    /// The backend answered an error code its op does not declare
    /// (`upstream_code` keeps it): a protocol break, never guessed at.
    pub const PROTOCOL_ERROR: &str = "cmux.cloud.protocol_error";
}

/// `cmux.wire/1` codes and the server code each maps to. Any other code is
/// `upstream_error` with the wire code kept in `upstream_code`.
const WIRE_CODES: &[(&str, &str)] = &[
    ("auth.unauthenticated", codes::AUTH_REQUIRED),
    ("auth.forbidden", codes::FORBIDDEN),
    ("auth.sso_required", codes::FORBIDDEN),
    ("client.too_old", codes::FORBIDDEN),
    ("policy.denied", codes::FORBIDDEN),
    ("validation.invalid", codes::INVALID_ARGS),
    ("selector.not_found", codes::NOT_FOUND),
    ("cloud.machine.not_found", codes::NOT_FOUND),
    ("cloud.snapshot.not_found", codes::NOT_FOUND),
    ("idempotency.conflict", codes::IDEMPOTENCY_CONFLICT),
    ("revision.conflict", codes::CONFLICT),
    ("mutation.indeterminate", codes::INDETERMINATE),
    ("owner.unreachable", codes::UPSTREAM),
    ("cloud.plan.required", codes::PLAN_REQUIRED),
    ("cloud.quota.exceeded", codes::QUOTA_EXCEEDED),
    ("cloud.size.locked", codes::SIZE_LOCKED),
    ("cloud.provider.unavailable", codes::PROVIDER_UNAVAILABLE),
    ("cloud.machine.not_bound", codes::NOT_BOUND),
    ("cloud.machine.paused", codes::MACHINE_PAUSED),
    ("cloud.migration.unavailable", codes::MIGRATION_UNAVAILABLE),
    ("cloud.machine.not_classic", codes::NOT_CLASSIC),
    ("cloud.upgrade.failed", codes::UPGRADE_FAILED),
    ("cloud.rate_limited", codes::RATE_LIMITED),
    ("cloud.no_snapshot_configured", codes::NO_SNAPSHOT_CONFIGURED),
];

/// A typed op failure.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct CloudError {
    pub code: &'static str,
    pub message: String,
    /// The upstream's own code (a `cmux.wire/1` code, or a daemon `fs.*` code).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub upstream_code: Option<String>,
    /// The backend's `details` (for example `{limit, used}` of a quota).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub details: Option<Value>,
    pub retryable: bool,
}

impl CloudError {
    pub fn new(code: &'static str, message: impl Into<String>) -> Self {
        Self { code, message: message.into(), upstream_code: None, details: None, retryable: false }
    }

    pub fn invalid(message: impl Into<String>) -> Self {
        Self::new(codes::INVALID_ARGS, message)
    }

    /// Maps a typed `cmux.wire/1` error of backend op `op`. A code `op`
    /// does not declare (`crate::ops::declared_errors`) is
    /// [`codes::PROTOCOL_ERROR`]; an op the table does not know maps as is.
    pub fn from_wire_for(op: &str, error: &WireError) -> Self {
        let declared = crate::ops::declared_errors(op);
        if declared.is_some_and(|d| !d.contains(&error.code.as_str())) {
            return Self {
                upstream_code: Some(error.code.clone()),
                details: error.details.clone(),
                ..Self::new(
                    codes::PROTOCOL_ERROR,
                    format!(
                        "{op} answered {}, which it does not declare: {}",
                        error.code, error.message
                    ),
                )
            };
        }
        Self::from_wire(error)
    }

    /// Maps a typed `cmux.wire/1` error. `mutation.indeterminate` is
    /// retryable here (with the same key), whatever the backend says;
    /// `cloud.provider.unavailable` and `owner.unreachable` are too.
    pub fn from_wire(error: &WireError) -> Self {
        let code = WIRE_CODES
            .iter()
            .find(|(wire, _)| *wire == error.code)
            .map_or(codes::UPSTREAM, |(_, code)| code);
        let retryable = error.retryable
            || matches!(code, codes::INDETERMINATE | codes::PROVIDER_UNAVAILABLE)
            || error.code == "owner.unreachable";
        Self {
            code,
            message: error.message.clone(),
            upstream_code: Some(error.code.clone()),
            details: error.details.clone(),
            retryable,
        }
    }
}

impl std::fmt::Display for CloudError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.code, self.message)
    }
}

impl std::error::Error for CloudError {}
