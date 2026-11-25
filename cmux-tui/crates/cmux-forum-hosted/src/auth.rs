//! Credentials and the agent-key token cache. Nothing here prints a secret.

use std::fmt;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

/// Seconds since the Unix epoch. Injected so tests control token expiry.
pub trait Clock: Send + Sync {
    fn now_unix(&self) -> u64;
}

#[derive(Clone, Copy, Debug, Default)]
pub struct SystemClock;

impl Clock for SystemClock {
    fn now_unix(&self) -> u64 {
        SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
    }
}

/// How the client signs its requests.
#[derive(Clone, PartialEq, Eq)]
pub enum Credential {
    /// A signed-in person's access token, passed in by the app per call; the daemon stores none.
    Session { access_token: String },
    /// An agent key (`cfk_...`), exchanged at `POST /v1/forum/token` for a short-lived bearer.
    AgentKey { key: String },
}

impl fmt::Debug for Credential {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Credential::Session { .. } => {
                f.write_str("Credential::Session { access_token: <redacted> }")
            }
            Credential::AgentKey { .. } => f.write_str("Credential::AgentKey { key: <redacted> }"),
        }
    }
}

/// Refresh an exchanged token this many seconds before it expires.
pub const TOKEN_REFRESH_MARGIN_SECONDS: u64 = 60;

#[derive(Clone)]
struct CachedToken {
    token: String,
    expires_at: u64,
}

/// The exchanged token for an agent key, reused until shortly before expiry.
#[derive(Default)]
pub(crate) struct TokenCache {
    slot: Mutex<Option<CachedToken>>,
}

impl TokenCache {
    /// The cached token when it is still good at `now`.
    pub(crate) fn get(&self, now: u64) -> Option<String> {
        let slot = self.slot.lock().unwrap_or_else(|e| e.into_inner());
        slot.as_ref()
            .filter(|t| now.saturating_add(TOKEN_REFRESH_MARGIN_SECONDS) < t.expires_at)
            .map(|t| t.token.clone())
    }

    pub(crate) fn put(&self, token: String, now: u64, expires_in: u64) {
        let mut slot = self.slot.lock().unwrap_or_else(|e| e.into_inner());
        *slot = Some(CachedToken { token, expires_at: now.saturating_add(expires_in) });
    }

    pub(crate) fn clear(&self) {
        *self.slot.lock().unwrap_or_else(|e| e.into_inner()) = None;
    }
}

impl fmt::Debug for TokenCache {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let cached = self.slot.lock().map(|s| s.is_some()).unwrap_or(false);
        f.debug_struct("TokenCache").field("cached", &cached).finish()
    }
}
