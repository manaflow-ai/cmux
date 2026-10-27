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
    /// Requests that block by design (`wait-for`), so not watched past the
    /// point where they start to wait.
    pub expected_waits: u64,
    /// Times the watchdog thread could not be started; a later request
    /// tries again. Nonzero means slow requests may have gone unrecorded.
    pub spawn_failures: u64,
    /// Times the watchdog thread woke since daemon start. It watches every
    /// kind of scope (requests, journal commits, holder-link frames), so an
    /// idle daemon adds 0.
    pub watchdog_wakeups: u64,
    /// How long a request runs before it is a hang.
    pub hang_ms: u64,
    /// Scopes of every kind written to the hang log (busy past their hang
    /// tier) since daemon start, by this watchdog.
    pub hangs: u64,
    /// The newest recorded requests, oldest first.
    pub recent: Vec<SlowRequest>,
}

/// One request that ran past the watchdog threshold, recorded once.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct SlowRequest {
    /// The request's `cmd` tag, its v2 `operation`, or `frame:<handler>` for
    /// a frame a connection handler answers itself.
    pub method: &'static str,
    /// The connection that sent it.
    pub client: u64,
    /// When it started, in milliseconds since the watchdog started (daemon start).
    pub started_ms: u64,
    /// How long it had run when the watchdog recorded it.
    pub busy_ms: u64,
    /// How long it ran in total; `None` while it still runs.
    pub duration_ms: Option<u64>,
    /// The stack of the thread running it, captured while it was still
    /// busy, innermost first: the interrupted pc, then return addresses.
    /// Empty when `stack_error` is set.
    pub stack: Vec<SlowRequestFrame>,
    /// `stack` holds only the interrupted pc because the daemon was built
    /// without frame pointers (Linux without `-C force-frame-pointers=yes`).
    pub stack_truncated: bool,
    /// Why `stack` is empty: `run-ended` (it ended before the watchdog could
    /// stop its thread), `unsupported`, `suspend-failed`,
    /// `thread-state-failed`, `signal-failed` or `timeout`.
    pub stack_error: Option<&'static str>,
}

/// One frame of a [`SlowRequest`] stack, for offline symbolication.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct SlowRequestFrame {
    /// The file name of the image that holds the address; null when no
    /// loaded image does.
    pub image: Option<String>,
    /// That image's build id, to pick the matching build's symbols: the
    /// Mach-O LC_UUID as `dwarfdump --uuid` prints it, or the ELF
    /// NT_GNU_BUILD_ID in lowercase hex; null when it has none.
    pub image_id: Option<String>,
    /// The address minus the image's load address (the address itself
    /// when `image` is null): `addr2line -e IMAGE OFFSET`, or for a Mach-O
    /// image `atos -o IMAGE -l 0x100000000 0x100000000+OFFSET`.
    pub offset: u64,
    /// The nearest exported symbol, mangled; null for a local function.
    pub symbol: Option<String>,
}
