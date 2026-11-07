//! The values the holder passes around: an account scope, an access grant, a sign-in prompt.

use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

/// The account scope that owns one local Codex refresh-token holder. Fixed for a holder's life.
#[derive(Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct Scope {
    pub user: String,
    pub team: Option<String>,
}

impl Scope {
    pub fn new(user: impl Into<String>, team: Option<&str>) -> Self {
        Self { user: user.into(), team: team.map(str::to_owned) }
    }

    /// `{"user": U, "team": T|null}`; anything else is none.
    pub fn from_json(value: &Value) -> Option<Self> {
        let user = value.get("user")?.as_str()?;
        let team = match value.get("team") {
            None | Some(Value::Null) => None,
            Some(team) => Some(team.as_str()?.to_owned()),
        };
        Some(Self { user: user.to_owned(), team })
    }

    pub fn to_json(&self) -> Value {
        json!({ "user": self.user, "team": self.team })
    }
}

/// The access-only credential delivered to a machine. The refresh token never enters it.
#[derive(Clone, Debug, PartialEq)]
pub struct Grant {
    pub access_token: String,
    pub account: String,
    /// Seconds since 1970.
    pub expires_at: f64,
}

/// A device-code sign-in the app shows; no credential in it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Prompt {
    pub verification_url: String,
    pub user_code: String,
}

/// Seconds since 1970, now.
pub fn now() -> f64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0.0, |d| d.as_secs_f64())
}

/// The latest expiry a grant may carry: 2100-01-01. Later, non-finite or not positive is a
/// malformed reply, never a timer.
pub const LATEST_EXPIRY: f64 = 4_102_444_800.0;

/// Whether `expiry` (seconds since 1970) is one a grant may carry.
pub fn valid_expiry(expiry: f64) -> bool {
    expiry.is_finite() && expiry > 0.0 && expiry < LATEST_EXPIRY
}

/// The longest timer the holder sets: a year. A renewal past it just renews early.
pub const LONGEST_WAIT: Duration = Duration::from_secs(366 * 86_400);

/// `seconds` as a timer, never a panic: below zero or not a number is zero, and anything longer
/// than [`LONGEST_WAIT`] (infinity too) is that.
pub fn wait(seconds: f64) -> Duration {
    if seconds.is_nan() || seconds <= 0.0 {
        return Duration::ZERO;
    }
    Duration::try_from_secs_f64(seconds).map_or(LONGEST_WAIT, |wait| wait.min(LONGEST_WAIT))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_timer_never_panics() {
        assert_eq!(wait(f64::NAN), Duration::ZERO);
        assert_eq!(wait(-1.0), Duration::ZERO);
        assert_eq!(wait(1e300), LONGEST_WAIT);
        assert_eq!(wait(f64::INFINITY), LONGEST_WAIT);
        assert_eq!(wait(2.5), Duration::from_millis(2500));
    }

    #[test]
    fn only_a_finite_expiry_before_2100_is_valid() {
        assert!(valid_expiry(2_147_483_647.0));
        for bad in [0.0, -1.0, f64::NAN, f64::INFINITY, 1e300, LATEST_EXPIRY] {
            assert!(!valid_expiry(bad), "{bad}");
        }
    }
}
