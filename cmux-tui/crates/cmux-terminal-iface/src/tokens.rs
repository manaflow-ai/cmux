//! Bearer values: `Debug` hides them so they never reach a log.

use std::fmt;

use crate::error::BackendError;

/// `open_token`: issued by the host for one open, resume or connect after
/// the user's gesture. An implementation passes it on and never mints it.
/// The host checks expiry, reuse and the app it was issued to; an
/// implementation can only check presence ([`OpenToken::check`]).
#[derive(Clone, PartialEq, Eq, serde::Deserialize, serde::Serialize)]
#[serde(transparent)]
pub struct OpenToken(pub String);

impl OpenToken {
    /// The token is present: not empty and not only spaces.
    pub fn check(&self) -> Result<(), BackendError> {
        if self.0.trim().is_empty() {
            return Err(BackendError::invalid(
                "open_token is missing: cmux issues one for each open",
            ));
        }
        Ok(())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Debug for OpenToken {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("OpenToken(..)")
    }
}

/// A backend's bearer credential for one terminal session (capability `resume`).
#[derive(Clone, PartialEq, Eq, serde::Deserialize, serde::Serialize)]
#[serde(transparent)]
pub struct ResumeToken(pub String);

impl fmt::Debug for ResumeToken {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("ResumeToken(..)")
    }
}
