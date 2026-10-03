//! The idempotency key a mutation carries: 1 to 128 UTF-8 bytes with at
//! least one non-whitespace scalar and no control characters.

use super::{MAX_IDEMPOTENCY_KEY_BYTES, ResourceError};

pub fn validate_idempotency_key(value: &str) -> Result<(), ResourceError> {
    if value.trim().is_empty() {
        return Err(ResourceError::validation_invalid(
            Some("idempotency_key"),
            "idempotency_key must contain at least one non-whitespace Unicode scalar",
        ));
    }
    if value.len() > MAX_IDEMPOTENCY_KEY_BYTES {
        return Err(ResourceError::validation_invalid(
            Some("idempotency_key"),
            "idempotency_key must contain 1 to 128 UTF-8 bytes",
        ));
    }
    if value.chars().any(char::is_control) {
        return Err(ResourceError::validation_invalid(
            Some("idempotency_key"),
            "idempotency_key must not contain Unicode control characters",
        ));
    }
    Ok(())
}
