//! The boundary to the cmux-next Cloud backend (`cmux.wire/1`, owner
//! `cloud:CloudDO`; plans/cmux-next/cloud-client-contract.md 1.1).
//!
//! The server never holds a token. It describes each op as a [`WireCall`]
//! `{op, params, idempotency_key}`; the host adds the install token, sends
//! it to `POST /v1/read` (no key) or `POST /v1/ops`, and answers the wire
//! result or the typed wire error ([`WireReply`]). Tests use a fake that
//! serves the shared vectors (`backend/catalog/cloud-vectors.json`).

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// One `cmux.wire/1` op call, without any credential. Reads carry no key;
/// a mutation carries the caller's key, the same on every retry.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct WireCall {
    pub op: String,
    pub params: Value,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub idempotency_key: Option<String>,
    /// A mutation's origin (`OpRequest.origin`: user, cli, mcp, script,
    /// remote) as the app supervisor stamped it; the host forwards it.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub origin: Option<&'static str>,
}

/// A successful wire answer: the op's `value`, its owner revision, and
/// whether the owner replayed a stored result for the key.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct WireResult {
    pub value: Value,
    pub revision: Option<String>,
    pub replayed: bool,
}

/// A typed wire error (`cmux.wire/1` `OpError`).
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct WireError {
    pub code: String,
    pub message: String,
    #[serde(default)]
    pub details: Option<Value>,
    #[serde(default)]
    pub retryable: bool,
}

/// The answer to one [`WireCall`].
#[derive(Debug, Clone, PartialEq)]
pub enum WireReply {
    Result(WireResult),
    Error(WireError),
}

/// The sign-in state the host reports. Never a token.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionStatus {
    pub signed_in: bool,
    pub team: Option<String>,
}

/// Why the relay could not make the call at all, or lost its answer.
#[derive(Debug, Clone, PartialEq)]
pub enum RelayError {
    /// The host has no Cloud sign-in.
    NotSignedIn,
    /// The host or the network did not answer.
    Unavailable(String),
}

/// Sends Cloud calls through the host. Single-threaded: the server's op
/// loop is the only caller.
pub trait ControlPlane {
    /// One wire op.
    fn call(&mut self, call: &WireCall) -> Result<WireReply, RelayError>;

    fn session(&mut self) -> Result<SessionStatus, RelayError>;
}
