//! The Stack client: one request to `<base>/api/v1` with its headers, deadline, transport retries
//! and one refresh-and-retry on an expired access token (APIClient.swift's `sendRequest` and
//! `sendWithRetry`), the refresh exchange and its cooldown, and the likely-valid access token
//! (`getOrFetchLikelyValidTokens`, `fetchNewAccessToken`).

use std::sync::{Mutex, PoisonError};
use std::time::{Duration, Instant, SystemTime};

use reqwest::header::{CONTENT_TYPE, HeaderMap, RETRY_AFTER};
use reqwest::{Method, Url};
use serde_json::Value;

use crate::config::StackConfig;
use crate::error::{RateLimit, StackError};
use crate::jwt::{is_token_expired, is_token_fresh_enough};
use crate::refresh::{RefreshFailure, RefreshOutcome, RefreshRateLimiter, random_jitter};
use crate::wire::{
    BodyKind, Session, form, header, hexclave_header, http_client, redacted_endpoint,
    retry_after_seconds, transport_words,
};

/// Stack's OAuth client secret for a project that needs no publishable key (the JS SDK's
/// `publishableClientKeyNotNecessarySentinel`).
pub(crate) const PUBLIC_CLIENT_SECRET: &str = "__stack_public_client__";

/// `x-hexclave-client-version`: which SDK is asking.
const CLIENT_VERSION: &str = concat!("rust@", env!("CARGO_PKG_VERSION"));

/// The refresh exchange's path, as a 429 from it is reported.
pub(crate) const TOKEN_PATH: &str = "/api/v1/auth/oauth/token";

/// What [`StackClient::likely_valid_access_token`] found.
#[derive(Clone, PartialEq)]
pub enum TokenResolution {
    /// A token to send: the stored one while fresh, or one just minted (written to the session).
    Valid(String),
    /// The refresh failed, but the stored token has not expired yet: send it, retry later.
    Fallback { access_token: String, failure: RefreshFailure },
    /// No refresh token and no unexpired access token: signed out.
    NoSession,
    /// Stack rejected the refresh token (400 or 401). The session was emptied; clear the store.
    Rejected,
    /// No usable token now, and the session is kept: a later call may succeed.
    Unavailable(RefreshFailure),
}

impl TokenResolution {
    /// The token to send, if any.
    pub fn access_token(&self) -> Option<&str> {
        match self {
            TokenResolution::Valid(token)
            | TokenResolution::Fallback { access_token: token, .. } => Some(token),
            _ => None,
        }
    }
}

/// Never the token.
impl std::fmt::Debug for TokenResolution {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            TokenResolution::Valid(_) => f.write_str("Valid(<redacted>)"),
            TokenResolution::Fallback { failure, .. } => {
                write!(f, "Fallback {{ access_token: <redacted>, failure: {failure:?} }}")
            }
            TokenResolution::NoSession => f.write_str("NoSession"),
            TokenResolution::Rejected => f.write_str("Rejected"),
            TokenResolution::Unavailable(failure) => write!(f, "Unavailable({failure:?})"),
        }
    }
}

/// One Stack project's client. Cheap to share behind an `Arc`; it holds the 429 cooldown and
/// the last minted token, so one client per process (per token store) is the intended use.
pub struct StackClient {
    pub(crate) config: StackConfig,
    http: reqwest::Client,
    limiter: Mutex<RefreshRateLimiter>,
    /// One refresh at a time, and the last token it minted with the refresh token that minted
    /// it: a caller that waited reuses that one instead of a second exchange.
    refresh_gate: tokio::sync::Mutex<Option<(String, String)>>,
}

/// One answer, read whole.
pub(crate) struct Answer {
    /// `x-hexclave-actual-status` when Stack sent one (it does, with
    /// `x-hexclave-override-error-status`), else the HTTP status.
    pub(crate) status: u16,
    pub(crate) headers: HeaderMap,
    pub(crate) body: Vec<u8>,
}

impl Answer {
    pub(crate) fn json(&self) -> Option<Value> {
        serde_json::from_slice(&self.body).ok()
    }
}

