//! `carrier serve`'s quiet listener: `<socket>.quiet`, next to `--socket`,
//! for callers that redial on their own (`cmux link project serve`) and must
//! never be the reason a machine runs.
//!
//! A dial asks the platform for a carrier (`POST /v1/cloud/machines/{id}/carrier`),
//! and that request starts a machine cmux paused for idleness. The idle
//! pause counts only the machine's workload, so a caller that redials a
//! dropped link every few seconds woke the machine as often as it paused.
//!
//! A connection accepted on the quiet socket:
//! - rides the held session when there is one the current credential may
//!   use ([`super::held`]'s identity rules), with no platform call;
//! - otherwise reads the machine's state first, with the machine read that
//!   wakes nothing (`POST /v1/read` `cloud.machine.get`). `paused` or
//!   `pausing`: the connection is closed having written nothing, and the
//!   machine is marked asleep. Any other state: it dials as a main-socket
//!   connection does. A read that fails counts as a read that saw nothing:
//!   the connection is closed the same way, so a broken read never turns into
//!   a dial that wakes the machine.
//! - The state is read at most once per [`RECHECK`] per machine
//!   (`CMUX_CARRIER_SERVE_ASLEEP_RECHECK_MS`, 1 to 3 600 000, overrides it):
//!   within it a quiet connection is closed on the last read's word, so a
//!   wake from elsewhere (the phone, the app) is seen within that bound.
//! - Any connection that gets a stream (on either socket) clears the mark:
//!   the session it holds means the machine is up, and the next quiet
//!   connection rides it.
//!
//! Each quiet refusal appends one line to the connect log, never stderr:
//! `carrier.quiet machine=<vm_id> outcome=<asleep|unread> seen=<read|cached> ms=<n>`.
//! A quiet socket that cannot be had (its path does not fit a Unix socket
//! address, or it cannot be claimed) is skipped with one line,
//! `carrier.quiet machine=<vm_id> socket=skipped reason=<too_long|claim>`,
//! and serve goes on with its main socket alone.

use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, PoisonError};
use std::time::Duration;

use tokio::time::Instant;

/// How long a read that saw the machine asleep stands.
pub(super) const RECHECK: Duration = Duration::from_secs(30);

/// `<socket>.quiet`, or `None` when that path does not fit a Unix socket
/// address.
pub(super) fn quiet_path(socket: &Path) -> Option<PathBuf> {
    let mut path = OsString::from(socket.as_os_str());
    path.push(".quiet");
    let path = PathBuf::from(path);
    cmux_unix_socket::fits(&path).then_some(path)
}

/// [`RECHECK`], or `CMUX_CARRIER_SERVE_ASLEEP_RECHECK_MS` when set.
pub(super) fn recheck_time() -> Duration {
    std::env::var("CMUX_CARRIER_SERVE_ASLEEP_RECHECK_MS")
        .ok()
        .and_then(|text| text.trim().parse::<u64>().ok())
        .filter(|ms| (1..=3_600_000).contains(ms))
        .map_or(RECHECK, Duration::from_millis)
}

/// What the last read of the machine's state said, when it closed a quiet
/// connection.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Seen {
    /// `paused` or `pausing`.
    Asleep,
    /// The read failed.
    Unread,
}

impl Seen {
    pub(super) fn name(self) -> &'static str {
        match self {
            Self::Asleep => "asleep",
            Self::Unread => "unread",
        }
    }
}

/// What a quiet connection with no session to ride does.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Look {
    /// A read within the recheck time closed connections: close this one
    /// too, without reading.
    Cached(Seen),
    /// Read the machine's state now.
    Read,
}

/// Whether a status the machine read answered means it is asleep.
pub(super) fn asleep(status: &str) -> bool {
    matches!(status, "paused" | "pausing")
}

/// The machine's asleep mark.
pub(super) struct Asleep {
    recheck: Duration,
    /// When the last read that closed a connection ran, and what it saw.
    last: Mutex<Option<(Instant, Seen)>>,
}

impl Asleep {
    pub(super) fn new(recheck: Duration) -> Self {
        Self { recheck, last: Mutex::new(None) }
    }

    /// Whether a quiet connection at `now` reads the state or stands on the
    /// last read.
    pub(super) fn look(&self, now: Instant) -> Look {
        match *self.last.lock().unwrap_or_else(PoisonError::into_inner) {
            Some((at, seen)) if now.saturating_duration_since(at) < self.recheck => {
                Look::Cached(seen)
            }
            _ => Look::Read,
        }
    }

    /// Records a read at `now` that answered `status` (`Err` when it
    /// failed): `Some` closes the connection, `None` dials.
    pub(super) fn saw(&self, now: Instant, status: Result<&str, ()>) -> Option<Seen> {
        let seen = match status {
            Ok(status) if asleep(status) => Some(Seen::Asleep),
            Ok(_) => None,
            Err(()) => Some(Seen::Unread),
        };
        *self.last.lock().unwrap_or_else(PoisonError::into_inner) = seen.map(|seen| (now, seen));
        seen
    }

    /// A connection got a stream: the machine is up.
    pub(super) fn clear(&self) {
        *self.last.lock().unwrap_or_else(PoisonError::into_inner) = None;
    }
}

/// The connect log's line for one quiet refusal.
pub(super) fn refusal_line(machine: &str, seen: Seen, cached: bool, elapsed: Duration) -> String {
    format!(
        "carrier.quiet machine={machine} outcome={} seen={} ms={}\n",
        seen.name(),
        if cached { "cached" } else { "read" },
        elapsed.as_millis()
    )
}

/// The connect log's line for a quiet socket serve goes without.
pub(super) fn skipped_line(machine: &str, reason: &str) -> String {
    format!("carrier.quiet machine={machine} socket=skipped reason={reason}\n")
}

#[cfg(test)]
#[path = "serve_quiet_tests.rs"]
mod tests;
