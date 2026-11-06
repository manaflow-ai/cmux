//! The values the holder passes around: an account scope, an access grant, a sign-in prompt.

use std::time::{SystemTime, UNIX_EPOCH};

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
