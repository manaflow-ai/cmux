//! The one retry rule for mutations (OWNERSHIP-PRINCIPLES invariant 5,
//! contract 1.1): when the outcome of a mutation is unknown, the caller
//! retries with the SAME idempotency key and never makes a new one.
//!
//! The outcome is unknown when the backend answers `mutation.indeterminate`
//! (a provider call cut off mid-flight) or when the relay lost the answer.
//! The server keeps the key's attempt open, so the retry reaches the
//! backend with the same key, and the backend's ledger row resumes the call
//! or answers the stored result. A delete needs nothing more: the backend's
//! tombstone answers `{deleted: true}` to the retry (and for 30 days).

use crate::api::{CloudError, codes};

/// True when `error` leaves the outcome unknown.
/// An undeclared backend code (`protocol_error`) also says nothing about
/// whether the call acted.
pub(super) fn indeterminate(error: &CloudError) -> bool {
    matches!(error.code, codes::INDETERMINATE | codes::RELAY_UNAVAILABLE | codes::PROTOCOL_ERROR)
}

/// The answer for an unknown outcome: retryable, and it says how.
pub(super) fn retry_with_same_key(name: &str, error: CloudError) -> CloudError {
    CloudError {
        retryable: true,
        message: format!("{}; retry {name} with the same idempotency key", error.message),
        ..error
    }
}
