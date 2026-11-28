//! Why the owner refused an op. Codes match the Swift socket stopgap
//! (`ControlRouter+Settings.swift`): a managed key is `managed`, a value the
//! schema refuses is `invalid_params`.

use std::fmt;

use serde_json::{Value, json};

use crate::managed::ManagedSource;
use crate::render::compact;
use crate::schema::Accepted;

#[derive(Debug, Clone, PartialEq)]
pub enum Refusal {
    /// The write would change a key an MDM profile or the team policy manages.
    Managed { key: String, source: ManagedSource },
    /// The schema refuses the value.
    InvalidValue { key: String, kind: &'static str, accepted: Accepted, value: Value },
    /// The key was retired (Swift `SettingRetired`, code `removed`).
    Removed { key: String, reason: String },
    /// The request itself is malformed (an empty path, ...).
    InvalidParams { message: String },
    /// Origin `mcp` may not change this key (or any non-schema path).
    AgentRefused { key: String, reason: Option<String> },
    /// The idempotency key was used for a different op or params.
    /// `committed_operation` is the operation the key committed (`settings.set`, ...).
    IdempotencyConflict { idempotency_key: String, committed_operation: String },
    /// `if_revision` does not match the owner's revision.
    RevisionConflict { expected: u64, actual: u64 },
    /// cmux.json is not valid JSONC (or its root is not an object); writing
    /// would lose what the user wrote.
    FileUnreadable { message: String },
    /// The atomic publish failed.
    Io { message: String },
}

impl Refusal {
    /// The wire error code.
    pub fn code(&self) -> &'static str {
        match self {
            Refusal::Managed { .. } => "managed",
            Refusal::InvalidValue { .. } | Refusal::InvalidParams { .. } => "invalid_params",
            Refusal::Removed { .. } => "removed",
            Refusal::AgentRefused { .. } => "agent_refused",
            Refusal::IdempotencyConflict { .. } => "idempotency_conflict",
            Refusal::RevisionConflict { .. } => "revision_conflict",
            Refusal::FileUnreadable { .. } => "file_unreadable",
            Refusal::Io { .. } => "io_error",
        }
    }

    /// Structured details for the wire error's `data`.
    pub fn data(&self) -> Value {
        match self {
            Refusal::Managed { key, source } => {
                json!({"key": key, "source": source.wire_name(), "team": source.team_name(), "reason": source.reason(key)})
            }
            Refusal::InvalidValue { key, kind, accepted, value } => {
                json!({"key": key, "kind": kind, "accepted": accepted.to_json(), "value": value})
            }
            Refusal::Removed { key, reason } => json!({"key": key, "reason": reason}),
            Refusal::InvalidParams { .. } => Value::Null,
            Refusal::AgentRefused { key, reason } => json!({"key": key, "reason": reason}),
            Refusal::IdempotencyConflict { idempotency_key, committed_operation } => {
                json!({"idempotency_key": idempotency_key, "committed_operation": committed_operation})
            }
            Refusal::RevisionConflict { expected, actual } => {
                json!({"expected": expected, "actual": actual})
            }
            Refusal::FileUnreadable { .. } | Refusal::Io { .. } => Value::Null,
        }
    }

    /// `{code, message, data}`.
    pub fn to_json(&self) -> Value {
        json!({"code": self.code(), "message": self.to_string(), "data": self.data()})
    }
}

impl fmt::Display for Refusal {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Refusal::Managed { key, source } => f.write_str(&source.reason(key)),
            Refusal::InvalidValue { key, value, .. } => {
                write!(f, "{key} does not accept {}", compact(value))
            }
            Refusal::Removed { key, reason } => write!(f, "{key} was removed: {reason}"),
            Refusal::InvalidParams { message } => f.write_str(message),
            Refusal::AgentRefused { key, reason } => match reason {
                Some(reason) => write!(f, "agents may not change {key} ({reason})"),
                None => write!(f, "agents may not change {key}: it is not a setting"),
            },
            Refusal::IdempotencyConflict { idempotency_key, .. } => {
                write!(f, "idempotency key {idempotency_key} was used for a different request")
            }
            Refusal::RevisionConflict { expected, actual } => {
                write!(f, "settings changed: expected revision {expected}, now {actual}")
            }
            Refusal::FileUnreadable { message } => {
                write!(f, "cmux.json is not valid JSONC: {message}")
            }
            Refusal::Io { message } => write!(f, "could not write cmux.json: {message}"),
        }
    }
}

impl std::error::Error for Refusal {}
