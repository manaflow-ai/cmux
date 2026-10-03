//! The JSON-lines protocol of the Tasks socket (plans/cmux-next/tasks.md
//! section 5). One JSON object per line in each direction.
//!
//! Client -> owner: `{"hello": {"credential"?}}` (optional, first line),
//! then requests `{"id", "op", "params", "key"?, "origin"?, "credential"?}`.
//! The owner stamps the actor from the credential (identity.rs); a caller
//! never states it.
//! Owner -> client: `{"id", "ok": result}` or `{"id", "err": {code, message}}`,
//! then `{"settled": {"id", "tx", "seq"}}` for every request;
//! on a subscription: one `{"snapshot": …}` (when `after_seq` is absent), then
//! `{"event": Event}` lines in sequence order.

use cmux_tasks_core::{Event, Origin};
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Request {
    pub id: u64,
    pub op: String,
    #[serde(default)]
    pub params: Value,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub key: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub origin: Option<Origin>,
    /// The lease epoch the router sent this request under (server.md 7.2).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub epoch: Option<u64>,
    /// The caller's launch credential (`CMUX_LAUNCH_CREDENTIAL`); overrides
    /// the hello's for this request. Never logged or echoed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub credential: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorCode {
    NotFound,
    Invalid,
    Conflict,
    IdempotencyConflict,
    Forbidden,
    /// The launch credential is bad, from another host, or names a closed
    /// terminal or ACP session (identity.md section 3).
    CredentialInvalid,
    /// Bad request shape (unknown op, missing key, bad params).
    Usage,
    /// The subscription asked for events older than the owner still holds.
    Resync,
    OwnerUnreachable,
    /// The request's lease epoch is not this owner's: the owner moved.
    OwnerMoved,
    /// A client-side deadline passed (bounded waits).
    Timeout,
    Internal,
}

impl ErrorCode {
    pub fn exit_code(&self) -> u8 {
        match self {
            Self::Usage => 2,
            Self::NotFound => 3,
            Self::Invalid
            | Self::Conflict
            | Self::Forbidden
            | Self::CredentialInvalid
            | Self::Resync => 4,
            Self::OwnerUnreachable | Self::OwnerMoved | Self::Timeout => 5,
            Self::IdempotencyConflict => 6,
            Self::Internal => 1,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ErrorBody {
    pub code: ErrorCode,
    pub message: String,
}

impl ErrorBody {
    pub fn new(code: ErrorCode, message: impl Into<String>) -> Self {
        Self { code, message: message.into() }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Settled {
    pub id: u64,
    /// The request's idempotency key, when it had one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tx: Option<String>,
    /// The owner's last committed sequence after this request.
    pub seq: u64,
}

// One line per value, serialized at once; boxing would only add noise.
#[allow(clippy::large_enum_variant)]
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum ServerLine {
    Ok { id: u64, ok: Value },
    Err { id: u64, err: ErrorBody },
    Settled { settled: Settled },
    Snapshot { snapshot: Value },
    Event { event: Event },
}

/// The optional first line. A caller never states its actor (P8): a hello
/// with any other field, `actor` included, is refused.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Hello {
    /// The default launch credential for this connection's requests.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub credential: Option<String>,
}
