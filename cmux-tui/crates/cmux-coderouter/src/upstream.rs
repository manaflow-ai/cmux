//! One upstream account and the pass-through to it.
//!
//! Phase 1 forwards to exactly one upstream. The client's own credential
//! headers are always dropped and the account credential is set by the
//! router, so a client key never leaves the machine and an account token
//! never reaches a client. Redirects are not followed (a credential never
//! follows a `Location`). Response headers pass through an allowlist; the
//! body streams through unbuffered (SSE stays incremental).

use crate::{keys::ApiFamily, secret::Secret};
use axum::body::Body;
use bytes::Bytes;
use http::{HeaderMap, HeaderName, HeaderValue, Method, Response, StatusCode};
use std::{fmt, time::Duration};
use url::Url;

/// How long the router waits for upstream response headers. A stalled
/// upstream fails the request instead of hanging the harness (the team
/// subrouter's header-timeout lesson).
pub const HEADER_TIMEOUT: Duration = Duration::from_secs(180);
const ANTHROPIC_OAUTH_BETA: &str = "oauth-2025-04-20";

/// The credential of one account. `Debug` never prints a token.
pub enum UpstreamAuth {
    /// An Anthropic API key (`x-api-key`).
    AnthropicApiKey(Secret<String>),
    /// A Claude OAuth access token or setup token (`Authorization: Bearer`
    /// plus the OAuth beta flag).
    ClaudeOAuth(Secret<String>),
    /// An OpenAI API key.
    OpenAiApiKey(Secret<String>),
    /// A ChatGPT (Codex) sign-in: access token and account id.
    ChatGpt {
        /// The OAuth access token.
        access_token: Secret<String>,
        /// The ChatGPT account id (`chatgpt-account-id`).
        account_id: Secret<String>,
    },
}

impl fmt::Debug for UpstreamAuth {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let kind = match self {
            Self::AnthropicApiKey(_) => "AnthropicApiKey",
            Self::ClaudeOAuth(_) => "ClaudeOAuth",
            Self::OpenAiApiKey(_) => "OpenAiApiKey",
            Self::ChatGpt { .. } => "ChatGpt",
        };
        write!(formatter, "{kind}(<redacted>)")
    }
}

impl UpstreamAuth {
    /// The API family this credential serves.
    pub fn family(&self) -> ApiFamily {
        match self {
            Self::AnthropicApiKey(_) | Self::ClaudeOAuth(_) => ApiFamily::AnthropicMessages,
            Self::OpenAiApiKey(_) | Self::ChatGpt { .. } => ApiFamily::OpenAiResponses,
        }
    }

    fn default_base(&self) -> &'static str {
        match self {
            Self::AnthropicApiKey(_) | Self::ClaudeOAuth(_) => "https://api.anthropic.com",
            Self::OpenAiApiKey(_) => "https://api.openai.com",
            Self::ChatGpt { .. } => "https://chatgpt.com/backend-api/codex",
        }
    }

    fn apply(&self, headers: &mut HeaderMap) -> Result<(), http::header::InvalidHeaderValue> {
        let sensitive = |value: String| -> Result<HeaderValue, _> {
            let mut value = HeaderValue::try_from(value)?;
            value.set_sensitive(true);
            Ok(value)
        };
        match self {
            Self::AnthropicApiKey(key) => {
                headers.insert("x-api-key", sensitive(key.expose().clone())?);
            }
            Self::ClaudeOAuth(token) => {
                let bearer = format!("Bearer {}", token.expose());
                headers.insert(http::header::AUTHORIZATION, sensitive(bearer)?);
                let mut betas: Vec<String> = headers
                    .get("anthropic-beta")
                    .and_then(|value| value.to_str().ok())
                    .unwrap_or_default()
                    .split(',')
                    .map(|beta| beta.trim().to_owned())
                    .filter(|beta| !beta.is_empty())
                    .collect();
                if !betas.iter().any(|beta| beta == ANTHROPIC_OAUTH_BETA) {
                    betas.push(ANTHROPIC_OAUTH_BETA.to_owned());
                }
                headers.insert("anthropic-beta", HeaderValue::try_from(betas.join(","))?);
            }
            Self::OpenAiApiKey(key) => {
                let bearer = format!("Bearer {}", key.expose());
                headers.insert(http::header::AUTHORIZATION, sensitive(bearer)?);
            }
            Self::ChatGpt { access_token, account_id } => {
                let bearer = format!("Bearer {}", access_token.expose());
                headers.insert(http::header::AUTHORIZATION, sensitive(bearer)?);
                headers.insert("chatgpt-account-id", sensitive(account_id.expose().clone())?);
            }
        }
        Ok(())
    }
}

/// Why an upstream was refused at configuration time.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum UpstreamError {
    /// The base URL does not parse.
    BadUrl,
    /// The base URL is not https (plain http is allowed only to loopback,
    /// for tests and a local mock).
    Insecure,
}

impl fmt::Display for UpstreamError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::BadUrl => "upstream base URL does not parse",
            Self::Insecure => "upstream base URL must be https (http only to loopback)",
        })
    }
}

impl std::error::Error for UpstreamError {}

/// One upstream account.
#[derive(Debug)]
pub struct Upstream {
    base: Url,
    auth: UpstreamAuth,
}

impl Upstream {
    /// The provider's real endpoint for `auth`.
    pub fn new(auth: UpstreamAuth) -> Result<Self, UpstreamError> {
        let base = auth.default_base();
        Self::with_base(base, auth)
    }

