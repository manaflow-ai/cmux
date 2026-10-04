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

/// TRANSITIONAL: one call to a classic Cloud API route. Only the attach
/// endpoint, the scp endpoint and the file routes use it (`link/`, `fs/`),
/// until the link slice moves them onto `cloud.machine.connect_info` and the
/// daemon link (contract 2.2a). No catalog op of this server's own groups
/// uses it.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct HttpCall {
    /// The catalog op that makes the call (for the host's audit and scope check).
    pub op: String,
    pub method: &'static str,
    /// Path and query under the classic Cloud API origin.
    pub path: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub body: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub idempotency_key: Option<String>,
}

/// TRANSITIONAL: the answer to an [`HttpCall`].
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

    /// TRANSITIONAL: one classic route call (see [`HttpCall`]). A control
    /// plane without the classic channel answers 501, which the server
    /// reports as `cmux.cloud.unsupported`.
    fn classic(&mut self, call: &HttpCall) -> Result<HttpReply, RelayError> {
        Ok(HttpReply {
            status: 501,
            body: serde_json::json!({
                "error": "classic_route_unavailable",
                "message": format!("{} needs a classic Cloud route this backend does not serve", call.op),
            }),
            error_code: None,
        })
    }
}
