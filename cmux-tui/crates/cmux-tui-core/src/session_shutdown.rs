//! When the owner's session was shutting down (`session-shutdown`).
//!
//! Ownership lead decision (2026-10-01, reversible; plans/cmux-next/ownership.md
//! section 3.2): a process end by signal at or after the owner began shutting
//! down (logout, reboot, `SIGTERM` or `SIGHUP` to the daemon,
//! `shutdown-daemon`, `server stop`) is a host loss, not a real end: the
//! session ended around the shell, and invariant 3 keeps its tab. Exits by
//! signal while the owner runs normally (a user's `kill`, Ctrl-C ending the
//! shell) and every exit with a status stay real ends.
//!
//! A shutdown window runs from [`SESSION_SHUTDOWN_LEAD_MS`] before the
//! shutdown start to [`SESSION_SHUTDOWN_WINDOW_MS`] after it, or to the next
//! owner's start if that is sooner. A signal exit after the window is a real
//! end again, so a daemon that hangs in its shutdown cannot keep later exits
//! dead.
//!
//! Logout signals the shell and the daemon at the same time, so a shell's
//! signal exit can reach the owner before the owner records its shutdown
//! start. The classification of such an exit is final only once the lead has
//! passed: [`SessionShutdownClock::settle`] reports it as pending until then,
//! and the owner commits the exit receipt without detaching the tabs and
//! re-classifies the receipt when the lead has passed. An owner that stops
//! first leaves the receipt to the next owner, which re-classifies it against
//! the recorded window with the same result.
//!
//! The next owner needs the previous owner's window, so the start is written
//! to a small marker file next to the workspace registry database. A file,
//! not a registry row, because the shutdown path must never wait for the
//! registry lock (an admitted journal commit may hold it). The file holds `S`
//! while the shutdown that started at `S` has no successor, and `S..E` once
//! the owner that started at `E` closed the window. A closed window stays
//! until the next shutdown replaces it, so an owner that crashes leaves the
//! same window to the next one, and exits during the crashed owner's run
//! (after `E`) stay real ends, unless closing the marker failed: then the
//! next owner closes it at its own start, so exits in the window limit after
//! `E` read as host losses (the safe side). Older binaries never read the
//! file.
//!
//! A receipt that settles to a host loss after it was committed with its
//! signal (the logout race) is rewritten to the host-loss shape, so owners
//! that no longer know the window read the host loss from the receipt.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use crate::terminal_end::TerminalEnd;
use crate::terminal_host_protocol::{TerminalExit, TerminalExitOutcome};

/// How long before the recorded shutdown start a signal exit still counts
/// as part of the shutdown. Logout signals every process of the session at
/// once, so a shell can die a moment before the owner records the start.
pub(crate) const SESSION_SHUTDOWN_LEAD_MS: u64 = 2_000;

/// Debug builds only: overrides [`SESSION_SHUTDOWN_LEAD_MS`] so integration
/// tests on loaded runners do not depend on a 2 s timing window. Release
/// builds ignore it.
#[cfg(debug_assertions)]
const SESSION_SHUTDOWN_LEAD_TEST_ENV: &str = "CMUX_TUI_TEST_SESSION_SHUTDOWN_LEAD_MS";

/// How long after its start a shutdown window lasts at most.
pub(crate) const SESSION_SHUTDOWN_WINDOW_MS: u64 = 60_000;

/// The marker file next to a registry database.
pub(crate) fn owner_shutdown_marker_path(database: &Path) -> PathBuf {
    database.with_extension("owner-shutdown")
}

/// The classification of a terminal end against the shutdown windows.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum SettledEnd {
    /// No later shutdown start can change the classification.
    Final(TerminalEnd),
    /// A process end by signal within the lead before now: a shutdown start
    /// recorded before `until_ms` would make it a host loss. Commit the
    /// receipt without detaching and classify it again at `until_ms`.
    Pending { end: TerminalEnd, until_ms: u64 },
}

