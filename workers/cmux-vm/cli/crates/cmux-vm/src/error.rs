//! Maps client failures to a message and an exit code (see [`crate::exit`]).

use std::io::Write;

use cmux_vm_client::{ByteStream, Error};
use futures::StreamExt;
use serde_json::{Value, json};

use crate::exit;

/// Error bodies larger than this are cut; the CLI only shows a message.
const MAX_ERROR_BODY: usize = 64 * 1024;

#[derive(Debug)]
pub struct CliError {
    code: i32,
    status: Option<u16>,
    tag: Option<String>,
    message: String,
}

impl CliError {
    pub fn usage(message: impl Into<String>) -> Self {
        Self::local(exit::USAGE, message)
    }

    pub fn unexpected(message: impl Into<String>) -> Self {
        Self::local(exit::UNEXPECTED, message)
    }

    pub fn unauthenticated(message: impl Into<String>) -> Self {
        Self::local(exit::UNAUTHENTICATED, message)
    }

    fn local(code: i32, message: impl Into<String>) -> Self {
        Self {
            code,
            status: None,
            tag: None,
            message: message.into(),
        }
    }

    pub fn exit_code(&self) -> i32 {
        self.code
    }

    pub async fn from_api(error: Error<ByteStream>) -> Self {
        match error {
            Error::ErrorResponse(response) => {
                let status = response.status().as_u16();
                let body = read_stream(response.into_inner()).await;
                Self::from_status(status, &body)
            }
            Error::UnexpectedResponse(response) => {
                let status = response.status().as_u16();
                let body = response
                    .bytes()
                    .await
                    .map(|b| b.to_vec())
                    .unwrap_or_default();
                Self::from_status(status, &body[..body.len().min(MAX_ERROR_BODY)])
            }
            Error::CommunicationError(e) | Error::ResponseBodyError(e) => Self::local(
                exit::NETWORK,
                format!("could not reach the cmux VM API: {e}"),
            ),
            Error::InvalidRequest(message) => Self::usage(message),
            Error::InvalidResponsePayload(_, e) => Self::local(
                exit::UNEXPECTED,
                format!("the cmux VM API sent a response this CLI cannot read: {e}"),
            ),
            other => Self::local(exit::UNEXPECTED, other.to_string()),
        }
    }

    fn from_status(status: u16, body: &[u8]) -> Self {
        let parsed: Option<Value> = serde_json::from_slice(body).ok();
        let field = |name: &str| {
            parsed
                .as_ref()
                .and_then(|v| v.get(name))
                .and_then(Value::as_str)
                .map(str::to_owned)
        };
        let tag = field("_tag");
        let server_message = field("message");
        let code = match status {
            400 => exit::BAD_REQUEST,
            401 => exit::UNAUTHENTICATED,
            402 => exit::PAYMENT_REQUIRED,
            403 => exit::FORBIDDEN,
            404 => exit::NOT_FOUND,
            409 => exit::CONFLICT,
            429 => exit::QUOTA_EXCEEDED,
            501 => exit::NOT_AVAILABLE_YET,
            503 => exit::SERVICE_UNAVAILABLE,
            _ => exit::UNEXPECTED,
        };
        let fallback = match status {
            400 => "the request was rejected as invalid",
            401 => "not authenticated: check the API key",
            402 => "the team's plan does not include this",
            403 => "this credential lacks the required scope",
            404 => "not found",
            409 => "the resource's current state does not allow this",
            429 => "a quota or rate limit was reached",
            501 => "this operation is not available yet",
            503 => "the cmux VM service is temporarily unavailable",
            _ => "the cmux VM API returned an error",
        };
        let mut message = server_message.unwrap_or_else(|| fallback.to_owned());
        if status == 501 && !message.contains("not available yet") {
            message = format!("not available yet: {message}");
        }
        Self {
            code,
            status: Some(status),
            tag,
            message,
        }
    }

    pub fn report(&self, json: bool, stderr: &mut dyn Write) {
        let _ = if json {
            let body = json!({
                "error": {
                    "status": self.status,
                    "tag": self.tag,
                    "message": self.message,
                    "exitCode": self.code,
                }
            });
            writeln!(stderr, "{body}")
        } else {
            match (self.status, &self.tag) {
                (Some(status), Some(tag)) => {
                    writeln!(stderr, "cmux-vm: {} (HTTP {status} {tag})", self.message)
                }
                (Some(status), None) => {
                    writeln!(stderr, "cmux-vm: {} (HTTP {status})", self.message)
                }
                _ => writeln!(stderr, "cmux-vm: {}", self.message),
            }
        };
    }
}

async fn read_stream(stream: ByteStream) -> Vec<u8> {
    let mut stream = stream.into_inner();
    let mut body = Vec::new();
    while let Some(Ok(chunk)) = stream.next().await {
        let room = MAX_ERROR_BODY.saturating_sub(body.len());
        body.extend_from_slice(&chunk[..chunk.len().min(room)]);
        if body.len() >= MAX_ERROR_BODY {
            break;
        }
    }
    body
}
