//! The boundary to the cmux Cloud API (L1, `web/app/api/vm`).
//!
//! The server never holds the Stack bearer (cloud-app.md 3.2). It describes
//! each HTTP call; the host credential relay adds the sign-in and the team
//! header, sends it and returns the status and JSON body. Tests use a fake
//! that serves recorded responses.

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// One `cmux.wire/1` op call, without any credential: the host sends it to
/// `POST /v1/read` (no key) or `POST /v1/ops` and adds the install token.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct WireCall {
    pub op: String,
    pub params: Value,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub idempotency_key: Option<String>,
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

/// One Cloud API call, without any credential.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct HttpCall {
    /// The catalog op that makes the call (for the host's audit and scope check).
    pub op: String,
    pub method: &'static str,
    /// Path and query under the Cloud API origin, for example `/api/vm/vm-1/pause`.
    pub path: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub body: Option<Value>,
    /// Sent as `Idempotency-Key`; the Cloud API dedups create, restore and fork.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub idempotency_key: Option<String>,
}

/// The Cloud API answer.
#[derive(Debug, Clone, PartialEq)]
pub struct HttpReply {
    pub status: u16,
    pub body: Value,
    /// The `x-cmux-vm-error` header, when present.
    pub error_code: Option<String>,
}

/// The sign-in state the host reports. Never a token.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionStatus {
    pub signed_in: bool,
    pub team: Option<String>,
}

/// Why the relay could not make the call at all.
#[derive(Debug, Clone, PartialEq)]
pub enum RelayError {
    /// The host has no Cloud sign-in.
    NotSignedIn,
    /// The host or the network did not answer.
    Unavailable(String),
}

/// Sends Cloud API calls through the host. Single-threaded: the server's op
/// loop is the only caller.
pub trait ControlPlane {
    fn call(&mut self, call: &HttpCall) -> Result<HttpReply, RelayError>;
    fn session(&mut self) -> Result<SessionStatus, RelayError>;
    /// RED scaffolding: the wire call the server does not make yet.
    fn wire(&mut self, _call: &WireCall) -> Result<WireReply, RelayError> {
        Err(RelayError::Unavailable("wire calls are not wired yet".into()))
    }
}