impl SettledEnd {
    pub(crate) fn end(&self) -> &TerminalEnd {
        match self {
            Self::Final(end) | Self::Pending { end, .. } => end,
        }
    }

    pub(crate) fn pending_until_ms(&self) -> Option<u64> {
        match self {
            Self::Final(_) => None,
            Self::Pending { until_ms, .. } => Some(*until_ms),
        }
    }
}

/// When this owner's session (and the previous owner's) was shutting down.
#[derive(Debug)]
pub(crate) struct SessionShutdownClock {
    /// From the previous owner's shutdown start to this owner's start, in
    /// Unix milliseconds.
    previous: Option<(u64, u64)>,
    /// Set before this owner's shutdown start is stamped, so a reader that
    /// sees it unset knows any later start is stamped after its own clock
    /// read.
    own_started: AtomicBool,
    /// This owner's own shutdown start; zero until stamped.
    own_since_ms: AtomicU64,
    /// Where the start is recorded for the next owner; `None` for an
    /// in-memory registry.
    marker: Option<PathBuf>,
    /// [`SESSION_SHUTDOWN_LEAD_MS`], or the debug-build test override.
    lead_ms: u64,
    /// A fixed clock for tests; zero reads the system clock.
    #[cfg(test)]
    test_now_ms: AtomicU64,
}

impl SessionShutdownClock {
    fn with_previous(previous: Option<(u64, u64)>, marker: Option<PathBuf>) -> Self {
        Self {
            previous,
            own_started: AtomicBool::new(false),
            own_since_ms: AtomicU64::new(0),
            marker,
            lead_ms: lead_ms(),
            #[cfg(test)]
            test_now_ms: AtomicU64::new(0),
        }
    }

    #[cfg(test)]
    pub(crate) fn new(previous: Option<(u64, u64)>) -> Self {
        Self::with_previous(previous, None)
    }

    /// Read (and close) the previous owner's window from `marker`, after
    /// removing temporary files a crashed rewrite left behind. A missing or
    /// unreadable marker means no window; failures are logged.
    pub(crate) fn open(marker: Option<PathBuf>, started_at_ms: u64) -> Self {
        if let Some(path) = marker.as_deref() {
            remove_stale_marker_temporaries(path);
        }
        let previous = marker.as_deref().and_then(|path| {
            previous_window(path, started_at_ms).unwrap_or_else(|error| {
                eprintln!("cmux-tui: could not read the previous session shutdown: {error:#}");
                None
            })
        });
        Self::with_previous(previous, marker)
    }

    /// The clock of exit receipts and shutdown starts, in Unix milliseconds.
    pub(crate) fn now_ms(&self) -> u64 {
        #[cfg(test)]
        {
            let fixed = self.test_now_ms.load(Ordering::Acquire);
            if fixed != 0 {
                return fixed;
            }
        }
        unix_now_ms()
    }

    #[cfg(test)]
    pub(crate) fn set_now_for_test(&self, now_ms: u64) {
        self.test_now_ms.store(now_ms, Ordering::Release);
    }

    /// Mark the start of this owner's shutdown, once (the earliest start
    /// wins), and record it for the next owner. Never takes a lock.
    pub(crate) fn begin(&self) {
        if self.own_started.swap(true, Ordering::SeqCst) {
            return;
        }
        self.stamp(self.now_ms());
    }

    #[cfg(test)]
    pub(crate) fn begin_at(&self, now_ms: u64) {
        if !self.own_started.swap(true, Ordering::SeqCst) {
            self.stamp(now_ms);
        }
    }

    fn stamp(&self, now_ms: u64) {
        let now_ms = now_ms.max(1);
        self.own_since_ms.store(now_ms, Ordering::SeqCst);
        if let Some(path) = &self.marker
            && let Err(error) = write_marker(path, &now_ms.to_string())
        {
            eprintln!("cmux-tui: could not record the session shutdown start: {error:#}");
        }
    }

