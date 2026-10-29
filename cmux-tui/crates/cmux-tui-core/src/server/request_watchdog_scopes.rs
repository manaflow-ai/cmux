//! What the request watchdog watches besides a request ([`WatchKind`]) and
//! the process's watchdog, for scopes opened with no `Mux` at hand (the
//! holder link's frames, a holder loop's hang report).
//!
//! The key echo path threads (crate::echo_thread) watch each item of their
//! work, never their wait for the next one, at [`ECHO_ITEM_HANG`], as Chrome
//! watches each task a thread runs and not its idle wait
//! (base/threading/hang_watcher.h, `WatchHangsInScope`).

#[cfg(debug_assertions)]
use crate::supervised::{self, Fatal, ShutdownBehavior};
use std::sync::atomic::Ordering;
use std::sync::{Arc, OnceLock};
use std::time::Duration;

use super::{FLAGS, REQUEST_HANG_THRESHOLD, RequestScope, Shared, WatchedMethod};

/// An item of echo thread work busy this long is a hang: every keystroke's
/// echo on that thread waits behind it.
pub(crate) const ECHO_ITEM_HANG: Duration = Duration::from_millis(100);

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
    /// One item a connection's `mux-line-out` writer writes to its socket.
    LineOut,
    /// One input write of `mux-pty-input` to a local terminal.
    PtyInput,
    /// One item a byte or browser view's drain sends (the scope keeps the
    /// name of the thread that once ran it).
    AttachOut,
    /// One item a render view's drain sends.
    RenderAttachOut,
    /// One item a snapshot viewer's drain builds and queues (a READY, a
    /// history or images chunk, output, a digest): it runs on a worker the
    /// echo path shares.
    SnapshotAttachOut,
}

impl WatchKind {
    pub(super) fn from_raw(raw: u32) -> Self {
        match raw {
            1 => Self::JournalWriter,
            #[cfg(unix)]
            2 => Self::HolderLink,
            #[cfg(debug_assertions)]
            3 => Self::OwnerTest,
            4 => Self::LineOut,
            5 => Self::PtyInput,
            6 => Self::AttachOut,
            7 => Self::RenderAttachOut,
            8 => Self::SnapshotAttachOut,
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
            Self::LineOut => 4,
            Self::PtyInput => 5,
            Self::AttachOut => 6,
            Self::RenderAttachOut => 7,
            Self::SnapshotAttachOut => 8,
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
            Self::LineOut => "mux-line-out",
            Self::PtyInput => "mux-pty-input",
            Self::AttachOut => "mux-attach-out",
            Self::RenderAttachOut => "mux-render-attach-out",
            Self::SnapshotAttachOut => "mux-snapshot-attach-out",
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
            Self::LineOut
            | Self::PtyInput
            | Self::AttachOut
            | Self::RenderAttachOut
            | Self::SnapshotAttachOut => ECHO_ITEM_HANG,
        }
    }

    /// An echo thread's item: its hang tier is under the watchdog's
    /// threshold, which is only the period the watchdog wakes on.
    pub(super) const fn is_echo(self) -> bool {
        matches!(
            self,
            Self::LineOut
                | Self::PtyInput
                | Self::AttachOut
                | Self::RenderAttachOut
                | Self::SnapshotAttachOut
        )
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
            Self::LineOut => "write-item",
            Self::PtyInput => "write-input",
            Self::AttachOut | Self::RenderAttachOut | Self::SnapshotAttachOut => "frame",
        }
    }

    /// A run's span in the hang ledger: `<scope>:<method>`.
    pub(super) fn hang_span(self, method: u32) -> String {
        format!("{}:{}", self.name(), self.method_name(method))
    }
}

/// The echo thread items a [`super::RequestWatchdog`] watches; a clone may
/// move to a thread that has no `Mux` at hand (`mux-pty-input` of the
/// cmux-tui app). It does not keep the `Mux` alive.
#[derive(Clone)]
pub struct EchoWatch {
    shared: Arc<Shared>,
}

impl EchoWatch {
    pub(super) fn new(shared: Arc<Shared>) -> Self {
        Self { shared }
    }

    /// Watch one item of `kind` (an echo thread's) until the scope drops;
    /// `None` once the watchdog stopped or every slot is taken.
    // perf-hot: <100ns daemon-request
    pub(crate) fn item(&self, kind: WatchKind) -> Option<RequestScope<'_>> {
        debug_assert!(kind.is_echo());
        if self.shared.stopping.load(Ordering::Relaxed) {
            return None;
        }
        let (_, slot, word) = self.shared.claim(kind, 0, 0)?;
        Some(RequestScope::new(&self.shared, slot, word))
    }

    /// [`Self::item`] for a `mux-pty-input` write.
    pub fn pty_input_write(&self) -> Option<EchoItem<'_>> {
        self.item(WatchKind::PtyInput).map(|scope| EchoItem { _scope: scope })
    }
}

/// One watched echo item outside this crate; dropping it ends the watch.
#[must_use = "the item is watched until it drops"]
pub struct EchoItem<'a> {
    _scope: RequestScope<'a>,
}

/// A holder's loop pass that its own hang watcher saw busy past
/// `deadline_ms` (its HANG frame): queued for the watchdog thread, which
/// writes it to the process's hang log as scope `holder-loop` and counts it
/// in `slow_requests.hangs`; the caller (a holder link's reader) does no
/// disk I/O. Nothing with no process watchdog.
#[cfg(unix)]
pub(crate) fn process_report_holder_hang(site: &str, deadline_ms: u64, busy_ms: u64) {
    if let Some(shared) = PROCESS.get() {
        shared.report_hang("holder-loop", site, deadline_ms, busy_ms);
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
    shared.claim(kind, 0, method).map_or(0, |(index, _, _)| u32::try_from(index + 1).unwrap_or(0))
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
    let _ = supervised::spawn_at(
        "owner-hang-test",
        cmux_threads::ThreadQos::Utility,
        Fatal,
        ShutdownBehavior::Continue,
        || {
            let _token = process_enter(WatchKind::OwnerTest, 0);
            loop {
                std::thread::park();
            }
        },
    );
}
