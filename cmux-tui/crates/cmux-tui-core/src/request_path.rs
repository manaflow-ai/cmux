//! Request-path blocking notes for the daemon (`cmux_tui_platform::request_path`,
//! re-exported here): the mode from `CMUX_TUI_REQUEST_PATH_IO` and the
//! `server-stats` `request_path_io` section.
//!
//! Every frame a connection reads, and every queued request a dispatcher or
//! worker runs, runs inside a [`RequestPathScope`] on the daemon's
//! [`RequestPathStats`]. Blocking primitives note their kind at the code that
//! called them: the registry connection (`sqlite`, and `lock_hold_over_1ms`
//! at release), journal receipt waits (`journal_wait`), process table reads
//! (`proc_scan`) and git runs (`child_process`). Queue Q9 (p05-ipc.md) is
//! `CMUX_TUI_REQUEST_PATH_IO=record cargo test -p cmux-tui-core | grep
//! REQUEST_PATH_IO`.

use std::sync::Arc;

use serde::Serialize;

pub(crate) use cmux_tui_platform::request_path::{
    BlockingKind, RequestPathMode, RequestPathScope, RequestPathStats, in_scope, note, note_at,
};

/// The daemon setting: unset or empty counts only; `record` keeps the site
/// ring and prints each note; `panic:<kind>,...` also panics on those kinds in
/// debug and test builds.
pub(crate) const MODE_ENV: &str = "CMUX_TUI_REQUEST_PATH_IO";

/// The daemon's stats, in the mode `CMUX_TUI_REQUEST_PATH_IO` names. A value
/// this build does not understand is reported once and counts only.
pub(crate) fn stats_from_env() -> Arc<RequestPathStats> {
    let mode = match std::env::var(MODE_ENV) {
        Ok(value) => RequestPathMode::parse(&value).unwrap_or_else(|error| {
            eprintln!("cmux: ignoring {MODE_ENV}: {error}");
            RequestPathMode::OFF
        }),
        Err(_) => RequestPathMode::OFF,
    };
    RequestPathStats::new(mode)
}

/// The `request_path_io` section of `server-stats`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct RequestPathIoSnapshot {
    /// The setting records sites (`record` or `panic:<kinds>`).
    pub recording: bool,
    /// Outermost request scopes entered: frames read plus queued requests run.
    pub scopes: u64,
    pub sqlite: u64,
    pub journal_wait: u64,
    pub process_spawn: u64,
    pub fs_write: u64,
    pub host_wait: u64,
    pub sleep: u64,
    pub proc_scan: u64,
    pub child_process: u64,
    pub network: u64,
    pub lock_hold_over_1ms: u64,
    /// The most recent recorded notes, newest first, at most 128.
    pub sites: Vec<RequestPathSiteSnapshot>,
}

/// One recorded note: its kind and the `file:line` that blocked.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct RequestPathSiteSnapshot {
    pub kind: &'static str,
    pub site: String,
}

impl RequestPathIoSnapshot {
    pub(crate) fn of(stats: &RequestPathStats) -> Self {
        let count = |kind| stats.count(kind);
        Self {
            recording: stats.mode().records(),
            scopes: stats.handler_runs(),
            sqlite: count(BlockingKind::Sqlite),
            journal_wait: count(BlockingKind::JournalWait),
            process_spawn: count(BlockingKind::ProcessSpawn),
            fs_write: count(BlockingKind::FsWrite),
            host_wait: count(BlockingKind::HostWait),
            sleep: count(BlockingKind::Sleep),
            proc_scan: count(BlockingKind::ProcScan),
            child_process: count(BlockingKind::ChildProcess),
            network: count(BlockingKind::Network),
            lock_hold_over_1ms: count(BlockingKind::LockHoldOver1ms),
            sites: stats
                .sites()
                .into_iter()
                .map(|noted| RequestPathSiteSnapshot {
                    kind: noted.kind.name(),
                    site: format!("{}:{}", noted.site.file(), noted.site.line()),
                })
                .collect(),
        }
    }
}

#[cfg(test)]
#[path = "request_path_tests.rs"]
mod tests;