    /// Whether this owner's shutdown began.
    pub(crate) fn began(&self) -> bool {
        self.own_started.load(Ordering::SeqCst)
    }

    /// This owner's shutdown start, once it began. `begin` stamps right
    /// after it sets the flag, so the wait is a few instructions.
    fn own_start(&self) -> Option<u64> {
        if !self.own_started.load(Ordering::SeqCst) {
            return None;
        }
        loop {
            let since = self.own_since_ms.load(Ordering::SeqCst);
            if since != 0 {
                return Some(since);
            }
            std::thread::yield_now();
        }
    }

    fn within(&self, start_ms: u64, end_ms: u64, exited_at_ms: u64) -> bool {
        let end_ms = end_ms.min(start_ms.saturating_add(SESSION_SHUTDOWN_WINDOW_MS));
        (start_ms.saturating_sub(self.lead_ms)..end_ms).contains(&exited_at_ms)
    }

    fn during_shutdown(&self, own_start: Option<u64>, exited_at_ms: u64) -> bool {
        let previous =
            self.previous.is_some_and(|(start, end)| self.within(start, end, exited_at_ms));
        previous || own_start.is_some_and(|start| self.within(start, u64::MAX, exited_at_ms))
    }

    fn classify_with(&self, own_start: Option<u64>, end: TerminalEnd) -> TerminalEnd {
        match end {
            TerminalEnd::ProcessEnded(TerminalExit {
                outcome: TerminalExitOutcome::Signal { signal, .. },
                exited_at_ms,
            }) if self.during_shutdown(own_start, exited_at_ms) => {
                TerminalEnd::HostLost(TerminalExit {
                    outcome: TerminalExitOutcome::Unknown {
                        reason: format!("session-shutdown: signal {signal}"),
                    },
                    exited_at_ms,
                })
            }
            other => other,
        }
    }

    /// Reclassify a process end by signal during a session shutdown as a
    /// host loss. The receipt keeps the signal in its reason and an unknown
    /// outcome, so every later owner classifies it the same way.
    #[cfg(test)]
    pub(crate) fn classify(&self, end: TerminalEnd) -> TerminalEnd {
        self.classify_with(self.own_start(), end)
    }

    /// Classify `end` and say whether a later shutdown start could still
    /// change it. Only a process end by signal while this owner has not
    /// begun shutting down, at most the lead before now, is pending: a start
    /// stamped later than the lead after the exit cannot cover it.
    pub(crate) fn settle(&self, end: TerminalEnd) -> SettledEnd {
        // Read the clock before the flag: if the flag is still unset, a
        // later `begin` sets it before it reads the clock, so its start is
        // at or after `now_ms`.
        let now_ms = self.now_ms();
        let own_start = self.own_start();
        let end = self.classify_with(own_start, end);
        match &end {
            TerminalEnd::ProcessEnded(TerminalExit {
                outcome: TerminalExitOutcome::Signal { .. },
                exited_at_ms,
            }) if own_start.is_none() => {
                let until_ms = exited_at_ms.saturating_add(self.lead_ms + 1);
                if now_ms < until_ms {
                    SettledEnd::Pending { end, until_ms }
                } else {
                    SettledEnd::Final(end)
                }
            }
            _ => SettledEnd::Final(end),
        }
    }
}

fn lead_ms() -> u64 {
    #[cfg(debug_assertions)]
    if let Some(lead_ms) =
        std::env::var(SESSION_SHUTDOWN_LEAD_TEST_ENV).ok().and_then(|value| value.parse().ok())
    {
        return lead_ms;
    }
    SESSION_SHUTDOWN_LEAD_MS
}

