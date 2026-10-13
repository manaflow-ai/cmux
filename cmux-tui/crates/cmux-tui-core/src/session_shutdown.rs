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
