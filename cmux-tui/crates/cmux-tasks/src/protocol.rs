//! The JSON-lines protocol of the Tasks socket (plans/cmux-next/tasks.md
//! section 5). One JSON object per line in each direction.
//!
//! Client -> owner: `{"hello": {"actor": Principal}}` (optional, first line),
//! then requests `{"id", "op", "params", "key"?, "origin"?}`.
//! Owner -> client: `{"id", "ok": result}` or `{"id", "err": {code, message}}`,
//! then `{"settled": {"id", "tx", "seq"}}` for every request;
//! on a subscription: one `{"snapshot": …}` (when `after_seq` is absent), then
//! `{"event": Event}` lines in sequence order.

use cmux_tasks_core::ids::Principal;
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
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorCode {
    NotFound,
    Invalid,
    Conflict,
    IdempotencyConflict,
    Forbidden,
    /// Bad request shape (unknown op, missing key, bad params).
    Usage,
    /// The subscription asked for events older than the owner still holds.
    Resync,
    OwnerUnreachable,
    /// A client-side deadline passed (bounded waits).
    Timeout,
    Internal,
}

impl ErrorCode {
    pub fn exit_code(&self) -> u8 {
        match self {
            Self::Usage => 2,
            Self::NotFound => 3,
            Self::Invalid | Self::Conflict | Self::Forbidden | Self::Resync => 4,
            Self::OwnerUnreachable | Self::Timeout => 5,
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

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Hello {
    pub actor: Principal,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum ClientLine {
    Hello { hello: Hello },
    Request(Request),
}