fn previous_window(path: &Path, started_at_ms: u64) -> anyhow::Result<Option<(u64, u64)>> {
    let value = match std::fs::read_to_string(path) {
        Ok(value) => value,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error.into()),
    };
    let value = value.trim();
    if let Some((start, end)) = value.split_once("..") {
        return Ok(start.parse().ok().zip(end.parse().ok()));
    }
    let Ok(start) = value.parse::<u64>() else { return Ok(None) };
    let end = started_at_ms.max(start);
    // The window is known now; closing it in the file only helps the owner
    // after this one, so a failed rewrite keeps the window. The next owner
    // then closes it at its own start, which the window limit bounds.
    if let Err(error) = write_marker(path, &format!("{start}..{end}")) {
        eprintln!("cmux-tui: could not close the previous session shutdown window: {error:#}");
    }
    Ok(Some((start, end)))
}

/// The temporary file name prefix and suffix `write_marker` uses for
/// `path`: `<marker file name>.<pid>.tmp`.
fn marker_temporary_affixes(path: &Path) -> Option<(String, &'static str)> {
    let name = path.file_name()?.to_str()?;
    Some((format!("{name}."), ".tmp"))
}

/// Remove the temporary files of marker rewrites that never reached their
/// rename (a crash in between). Only the registry's owner opens the marker,
/// so no other writer is mid-rewrite. Failures are logged.
fn remove_stale_marker_temporaries(path: &Path) {
    let (Some(directory), Some((prefix, suffix))) = (path.parent(), marker_temporary_affixes(path))
    else {
        return;
    };
    let entries = match std::fs::read_dir(directory) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return,
        Err(error) => {
            eprintln!("cmux-tui: could not list session shutdown marker files: {error:#}");
            return;
        }
    };
    for entry in entries.flatten() {
        let name = entry.file_name();
        let Some(name) = name.to_str() else { continue };
        let Some(pid) = name.strip_prefix(&prefix).and_then(|rest| rest.strip_suffix(suffix))
        else {
            continue;
        };
        if pid.is_empty() || !pid.bytes().all(|byte| byte.is_ascii_digit()) {
            continue;
        }
        if !entry.file_type().is_ok_and(|kind| kind.is_file()) {
            continue;
        }
        if let Err(error) = std::fs::remove_file(entry.path()) {
            eprintln!("cmux-tui: could not remove a stale session shutdown marker file: {error:#}");
        }
    }
}

/// Replace the marker atomically (a private temporary file, then rename).
fn write_marker(path: &Path, value: &str) -> anyhow::Result<()> {
    use std::io::Write;

    let temporary = path.with_extension(format!("owner-shutdown.{}.tmp", std::process::id()));
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(&temporary)?;
    file.write_all(value.as_bytes())?;
    file.sync_all()?;
    drop(file);
    std::fs::rename(&temporary, path)?;
    Ok(())
}

/// The current time in Unix milliseconds, the clock of exit receipts.
pub(crate) fn unix_now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .min(u128::from(u64::MAX)) as u64
}

#[cfg(test)]
mod tests {
    use super::*;

    fn signal_end(exited_at_ms: u64) -> TerminalEnd {
        TerminalEnd::ProcessEnded(TerminalExit {
            outcome: TerminalExitOutcome::Signal { signal: 1, core_dumped: false },
            exited_at_ms,
        })
    }

    fn exit_end(exited_at_ms: u64) -> TerminalEnd {
        TerminalEnd::ProcessEnded(TerminalExit {
            outcome: TerminalExitOutcome::Exit { code: 0 },
            exited_at_ms,
        })
    }

    #[test]
    fn signal_exits_during_the_previous_shutdown_are_host_losses() {
        let clock = SessionShutdownClock::new(Some((100_000, 150_000)));
        for at in [100_000 - SESSION_SHUTDOWN_LEAD_MS, 100_000, 125_000, 149_999] {
            let end = clock.classify(signal_end(at));
            assert!(matches!(end, TerminalEnd::HostLost(_)), "{at}: {end:?}");
            assert!(end.detach_proof().is_none());
            assert_eq!(end.exit().exited_at_ms, at);
            let receipt = serde_json::json!({
                "outcome": end.exit().outcome,
                "exited_at": at.to_string(),
                "revision": "1",
            });
            assert!(matches!(TerminalEnd::from_receipt(Some(&receipt)), TerminalEnd::HostLost(_)));
        }
        // Before the shutdown or during this owner's run: a real end.
        for at in [100_000 - SESSION_SHUTDOWN_LEAD_MS - 1, 150_000, 300_000] {
            assert!(matches!(clock.classify(signal_end(at)), TerminalEnd::ProcessEnded(_)));
        }
        // An exit with a status is always a real end.
        assert!(matches!(clock.classify(exit_end(125_000)), TerminalEnd::ProcessEnded(_)));
    }

