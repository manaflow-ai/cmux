//! The owner's startup timings: the open's laps, and the line each start
//! appends to `startup-timings.jsonl` (see `crate::startup_timings`).

use super::*;
use crate::startup_timings::{StartupTimings, append_startup_timings, unix_now_ms};

impl Mux {
    /// The laps of this owner's open (registry, restore, terminal adoption),
    /// once; nil for a mux that was not opened from a registry or was taken.
    pub fn take_startup_timings(&self) -> Option<StartupTimings> {
        self.startup_timings.lock().unwrap_or_else(PoisonError::into_inner).take()
    }

    /// Appends `timings` to the session's `startup-timings.jsonl` (a
    /// persistent owner only: an in-memory mux has no session directory) and
    /// logs their summary. A failed write is logged, never fatal.
    pub fn record_startup_timings(&self, timings: &StartupTimings) {
        let database = self
            .workspace_registry
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .session_journal_database_path();
        let Some(session_dir) = database.as_deref().and_then(Path::parent) else { return };
        let line = timings.to_line(std::process::id(), unix_now_ms());
        if let Err(error) = append_startup_timings(session_dir, &line) {
            eprintln!("cmux-tui: could not record startup timings: {error}");
        }
        eprintln!("cmux-tui: {}", timings.summary());
    }
}