/// Why a request got no answer.
pub(crate) enum NoAnswer {
    TimedOut,
    /// Connect, DNS or TLS: the request never reached the server.
    Connect,
    Failed(&'static str),
}

impl From<NoAnswer> for StackError {
    fn from(no: NoAnswer) -> Self {
        match no {
            NoAnswer::TimedOut => StackError::TimedOut,
            NoAnswer::Connect => StackError::Network("could not connect"),
            NoAnswer::Failed(words) => StackError::Network(words),
        }
    }
}

/// Sends `request` and reads its body, all by `deadline`.
pub(crate) async fn exchange(
    request: reqwest::RequestBuilder,
    deadline: Duration,
) -> Result<Answer, NoAnswer> {
    let read = async {
        let response = request.send().await?;
        let status = response.status().as_u16();
        let headers = response.headers().clone();
        let body = response.bytes().await?.to_vec();
        Ok::<_, reqwest::Error>((status, headers, body))
    };
    match tokio::time::timeout(deadline, read).await {
        Err(_) => Err(NoAnswer::TimedOut),
        Ok(Err(error)) if error.is_timeout() => Err(NoAnswer::TimedOut),
        Ok(Err(error)) if error.is_connect() => Err(NoAnswer::Connect),
        Ok(Err(error)) => Err(NoAnswer::Failed(transport_words(&error))),
        Ok(Ok((status, headers, body))) => {
            let status = hexclave_header(&headers, "actual-status")
                .and_then(|s| s.trim().parse().ok())
                .unwrap_or(status);
            Ok(Answer { status, headers, body })
        }
    }
}

impl StackClient {
    pub fn new(config: StackConfig) -> Result<Self, StackError> {
        Ok(StackClient {
            config,
            http: http_client().map_err(StackError::Client)?,
            limiter: Mutex::new(RefreshRateLimiter::default()),
            refresh_gate: tokio::sync::Mutex::new(None),
        })
    }

    pub fn config(&self) -> &StackConfig {
        &self.config
    }

    /// The OAuth `client_secret`: the publishable key, or the public-client secret without one.
    pub(crate) fn oauth_client_secret(&self) -> &str {
        if self.config.publishable_client_key.is_empty() {
            PUBLIC_CLIENT_SECRET
        } else {
            &self.config.publishable_client_key
        }
    }

    pub(crate) fn url(&self, path: &str) -> Result<Url, StackError> {
        Url::parse(&format!("{}{path}", self.config.base_url))
            .map_err(|_| StackError::Client("the Stack base URL does not parse"))
    }

    pub(crate) fn http(&self) -> &reqwest::Client {
        &self.http
    }

    /// The project's headers every API request carries. Only `x-hexclave-*` names: Stack
    /// answers 429 to a request with the `x-stack-*` aliases.
    fn api_request(&self, method: Method, url: Url) -> reqwest::RequestBuilder {
        let mut builder = self
            .http
            .request(method, url)
            .timeout(self.config.request_timeout)
            .header("x-hexclave-project-id", &self.config.project_id)
            .header("x-hexclave-client-version", CLIENT_VERSION)
            .header("x-hexclave-access-type", "client")
            .header("x-hexclave-override-error-status", "true")
            .header("x-hexclave-random-nonce", uuid::Uuid::new_v4().to_string());
        if !self.config.publishable_client_key.is_empty() {
            builder = builder
                .header("x-hexclave-publishable-client-key", &self.config.publishable_client_key);
        }
        builder
    }

    /// One API call to `/api/v1{path}`. With a `session` it is authenticated: the pair rides in
    /// `x-hexclave-access-token` and `x-hexclave-refresh-token`, and a 401 `invalid_access_token`
    /// refreshes once (the new token lands in `session`) and retries. A transport failure of an
    /// idempotent method is retried with doubling waits. Answers a 2xx body.
    pub(crate) async fn call(
        &self,
        method: Method,
        path: &str,
        body: Option<&Value>,
        mut session: Option<&mut Session>,
    ) -> Result<Answer, StackError> {
        let url = self.url(&format!("/api/v1{path}"))?;
        let idempotent = matches!(
            method,
            Method::GET | Method::HEAD | Method::OPTIONS | Method::PUT | Method::DELETE
        );
        let mut attempt: u32 = 0;
        let mut refreshed = false;
        loop {
            let mut request = self.api_request(method.clone(), url.clone());
            if let Some(session) = session.as_deref() {
                if let Some(access) = &session.access_token {
                    request = request.header("x-hexclave-access-token", access);
                }
                if let Some(refresh) = &session.refresh_token {
                    request = request.header("x-hexclave-refresh-token", refresh);
                }
            }
            request = match body {
                Some(body) => request.json(body),
                // A mutating method carries a body even when empty.
                None if matches!(method, Method::POST | Method::PATCH | Method::PUT) => {
                    request.header(CONTENT_TYPE, "application/json").body("{}")
                }
                None => request,
            };
            let answer = match exchange(request, self.config.request_timeout).await {
                Ok(answer) => answer,
                Err(_) if idempotent && attempt < self.config.transport_retries => {
                    let wait = self
                        .config
                        .transport_retry_base
                        .saturating_mul(2_u32.saturating_pow(attempt));
                    tokio::time::sleep(wait).await;
                    attempt = attempt.saturating_add(1);
                    continue;
                }
                Err(no) => return Err(no.into()),
            };
            let known_error = hexclave_header(&answer.headers, "known-error");
            if answer.status == 401
                && !refreshed
                && known_error.as_deref() == Some("invalid_access_token")
            {
                if let Some(session) = session.as_deref_mut() {
                    if let TokenResolution::Valid(_) =
                        self.force_refresh_access_token(session).await
                    {
                        refreshed = true;
                        attempt = 0;
                        continue;
                    }
                }
            }
            return read_answer(answer, known_error, url.path());
        }
    }

