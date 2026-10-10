//! Remote request errors for tests (moved out of session/mod.rs, behavior unchanged).

use super::*;

pub(crate) fn test_remote_timeout_error() -> anyhow::Error {
    remote::RemoteRequestError::Timeout.into()
}