    #[test]
    fn signal_exits_after_this_owner_began_shutting_down_are_host_losses() {
        let clock = SessionShutdownClock::new(None);
        assert!(matches!(clock.classify(signal_end(50_000)), TerminalEnd::ProcessEnded(_)));
        clock.begin_at(50_000);
        clock.begin_at(60_000);
        assert!(matches!(clock.classify(signal_end(50_001)), TerminalEnd::HostLost(_)));
        assert!(matches!(clock.classify(exit_end(50_001)), TerminalEnd::ProcessEnded(_)));
        assert!(matches!(
            clock.classify(signal_end(50_000 - SESSION_SHUTDOWN_LEAD_MS - 1)),
            TerminalEnd::ProcessEnded(_)
        ));
    }

    #[test]
    fn a_shutdown_window_closes_at_the_next_start_and_survives_a_crash() {
        let root = std::env::temp_dir()
            .join(format!("cmux-owner-shutdown-{}", crate::workspace_registry::new_uuid_v4()));
        std::fs::create_dir_all(&root).unwrap();
        let marker = owner_shutdown_marker_path(&root.join("workspace-registry.sqlite3"));
        assert_eq!(SessionShutdownClock::open(Some(marker.clone()), 10).previous, None);
        let first = SessionShutdownClock::open(Some(marker.clone()), 10);
        first.begin_at(1_000);
        first.begin_at(2_000);

        // The next owner closes the window at its start.
        let second = SessionShutdownClock::open(Some(marker.clone()), 5_000);
        assert_eq!(second.previous, Some((1_000, 5_000)));
        // That owner crashed without a shutdown: the same window again.
        let third = SessionShutdownClock::open(Some(marker.clone()), 9_000);
        assert_eq!(third.previous, Some((1_000, 5_000)));
        // The next shutdown replaces it.
        third.begin_at(10_000);
        let fourth = SessionShutdownClock::open(Some(marker), 12_000);
        assert_eq!(fourth.previous, Some((10_000, 12_000)));
        let _ = std::fs::remove_dir_all(root);
    }

    fn scratch_marker(name: &str) -> (PathBuf, PathBuf) {
        let root = std::env::temp_dir().join(format!(
            "cmux-owner-shutdown-{name}-{}",
            crate::workspace_registry::new_uuid_v4()
        ));
        std::fs::create_dir_all(&root).unwrap();
        let marker = owner_shutdown_marker_path(&root.join("workspace-registry.sqlite3"));
        (root, marker)
    }

    /// A shutdown window lasts from its start to 60 s after it, even when no
    /// owner starts in between: a signal exit after that is a real end again.
    #[test]
    fn a_shutdown_window_ends_sixty_seconds_after_its_start() {
        let previous = SessionShutdownClock::new(Some((100_000, 400_000)));
        let limit = 100_000 + SESSION_SHUTDOWN_WINDOW_MS;
        assert!(matches!(previous.classify(signal_end(limit - 1)), TerminalEnd::HostLost(_)));
        for at in [limit, 300_000] {
            let end = previous.classify(signal_end(at));
            assert!(matches!(end, TerminalEnd::ProcessEnded(_)), "{at}: {end:?}");
        }
        // A next owner that starts sooner still closes the window at its start.
        let closed = SessionShutdownClock::new(Some((100_000, 120_000)));
        assert!(matches!(closed.classify(signal_end(120_000)), TerminalEnd::ProcessEnded(_)));

        let own = SessionShutdownClock::new(None);
        own.begin_at(50_000);
        let limit = 50_000 + SESSION_SHUTDOWN_WINDOW_MS;
        assert!(matches!(own.classify(signal_end(limit - 1)), TerminalEnd::HostLost(_)));
        for at in [limit, 200_000] {
            let end = own.classify(signal_end(at));
            assert!(matches!(end, TerminalEnd::ProcessEnded(_)), "{at}: {end:?}");
        }
    }

