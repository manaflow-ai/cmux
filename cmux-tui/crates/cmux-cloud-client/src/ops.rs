//! The `cmux.wire/1` ops (`POST /v1/read` for a read, `POST /v1/ops` for a
//! mutation), typed by `cmux-cloud-wire`'s op catalog. This is the half of the
//! contract `openapi.json` does not describe yet (cmux-platform#825): the
//! machine record's ops (`cloud.machine.create`, `cloud.machine.get`, ...).
//!
//! [`call`] sends one op and reads its answer into [`Answer`]: the value, or
//! the op's declared error, or an [`ApiError`] for a refused request. A
//! mutation whose catalog row requires an idempotency key gets one from the
//! caller ([`crate::client_key`]); the same key goes on every retry of the
//! same intent.

use cmux_cloud_wire::{
    HttpError, Op, OpError, OpRequest, OpResponse, Origin, ReadResponse, WireClass, WireError,
    WireIdempotency,
};

use cmux_cloud_machine::refusals;

use crate::ApiError;

/// An op's answer.
#[derive(Debug, Clone, PartialEq)]
pub enum Answer<T, E> {
    /// The op's value and the owner's revision after it.
    Value { value: T, revision: Option<String>, replayed: bool },
    /// The op refused with one of its declared codes (or a code this build
    /// does not know, kept verbatim).
    Refused(OpError<E>),
}

/// Sends `O` with `params` to `base_url` (`/v1/read` or `/v1/ops` by its
/// class). `key` is the idempotency key: required for an op whose catalog
/// row requires one, refused for a read and for a mutation that refuses keys
/// (`WireIdempotency::None`).
pub async fn call<O: Op>(
    http: &reqwest::Client,
    base_url: &str,
    params: O::Params,
    key: Option<&str>,
    origin: Option<Origin>,
) -> Result<Answer<O::Result, O::Error>, ApiError> {
    let mut request = OpRequest::new::<O>(params);
    match (O::IDEMPOTENCY, key) {
        (WireIdempotency::Required, None) => {
            return Err(local(format!("{} needs an idempotency key", O::NAME)));
        }
        (WireIdempotency::Forbidden | WireIdempotency::None, Some(_)) => {
            return Err(local(format!("{} takes no idempotency key", O::NAME)));
        }
        (_, Some(key)) if O::CLASS == WireClass::Mutation => {
            request = request.with_idempotency_key(key);
        }
        _ => {}
    }
    if let Some(origin) = origin {
        request = request.with_origin(origin);
    }
    let url = format!("{}{}", base_url.trim_end_matches('/'), O::CLASS.http_path());
    let response =
        http.post(url).json(&request).send().await.map_err(|e| ApiError::unreachable(&e))?;
    let status = response.status().as_u16();
    let retry_after = response
        .headers()
        .get(reqwest::header::RETRY_AFTER)
        .and_then(|value| value.to_str().ok())
        .map(str::to_owned);
    let body = response.bytes().await.map_err(|e| ApiError::unreachable(&e))?;
    read_answer::<O>(status, retry_after.as_deref(), &body)
}

/// Reads an op's HTTP answer (split out for tests): its status, its Retry-After header (a rate
/// limit's window when the body names none) and its body.
pub fn read_answer<O: Op>(
    status: u16,
    retry_after: Option<&str>,
    body: &[u8],
) -> Result<Answer<O::Result, O::Error>, ApiError> {
    if status != 200 {
        let mut error = ApiError::from_answer(status, retry_after, body);
        if let Ok(typed) = serde_json::from_slice::<HttpError<O::Error>>(body) {
            error.code = Some(typed.code.code().to_owned());
        }
        return Err(error);
    }
    match O::CLASS {
        WireClass::Read => {
            let read: ReadResponse<O::Result> =
                serde_json::from_slice(body).map_err(ApiError::unreadable)?;
            Ok(Answer::Value { value: read.value, revision: Some(read.revision), replayed: false })
        }
        WireClass::Mutation => {
            let answer: OpResponse<O::Result, O::Error> =
                serde_json::from_slice(body).map_err(ApiError::unreadable)?;
            match (answer.ok, answer.value, answer.error) {
                (true, Some(value), _) => Ok(Answer::Value {
                    value,
                    revision: answer.revision,
                    replayed: answer.replayed,
                }),
                (false, _, Some(error)) => Ok(Answer::Refused(error)),
                _ => Err(ApiError::unreadable(format!(
                    "{} answered ok={} with no value or error",
                    O::NAME,
                    answer.ok
                ))),
            }
        }
    }
}

impl<T, E: WireError> Answer<T, E> {
    /// The value, or the refusal as an [`ApiError`]: its code, message and `retryable`, and, for
    /// one that may be retried, the window its `details.retry_after_ms` asks for (a rate limit
    /// with none waits the platform's default).
    pub fn into_result(self) -> Result<T, ApiError> {
        match self {
            Self::Value { value, .. } => Ok(value),
            Self::Refused(error) => {
                let code = error.code.code().to_owned();
                let facts = refusals::Facts::read(
                    Some(&serde_json::json!({"details": error.details})),
                    None,
                );
                let rate_limit = refusals::platform(&code)
                    .is_some_and(|row| row.handling() == refusals::Handling::RetryAfter);
                let retry_after = (error.retryable
                    && (rate_limit || facts.retry_after_s.is_some()))
                .then(|| std::time::Duration::from_secs(facts.wait_s()));
                Err(ApiError {
                    status: Some(200),
                    tag: None,
                    code: Some(code),
                    message: error.message,
                    retryable: error.retryable,
                    retry_after,
                })
            }
        }
    }
}

fn local(message: String) -> ApiError {
    ApiError {
        status: None,
        tag: None,
        code: Some("cloud.client.usage".to_owned()),
        message,
        retryable: false,
        retry_after: None,
    }
}

#[cfg(test)]
mod tests;
