//! Process exit codes. Each documented API error status has its own code so
//! scripts can branch on the outcome without parsing output.

/// Success.
pub const OK: i32 = 0;
/// An error with no more specific code: an undocumented HTTP status or a
/// response the CLI could not read.
pub const UNEXPECTED: i32 = 1;
/// Invalid command-line usage or an argument the API would reject.
pub const USAGE: i32 = 2;
/// The API could not be reached (DNS, connection, TLS or timeout).
pub const NETWORK: i32 = 3;
/// A `delete` or `revoke` was not confirmed; nothing was changed.
pub const CANCELLED: i32 = 4;
/// HTTP 400: the request did not match the API schema.
pub const BAD_REQUEST: i32 = 10;
/// HTTP 401, or no API key configured.
pub const UNAUTHENTICATED: i32 = 11;
/// HTTP 402: the team's plan does not include this.
pub const PAYMENT_REQUIRED: i32 = 12;
/// HTTP 403: the credential lacks a scope.
pub const FORBIDDEN: i32 = 13;
/// HTTP 404: no such resource for this team.
pub const NOT_FOUND: i32 = 14;
/// HTTP 409: the resource's current state does not allow this.
pub const CONFLICT: i32 = 15;
/// HTTP 429: a quota or rate limit was reached.
pub const QUOTA_EXCEEDED: i32 = 16;
/// HTTP 501: the operation is part of the API but not available yet.
pub const NOT_AVAILABLE_YET: i32 = 17;
/// HTTP 503: the service is temporarily unavailable.
pub const SERVICE_UNAVAILABLE: i32 = 18;
/// HTTP 413: the request or the file is larger than the API accepts.
pub const PAYLOAD_TOO_LARGE: i32 = 19;
/// HTTP 426: a terminal endpoint was called without a WebSocket upgrade.
pub const UPGRADE_REQUIRED: i32 = 20;

/// The exit code for an HTTP error status. Statuses the API does not document
/// map to [`UNEXPECTED`]; a test checks that every status in openapi.json has
/// its own code.
pub fn for_status(status: u16) -> i32 {
    match status {
        400 => BAD_REQUEST,
        401 => UNAUTHENTICATED,
        402 => PAYMENT_REQUIRED,
        403 => FORBIDDEN,
        404 => NOT_FOUND,
        409 => CONFLICT,
        413 => PAYLOAD_TOO_LARGE,
        426 => UPGRADE_REQUIRED,
        429 => QUOTA_EXCEEDED,
        501 => NOT_AVAILABLE_YET,
        503 => SERVICE_UNAVAILABLE,
        _ => UNEXPECTED,
    }
}
