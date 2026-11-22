//! Remote request errors for tests (moved out of session/mod.rs, behavior unchanged).

use super::*;

pub(crate) fn test_remote_timeout_error() -> anyhow::Error {
    remote::RemoteRequestError::Timeout.into()
}

pub(crate) fn test_remote_transport_error() -> anyhow::Error {
    remote::RemoteRequestError::Transport(std::io::Error::new(
        std::io::ErrorKind::BrokenPipe,
        "socket closed",
    ))
    .into()
}

pub(crate) fn test_remote_rejected_error() -> anyhow::Error {
    test_remote_rejected_error_with_message("unknown surface")
}

pub(crate) fn test_remote_rejected_error_with_message(message: &str) -> anyhow::Error {
    remote::RemoteRequestError::Rejected { error: message.to_string(), code: None, delivery: None }
        .into()
}

pub(crate) fn test_remote_rejected_error_with_code(message: &str, code: &str) -> anyhow::Error {
    remote::RemoteRequestError::Rejected {
        error: message.to_string(),
        code: Some(code.to_string()),
        delivery: None,
    }
    .into()
}
