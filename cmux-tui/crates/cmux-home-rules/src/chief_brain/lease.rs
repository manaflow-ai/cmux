//! `ModelRouterLease.run`'s renewal loop as a step: how long to wait, whether to force
//! a token refresh, and what to log. Swift keeps the token fetch, the router call and
//! the timer.

use serde::{Deserialize, Serialize};

/// `ModelRouterLease.renewMargin`, in seconds.
pub const RENEW_MARGIN_SECS: f64 = 90.0;
/// `ModelRouterLease.retryDelays`, in seconds.
pub const RETRY_DELAYS_SECS: [f64; 6] = [2.0, 5.0, 15.0, 30.0, 60.0, 120.0];

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct LeaseState {
    pub failures: u32,
    /// Ask `accessToken(forceRefresh:)` for a new token next pass.
    pub force_refresh: bool,
    /// The local router's pid at the last upstream set.
    pub router_pid: Option<i64>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum LeaseEvent {
    /// `setUpstream` took the bearer. `expiresAtMs`: the JWT's expiry or the fallback.
    #[serde(rename_all = "camelCase")]
    Set { expires_at_ms: i64, pid: Option<i64>, now_secs: f64 },
    /// The token fetch or `setUpstream` failed (not by cancellation).
    #[serde(rename_all = "camelCase")]
    Failed {
        #[serde(default)]
        error: String,
    },
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LeaseReply {
    pub state: LeaseState,
    /// `setUpstream`'s `expiresAt` (seconds), for a `set`.
    pub expires_at: Option<i64>,
    /// Wait this long (or until the router's pid is gone) before the next pass.
    pub wait_secs: f64,
    /// A line to log (info), if any.
    pub log: Option<String>,
}

/// `expiresAtMs / 1000` (whole seconds), as `setUpstream` takes it.
pub fn expires_at(expires_at_ms: i64) -> i64 {
    expires_at_ms / 1000
}

/// One pass of the lease loop.
pub fn step(mut s: LeaseState, event: LeaseEvent) -> LeaseReply {
    match event {
        LeaseEvent::Set { expires_at_ms, pid, now_secs } => {
            let at = expires_at(expires_at_ms);
            let log = match (pid, s.router_pid) {
                (Some(pid), Some(last)) if pid != last => Some(format!(
                    "model router lease: the local relay restarted (pid {last} -> {pid}); bearer sent again"
                )),
                _ => None,
            };
            s.router_pid = pid;
            s.failures = 0;
            let remaining = at as f64 - now_secs;
            s.force_refresh = remaining <= RENEW_MARGIN_SECS * 2.0;
            LeaseReply {
                state: s,
                expires_at: Some(at),
                wait_secs: (remaining - RENEW_MARGIN_SECS).max(10.0),
                log,
            }
        }
        LeaseEvent::Failed { error } => {
            let log = (s.failures == 0).then(|| format!("model router lease: {error}"));
            let index = (s.failures as usize).min(RETRY_DELAYS_SECS.len() - 1);
            let wait_secs = RETRY_DELAYS_SECS
                .get(index)
                .or(RETRY_DELAYS_SECS.last())
                .copied()
                .unwrap_or_default();
            s.failures += 1;
            LeaseReply { state: s, expires_at: None, wait_secs, log }
        }
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LeaseRequest {
    #[serde(default)]
    pub state: LeaseState,
    pub event: LeaseEvent,
}
