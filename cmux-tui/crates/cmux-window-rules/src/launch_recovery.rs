//! How this launch follows the previous run: clean, a restart (restore
//! everything and show the notice), or a safe restart after a restart loop
//! (the pages the quick-ending run started wait for Reload). Pure: the app's
//! `AppRunMarker` reads the previous run's marker and asks here. Was
//! `LaunchRecovery.swift`.

use serde::{Deserialize, Serialize};

/// `SIGHUP`, `SIGINT`, `SIGTERM` (the same numbers on macOS and Linux): the
/// signals that ask the app to quit (`kill`, Ctrl-C in the launching
/// terminal, that terminal closing). Ending on one is never a restart.
pub const REQUESTED_QUIT_SIGNALS: [i32; 3] = [1, 2, 15];

/// The footprint at or above which a signal-less, unrequested end reads as an
/// OOM kill (`MemoryPressureReporter.defaultHighFootprintMegabytes`).
pub const HIGH_FOOTPRINT_MEGABYTES: i64 = 4 * 1024;

/// What the previous run left behind (`PreviousRun`), the facts the rules read.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct PreviousRun {
    /// That run followed a crash or a quick kill (`watches_for_loop`).
    pub recovery: bool,
    /// That run lived past the quick-crash window (60 s).
    pub survived: bool,
    /// The fatal signal the run's handler wrote. None: the process ended
    /// without a handler running (SIGKILL, jetsam, power loss).
    pub signal: Option<i32>,
    /// That run had begun a quit someone asked for when it ended. None in
    /// markers written before the field existed.
    pub quitting: Option<bool>,
    /// The run ended on an uncaught Objective-C exception.
    pub exception: bool,
    /// The last crash-context snapshot's footprint, if any.
    pub footprint_megabytes: Option<i64>,
    /// Restored browser tabs whose page the run started before it lived past
    /// the quick-crash window.
    pub started_pages: Option<Vec<String>>,
}

impl PreviousRun {
    /// The run ended because someone asked it to: a requested-quit signal its
    /// handler recorded, or no fatal signal while a requested quit ran. A
    /// fault during a quit is still a crash.
    pub fn ended_as_asked(&self) -> bool {
        match self.signal {
            Some(signal) => REQUESTED_QUIT_SIGNALS.contains(&signal),
            None => self.quitting == Some(true),
        }
    }

    /// Its fatal signal handler wrote the signal, or it ended on an uncaught
    /// exception. `kill -9`, jetsam and power loss are not crashes.
    pub fn crashed(&self) -> bool {
        self.signal.is_some() || self.exception
    }

    /// A signal-less, unrequested end after a high-footprint snapshot: the
    /// marker's only reliable sign of an OOM kill.
    pub fn was_likely_oom(&self) -> bool {
        if self.signal.is_some() || self.exception || self.ended_as_asked() {
            return false;
        }
        self.footprint_megabytes.unwrap_or(0) >= HIGH_FOOTPRINT_MEGABYTES
    }
}

/// How this launch follows the previous one.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Recovery {
    /// It quit normally, was asked to, or was killed with no handler running
    /// and no OOM evidence.
    Clean,
    /// It ended unexpectedly: restore everything and show the notice.
    Restarted,
    /// It followed a crash or quick kill and ended again soon after it
    /// started: restore everything, but its started pages wait for Reload.
    RestartedSafely,
}

/// How this launch follows `previous`.
pub fn decide(previous: Option<&PreviousRun>) -> Recovery {
    let Some(previous) = previous.filter(|run| !run.ended_as_asked()) else {
        return Recovery::Clean;
    };
    if previous.was_likely_oom() {
        return Recovery::Restarted;
    }
    if previous.recovery && !previous.survived {
        return Recovery::RestartedSafely;
    }
    if previous.crashed() { Recovery::Restarted } else { Recovery::Clean }
}

/// Whether this launch watches for a restart loop: it follows a crash, or a
/// run killed within the quick-crash window (a hang at restore ends in Force
/// Quit, which records no signal).
pub fn watches_for_loop(previous: Option<&PreviousRun>) -> bool {
    if decide(previous) != Recovery::Clean {
        return true;
    }
    previous.is_some_and(|run| !run.ended_as_asked() && !run.survived)
}

/// The launch's whole answer.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Plan {
    pub recovery: Recovery,
    pub watches_for_loop: bool,
    /// The restored tabs whose page stays unloaded until the person reloads
    /// it: only after a restart loop, the pages the quick-ending run started.
    pub crashed_pages: Vec<String>,
    /// In a restart loop the updater starts before windows.
    pub starts_updater_before_windows: bool,
}

/// `decide`, `watches_for_loop` and the crashed pages in one answer.
pub fn plan(previous: Option<&PreviousRun>) -> Plan {
    let recovery = decide(previous);
    let mut crashed_pages = match (recovery, previous) {
        (Recovery::RestartedSafely, Some(run)) => run.started_pages.clone().unwrap_or_default(),
        _ => Vec::new(),
    };
    crashed_pages.sort();
    crashed_pages.dedup();
    Plan {
        recovery,
        watches_for_loop: watches_for_loop(previous),
        crashed_pages,
        starts_updater_before_windows: recovery == Recovery::RestartedSafely,
    }
}

#[cfg(test)]
#[path = "launch_recovery_tests.rs"]
mod tests;
