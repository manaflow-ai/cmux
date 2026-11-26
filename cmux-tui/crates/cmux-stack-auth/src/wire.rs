//! The wire rules every call shares: the session pair, the form encoding of the OAuth token
//! endpoint, how a response's Stack headers read, `Retry-After`, and how a 429 is reported
//! with no id, token or address in it (the SDK's APIClient.swift and RateLimitObservation.swift).

use std::time::{Duration, SystemTime};

use reqwest::header::HeaderMap;

/// A signed-in session's token pair, as the caller's store holds it. A call that refreshes the
/// access token writes the new one here; the caller persists it.
#[derive(Clone, Default, PartialEq, Eq)]
pub struct Session {
    pub access_token: Option<String>,
    pub refresh_token: Option<String>,
}

impl Session {
    pub fn new(access_token: Option<&str>, refresh_token: Option<&str>) -> Self {
        Session {
            access_token: access_token.map(str::to_owned),
            refresh_token: refresh_token.map(str::to_owned),
        }
    }
}

/// Never the tokens: only which are present.
impl std::fmt::Debug for Session {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Session")
            .field("access_token", &self.access_token.as_ref().map(|_| "<redacted>"))
            .field("refresh_token", &self.refresh_token.as_ref().map(|_| "<redacted>"))
            .finish()
    }
}

/// The shape of a 429 body: the Stack API answers JSON, an edge throttle in front of it HTML.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BodyKind {
    Json,
    Html,
    Other,
}

impl BodyKind {
    /// By content type, then by the first non-space byte of the body's first 64.
    pub fn classify(content_type: Option<&str>, body: &[u8]) -> Self {
        let kind = content_type.unwrap_or_default().to_ascii_lowercase();
        if kind.contains("json") {
            return BodyKind::Json;
        }
        if kind.contains("html") {
            return BodyKind::Html;
        }
        match body.iter().take(64).find(|b| !b.is_ascii_whitespace()) {
            Some(b'<') => BodyKind::Html,
            Some(b'{' | b'[') => BodyKind::Json,
            _ => BodyKind::Other,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            BodyKind::Json => "json",
            BodyKind::Html => "html",
            BodyKind::Other => "other",
        }
    }
}

/// A URL path for telemetry: no query, and every segment that is not a route word (`users`,
/// `sign-in`, `v1`) replaced by `ID`, so no id, token or address survives. At most 200 chars.
pub fn redacted_endpoint(path: &str) -> String {
    let path = path.split(['?', '#']).next().unwrap_or_default();
    if path.is_empty() {
        return "/".to_owned();
    }
    let joined = path
        .split('/')
        .map(|segment| if is_identifier_like(segment) { "ID" } else { segment })
        .collect::<Vec<_>>()
        .join("/");
    joined.chars().take(200).collect()
}

fn is_identifier_like(segment: &str) -> bool {
    let mut chars = segment.chars();
    let Some(first) = chars.next() else { return false };
    let count = segment.chars().count();
    let is_version = first == 'v' && (2..=3).contains(&count) && chars.all(|c| c.is_ascii_digit());
    if is_version {
        return false;
    }
    let is_route_word = count <= 24
        && first.is_ascii_lowercase()
        && segment.chars().all(|c| c.is_ascii_lowercase() || c == '-' || c == '_');
    !is_route_word
}

/// The longest wait any `Retry-After` is taken for: a remote header, bounded for every caller.
const MAX_RETRY_AFTER: f64 = 86_400.0;

/// A `Retry-After` value (delta-seconds or an HTTP-date) as seconds from `now`, at most a day;
/// `None` when absent or unreadable.
pub fn retry_after_seconds(value: Option<&str>, now: SystemTime) -> Option<f64> {
    let raw = value?.trim();
    if raw.is_empty() {
        return None;
    }
    if let Ok(seconds) = raw.parse::<f64>() {
        return (seconds.is_finite() && seconds >= 0.0).then(|| seconds.min(MAX_RETRY_AFTER));
    }
    let date = httpdate::parse_http_date(raw).ok()?;
    let ahead = date.duration_since(now).unwrap_or(Duration::ZERO);
    Some(ahead.as_secs_f64().min(MAX_RETRY_AFTER))
}

/// Percent-encodes `value` for an `application/x-www-form-urlencoded` body: only RFC 3986's
/// unreserved characters stay (the SDK's `formURLEncode`; stricter than a query encoder, which
/// lets `&`, `=` and `+` through).
pub(crate) fn form_encode(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for byte in value.bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b'_' | b'~') {
            out.push(char::from(byte));
        } else {
            out.push('%');
            out.push(hex_digit(byte >> 4));
            out.push(hex_digit(byte & 0x0f));
        }
    }
    out
}

fn hex_digit(nibble: u8) -> char {
    char::from_digit(u32::from(nibble), 16).map_or('0', |c| c.to_ascii_uppercase())
}

/// A form body from `pairs`, each value encoded.
pub(crate) fn form(pairs: &[(&str, &str)]) -> String {
    pairs
        .iter()
        .map(|(name, value)| format!("{name}={}", form_encode(value)))
        .collect::<Vec<_>>()
        .join("&")
}

/// A Stack response header by its Hexclave name, else the legacy `x-stack-*` name.
pub(crate) fn hexclave_header(headers: &HeaderMap, suffix: &str) -> Option<String> {
    [format!("x-hexclave-{suffix}"), format!("x-stack-{suffix}")]
        .iter()
        .find_map(|name| headers.get(name.as_str()))
        .and_then(|value| value.to_str().ok())
        .map(str::to_owned)
}

/// A response header as text.
pub(crate) fn header(headers: &HeaderMap, name: &str) -> Option<String> {
    headers.get(name).and_then(|value| value.to_str().ok()).map(str::to_owned)
}

/// Why a request got no answer, in fixed words: reqwest's own text names the URL, which can
/// carry a code or a token.
pub(crate) fn transport_words(error: &reqwest::Error) -> &'static str {
    if error.is_timeout() {
        "timed out"
    } else if error.is_connect() {
        "could not connect"
    } else if error.is_body() || error.is_decode() {
        "the answer broke off"
    } else {
        "the request failed"
    }
}

/// One shared HTTP client: no redirects (a redirect would carry the token headers elsewhere).
pub(crate) fn http_client() -> Result<reqwest::Client, &'static str> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .user_agent(concat!("cmux/", env!("CARGO_PKG_VERSION")))
        .build()
        .map_err(|_| "could not build the HTTP client")
}

#[cfg(test)]
#[path = "wire_tests.rs"]
mod tests;
