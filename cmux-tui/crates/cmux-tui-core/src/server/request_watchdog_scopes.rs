//! What the request watchdog watches besides a request ([`WatchKind`]) and
//! the process's watchdog, for scopes opened with no `Mux` at hand (the
//! holder link's frames).

use std::sync::atomic::Ordering;
use std::sync::{Arc, OnceLock};
use std::time::Duration;

use super::{FLAGS, REQUEST_HANG_THRESHOLD, Shared, WatchedMethod};

/// What a watched scope is: its name in the hang log, its tiers and how its
/// method is named. Stored in a slot as [`Self::raw`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum WatchKind {
    /// A daemon request: recorded in `slow_requests` past the threshold,
    /// written to the hang log past [`REQUEST_HANG_THRESHOLD`].
    MuxConn,
    /// One batch commit of the journal writer: requests wait on it.
    JournalWriter,
    /// One frame the holder link's reader routes: every terminal's output
    /// waits behind it.
    #[cfg(unix)]
    HolderLink,
    /// Debug builds only: the owner's hang log test (tests/owner_panic.rs).
    #[cfg(debug_assertions)]
    OwnerTest,
}

impl WatchKind {
    pub(super) fn from_raw(raw: u32) -> Self {
        match raw {
            1 => Self::JournalWriter,
            #[cfg(unix)]
            2 => Self::HolderLink,
            #[cfg(debug_assertions)]
            3 => Self::OwnerTest,
            _ => Self::MuxConn,
        }
    }

    pub(super) const fn raw(self) -> u32 {
        match self {
            Self::MuxConn => 0,
            Self::JournalWriter => 1,
            #[cfg(unix)]
            Self::HolderLink => 2,
            #[cfg(debug_assertions)]
            Self::OwnerTest => 3,
        }
    }

    /// The scope's name in each hang record.
    pub(crate) const fn name(self) -> &'static str {
        match self {
            Self::MuxConn => "mux-conn",
            Self::JournalWriter => "journal-writer",
            #[cfg(unix)]
            Self::HolderLink => "holder-link",
            #[cfg(debug_assertions)]
            Self::OwnerTest => "owner-hang-test",
        }
    }

    /// Past this a scope is written to the hang log with its stack.
    pub(crate) const fn hang(self) -> Duration {
        match self {
            Self::MuxConn => REQUEST_HANG_THRESHOLD,
            Self::JournalWriter => crate::workspace_registry::session_journal::JOURNAL_WRITER_HANG,
            #[cfg(unix)]
            Self::HolderLink => crate::holder_runtime::HOLDER_LINK_HANG,
            #[cfg(debug_assertions)]
            Self::OwnerTest => Duration::from_millis(500),
        }
    }

    /// Whether the kind's first tier is the watchdog threshold, recorded in
    /// `slow_requests`; the other kinds have only the hang tier.
    pub(super) const fn records_slow(self) -> bool {
        matches!(self, Self::MuxConn)
    }

    /// The name of a scope's method, read only when a record is written.
    pub(crate) fn method_name(self, method: u32) -> &'static str {
        match self {
            Self::MuxConn => WatchedMethod(method).name(),
            Self::JournalWriter => "commit-batch",
            #[cfg(unix)]
            Self::HolderLink => crate::holder_runtime::holder_frame_name(method),
            #[cfg(debug_assertions)]
            Self::OwnerTest => "owner-hang-test",
        }
    }
}

/// The process's watchdog ([`super::RequestWatchdog::watch_for_process`]).
pub(super) static PROCESS: OnceLock<Arc<Shared>> = OnceLock::new();

/// Open a scope of `kind` on the process's watchdog for a caller that
/// cannot hold a [`super::RequestScope`] (a seam of a crate that does not link
/// this one); end it with [`process_exit`]. 0: no scope (no process
/// watchdog, it stopped, or every slot is taken).
// perf-hot: <100ns daemon-request
pub(crate) fn process_enter(kind: WatchKind, method: u32) -> u32 {
    let Some(shared) = PROCESS.get() else { return 0 };
    if shared.stopping.load(Ordering::Relaxed) {
        return 0;
    }
    shared.claim(kind, 0, method).map_or(0, |(index, _)| u32::try_from(index + 1).unwrap_or(0))
}

/// End the scope [`process_enter`] returned `token` for. Each token is
/// ended once.
// perf-hot: <100ns daemon-request
pub(crate) fn process_exit(token: u32) {
    let (Some(shared), Some(index)) = (PROCESS.get(), token.checked_sub(1)) else { return };
    let Some(slot) = shared.slots.get(index as usize) else { return };
    // The slot is this scope's until it ends: the watchdog changes only its
    // flags, never its start.
    let word = slot.busy.load(Ordering::Relaxed) & !FLAGS;
    shared.end_run(slot, word);
}

/// Debug builds only: block a thread named `owner-hang-test` in a scope of
/// [`WatchKind::OwnerTest`] on the process's watchdog, so its hang is
/// written to the hang log (tests/owner_panic.rs).
#[cfg(debug_assertions)]
pub(crate) fn spawn_owner_hang_test() {
    let _ = cmux_threads::spawn("owner-hang-test", cmux_threads::ThreadQos::Utility, || {
        let _token = process_enter(WatchKind::OwnerTest, 0);
        loop {
            std::thread::park();
        }
    });
}
