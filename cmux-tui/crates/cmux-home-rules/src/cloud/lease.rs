//! The cloud session lease's rules (`HomeCloudLease.swift`): the API origin
//! the daemon takes, the JWT claims a lease reads (unverified: the daemon and
//! the Worker verify the token), and the check that a token is for the
//! account asked for.

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

/// No access token lives longer than this; a later `exp` is not trusted.
pub const MAX_LIFETIME_SECS: f64 = 30.0 * 24.0 * 3600.0;
/// A token without a readable `exp` is leased for this long.
pub const FALLBACK_LIFETIME_SECS: f64 = 300.0;

/// The API origin: scheme, host and port only (the daemon refuses a path).
/// An IPv6 host keeps (or gets) its brackets. `None` when the URL has no
/// scheme or no host.
pub fn origin(url: &str) -> Option<String> {
    let (scheme, rest) = url.split_once("://")?;
    if scheme.is_empty()
        || !scheme.chars().all(|c| c.is_ascii_alphanumeric() || "+-.".contains(c))
        || !scheme.starts_with(|c: char| c.is_ascii_alphabetic())
    {
        return None;
    }
    let authority = rest.split(['/', '?', '#']).next().unwrap_or_default();
    let host_port = authority.rsplit_once('@').map_or(authority, |(_, h)| h);
    let (host, port) = if let Some(inner) = host_port.strip_prefix('[') {
        let (host, after) = inner.split_once(']')?;
        (host, after.strip_prefix(':'))
    } else {
        match host_port.rsplit_once(':') {
            Some((host, port)) => (host, Some(port)),
            None => (host_port, None),
        }
    };
    if host.is_empty() {
        return None;
    }
    let port = match port {
        None | Some("") => None,
        Some(port) => Some(port.parse::<u16>().ok()?),
    };
    let bracketed = if host.contains(':') && !host.starts_with('[') {
        format!("[{host}]")
    } else {
        host.to_owned()
    };
    let port = port.map(|p| format!(":{p}")).unwrap_or_default();
    Some(format!("{scheme}://{bracketed}{port}"))
}

/// The Worker's user id for a Stack user id: `user_` first, once.
pub fn cloud_id(stack_user_id: &str) -> String {
    if stack_user_id.starts_with("user_") {
        stack_user_id.to_owned()
    } else {
        format!("user_{stack_user_id}")
    }
}

/// The decoded payload of a JWT, unverified.
pub fn claims(token: &str) -> Option<Map<String, Value>> {
    let mut segments = token.split('.');
    let (Some(_), Some(payload), Some(_), None) =
        (segments.next(), segments.next(), segments.next(), segments.next())
    else {
        return None;
    };
    let data = base64url_decode(payload)?;
    match serde_json::from_slice::<Value>(&data).ok()? {
        Value::Object(map) => Some(map),
        _ => None,
    }
}

/// Base64 with the URL alphabet (or the standard one), padding optional.
fn base64url_decode(text: &str) -> Option<Vec<u8>> {
    fn value(byte: u8) -> Option<u32> {
        Some(match byte {
            b'A'..=b'Z' => byte - b'A',
            b'a'..=b'z' => byte - b'a' + 26,
            b'0'..=b'9' => byte - b'0' + 52,
            b'-' | b'+' => 62,
            b'_' | b'/' => 63,
            _ => return None,
        } as u32)
    }
    let trimmed = text.trim_end_matches('=');
    if text.len() - trimmed.len() > 2 {
        return None;
    }
    let bytes = trimmed.as_bytes();
    if bytes.len() % 4 == 1 {
        return None;
    }
    let mut out = Vec::with_capacity(bytes.len() * 3 / 4);
    for chunk in bytes.chunks(4) {
        let mut acc = 0u32;
        for (i, &b) in chunk.iter().enumerate() {
            acc |= value(b)? << (18 - 6 * i);
        }
        out.push((acc >> 16) as u8);
        if chunk.len() > 2 {
            out.push((acc >> 8) as u8);
        }
        if chunk.len() > 3 {
            out.push(acc as u8);
        }
    }
    Some(out)
}

/// The `exp` claim as Unix milliseconds; one that is not a finite positive
/// number, or later than `MAX_LIFETIME_SECS` from `now_ms`, reads as missing.
pub fn expiry(token: &str, now_ms: f64) -> Option<u64> {
    let exp = claims(token)?.get("exp")?.as_f64()?;
    let now = now_ms / 1000.0;
    (exp.is_finite() && exp > 0.0 && exp <= now + MAX_LIFETIME_SECS)
        .then_some((exp * 1000.0) as u64)
}

fn string_claim(token: &str, key: &str) -> Option<String> {
    match claims(token)?.get(key)? {
        Value::String(s) if !s.is_empty() => Some(s.clone()),
        _ => None,
    }
}

/// The `sub` claim: the Stack user id the token was issued for.
pub fn subject(token: &str) -> Option<String> {
    string_claim(token, "sub")
}

/// The `team` claim of an install token (never trusted as a credential).
pub fn team(token: &str) -> Option<String> {
    string_claim(token, "team")
}

/// The expiry a token without a readable `exp` is leased until.
pub fn fallback_expiry(now_ms: f64) -> u64 {
    (now_ms + FALLBACK_LIFETIME_SECS * 1000.0) as u64
}

/// `cloud.jwt_claims` request.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClaimsRequest {
    pub token: String,
    pub now_ms: f64,
}

/// `cloud.jwt_claims` reply.
#[derive(Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ClaimsReply {
    pub subject: Option<String>,
    pub team: Option<String>,
    pub expires_at: Option<u64>,
    pub fallback_expires_at: u64,
}

pub fn jwt_claims(req: &ClaimsRequest) -> ClaimsReply {
    ClaimsReply {
        subject: subject(&req.token),
        team: team(&req.token),
        expires_at: expiry(&req.token, req.now_ms),
        fallback_expires_at: fallback_expiry(req.now_ms),
    }
}

/// `cloud.lease_check` request: the token read for `expectedUserId`, and the
/// API base URL the lease names.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CheckRequest {
    pub token: String,
    pub expected_user_id: String,
    pub api_base_url: String,
    pub now_ms: f64,
}

/// What a token read for a lease amounts to.
#[derive(Debug, Serialize, PartialEq)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum CheckReply {
    /// Send `cloud-session-set` with these.
    #[serde(rename_all = "camelCase")]
    Lease { origin: String, subject: String, expires_at: u64 },
    /// The base URL has no origin: the lease fails.
    NoOrigin,
    /// The token is another account's (the user switched while it was read).
    OtherAccount,
}

pub fn check(req: &CheckRequest) -> CheckReply {
    let Some(origin) = origin(&req.api_base_url) else {
        return CheckReply::NoOrigin;
    };
    match subject(&req.token) {
        Some(subject) if cloud_id(&subject) == cloud_id(&req.expected_user_id) => {
            let expires_at =
                expiry(&req.token, req.now_ms).unwrap_or_else(|| fallback_expiry(req.now_ms));
            CheckReply::Lease { origin, subject, expires_at }
        }
        _ => CheckReply::OtherAccount,
    }
}
