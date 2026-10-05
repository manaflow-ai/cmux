//! The Cloud host's link-token keyset: the public Ed25519 keys that sign
//! link tokens (`GET <api_origin>/v1/cloud/keyset`, and the `keyset` of the
//! bind answer; schemas/link-token/keyset-vectors.json).
//!
//! [`read_answer`] reads one keyset answer. Unknown fields are ignored. The
//! whole answer is refused when any key is not an `OKP`/`Ed25519` key with
//! `alg: EdDSA`, a `kid` equal to its map key, an `x` of exactly 43
//! base64url characters and no private part `d`; when it has not 1 or 2
//! kids; or when its version is not 16 lowercase hex characters.
//!
//! [`KeysetRefresh`] decides when to fetch, with the time passed in (no
//! clock, no sleep, no polling): once at bind (from the bind answer), then
//! one deadline a day at a jittered time of day, and on a token with an
//! unknown kid at most one fetch per 60 s. A 429 holds every fetch until
//! its `retry-after` (60 s when absent or invalid). Only a 200 that passes
//! every check replaces the held keyset; any other answer keeps it.

use std::collections::BTreeMap;
use std::time::{Duration, Instant};

use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use serde_json::Value;

/// The most kids an answer may hold (the current key and the next one).
pub const MAX_KIDS: usize = 2;

/// One day: the period of the refresh deadline.
pub const REFRESH_PERIOD: Duration = Duration::from_secs(24 * 60 * 60);

/// The shortest time between two fetches for an unknown kid.
pub const UNKNOWN_KID_INTERVAL: Duration = Duration::from_secs(60);

/// The wait after a 429 without a valid `retry-after`.
pub const DEFAULT_RETRY_AFTER: Duration = Duration::from_secs(60);

/// A keyset that passed every check.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Keyset {
    /// 16 lowercase hex characters.
    pub version: String,
    /// The Ed25519 public key of each kid.
    pub keys: BTreeMap<String, [u8; 32]>,
}

impl Keyset {
    /// The kids, sorted.
    pub fn kids(&self) -> Vec<&str> {
        self.keys.keys().map(String::as_str).collect()
    }
}

/// Why an answer did not replace the held keyset.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeysetRefused {
    /// A 429: wait `retry_after` before any fetch.
    RateLimited { retry_after: Duration },
    /// Any status other than 200 and 429.
    Unavailable,
    /// Not a keyset (no `ok: true`, no `value`, a bad version, no kid or a
    /// bad kid name).
    Malformed,
    /// More than [`MAX_KIDS`] kids.
    TooManyKids,
    /// A key failed a check.
    BadKey,
}

impl KeysetRefused {
    /// The error name of the vectors file.
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::RateLimited { .. } => "rate_limited",
            Self::Unavailable => "unavailable",
            Self::Malformed => "malformed",
            Self::TooManyKids => "too_many_kids",
            Self::BadKey => "bad_key",
        }
    }
}

/// Read one `GET /v1/cloud/keyset` answer. `headers` are (name, value)
/// pairs; names compare without case.
pub fn read_answer(
    status: u16,
    headers: &[(String, String)],
    body: &[u8],
) -> Result<Keyset, KeysetRefused> {
        // RED: not implemented yet.
        let _ = (status, headers, body);
        Err(KeysetRefused::Unavailable)
    }

/// Read a keyset value (`{version, keys}`): the `value` of a keyset answer,
/// or the `keyset` of the bind answer.
pub fn read_keyset(value: &Value) -> Result<Keyset, KeysetRefused> {
        // RED: not implemented yet.
        let _ = value;
        Err(KeysetRefused::Malformed)
    }

/// A kid of 1 to 64 characters from `A-Z a-z 0-9 . _ -`.
fn valid_kid(kid: &str) -> bool {
    (1..=64).contains(&kid.len())
        && kid.bytes().all(|byte| byte.is_ascii_alphanumeric() || b"._-".contains(&byte))
}

/// The time of day of a host's daily refresh: a stable offset in
/// `[0, 24 h)` from the host id, so hosts behind one egress address spread
/// over the day instead of fetching together.
pub fn daily_jitter(host: &str) -> Duration {
    use sha2::Digest as _;
    let digest = sha2::Sha256::digest(host.as_bytes());
    let mut first = [0u8; 8];
    first.copy_from_slice(&digest[..8]);
    Duration::from_secs(u64::from_be_bytes(first) % REFRESH_PERIOD.as_secs())
}

/// The held keyset and the fetch schedule of one Cloud host.
#[derive(Debug)]
pub struct KeysetRefresh {
    held: Keyset,
    /// The daily deadline: the only timer this schedule arms.
    next_daily: Instant,
    /// No fetch before this (a 429's `retry-after`).
    hold_until: Option<Instant>,
    /// The start of the last fetch for an unknown kid.
    last_unknown_kid_fetch: Option<Instant>,
}

impl KeysetRefresh {
    /// The schedule at bind: the bind answer's keyset is held, and the
    /// first daily deadline is `jitter` after `now` ([`daily_jitter`]).
    pub fn at_bind(bind_keyset: Keyset, now: Instant, jitter: Duration) -> Self {
        Self {
            held: bind_keyset,
            next_daily: now + jitter.min(REFRESH_PERIOD),
            hold_until: None,
            last_unknown_kid_fetch: None,
        }
    }

    /// The held keyset.
    pub fn held(&self) -> &Keyset {
        &self.held
    }

    /// The public key of `kid`, when the held keyset has it.
    pub fn key(&self, kid: &str) -> Option<&[u8; 32]> {
        self.held.keys.get(kid)
    }

    /// The one deadline to wait for: the daily deadline, or the end of a
    /// 429 hold when that is later.
    pub fn next_wakeup(&self) -> Instant {
        // RED: not implemented yet.
        self.next_daily
    }

    /// The daily deadline fired at `now`: true to fetch. The deadline moves
    /// to the next day (once, past `now`); a 429 hold defers the fetch to
    /// the end of the hold without arming a second timer.
    pub fn on_daily_deadline(&mut self, now: Instant) -> bool {
        // RED: not implemented yet.
        let _ = now;
        false
    }

    /// A token named `kid`, which the held keyset does not have: true to
    /// fetch now (at most once per [`UNKNOWN_KID_INTERVAL`], never during a
    /// 429 hold).
    pub fn on_unknown_kid(&mut self, kid: &str, now: Instant) -> bool {
        // RED: not implemented yet.
        let _ = (kid, now, self.last_unknown_kid_fetch, self.hold_until);
        true
    }

    /// Apply the answer of a fetch made at `now`. Only an accepted keyset
    /// replaces the held one; a 429 holds every fetch for its `retry-after`.
    pub fn apply(&mut self, read: Result<Keyset, KeysetRefused>, now: Instant) {
        // RED: not implemented yet.
        let _ = (read, now);
    }
}

#[cfg(test)]
#[path = "keyset_tests.rs"]
mod tests;
