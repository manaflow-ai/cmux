//! Which way Move to Cloud sends a folder, from the estimate and the measured uplink
//! (RFD 0066 piece 9, "Route by estimate over uplink").
//!
//! - under [`SEND_BUDGET`] of sending: [`Route::WholeSnapshot`];
//! - over it, up to [`SNAPSHOT_MAX_BYTES`] and under [`SNAPSHOT_MAX_FILES`]:
//!   [`Route::ListingFirstSnapshotBehind`] (the chat starts on the projected listing, the
//!   snapshot uploads behind it, and [`sleep_minutes`] says when the laptop may sleep);
//! - past either limit: [`Route::ListingOnly`].
//!
//! [`choose`] is pure. [`enabled`] is the off-by-default switch ([`ENV`]); with it off, Move to
//! Cloud routes as it did before this existed (`project_first` in `seed_cli.rs`).

use std::time::Duration;

/// A snapshot that sends in less than this goes whole, before the chat starts.
pub(super) const SEND_BUDGET: Duration = Duration::from_secs(60);
/// Past this many bytes (after packing) no snapshot is made: 20 GiB.
pub(super) const SNAPSHOT_MAX_BYTES: u64 = 20 * 1024 * 1024 * 1024;
/// At this many files or more no snapshot is made.
pub(super) const SNAPSHOT_MAX_FILES: u64 = 500_000;
/// The uplink assumed when none was measured (bytes a second): 0.55 MB/s, the slowest home
/// uplink in the RFD's table, so an unmeasured Mac routes toward the listing, never toward a
/// long wait. The caller says the rate was a default.
pub(super) const DEFAULT_UPLINK: u64 = 550_000;
/// The env switch (`1`/`true`): off unless set, because turning projection on for moves is
/// RFD 0066 open question 2.
pub(super) const ENV: &str = "CMUX_ROUTE_BY_ESTIMATE";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Route {
    WholeSnapshot,
    ListingFirstSnapshotBehind,
    ListingOnly,
}

/// Whether Move to Cloud routes by estimate: [`ENV`] set to `1` or `true`; off otherwise.
pub(super) fn enabled() -> bool {
    matches!(std::env::var(ENV).ok().as_deref(), Some("1" | "true"))
}

/// The route for a folder that packs to `packed_bytes` in `files` files, over an uplink of
/// `uplink` bytes a second (a zero rate counts as [`DEFAULT_UPLINK`]).
pub(super) fn choose(packed_bytes: u64, files: u64, uplink: u64) -> Route {
    if packed_bytes > SNAPSHOT_MAX_BYTES || files >= SNAPSHOT_MAX_FILES {
        return Route::ListingOnly;
    }
    if send_time(packed_bytes, uplink) < SEND_BUDGET {
        Route::WholeSnapshot
    } else {
        Route::ListingFirstSnapshotBehind
    }
}

/// How long `packed_bytes` take to send at `uplink` bytes a second.
pub(super) fn send_time(packed_bytes: u64, uplink: u64) -> Duration {
    let uplink = if uplink == 0 { DEFAULT_UPLINK } else { uplink };
    Duration::from_secs_f64(packed_bytes as f64 / uplink as f64)
}

/// "The laptop can sleep in N min": the minutes (rounded up, at least 1) the snapshot takes to
/// upload behind the listing.
pub(super) fn sleep_minutes(packed_bytes: u64, uplink: u64) -> u64 {
    ((send_time(packed_bytes, uplink).as_secs_f64() / 60.0).ceil() as u64).max(1)
}

#[cfg(test)]
#[path = "route_tests.rs"]
mod tests;
