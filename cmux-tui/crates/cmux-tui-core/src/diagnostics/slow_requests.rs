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
    /// The stack of the thread running it when it was recorded, innermost
    /// first: the interrupted pc, then return addresses. Empty when
    /// `stack_error` is set.
    pub stack: Vec<SlowRequestFrame>,
    /// Why `stack` is empty: `unsupported`, `suspend-failed`,
    /// `thread-state-failed`, `signal-failed`, `timeout` or `run-ended`.
    pub stack_error: Option<&'static str>,
}

/// One frame of a [`SlowRequest`] stack, for offline symbolication.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct SlowRequestFrame {
    /// The file name of the image that holds the address; null when no
    /// loaded image does.
    pub image: Option<String>,
    /// The address minus the image's load address (the address itself
    /// when `image` is null): `addr2line -e IMAGE OFFSET`, or for a Mach-O
    /// image `atos -o IMAGE -l 0x100000000 0x100000000+OFFSET`.
    pub offset: u64,
    /// The nearest exported symbol, mangled; null for a local function.
    pub symbol: Option<String>,
}