    /// One refresh exchange: `POST /api/v1/auth/oauth/token` with `grant_type=refresh_token`,
    /// bounded by the refresh deadline, ignoring any cooldown.
    pub async fn refresh_exchange(&self, refresh_token: &str) -> RefreshOutcome {
        let Ok(url) = self.url(TOKEN_PATH) else { return RefreshOutcome::Transient };
        let body = form(&[
            ("grant_type", "refresh_token"),
            ("refresh_token", refresh_token),
            ("client_id", &self.config.project_id),
            ("client_secret", self.oauth_client_secret()),
        ]);
        let mut request = self
            .http
            .post(url)
            .timeout(self.config.request_timeout)
            .header(CONTENT_TYPE, "application/x-www-form-urlencoded")
            .header("x-hexclave-project-id", &self.config.project_id)
            .header("x-hexclave-access-type", "client")
            .body(body);
        if !self.config.publishable_client_key.is_empty() {
            request = request
                .header("x-hexclave-publishable-client-key", &self.config.publishable_client_key);
        }
        let deadline = self.config.refresh_timeout.min(self.config.request_timeout);
        let answer = match exchange(request, deadline).await {
            Ok(answer) => answer,
            Err(NoAnswer::TimedOut) => return RefreshOutcome::TimedOut,
            Err(NoAnswer::Connect | NoAnswer::Failed(_)) => return RefreshOutcome::Transient,
        };
        match answer.status {
            200 => {
                match answer.json().and_then(|v| v.get("access_token")?.as_str().map(str::to_owned))
                {
                    Some(access_token) => RefreshOutcome::Success { access_token },
                    // A 200 the client cannot read is a server anomaly, not a dead token.
                    None => RefreshOutcome::Transient,
                }
            }
            400 | 401 => RefreshOutcome::Rejected,
            429 => RefreshOutcome::RateLimited {
                retry_after_s: retry_after_seconds(
                    header(&answer.headers, RETRY_AFTER.as_str()).as_deref(),
                    SystemTime::now(),
                ),
                body_kind: body_kind(&answer),
            },
            _ => RefreshOutcome::Transient,
        }
    }

    /// One exchange unless a 429's cooldown is still running; records the outcome.
    async fn refresh_respecting_rate_limit(
        &self,
        refresh_token: &str,
    ) -> Result<RefreshOutcome, RefreshFailure> {
        if self.limiter.lock().unwrap_or_else(PoisonError::into_inner).cooling_down(Instant::now())
        {
            return Err(RefreshFailure::CoolingDown);
        }
        let outcome = self.refresh_exchange(refresh_token).await;
        self.limiter.lock().unwrap_or_else(PoisonError::into_inner).record(
            &outcome,
            Instant::now(),
            random_jitter(),
        );
        Ok(outcome)
    }

    /// A token to send for `session`: the stored access token while fresh enough, else one
    /// minted from the refresh token. A failed refresh falls back to the stored token while it
    /// has not expired. Only a rejection empties `session`.
    pub async fn likely_valid_access_token(&self, session: &mut Session) -> TokenResolution {
        if session.refresh_token.is_none() {
            // A token-only session is valid until its token expires.
            return match &session.access_token {
                Some(access) if !is_token_expired(Some(access), SystemTime::now()) => {
                    TokenResolution::Valid(access.clone())
                }
                _ => TokenResolution::NoSession,
            };
        }
        if let Some(access) = &session.access_token {
            if is_token_fresh_enough(Some(access), self.config.refresh_lead, SystemTime::now()) {
                return TokenResolution::Valid(access.clone());
            }
        }
        self.resolve_refresh(session, true).await
    }

    /// A newly minted token for `session`, after the server rejected the current one: never
    /// falls back to the stored token.
    pub async fn force_refresh_access_token(&self, session: &mut Session) -> TokenResolution {
        if session.refresh_token.is_none() {
            return TokenResolution::NoSession;
        }
        self.resolve_refresh(session, false).await
    }

