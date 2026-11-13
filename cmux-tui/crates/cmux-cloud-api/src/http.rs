//! One request of `cmux cloud api`: the URL (path segments encoded, a base path kept), the
//! auth's headers, the deadline, and how a failure reads (the app's `CloudAPIError` cases).

use std::time::Duration;

use cmux_cloud_machine::error::{self, ApiError};
use serde_json::{Value, json};
use zeroize::Zeroizing;

use super::Request;

/// Which credentials and headers a call sends (the crate docs).
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Deserialize, serde::Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Auth {
    Stack,
    Owner,
    Worker,
}

/// Why a call failed: the app's `CloudAPIError` cases (no `not_signed_in`, which the app's own
/// token read decides).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Failure {
    /// No answer by the deadline: the path that timed out.
    TimedOut(String),
    Transport(String),
    /// A loopback backend that is not running.
    NoBackend,
    Http {
        status: u16,
        code: Option<String>,
        message: Option<String>,
        action: Option<String>,
        trace_id: Option<String>,
        /// The body's own `retryable` (cmux-platform#1192 sends one on every Cloud refusal).
        retryable: Option<bool>,
        /// A rate limit's window: the body's `retryAfterSeconds`.
        retry_after_s: Option<u64>,
    },
    /// A refusal a paid plan lifts (`pro` or `max`).
    PlanRequired {
        message: Option<String>,
        upgrade_url: Option<String>,
        plan: String,
    },
    Decoding(String),
}

/// One line for a person or a log: the kind, and the status, code and message a refusal has.
impl std::fmt::Display for Failure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Failure::TimedOut(path) => write!(f, "the Cloud API did not answer in time ({path})"),
            Failure::Transport(message) | Failure::Decoding(message) => f.write_str(message),
            Failure::NoBackend => f.write_str("the local Cloud backend is not running"),
            Failure::Http { status, code, message, .. } => {
                write!(f, "the Cloud API refused the call: {status}")?;
                if let Some(code) = code {
                    write!(f, " {code}")?;
                }
                match message {
                    Some(message) => write!(f, ": {message}"),
                    None => Ok(()),
                }
            }
            Failure::PlanRequired { plan, .. } => write!(f, "this needs the {plan} plan"),
        }
    }
}

impl Failure {
    /// The `kind` of [`Failure::json`].
    pub fn kind(&self) -> &'static str {
        match self {
            Failure::TimedOut(_) => "timed_out",
            Failure::Transport(_) => "transport",
            Failure::NoBackend => "no_backend",
            Failure::Http { .. } => "http",
            Failure::PlanRequired { .. } => "plan_required",
            Failure::Decoding(_) => "decoding",
        }
    }

    pub(crate) fn http(status: u16, code: Option<String>, message: Option<String>) -> Self {
        Failure::Http {
            status,
            code,
            message,
            action: None,
            trace_id: None,
            retryable: None,
            retry_after_s: None,
        }
    }

    pub fn json(&self) -> Value {
        match self {
            Failure::TimedOut(path) => json!({ "kind": "timed_out", "path": path }),
            Failure::Transport(message) => json!({ "kind": "transport", "message": message }),
            Failure::NoBackend => json!({ "kind": "no_backend" }),
            Failure::Http { status, code, message, action, trace_id, retryable, retry_after_s } => {
                let mut line = json!({
                    "kind": "http", "status": status, "code": code, "message": message,
                    "action": action, "trace_id": trace_id,
                });
                // Only when the refusal said: the app's error cases stay as they were otherwise.
                if let Value::Object(object) = &mut line {
                    if let Some(retryable) = retryable {
                        object.insert("retryable".into(), json!(retryable));
                    }
                    if let Some(seconds) = retry_after_s {
                        object.insert("retry_after_s".into(), json!(seconds));
                    }
                }
                line
            }
            Failure::PlanRequired { message, upgrade_url, plan } => json!({
                "kind": "plan_required", "message": message, "upgrade_url": upgrade_url, "plan": plan,
            }),
            Failure::Decoding(message) => json!({ "kind": "decoding", "message": message }),
        }
    }
}

/// A request body.
pub(crate) enum Body {
    Json(Value),
    /// Raw bytes and their content type (a keyed start's key line).
    /// Raw bytes (the keyed start's person key): the request's buffer is wiped when reqwest drops it.
    Bytes(Zeroizing<Vec<u8>>, &'static str),
}

/// What came back.
pub(crate) struct Reply {
    pub(crate) status: u16,
    /// `x-cmux-vm-error`, classic's code header.
    pub(crate) header_code: Option<String>,
    /// `Retry-After`: a rate limit's window, in seconds.
    pub(crate) retry_after: Option<String>,
    pub(crate) body: Vec<u8>,
}

impl Reply {
    pub(crate) fn ok(&self) -> bool {
        (200..300).contains(&self.status)
    }

