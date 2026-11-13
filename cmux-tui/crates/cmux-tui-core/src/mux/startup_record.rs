//! The owner's startup timings: the open's laps, and the line each start
//! appends to `startup-timings.jsonl` (see `crate::startup_timings`).

use super::*;
use crate::startup_timings::{
    StartupTimings, add_after_ready, append_startup_timings, unix_now_ms,
};

/// The owner's laps for `startup-timings.jsonl`. Two leaf locks.
#[derive(Default)]
pub(super) struct StartupLaps {
    /// The laps of the open (registry, restore, adoption), until the owner's start takes them.
    pub(super) open: Mutex<Option<StartupTimings>>,
    /// Held over the write of the file.
    after_ready: Mutex<AfterReady>,
}

/// The start line of this owner in `startup-timings.jsonl`, and the laps of the work that ends
/// after ready (the restatement in parts). Either can come first: the one that comes second
/// writes the laps into the line.
#[derive(Debug, Default)]
struct AfterReady {
    /// The session directory and the `pid` and `at_ms` of the line, once it is in the file.
    line: Option<(std::path::PathBuf, u32, u64)>,
    laps: Option<Value>,
}

impl Mux {
    /// The laps of this owner's open (registry, restore, terminal adoption),
    /// once; nil for a mux that was not opened from a registry or was taken.
    pub fn take_startup_timings(&self) -> Option<StartupTimings> {
        self.startup_timings.open.lock().unwrap_or_else(PoisonError::into_inner).take()
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
        self.open_slow_request_log(session_dir, database.as_deref());
        let (pid, at_ms) = (std::process::id(), unix_now_ms());
        let mut line = timings.to_line(pid, at_ms);
        let mut after_ready =
            self.startup_timings.after_ready.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(laps) = after_ready.laps.clone() {
            line["after_ready"] = laps;
        }
        match append_startup_timings(session_dir, &line) {
            Ok(()) => after_ready.line = Some((session_dir.to_path_buf(), pid, at_ms)),
            Err(error) => eprintln!("cmux-tui: could not record startup timings: {error}"),
        }
        drop(after_ready);
        eprintln!("cmux-tui: {}", timings.summary());
    }

    /// The laps of the restatement in parts, which ends after ready: a list `after_ready` on
    /// the line of this start (`total_ms` and `steps` do not change). When the line is not in
    /// the file yet, [`Self::record_startup_timings`] writes them with it.
    pub(super) fn record_session_restate(
        &self,
        tally: &startup_restore::restate_parts::RestateTally,
    ) {
        let mut after_ready =
            self.startup_timings.after_ready.lock().unwrap_or_else(PoisonError::into_inner);
        let laps = tally.laps();
        if let Some((session_dir, pid, at_ms)) = after_ready.line.as_ref()
            && let Err(error) = add_after_ready(session_dir, *pid, *at_ms, &laps)
        {
            eprintln!("cmux-tui: could not record the laps after ready: {error}");
        }
        after_ready.laps = Some(laps);
    }

    /// The laps that [`Self::record_session_restate`] took, for tests.
    #[cfg(test)]
    pub(crate) fn session_restate_laps_for_test(&self) -> Option<Value> {
        self.startup_timings.after_ready.lock().unwrap_or_else(PoisonError::into_inner).laps.clone()
    }

    /// Opens the session's slow request log (`diagnostics/request_log.rs`) in `session_dir`,
    /// names the two session locks to it, and writes its start line.
    pub(crate) fn open_slow_request_log(&self, session_dir: &Path, database: Option<&Path>) {
        use crate::diagnostics::request_log::{Label, StartInfo};
        let Some(log) = self.connection_stats.open_request_log(session_dir) else { return };
        self.state.stats().report_long_holds("mux.state", log.clone());
        self.workspace_registry.stats().report_long_holds("workspace.registry", log.clone());
        let bytes = |suffix: &str| {
            database.map_or(0, |path| {
                let mut name = path.as_os_str().to_os_string();
                name.push(suffix);
                std::fs::metadata(name).map_or(0, |file| file.len())
            })
        };
        let (workspaces, surfaces) =
            self.with_state(|state| (state.workspaces.len(), state.surfaces.len()));
        log.started(StartInfo {
            session_hash: session_dir
                .file_name()
                .and_then(|name| name.to_str())
                .and_then(Label::session_hash),
            workspaces,
            surfaces,
            clients: self.client_count(),
            registry_bytes: bytes(""),
            registry_wal_bytes: bytes("-wal"),
        });
    }
}
