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
//! The next owner needs the window from the previous owner's shutdown start
//! to its own start, so the start is written to a small marker file next to
//! the workspace registry database. A file, not a registry row, because the
//! shutdown path must never wait for the registry lock (an admitted journal
//! commit may hold it). The file holds `S` while the shutdown that started
//! at `S` has no successor, and `S..E` once the owner that started at `E`
//! closed the window. A closed window stays until the next shutdown replaces
//! it, so an owner that crashes leaves the same window to the next one, and
//! exits during the crashed owner's run (after `E`) stay real ends. Older
//! binaries never read the file.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use crate::terminal_end::TerminalEnd;
use crate::terminal_host_protocol::{TerminalExit, TerminalExitOutcome};

/// How long before the recorded shutdown start a signal exit still counts
/// as part of the shutdown. Logout signals every process of the session at
/// once, so a shell can die a moment before the owner records the start.
pub(crate) const SESSION_SHUTDOWN_LEAD_MS: u64 = 2_000;

/// The marker file next to a registry database.
pub(crate) fn owner_shutdown_marker_path(database: &Path) -> PathBuf {
    database.with_extension("owner-shutdown")
}

/// When this owner's session (and the previous owner's) was shutting down.
#[derive(Debug)]
pub(crate) struct SessionShutdownClock {
    /// From the previous owner's shutdown start to this owner's start, in
    /// Unix milliseconds.
    previous: Option<(u64, u64)>,
    /// This owner's own shutdown start; zero while it runs.
    own_since_ms: AtomicU64,
    /// Where the start is recorded for the next owner; `None` for an
    /// in-memory registry.
    marker: Option<PathBuf>,
}

impl SessionShutdownClock {
    #[cfg(test)]
    pub(crate) fn new(previous: Option<(u64, u64)>) -> Self {
        Self { previous, own_since_ms: AtomicU64::new(0), marker: None }
    }

    /// Read (and close) the previous owner's window from `marker`. A missing
    /// or unreadable marker means no window; failures are logged.
    pub(crate) fn open(marker: Option<PathBuf>, started_at_ms: u64) -> Self {
        let previous = marker.as_deref().and_then(|path| {
            previous_window(path, started_at_ms).unwrap_or_else(|error| {
                eprintln!("cmux-tui: could not read the previous session shutdown: {error:#}");
                None
            })
        });
        Self { previous, own_since_ms: AtomicU64::new(0), marker }
    }

    /// Mark the start of this owner's shutdown, once (the earliest start
    /// wins), and record it for the next owner. Never takes a lock.
    pub(crate) fn begin(&self, now_ms: u64) {
        let now_ms = now_ms.max(1);
        if self
            .own_since_ms
            .compare_exchange(0, now_ms, Ordering::AcqRel, Ordering::Acquire)
            .is_err()
        {
            return;
        }
        if let Some(path) = &self.marker
            && let Err(error) = write_marker(path, &now_ms.to_string())
        {
            eprintln!("cmux-tui: could not record the session shutdown start: {error:#}");
        }
    }

    fn during_shutdown(&self, exited_at_ms: u64) -> bool {
        let previous = self.previous.is_some_and(|(start, end)| {
            (start.saturating_sub(SESSION_SHUTDOWN_LEAD_MS)..end).contains(&exited_at_ms)
        });
        let own = self.own_since_ms.load(Ordering::Acquire);
        previous || (own != 0 && exited_at_ms >= own.saturating_sub(SESSION_SHUTDOWN_LEAD_MS))
    }

    /// Reclassify a process end by signal during a session shutdown as a
    /// host loss. The receipt keeps the signal in its reason and an unknown
    /// outcome, so every later owner classifies it the same way.
    pub(crate) fn classify(&self, end: TerminalEnd) -> TerminalEnd {
        match end {
            TerminalEnd::ProcessEnded(TerminalExit {
                outcome: TerminalExitOutcome::Signal { signal, .. },
                exited_at_ms,
            }) if self.during_shutdown(exited_at_ms) => TerminalEnd::HostLost(TerminalExit {
                outcome: TerminalExitOutcome::Unknown {
                    reason: format!("session-shutdown: signal {signal}"),
                },
                exited_at_ms,
            }),
            other => other,
        }
    }
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
    write_marker(path, &format!("{start}..{end}"))?;
    Ok(Some((start, end)))
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
        let clock = SessionShutdownClock::new(Some((100_000, 200_000)));
        for at in [100_000 - SESSION_SHUTDOWN_LEAD_MS, 100_000, 150_000, 199_999] {
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
        for at in [100_000 - SESSION_SHUTDOWN_LEAD_MS - 1, 200_000, 300_000] {
            assert!(matches!(clock.classify(signal_end(at)), TerminalEnd::ProcessEnded(_)));
        }
        // An exit with a status is always a real end.
        assert!(matches!(clock.classify(exit_end(150_000)), TerminalEnd::ProcessEnded(_)));
    }

    #[test]
    fn signal_exits_after_this_owner_began_shutting_down_are_host_losses() {
        let clock = SessionShutdownClock::new(None);
        assert!(matches!(clock.classify(signal_end(50_000)), TerminalEnd::ProcessEnded(_)));
        clock.begin(50_000);
        clock.begin(60_000);
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
        first.begin(1_000);
        first.begin(2_000);

        // The next owner closes the window at its start.
        let second = SessionShutdownClock::open(Some(marker.clone()), 5_000);
        assert_eq!(second.previous, Some((1_000, 5_000)));
        // That owner crashed without a shutdown: the same window again.
        let third = SessionShutdownClock::open(Some(marker.clone()), 9_000);
        assert_eq!(third.previous, Some((1_000, 5_000)));
        // The next shutdown replaces it.
        third.begin(10_000);
        let fourth = SessionShutdownClock::open(Some(marker), 12_000);
        assert_eq!(fourth.previous, Some((10_000, 12_000)));
        let _ = std::fs::remove_dir_all(root);
    }
}