    /// `auth` at `base` (an https URL, or http on a loopback host).
    pub fn with_base(base: &str, auth: UpstreamAuth) -> Result<Self, UpstreamError> {
        let base = Url::parse(base).map_err(|_| UpstreamError::BadUrl)?;
        let loopback = match base.host() {
            Some(url::Host::Ipv4(ip)) => ip.is_loopback(),
            Some(url::Host::Ipv6(ip)) => ip.is_loopback(),
            Some(url::Host::Domain(name)) => name.eq_ignore_ascii_case("localhost"),
            None => false,
        };
        match base.scheme() {
            "https" => {}
            "http" if loopback => {}
            _ => return Err(UpstreamError::Insecure),
        }
        Ok(Self { base, auth })
    }

    /// The API family this upstream serves.
    pub fn family(&self) -> ApiFamily {
        self.auth.family()
    }

    fn url_for(&self, path: &str, query: Option<&str>) -> String {
        let base = self.base.as_str().trim_end_matches('/');
        let path = match self.auth {
            // The ChatGPT backend serves Responses at `<base>/responses`.
            UpstreamAuth::ChatGpt { .. } => path.strip_prefix("/v1").unwrap_or(path),
            _ => path,
        };
        match query {
            Some(query) if !query.is_empty() => format!("{base}{path}?{query}"),
            _ => format!("{base}{path}"),
        }
    }
}

/// The HTTP client the router uses upstream: rustls, no redirects, no
/// overall timeout (streams are long), no proxy from the environment.
pub fn client() -> Result<reqwest::Client, reqwest::Error> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .no_proxy()
        .connect_timeout(Duration::from_secs(20))
        .build()
}

const STRIPPED: &[&str] = &[
    "authorization",
    "x-api-key",
    "chatgpt-account-id",
    "host",
    "content-length",
    "connection",
    "keep-alive",
    "transfer-encoding",
    "te",
    "trailer",
    "upgrade",
    "proxy-authorization",
    "proxy-connection",
    "cookie",
    "forwarded",
    "via",
    "origin",
    "referer",
];
const STRIPPED_PREFIXES: &[&str] = &["x-forwarded-", "x-real-ip", "x-cmux-", "sec-"];
const RESPONSE_HEADERS: &[&str] =
    &["content-type", "request-id", "x-request-id", "retry-after", "x-should-retry"];
const RESPONSE_PREFIXES: &[&str] = &["anthropic-ratelimit-", "x-ratelimit-", "x-codex-", "openai-"];

fn forwardable(name: &HeaderName) -> bool {
    let name = name.as_str();
    !STRIPPED.contains(&name) && !STRIPPED_PREFIXES.iter().any(|prefix| name.starts_with(prefix))
}

fn returnable(name: &HeaderName) -> bool {
    let name = name.as_str();
    RESPONSE_HEADERS.contains(&name) || RESPONSE_PREFIXES.iter().any(|p| name.starts_with(p))
}

/// A JSON error response in the Anthropic error shape (both harness
/// families print `error.message`).
pub fn error_response(status: StatusCode, kind: &str, message: &str) -> Response<Body> {
    let body = serde_json::json!({
        "type": "error",
        "error": {"type": kind, "message": message},
    });
    let mut response = Response::new(Body::from(body.to_string()));
    *response.status_mut() = status;
    response
        .headers_mut()
        .insert(http::header::CONTENT_TYPE, HeaderValue::from_static("application/json"));
    response
}

/// Forward one admitted request to `upstream` and stream the answer back.
pub async fn forward(
    client: &reqwest::Client,
    upstream: &Upstream,
    method: Method,
    path: &str,
    query: Option<&str>,
    headers: &HeaderMap,
    body: Bytes,
) -> Response<Body> {
    let mut outgoing = HeaderMap::new();
    for (name, value) in headers {
        if forwardable(name) {
            outgoing.append(name.clone(), value.clone());
        }
    }
    if upstream.auth.apply(&mut outgoing).is_err() {
        return error_response(
            StatusCode::BAD_GATEWAY,
            "account_credential_invalid",
            "the account credential is not a valid header value",
        );
    }
    let request = client.request(method, upstream.url_for(path, query)).headers(outgoing).body(body);
    let response = match tokio::time::timeout(HEADER_TIMEOUT, request.send()).await {
        Err(_) => {
            return error_response(
                StatusCode::GATEWAY_TIMEOUT,
                "upstream_header_timeout",
                "the upstream sent no response headers in time",
            );
        }
        // reqwest errors can carry the URL; the URL holds no secret, but
        // the message is kept generic so nothing upstream-specific leaks.
        Ok(Err(_)) => {
            return error_response(
                StatusCode::BAD_GATEWAY,
                "upstream_unreachable",
                "the upstream could not be reached",
            );
        }
        Ok(Ok(response)) => response,
    };
    let mut reply = Response::builder().status(response.status());
    for (name, value) in response.headers() {
        if returnable(name) {
            reply = reply.header(name, value);
        }
    }
    let stream = futures_util::stream::unfold(Some(response), |state| async move {
        let mut response = state?;
        match response.chunk().await {
            Ok(Some(chunk)) => Some((Ok::<Bytes, reqwest::Error>(chunk), Some(response))),
            Ok(None) => None,
            Err(error) => Some((Err(error), None)),
        }
    });
    reply.body(Body::from_stream(stream)).unwrap_or_else(|_| {
        error_response(StatusCode::BAD_GATEWAY, "upstream_bad_response", "bad upstream response")
    })
}
