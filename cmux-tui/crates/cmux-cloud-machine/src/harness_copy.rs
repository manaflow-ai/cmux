//! The remote off switch for a Release build's copy of the person's Claude login to their own
//! Cloud machine (Leo, 2026-11-02: "A remote off switch, so if Anthropic objects we turn it off
//! for everyone within minutes and fall back to the one-click sign-in"). The API Worker answers
//! it (`GET /v1/cloud/harness-login-copy`, cmux-platform); the app asks before each Release copy.
//!
//! Fail closed: an answer older than its `ttlSeconds`, a failed read, or no read at all is off.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::json::Strict;

/// The longest an answer is trusted, whatever the route says: the switch takes effect within this.
pub const MAX_TTL_SECONDS: i64 = 300;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Copy {
    pub enabled: bool,
    pub ttl_seconds: i64,
}

/// The route's answer: `{enabled, ttlSeconds}`, or that object under `value`; the ttl cut to
/// `0...300` seconds.
pub fn read(answer: &Value) -> Strict<Copy> {
    let mut copy = serde_json::from_value::<Copy>(answer.clone())
        .or_else(|_| {
            serde_json::from_value::<Copy>(answer.get("value").cloned().unwrap_or(Value::Null))
        })
        .map_err(|error| format!("/v1/cloud/harness-login-copy: {error}"))?;
    copy.ttl_seconds = copy.ttl_seconds.clamp(0, MAX_TTL_SECONDS);
    Ok(copy)
}

/// The switch now: the last answer's `enabled` while it is no older than its ttl (`age_ms`
/// since it came), else None (off).
pub fn current(enabled: Option<bool>, ttl_seconds: i64, age_ms: i64) -> Option<bool> {
    enabled.filter(|_| age_ms <= ttl_seconds.saturating_mul(1000))
}

#[cfg(test)]
mod tests;
