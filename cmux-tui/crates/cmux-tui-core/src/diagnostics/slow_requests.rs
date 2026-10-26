//! The `slow_requests` section of `server-stats`: requests the daemon's
//! request watchdog (server/request_watchdog.rs) saw run past its threshold.

use serde::Serialize;

/// The `slow_requests` section of `server-stats`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct SlowRequestsSnapshot {
    /// How long a request runs before it is recorded.
    pub threshold_ms: u64,
    /// Requests recorded since daemon start; `recent` keeps the newest 128.
    pub total: u64,
    /// Requests that ran while every watchdog slot was taken, so unwatched.
    pub unwatched: u64,
    /// Times the watchdog thread woke since daemon start.
    pub watchdog_wakeups: u64,
    /// The newest recorded requests, oldest first.
    pub recent: Vec<SlowRequest>,
}

/// One request that ran past the watchdog threshold, recorded once.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct SlowRequest {
    /// The request's `cmd` tag.
    pub method: &'static str,
    /// The connection that sent it.
    pub client: u64,
    /// When it started, in milliseconds since the watchdog started (daemon start).
    pub started_ms: u64,
    /// How long it had run when the watchdog recorded it.
    pub busy_ms: u64,
}