    /// The previous window is known once the marker is read; failing to
    /// rewrite it (closing the window) must not lose it.
    #[test]
    fn a_failed_marker_rewrite_still_returns_the_previous_window() {
        let (root, marker) = scratch_marker("rewrite-fails");
        std::fs::write(&marker, "1000").unwrap();
        // A directory where the rewrite's temporary file goes makes the
        // rewrite fail, also for a privileged test user.
        let temporary = marker.with_extension(format!("owner-shutdown.{}.tmp", std::process::id()));
        std::fs::create_dir_all(&temporary).unwrap();
        let clock = SessionShutdownClock::open(Some(marker.clone()), 5_000);
        assert_eq!(clock.previous, Some((1_000, 5_000)));
        assert!(matches!(clock.classify(signal_end(1_500)), TerminalEnd::HostLost(_)));
        assert_eq!(std::fs::read_to_string(&marker).unwrap(), "1000");
        let _ = std::fs::remove_dir_all(root);
    }

    /// A crash between creating and renaming the marker's temporary file
    /// leaves it behind; the next owner removes it at open.
    #[test]
    fn opening_removes_stale_marker_temporary_files() {
        let (root, marker) = scratch_marker("stale-temporary");
        let stale = marker.with_extension("owner-shutdown.4242.tmp");
        std::fs::write(&stale, "1000").unwrap();
        let unrelated = root.join("other-registry.owner-shutdown.4242.tmp");
        std::fs::write(&unrelated, "1000").unwrap();
        let clock = SessionShutdownClock::open(Some(marker), 10);
        assert_eq!(clock.previous, None);
        assert!(!stale.exists(), "the stale temporary file stayed");
        assert!(unrelated.exists(), "another registry's file was removed");
        let _ = std::fs::remove_dir_all(root);
    }

    /// A signal exit stays pending for the lead while this owner runs, and
    /// is final once the lead has passed or the shutdown has begun.
    #[test]
    fn a_live_signal_exit_settles_after_the_lead() {
        let clock = SessionShutdownClock::new(None);
        clock.set_now_for_test(10_000);
        let pending = clock.settle(signal_end(10_000));
        let until = 10_000 + SESSION_SHUTDOWN_LEAD_MS + 1;
        assert_eq!(pending.pending_until_ms(), Some(until));
        assert!(pending.end().detach_proof().is_some());
        // An exit with a status, or an older signal exit, is final.
        assert_eq!(clock.settle(exit_end(10_000)), SettledEnd::Final(exit_end(10_000)));
        clock.set_now_for_test(until);
        assert_eq!(clock.settle(signal_end(10_000)), SettledEnd::Final(signal_end(10_000)));

        // A shutdown that starts within the lead makes it a host loss.
        let clock = SessionShutdownClock::new(None);
        clock.set_now_for_test(10_000);
        assert!(clock.settle(signal_end(10_000)).pending_until_ms().is_some());
        clock.set_now_for_test(11_000);
        clock.begin();
        clock.set_now_for_test(until);
        let settled = clock.settle(signal_end(10_000));
        assert!(matches!(settled, SettledEnd::Final(TerminalEnd::HostLost(_))), "{settled:?}");
        // A start later than the lead after the exit does not cover it.
        let clock = SessionShutdownClock::new(None);
        clock.begin_at(10_000 + SESSION_SHUTDOWN_LEAD_MS + 1);
        let settled = clock.settle(signal_end(10_000));
        assert_eq!(settled, SettledEnd::Final(signal_end(10_000)));
    }
}
