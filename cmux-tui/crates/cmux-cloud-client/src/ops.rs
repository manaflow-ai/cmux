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
/// row requires one, refused for one that forbids it.
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
        (WireIdempotency::Forbidden, Some(_)) => {
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
    let body = response.bytes().await.map_err(|e| ApiError::unreachable(&e))?;
    read_answer::<O>(status, &body)
}

/// Reads an op's HTTP answer (split out for tests).
pub fn read_answer<O: Op>(
    status: u16,
    body: &[u8],
) -> Result<Answer<O::Result, O::Error>, ApiError> {
    if status != 200 {
        let mut error = ApiError::from_status(status, body);
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
    /// The value, or the refusal as an [`ApiError`] (its code and message).
    pub fn into_result(self) -> Result<T, ApiError> {
        match self {
            Self::Value { value, .. } => Ok(value),
            Self::Refused(error) => Err(ApiError {
                status: Some(200),
                tag: None,
                code: Some(error.code.code().to_owned()),
                message: error.message,
                retryable: error.retryable,
            }),
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
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use cmux_cloud_wire::{CloudMachineDeleteOp, CloudMachineGetOp};

    #[test]
    fn a_refused_mutation_keeps_its_declared_code() {
        let body = br#"{"ok":false,"op":"cloud.machine.delete","error":{"code":"cloud.machine.not_found","message":"gone","retryable":false},"transaction":"t","idempotency_key":"ck_1","replayed":false,"stream":"s","sequence":3}"#;
        let answer = read_answer::<CloudMachineDeleteOp>(200, body).unwrap();
        let error = answer.into_result().unwrap_err();
        assert_eq!(error.code.as_deref(), Some("cloud.machine.not_found"));
        assert_eq!(error.message, "gone");
    }

    #[test]
    fn a_refused_request_reads_as_an_api_error() {
        let body = br#"{"_tag":"Unauthorized","code":"auth.required","message":"sign in"}"#;
        let error = read_answer::<CloudMachineGetOp>(401, body).unwrap_err();
        assert_eq!(error.status, Some(401));
        assert_eq!(error.code.as_deref(), Some("auth.required"));
    }

    #[tokio::test]
    async fn a_required_key_is_checked_before_sending() {
        crate::test_tls();
        let http = reqwest::Client::new();
        let params = serde_json::from_value(serde_json::json!({"machine": "vm_x"})).unwrap();
        let error = call::<CloudMachineDeleteOp>(&http, "http://127.0.0.1:9", params, None, None)
            .await
            .unwrap_err();
        assert_eq!(error.code.as_deref(), Some("cloud.client.usage"));
    }
}
