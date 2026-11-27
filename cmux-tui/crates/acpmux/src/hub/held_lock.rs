//! Part of `Hub`; see `hub/mod.rs`. A diagnostic, never a guard: a std mutex the daemon's hot
//! paths share (the peer registry, `peer_table.rs`; the rows writer, `remote_table.rs`), held on
//! a tokio worker for longer than [`HELD_WARN`], logs where it was taken and for how long when it
//! is let go. Nothing is refused or changed by it.
//!
//! Why: Leo's daemon wedged twice on 2026-11-25 with every worker parked on one std mutex, off
//! CPU. A `sample` shows the waiters, not the holder; this line names the holder's call site
//! the way an off-CPU analysis pairs a wait with the release that ends it, so the next wedge
//! names its cause in the log instead of a symbolized sample. Coordinator, 2026-11-25: "add a
//! debug RPC or a log line that names a std mutex held longer than N ms on a runtime worker".

use std::panic::Location;
use std::time::{Duration, Instant};

/// A hold longer than this on a runtime worker is logged.
pub(crate) const HELD_WARN: Duration = Duration::from_millis(50);

/// Times one hold of a lock from its taking; logs on drop when it ran long on a worker.
pub(crate) struct HeldTimer {
    what: &'static str,
    site: &'static Location<'static>,
    at: Instant,
}

impl HeldTimer {
    #[track_caller]
    pub(crate) fn start(what: &'static str) -> Self {
        Self { what, site: Location::caller(), at: Instant::now() }
    }
}

impl Drop for HeldTimer {
    fn drop(&mut self) {
        let held = self.at.elapsed();
        if held > HELD_WARN && tokio::runtime::Handle::try_current().is_ok() {
            let thread = std::thread::current();
            tracing::warn!(
                lock = self.what,
                at = %self.site,
                held_ms = held.as_millis() as u64,
                thread = thread.name().unwrap_or("?"),
                "a std mutex was held long on a runtime worker"
            );
        }
    }
}
