//! The error body every `err` envelope carries, and the protocol-level codes
//! any peer may return for any op.

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Session-level codes are `cmux.protocol.*` (TS lane wire decision 6);
/// op-level codes come from the IR (`<ns>.<code>`).
///
/// The transport closed before the call finished (retryable).
pub const CLOSED: &str = "cmux.protocol.closed";
/// The caller cancelled the call.
pub const CANCELLED: &str = "cmux.protocol.cancelled";
/// No handler for this op, or the op is not in the IR.
pub const UNKNOWN_OP: &str = "cmux.protocol.unknown_op";
/// No event source for this stream name, or it is not in the IR.
pub const UNKNOWN_STREAM: &str = "cmux.protocol.unknown_stream";
/// Params fail the op's schema.
pub const INVALID_PARAMS: &str = "cmux.protocol.invalid_params";
/// A result fails the op's schema.
pub const INVALID_RESULT: &str = "cmux.protocol.invalid_result";
/// Event data fails the event's schema.
pub const INVALID_EVENT: &str = "cmux.protocol.invalid_event";
/// The handler failed in a way that is not one of the op's declared errors.
pub const INTERNAL: &str = "cmux.protocol.internal";
/// The peer sent stream bytes beyond its credit.
pub const CREDIT_EXCEEDED: &str = "cmux.protocol.credit_exceeded";
/// A byte stream was aborted, or its id is not usable (wrong parity, in use).
pub const STREAM_ABORTED: &str = "cmux.protocol.stream_aborted";
/// The `auth` frame was missing or its token was refused; sent as
/// `{"t":"err","id":0,...}` before any other message, then the connection
/// closes (WebSocket close code [`AUTH_REFUSED_CLOSE_CODE`]).
pub const AUTH_REFUSED: &str = "cmux.protocol.auth_refused";
/// The session's token expired; refresh it and reconnect (retryable).
pub const TOKEN_EXPIRED: &str = "cmux.protocol.token_expired";
/// The token is valid but does not grant this op's namespace or scope.
pub const FORBIDDEN: &str = "cmux.protocol.forbidden";
/// A malformed envelope or frame, or an id outside 1..=2^53-1.
pub const BAD_MESSAGE: &str = "cmux.protocol.bad_message";
/// The provider is overloaded; retry later.
pub const BUSY: &str = "cmux.protocol.busy";
/// The router answers only control-plane ops; it never relays data-plane traffic.
pub const NOT_ROUTED: &str = "cmux.protocol.not_routed";
/// A message was larger than the 16 MiB limit.
pub const TOO_LARGE: &str = "cmux.protocol.too_large";

/// WebSocket close code after an auth refusal (application range).
pub const AUTH_REFUSED_CLOSE_CODE: u16 = 4001;

/// The payload of an `err` envelope.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ErrorBody {
    /// `<namespace>.<code>`.
    pub code: String,
    pub message: String,
    pub retryable: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub details: Option<serde_json::Map<String, Value>>,
}

impl ErrorBody {
    pub fn new(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self { code: code.into(), message: message.into(), retryable: false, details: None }
    }

    pub fn retryable(mut self) -> Self {
        self.retryable = true;
        self
    }

    /// Attach details; a non-object value is wrapped as `{"value": ...}`.
    pub fn with_details(mut self, details: Value) -> Self {
        self.details = Some(match details {
            Value::Object(map) => map,
            other => serde_json::Map::from_iter([("value".to_owned(), other)]),
        });
        self
    }
}

impl std::fmt::Display for ErrorBody {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "{}: {}", self.code, self.message)
    }
}

impl std::error::Error for ErrorBody {}
