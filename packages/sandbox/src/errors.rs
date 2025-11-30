use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;
use serde::Serialize;
use thiserror::Error;
use utoipa::ToSchema;
use uuid::Uuid;

#[derive(Debug, Error)]
pub enum SandboxError {
    #[error("sandbox {0} not found")]
    NotFound(Uuid),
    #[error("required binary '{0}' not found in PATH")]
    MissingBinary(String),
    #[error("command '{command}' failed: {message}")]
    CommandFailed { command: String, message: String },
    #[error("unable to allocate additional sandbox addresses")]
    IpPoolExhausted,
    #[error("invalid request: {0}")]
    InvalidRequest(String),
    #[error("process failed to start")]
    ProcessNotStarted,
    #[error("internal error: {0}")]
    Internal(String),
    #[error(transparent)]
    Io(#[from] std::io::Error),
}

#[derive(Debug, Serialize, ToSchema)]
pub struct ErrorBody {
    pub code: String,
    pub message: String,
}

impl IntoResponse for SandboxError {
    fn into_response(self) -> Response {
        let status = match self {
            SandboxError::NotFound(_) => StatusCode::NOT_FOUND,
            SandboxError::MissingBinary(_) => StatusCode::SERVICE_UNAVAILABLE,
            SandboxError::CommandFailed { .. } => StatusCode::BAD_GATEWAY,
            SandboxError::IpPoolExhausted => StatusCode::INSUFFICIENT_STORAGE,
            SandboxError::InvalidRequest(_) => StatusCode::BAD_REQUEST,
            SandboxError::ProcessNotStarted => StatusCode::INTERNAL_SERVER_ERROR,
            SandboxError::Internal(_) => StatusCode::INTERNAL_SERVER_ERROR,
            SandboxError::Io(_) => StatusCode::INTERNAL_SERVER_ERROR,
        };

        let code = match status.as_u16() {
            400 => "bad_request",
            404 => "not_found",
            500 => "internal_error",
            507 => "ip_pool_exhausted",
            502 => "command_failed",
            503 => "missing_dependency",
            _ => "error",
        }
        .to_string();

        let body = ErrorBody {
            code,
            message: self.to_string(),
        };

        (status, Json(body)).into_response()
    }
}

pub type SandboxResult<T> = Result<T, SandboxError>;