    pub(crate) fn json(&self) -> Option<Value> {
        serde_json::from_slice(&self.body).ok()
    }
}

/// One call's session: the client, the base URL and the credentials.
pub struct Http {
    client: reqwest::Client,
    base: reqwest::Url,
    pub(crate) auth: Auth,
    credential: String,
    refresh: String,
    pub(crate) team: Option<String>,
    app_version: String,
    local_only: bool,
}

impl Http {
    pub fn new(request: &Request) -> Result<Self, Failure> {
        let base = base_url(&request.api).map_err(Failure::Transport)?;
        let _ = rustls::crypto::ring::default_provider().install_default();
        let client = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .user_agent(concat!("cmux/", env!("CARGO_PKG_VERSION")))
            .build()
            .map_err(|e| Failure::Transport(e.to_string()))?;
        Ok(Http {
            client,
            base,
            auth: request.auth,
            credential: request.credential.clone(),
            refresh: request.refresh.clone().unwrap_or_default(),
            team: request.team.clone().filter(|t| !t.is_empty()),
            app_version: request.app_version.clone().unwrap_or_else(|| "cmux-next".into()),
            local_only: request.local_only,
        })
    }

    /// `base` and `segments` (each one percent-encoded, `/` included) with `query`.
    pub(crate) fn url(&self, segments: &[&str], query: &[(&str, String)]) -> reqwest::Url {
        let mut url = self.base.clone();
        if let Ok(mut path) = url.path_segments_mut() {
            path.pop_if_empty().extend(segments);
        }
        if !query.is_empty() {
            let mut pairs = url.query_pairs_mut();
            for (name, value) in query {
                pairs.append_pair(name, value);
            }
        }
        url
    }

    /// Sends one request. `path` names it in a timeout (the app shows it).
    pub(crate) async fn send(
        &self,
        method: reqwest::Method,
        url: reqwest::Url,
        body: Option<Body>,
        idempotency_key: Option<&str>,
        timeout: Duration,
        path: &str,
    ) -> Result<Reply, Failure> {
        let mut builder =
            self.client.request(method, url).bearer_auth(&self.credential).timeout(timeout);
        match self.auth {
            Auth::Stack => {
                builder = builder
                    .header("X-Cmux-Client", "cmux-mac")
                    .header("X-Cmux-App-Version", &self.app_version)
                    .header("X-Stack-Refresh-Token", &self.refresh);
                if let Some(team) = &self.team {
                    builder = builder.header("X-Cmux-Team-Id", team);
                }
            }
            // RULE (cx-kvmz, hq-84): Authorization, Content-Type, Content-Length and x-cmux-team
            // only. The Worker's invocation log records every other header and the URL, so no
            // other header, no query and no path part that could hold a key is ever added.
            Auth::Owner | Auth::Worker => {
                if let Some(team) = &self.team {
                    builder = builder.header(crate::session::TEAM_HEADER, team);
                }
            }
        }
        if let Some(key) = idempotency_key {
            builder = builder.header("Idempotency-Key", key);
        }
        builder = match body {
            Some(Body::Json(value)) => builder.json(&value),
            Some(Body::Bytes(bytes, content_type)) => builder
                .header(reqwest::header::CONTENT_TYPE, content_type)
                .body(bytes::Bytes::from_owner(bytes)),
            None => builder,
        };
        let response = match tokio::time::timeout(timeout, builder.send()).await {
            Err(_) => return Err(Failure::TimedOut(path.to_owned())),
            Ok(Err(e)) if e.is_timeout() => return Err(Failure::TimedOut(path.to_owned())),
            Ok(Err(e)) if self.local_only && e.is_connect() => return Err(Failure::NoBackend),
            Ok(Err(e)) => return Err(Failure::Transport(transport_text(e))),
            Ok(Ok(response)) => response,
        };
        let status = response.status().as_u16();
        let header_code = response
            .headers()
            .get("x-cmux-vm-error")
            .and_then(|v| v.to_str().ok())
            .map(str::to_owned);
        let retry_after = response
            .headers()
            .get(reqwest::header::RETRY_AFTER)
            .and_then(|v| v.to_str().ok())
            .map(str::to_owned);
        let body =
            match tokio::time::timeout(timeout, bounded_body(response, crate::MAX_ANSWER_BYTES))
                .await
            {
                Err(_) => return Err(Failure::TimedOut(path.to_owned())),
                Ok(Err(BodyError::Read(e))) if e.is_timeout() => {
                    return Err(Failure::TimedOut(path.to_owned()));
                }
                Ok(Err(BodyError::Read(e))) => return Err(Failure::Transport(transport_text(e))),
                Ok(Err(BodyError::TooLarge(limit))) => {
                    return Err(Failure::Transport(format!(
                        "{path}: the answer is larger than {limit} bytes"
                    )));
                }
                Ok(Ok(bytes)) => bytes,
            };
        Ok(Reply { status, header_code, retry_after, body })
    }

