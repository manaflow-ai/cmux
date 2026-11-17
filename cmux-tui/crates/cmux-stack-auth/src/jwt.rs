//! When an access token needs a refresh: its JWT `exp` and `iat`, read without checking the
//! signature (the server checks it; this only decides whether to ask for a new one). The SDK's
//! `isTokenExpired` and `isTokenFreshEnough` (APIClient.swift).

use std::time::{Duration, SystemTime, UNIX_EPOCH};

use base64::Engine as _;
use base64::engine::general_purpose::{STANDARD_NO_PAD, URL_SAFE_NO_PAD};

/// The smallest refresh lead, so a token is never handed out with only seconds left.
pub const MINIMUM_REFRESH_LEAD: Duration = Duration::from_secs(20);

/// A token's `exp` and `iat`, in seconds since the epoch.
#[derive(Clone, Copy, Debug, PartialEq)]
struct Claims {
    exp: Option<f64>,
    iat: Option<f64>,
}

fn claims(token: &str) -> Option<Claims> {
    let payload = token.split('.').nth(1)?;
    // base64url, with or without padding (the SDK also took plain base64).
    let payload = payload.trim_end_matches('=');
    let bytes =
        URL_SAFE_NO_PAD.decode(payload).or_else(|_| STANDARD_NO_PAD.decode(payload)).ok()?;
    let value: serde_json::Value = serde_json::from_slice(&bytes).ok()?;
    let object = value.as_object()?;
    Some(Claims {
        exp: object.get("exp").and_then(serde_json::Value::as_f64),
        iat: object.get("iat").and_then(serde_json::Value::as_f64),
    })
}

fn now_seconds(now: SystemTime) -> f64 {
    now.duration_since(UNIX_EPOCH).map_or(0.0, |d| d.as_secs_f64())
}

/// Milliseconds until `exp` (infinite with no `exp`, 0 once past it).
fn expires_in_ms(claims: Claims, now: SystemTime) -> f64 {
    match claims.exp {
        None => f64::INFINITY,
        Some(exp) => (exp * 1000.0 - now_seconds(now) * 1000.0).max(0.0),
    }
}

/// Whether `token` is missing, undecodable or past its `exp`.
pub fn is_token_expired(token: Option<&str>, now: SystemTime) -> bool {
    match token.and_then(claims) {
        None => true,
        Some(claims) => expires_in_ms(claims, now) <= 0.0,
    }
}

/// Whether `token` may be used without a refresh: it is more than `lead` from its `exp`. The
/// lead is capped at half the token's lifetime (`exp - iat`), so a short-lived token is not
/// refreshed the moment it arrives, and floored at [`MINIMUM_REFRESH_LEAD`].
///
/// The upstream SDK also treated every token issued more than 75 s ago as stale, so each Mac
/// refreshed about every 90 s and many Macs behind one office IP hit Stack's per-IP limit; the
/// cmux fork dropped that rule and so does this.
pub fn is_token_fresh_enough(token: Option<&str>, lead: Duration, now: SystemTime) -> bool {
    let Some(claims) = token.and_then(claims) else { return false };
    let mut lead_ms = lead.as_secs_f64() * 1000.0;
    if let (Some(exp), Some(iat)) = (claims.exp, claims.iat) {
        if exp > iat {
            lead_ms = lead_ms.min((exp - iat) * 1000.0 / 2.0);
        }
    }
    lead_ms = lead_ms.max(MINIMUM_REFRESH_LEAD.as_secs_f64() * 1000.0);
    expires_in_ms(claims, now) > lead_ms
}

#[cfg(test)]
#[path = "jwt_tests.rs"]
mod tests;
