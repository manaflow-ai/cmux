//! One reading of every Cloud refusal. cmux-platform's errors are Effect
//! tagged errors (`{"_tag": "MachineConflict", "code": "...", "message":
//! "..."}`); the generated client keeps each one as a byte stream (the
//! generator's normalization), and a proxy may answer with HTML. [`ApiError`]
//! keeps the status, the tag, the code and the message, whatever came back.

use futures::StreamExt;
use serde_json::Value;

use crate::{ByteStream, Error};

/// The most of an error body that is read.
const MAX_ERROR_BODY: usize = 64 * 1024;

/// A refused or failed Cloud call.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ApiError {
    /// The HTTP status, when an answer came back.
    pub status: Option<u16>,
    /// The error's `_tag` (`MachineConflict`, ...), when the body had one.
    pub tag: Option<String>,
    /// The error's `code` (`machine.revoked`, ...), when the body had one.
    pub code: Option<String>,
    /// A message for a person: the body's `message`, or what went wrong.
    pub message: String,
    /// Whether the same call (with the same idempotency key) may succeed if
    /// sent again: no answer, a 429, a 503, or a 502/504 from a proxy.
    pub retryable: bool,
}

impl std::fmt::Display for ApiError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match (self.status, &self.code) {
            (Some(status), Some(code)) => write!(f, "HTTP {status} {code}: {}", self.message),
            (Some(status), None) => write!(f, "HTTP {status}: {}", self.message),
            (None, _) => f.write_str(&self.message),
        }
    }
}

impl std::error::Error for ApiError {}

impl ApiError {
    /// Reads an answer with `status` and `body`.
    pub fn from_status(status: u16, body: &[u8]) -> Self {
        let parsed: Option<Value> = serde_json::from_slice(body).ok();
        let field = |name: &str| {
            parsed
                .as_ref()
                .and_then(|v| v.get(name).or_else(|| v.pointer(&format!("/error/{name}"))))
                .and_then(Value::as_str)
                .filter(|s| !s.is_empty())
                .map(str::to_owned)
        };
        let message = field("message").unwrap_or_else(|| {
            let text = String::from_utf8_lossy(body);
            let text = text.trim();
            if text.is_empty() || text.starts_with('<') {
                format!("the Cloud API answered HTTP {status}")
            } else {
                text.chars().take(500).collect()
            }
        });
        Self {
            status: Some(status),
            tag: field("_tag"),
            code: field("code"),
            message,
            retryable: matches!(status, 429 | 502 | 503 | 504),
        }
    }

    /// A call that never got an answer (no route, a reset, a timeout).
    pub fn unreachable(error: &reqwest::Error) -> Self {
        Self {
            status: None,
            tag: None,
            code: None,
            message: format!("could not reach the Cloud API: {error}"),
            retryable: true,
        }
    }

    /// An answer this build cannot read.
    pub fn unreadable(what: impl std::fmt::Display) -> Self {
        Self {
            status: None,
            tag: None,
            code: Some("cloud.client.unreadable".to_owned()),
            message: format!("the Cloud API sent an answer this cmux cannot read: {what}"),
            retryable: false,
        }
    }

    /// Reads a generated method's error.
    pub async fn from_api(error: Error<ByteStream>) -> Self {
        match error {
            Error::ErrorResponse(response) => {
                let status = response.status().as_u16();
                let mut stream = response.into_inner().into_inner();
                let mut body = Vec::new();
                while body.len() < MAX_ERROR_BODY {
                    match stream.next().await {
                        Some(Ok(chunk)) => append_capped(&mut body, &chunk),
                        _ => break,
                    }
                }
                Self::from_status(status, &body)
            }
            Error::UnexpectedResponse(mut response) => {
                let status = response.status().as_u16();
                let mut body = Vec::new();
                while body.len() < MAX_ERROR_BODY {
                    match response.chunk().await {
                        Ok(Some(chunk)) => append_capped(&mut body, &chunk),
                        _ => break,
                    }
                }
                Self::from_status(status, &body)
            }
            Error::CommunicationError(e) | Error::ResponseBodyError(e) => Self::unreachable(&e),
            Error::InvalidResponsePayload(_, e) => Self::unreadable(e),
            other => Self::unreadable(other),
        }
    }
}

fn append_capped(body: &mut Vec<u8>, chunk: &[u8]) {
    let room = MAX_ERROR_BODY.saturating_sub(body.len());
    body.extend_from_slice(chunk.get(..room).unwrap_or(chunk));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_tagged_platform_error_keeps_its_tag_code_and_message() {
        let e = ApiError::from_status(
            409,
            br#"{"_tag":"MachineConflict","code":"machine.capacity","message":"no room"}"#,
        );
        assert_eq!(e.tag.as_deref(), Some("MachineConflict"));
        assert_eq!(e.code.as_deref(), Some("machine.capacity"));
        assert_eq!(e.message, "no room");
        assert!(!e.retryable);
        assert_eq!(e.to_string(), "HTTP 409 machine.capacity: no room");
    }

    #[test]
    fn a_wire_error_body_reads_the_same_way() {
        let e = ApiError::from_status(
            503,
            br#"{"error":{"code":"cloud.provider.unavailable","message":"later"}}"#,
        );
        assert_eq!(e.code.as_deref(), Some("cloud.provider.unavailable"));
        assert!(e.retryable);
    }

    #[test]
    fn an_html_proxy_page_is_not_shown_as_the_message() {
        let e = ApiError::from_status(502, b"<html>bad gateway</html>");
        assert_eq!(e.message, "the Cloud API answered HTTP 502");
        assert!(e.retryable);
        assert_eq!(e.code, None);
    }
}
