//! One reading of every Cloud refusal. cmux-platform's errors are Effect
//! tagged errors (`{"_tag": "MachineConflict", "code": "...", "message":
//! "..."}`); the generated client keeps each one as a byte stream (the
//! generator's normalization), and a proxy may answer with HTML. [`ApiError`]
//! keeps the status, the tag, the code and the message, whatever came back.

use cmux_cloud_machine::refusals;
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
    /// sent again: the body's own `retryable` (cmux-platform#1192 sends one on
    /// every refusal); with none, the platform's table for its code
    /// ([`cmux_cloud_machine::refusals`]); with neither, a 429, a 502, 503 or
    /// 504 from a proxy, or no answer at all.
    pub retryable: bool,
    /// How long a rate limit (429) asks to wait before the same call again:
    /// its `retryAfterSeconds` or Retry-After, else the platform's default.
    pub retry_after: Option<std::time::Duration>,
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
        Self::from_answer(status, None, body)
    }

    /// Reads an answer with `status`, its Retry-After header and `body`.
    pub fn from_answer(status: u16, retry_after: Option<&str>, body: &[u8]) -> Self {
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
        let code = field("code");
        let facts = refusals::Facts::read(parsed.as_ref(), retry_after);
        let handling = refusals::handling(status, code.as_deref(), facts.retryable);
        Self {
            status: Some(status),
            tag: field("_tag"),
            code,
            message,
            retryable: handling != refusals::Handling::Final,
            retry_after: (handling == refusals::Handling::RetryAfter)
                .then(|| std::time::Duration::from_secs(facts.wait_s())),
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
            retry_after: None,
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
            retry_after: None,
        }
    }

    /// Reads a generated method's error.
    pub async fn from_api(error: Error<ByteStream>) -> Self {
        match error {
            Error::ErrorResponse(response) => {
                let status = response.status().as_u16();
                let retry_after = retry_after_header(response.headers());
                let mut stream = response.into_inner().into_inner();
                let mut body = Vec::new();
                while body.len() < MAX_ERROR_BODY {
                    match stream.next().await {
                        Some(Ok(chunk)) => append_capped(&mut body, &chunk),
                        _ => break,
                    }
                }
                Self::from_answer(status, retry_after.as_deref(), &body)
            }
            Error::UnexpectedResponse(mut response) => {
                let status = response.status().as_u16();
                let retry_after = retry_after_header(response.headers());
                let mut body = Vec::new();
                while body.len() < MAX_ERROR_BODY {
                    match response.chunk().await {
                        Ok(Some(chunk)) => append_capped(&mut body, &chunk),
                        _ => break,
                    }
                }
                Self::from_answer(status, retry_after.as_deref(), &body)
            }
            Error::CommunicationError(e) | Error::ResponseBodyError(e) => Self::unreachable(&e),
            Error::InvalidResponsePayload(_, e) => Self::unreadable(e),
            other => Self::unreadable(other),
        }
    }
}

fn retry_after_header(headers: &reqwest::header::HeaderMap) -> Option<String> {
    headers.get(reqwest::header::RETRY_AFTER)?.to_str().ok().map(str::to_owned)
}

fn append_capped(body: &mut Vec<u8>, chunk: &[u8]) {
    let room = MAX_ERROR_BODY.saturating_sub(body.len());
    body.extend_from_slice(chunk.get(..room).unwrap_or(chunk));
}

#[cfg(test)]
mod tests;
