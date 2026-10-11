//! What a resource command prints when it cannot reach a working session,
//! and which daemon errors settle a mutation's outcome.

use std::io;
use std::path::Path;

use serde_json::Value;

/// The connect failure for `socket`, naming the command that fixes it.
pub(in crate::cli) fn connect_failure(socket: &Path, error: &io::Error) -> String {
    crate::localization::catalog().cli_connection.connect_failed(
        &socket.display().to_string(),
        error.kind() == io::ErrorKind::NotFound,
        error.kind() == io::ErrorKind::ConnectionRefused,
        &error.to_string(),
    )
}

/// A read that timed out: the socket accepted but nothing answered.
pub(super) fn is_no_answer(error: &io::Error) -> bool {
    matches!(error.kind(), io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut)
}

pub(super) fn no_answer() -> &'static str {
    crate::localization::catalog().cli_connection.no_answer()
}

/// A reply that is JSON but no cmux.protocol/2 envelope (an older cmux's
/// command protocol or another program).
pub(super) fn wrong_protocol() -> &'static str {
    crate::localization::catalog().cli_connection.wrong_protocol()
}

/// Whether a daemon error means the mutation did not apply, so there is no
/// outcome to retry with the idempotency key. Errors that can arrive after
/// part of the work ran (`operation.failed`, `mutation.indeterminate`,
/// `terminal_host.unavailable`, `local.io`, `transport.closed`) keep the note.
pub(super) fn settles_mutation(error: &Value) -> bool {
    let code = error.get("code").and_then(Value::as_str).unwrap_or_default();
    code.starts_with("selector.")
        || code.starts_with("cursor.")
        || code.starts_with("home.")
        || matches!(
            code,
            "validation.invalid"
                | "revision.conflict"
                | "idempotency.conflict"
                | "confirmation.required"
                | "creation.conflict"
                | "origin.forbidden"
                | "operation.unsupported"
                | "resource.not_found"
        )
}
