//! The `cmux.wire/1` HTTP envelope (`OpRequest`, `OpResponse`,
//! `ReadResponse`, `OpError` in backend/packages/protocol/src/api.ts, and the
//! HTTP error body `{_tag, code, message}`), typed by the op.

use crate::{Op, WireError};
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Who started a mutation (`Origin` in backend/packages/protocol/src/schemas.ts).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Origin {
    User,
    Cli,
    Mcp,
    Script,
    Remote,
}

/// The request body of an op (`POST` to [`crate::WireClass::http_path`]).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct OpRequest<P> {
    pub op: String,
    pub params: P,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub idempotency_key: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub origin: Option<Origin>,
    /// Optimistic concurrency: the owner's revision the caller last saw.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expected_revision: Option<String>,
}

impl<P> OpRequest<P> {
    /// A request for `O` with no key, origin or revision precondition.
    pub fn new<O: Op<Params = P>>(params: P) -> Self {
        Self {
            op: O::NAME.to_owned(),
            params,
            idempotency_key: None,
            origin: None,
            expected_revision: None,
        }
    }

    pub fn with_idempotency_key(mut self, key: impl Into<String>) -> Self {
        self.idempotency_key = Some(key.into());
        self
    }

    pub fn with_origin(mut self, origin: Origin) -> Self {
        self.origin = Some(origin);
        self
    }

    pub fn with_expected_revision(mut self, revision: impl Into<String>) -> Self {
        self.expected_revision = Some(revision.into());
        self
    }
}

/// The answer of a read (HTTP 200 from `/v1/read`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ReadResponse<T> {
    pub op: String,
    pub value: T,
    pub stream: String,
    /// Decimal string: the owner's event sequence of this answer.
    pub revision: String,
}

/// One op error (`OpError`): a declared code of the op.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(bound(serialize = "E: WireError", deserialize = "E: WireError"))]
pub struct OpError<E> {
    #[serde(
        serialize_with = "crate::op::serialize_error",
        deserialize_with = "crate::op::deserialize_error"
    )]
    pub code: E,
    pub message: String,
    #[serde(default, skip_serializing_if = "Option::is_none", with = "crate::value::present")]
    pub details: Option<Value>,
    pub retryable: bool,
}

/// The answer of a mutation (HTTP 200 from `/v1/ops`): `value` when `ok`,
/// `error` otherwise, always with the settle (write barrier). `value`,
/// `revision`, `transaction` and `replayed` are the catalog's
/// `MutationResult<T>` generic (the generator refuses a catalog whose generic
/// has other fields); an op without idempotency answers no `revision`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(bound(
    serialize = "T: Serialize, E: WireError",
    deserialize = "T: Deserialize<'de>, E: WireError"
))]
pub struct OpResponse<T, E> {
    pub ok: bool,
    pub op: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub value: Option<T>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<OpError<E>>,
    pub transaction: String,
    pub idempotency_key: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub revision: Option<String>,
    pub replayed: bool,
    pub stream: String,
    pub sequence: i64,
}

/// The HTTP error body of a refused request (a non-200 status).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(bound(serialize = "E: WireError", deserialize = "E: WireError"))]
pub struct HttpError<E> {
    #[serde(rename = "_tag")]
    pub tag: String,
    #[serde(
        serialize_with = "crate::op::serialize_error",
        deserialize_with = "crate::op::deserialize_error"
    )]
    pub code: E,
    pub message: String,
}