    /// A classic call (`/api/runs`): a 2xx body as JSON (`null` when it has none),
    /// a refusal read by [`vm_error`].
    pub(crate) async fn classic(
        &self,
        method: reqwest::Method,
        segments: &[&str],
        query: &[(&str, String)],
        body: Option<Value>,
        idempotency_key: Option<&str>,
        timeout: Duration,
    ) -> Result<Value, Failure> {
        let path = path_text(segments);
        let url = self.url(segments, query);
        let reply =
            self.send(method, url, body.map(Body::Json), idempotency_key, timeout, &path).await?;
        if !reply.ok() {
            return Err(vm_error(reply.status, &reply.body, reply.header_code.as_deref()));
        }
        if reply.body.iter().all(u8::is_ascii_whitespace) {
            return Ok(Value::Null);
        }
        reply.json().ok_or_else(|| Failure::Decoding(format!("{path}: the answer is not JSON")))
    }
}

/// Why [`bounded_body`] read no body.
#[derive(Debug)]
pub(crate) enum BodyError {
    /// The body is longer than this many bytes; reading stopped there.
    TooLarge(usize),
    Read(reqwest::Error),
}

/// `response`'s body, refused once it passes `limit` bytes (a declared length over it is
/// refused before any read), so a huge body never sits in memory.
pub(crate) async fn bounded_body(
    mut response: reqwest::Response,
    limit: usize,
) -> Result<Vec<u8>, BodyError> {
    let declared = response.content_length().and_then(|n| usize::try_from(n).ok());
    if declared.is_some_and(|n| n > limit) {
        return Err(BodyError::TooLarge(limit));
    }
    let mut body = Vec::with_capacity(declared.unwrap_or(0));
    while let Some(chunk) = response.chunk().await.map_err(BodyError::Read)? {
        if chunk.len() > limit.saturating_sub(body.len()) {
            return Err(BodyError::TooLarge(limit));
        }
        body.extend_from_slice(&chunk);
    }
    Ok(body)
}

/// `response`'s body as JSON, `None` when it is not JSON or is longer than `limit` bytes.
pub(crate) async fn bounded_json(response: reqwest::Response, limit: usize) -> Option<Value> {
    let body = bounded_body(response, limit).await.ok()?;
    serde_json::from_slice(&body).ok()
}

fn transport_text(error: reqwest::Error) -> String {
    format!("the Cloud API did not answer: {}", error.without_url())
}

/// `/a/b` for the segments, as a timeout or decoding error names the route.
pub(crate) fn path_text(segments: &[&str]) -> String {
    segments.iter().fold(String::new(), |mut text, segment| {
        text.push('/');
        text.push_str(segment);
        text
    })
}

/// The base URL: absolute, no user, query or fragment; plain http only to a loopback host (a
/// credential never goes over plain http to another). A path prefix is kept.
pub(crate) fn base_url(raw: &str) -> Result<reqwest::Url, String> {
    let url = reqwest::Url::parse(raw.trim_end_matches('/'))
        .map_err(|_| "the Cloud API is not a URL".to_owned())?;
    if url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return Err("the Cloud API URL must have no user, query or fragment".into());
    }
    let local = matches!(url.host_str(), Some("127.0.0.1" | "localhost" | "[::1]" | "::1"));
    if url.scheme() != "https" && !(url.scheme() == "http" && local) {
        return Err("the Cloud API is not https: a credential never goes over plain http".into());
    }
    Ok(url)
}

/// Classic's refusal body, or the Worker's nested `{ok: false, error: {code, message}}`, read by
/// the app's own rule ([`cmux_cloud_machine::error::from_response`]); a refusal a paid plan lifts
/// is [`Failure::PlanRequired`].
pub(crate) fn vm_error(status: u16, body: &[u8], header_code: Option<&str>) -> Failure {
    match error::from_response(i64::from(status), body, header_code) {
        ApiError::PlanRequired { message, upgrade_url, plan } => {
            Failure::PlanRequired { message, upgrade_url, plan }
        }
        ApiError::Http { code, message, action, trace_id, .. } => Failure::Http {
            status,
            code,
            message,
            action,
            trace_id,
            retryable: None,
            retry_after_s: None,
        },
        // `from_response` reads a response, so it answers one of the two above.
        _ => Failure::http(status, None, None),
    }
}

/// The Worker's refusal: `{error: {code, message}}`.
pub(crate) fn worker_error(status: u16, body: Option<&Value>) -> Failure {
    let error = body.and_then(|b| b.get("error"));
    let text =
        |name: &str| error.and_then(|e| e.get(name)).and_then(Value::as_str).map(str::to_owned);
    Failure::http(status, text("code"), text("message"))
}
