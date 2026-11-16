//! The owner's hand routes on the API Worker (backend hand-routes.ts), called
//! with the person's own session: the routes refuse an install token or a
//! Chief token. Ids are checked before a path is built; no redirect is
//! followed and nothing is retried. Answers `{ok: true, value}`.

use std::time::Duration;

use serde_json::{Value, json};

/// Each call's deadline.
// timeout: a Cloud call that never answers fails that call.
pub(super) const TIMEOUT: Duration = Duration::from_secs(20);

/// Why a call gave no value, as the app reads it (`kind`: `not_signed_in`,
/// `timed_out`, `transport`, `http`, `decoding`, `invalid`, `unknown_approval`).
#[derive(Debug, Clone, PartialEq)]
pub(super) struct Failure {
    pub(super) kind: &'static str,
    pub(super) status: Option<u16>,
    pub(super) code: Option<String>,
    pub(super) message: String,
}

impl Failure {
    pub(super) fn new(kind: &'static str, message: impl Into<String>) -> Self {
        Self { kind, status: None, code: None, message: message.into() }
    }

    pub(super) fn to_value(&self) -> Value {
        json!({ "kind": self.kind, "status": self.status, "code": self.code, "message": self.message })
    }

    pub(super) fn code_is(&self, code: &str) -> bool {
        self.code.as_deref() == Some(code)
    }
}

impl std::fmt::Display for Failure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match (self.status, &self.code) {
            (Some(status), code) => {
                write!(f, "HTTP {status} {} {}", code.as_deref().unwrap_or(""), self.message)
            }
            (None, _) => write!(f, "{}: {}", self.kind, self.message),
        }
    }
}

/// One call: `method` `path` on `api` with `credential` (none: signed out).
pub(super) async fn call(
    api: &str,
    credential: Option<&str>,
    method: reqwest::Method,
    path: &str,
    body: Option<Value>,
) -> Result<Value, Failure> {
    let Some(credential) = credential.filter(|c| !c.is_empty()) else {
        return Err(Failure::new("not_signed_in", "not signed in"));
    };
    let user_agent = concat!("cmux/", env!("CARGO_PKG_VERSION"));
    let (base, http) = cmux_cloud_client::http(api, Some(credential), None, user_agent, TIMEOUT)
        .map_err(|e| Failure::new("transport", e.to_string()))?;
    let mut request = http.request(method, format!("{base}{path}"));
    if let Some(body) = body {
        request = request.json(&body);
    }
    let response = request.send().await.map_err(|e| {
        if e.is_timeout() {
            Failure::new("timed_out", path.to_owned())
        } else {
            Failure::new("transport", e.without_url().to_string())
        }
    })?;
    let status = response.status().as_u16();
    let bytes = response
        .bytes()
        .await
        .map_err(|e| Failure::new("transport", e.without_url().to_string()))?;
    read(status, &bytes)
}

/// The value of a `{ok: true, value}` answer, else the refusal's code and message.
pub(super) fn read(status: u16, body: &[u8]) -> Result<Value, Failure> {
    let object = serde_json::from_slice::<Value>(body).ok().filter(Value::is_object);
    let ok = object.as_ref().and_then(|o| o.get("ok")).and_then(Value::as_bool) == Some(true);
    if (200..300).contains(&status)
        && ok
        && let Some(value) = object.as_ref().and_then(|o| o.get("value"))
    {
        return Ok(value.clone());
    }
    let error = object.as_ref().and_then(|o| o.get("error"));
    let field =
        |key: &str| error.and_then(|e| e.get(key)).and_then(Value::as_str).map(str::to_owned);
    Err(Failure {
        kind: "http",
        status: Some(status),
        code: field("code"),
        message: field("message").unwrap_or_default(),
    })
}
