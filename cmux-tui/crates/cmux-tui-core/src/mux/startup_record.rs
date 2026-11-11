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
        self.open_slow_request_log(session_dir, database.as_deref());
        let line = timings.to_line(std::process::id(), unix_now_ms());
        if let Err(error) = append_startup_timings(session_dir, &line) {
            eprintln!("cmux-tui: could not record startup timings: {error}");
        }
        eprintln!("cmux-tui: {}", timings.summary());
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