    async fn resolve_refresh(
        &self,
        session: &mut Session,
        allow_fallback: bool,
    ) -> TokenResolution {
        let Some(refresh) = session.refresh_token.clone() else {
            return TokenResolution::NoSession;
        };
        let observed = session.access_token.clone();
        let mut last = self.refresh_gate.lock().await;
        // A refresh that finished while this one waited minted a token for the same session.
        if let Some((minted_for, minted)) = last.as_ref() {
            if *minted_for == refresh
                && observed.as_ref() != Some(minted)
                && !is_token_expired(Some(minted), SystemTime::now())
            {
                session.access_token = Some(minted.clone());
                return TokenResolution::Valid(minted.clone());
            }
        }
        let failure = match self.refresh_respecting_rate_limit(&refresh).await {
            Ok(RefreshOutcome::Success { access_token }) => {
                *last = Some((refresh, access_token.clone()));
                session.access_token = Some(access_token.clone());
                return TokenResolution::Valid(access_token);
            }
            Ok(RefreshOutcome::Rejected) => {
                *last = None;
                *session = Session::default();
                return TokenResolution::Rejected;
            }
            Ok(RefreshOutcome::Transient) => RefreshFailure::Transient,
            Ok(RefreshOutcome::TimedOut) => RefreshFailure::TimedOut,
            Ok(RefreshOutcome::RateLimited { retry_after_s, .. }) => {
                RefreshFailure::RateLimited { retry_after_s }
            }
            Err(cooling) => cooling,
        };
        match observed {
            Some(access)
                if allow_fallback && !is_token_expired(Some(&access), SystemTime::now()) =>
            {
                TokenResolution::Fallback { access_token: access, failure }
            }
            _ => TokenResolution::Unavailable(failure),
        }
    }

    /// Resolves a token for an authenticated call: signed out reads as
    /// [`StackError::NotSignedIn`], a kept session with no usable token as its failure.
    pub(crate) async fn authorize(&self, session: &mut Session) -> Result<(), StackError> {
        match self.likely_valid_access_token(session).await {
            TokenResolution::Valid(_) | TokenResolution::Fallback { .. } => Ok(()),
            TokenResolution::NoSession | TokenResolution::Rejected => Err(StackError::NotSignedIn),
            TokenResolution::Unavailable(failure) => Err(refresh_failure_error(failure)),
        }
    }
}

/// A kept session's refresh failure as a call's error.
pub(crate) fn refresh_failure_error(failure: RefreshFailure) -> StackError {
    match failure {
        RefreshFailure::Transient => StackError::Network("the token refresh failed"),
        RefreshFailure::TimedOut => StackError::TimedOut,
        RefreshFailure::RateLimited { retry_after_s } => StackError::RateLimited(RateLimit {
            endpoint: TOKEN_PATH.to_owned(),
            body_kind: BodyKind::Other,
            retry_after_s,
            request_id: None,
        }),
        RefreshFailure::CoolingDown => StackError::RateLimited(RateLimit {
            endpoint: TOKEN_PATH.to_owned(),
            body_kind: BodyKind::Other,
            retry_after_s: None,
            request_id: None,
        }),
    }
}

pub(crate) fn body_kind(answer: &Answer) -> BodyKind {
    BodyKind::classify(header(&answer.headers, CONTENT_TYPE.as_str()).as_deref(), &answer.body)
}

/// A 2xx answer, or its failure: a 429 by status alone (the edge answers HTML), then a known
/// error by its header, then any other status.
fn read_answer(
    answer: Answer,
    known_error: Option<String>,
    path: &str,
) -> Result<Answer, StackError> {
    let request_id = hexclave_header(&answer.headers, "request-id");
    if answer.status == 429 {
        return Err(StackError::RateLimited(RateLimit {
            endpoint: redacted_endpoint(path),
            body_kind: body_kind(&answer),
            retry_after_s: retry_after_seconds(
                header(&answer.headers, RETRY_AFTER.as_str()).as_deref(),
                SystemTime::now(),
            ),
            request_id,
        }));
    }
    if let Some(code) = known_error {
        let json = answer.json();
        let field =
            |name: &str| json.as_ref().and_then(|v| v.get(name)?.as_str().map(str::to_owned));
        return Err(StackError::Known {
            code,
            message: field("message")
                .or_else(|| field("error"))
                .unwrap_or_else(|| "Unknown error".to_owned()),
            http_status: answer.status,
            request_id,
            details: json.as_ref().and_then(|v| v.get("details")).cloned(),
        });
    }
    if (200..300).contains(&answer.status) {
        return Ok(answer);
    }
    Err(StackError::Http { status: answer.status, request_id })
}
