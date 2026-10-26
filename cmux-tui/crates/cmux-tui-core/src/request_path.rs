//! Request-path blocking notes for the daemon (`cmux_tui_platform::request_path`,
//! re-exported here): the mode from `CMUX_TUI_REQUEST_PATH_IO` and the
//! `server-stats` `request_path_io` section.
//!
//! Every frame a connection reads, and every queued request a dispatcher or
//! worker runs, runs inside a [`RequestPathScope`] on the daemon's
//! [`RequestPathStats`]. Blocking primitives note their kind at the code that
//! called them:
//!
//! - `sqlite`: the first acquisition of the registry connection
//!   (`RegistryConnection::get`, `get_at`, `pin`); `lock_hold_over_1ms` at
//!   its release, timed only while the setting records.
//! - `journal_wait`: journal writer receipt and queue-space waits
//!   (`journal_ingress`), registry intent receipts through the intent sink,
//!   and earlier indeterminate receipts (`drain_unsettled`).
//! - `process_spawn`: terminal, terminal host, browser, hook, plugin and
//!   brain process starts; `host_wait`: terminal-host handshakes and holder
//!   spawn round trips; `child_process`: git operations (`git_ops`).
//! - `proc_scan`: process table reads (`process_resources::Sampler`, the
//!   `platform::foreground_*` lookups); `fs_write`: file writes and fsyncs
//!   (`fs_ops`, attachments, state files, `platform::sync_directory`);
//!   `network`: loopback connects; `sleep`: [`sleep`], which daemon code uses
//!   in place of `std::thread::sleep`.
//!
//! The registry, store, state and mux functions between a handler and these
//! primitives are `#[track_caller]` (request_path_tests.rs checks the direct
//! connection callers), so a note's site is the handler's line. Queue Q9
//! (p05-ipc.md) is `CMUX_TUI_REQUEST_PATH_IO=record cargo test -p
//! cmux-tui-core | grep REQUEST_PATH_IO`.

use std::sync::Arc;

use serde::Serialize;

#[cfg(test)]
pub(crate) use cmux_tui_platform::request_path::in_scope;
pub(crate) use cmux_tui_platform::request_path::{
    BlockingKind, Noted, RequestPathMode, RequestPathScope, RequestPathStats, note, note_at, sleep,
};

/// The daemon setting: unset or empty counts only; `record` keeps the site
/// ring and prints each note; `panic:<kind>,...` also panics on those kinds in
/// debug and test builds.
pub(crate) const MODE_ENV: &str = "CMUX_TUI_REQUEST_PATH_IO";

/// The daemon's stats, in the mode `CMUX_TUI_REQUEST_PATH_IO` names. A value
/// this build does not understand is reported once and counts only.
pub(crate) fn stats_from_env() -> Arc<RequestPathStats> {
    RequestPathStats::new(mode_from_setting(std::env::var(MODE_ENV).ok().as_deref()))
}

/// The mode a `CMUX_TUI_REQUEST_PATH_IO` value names (`None`: unset).
fn mode_from_setting(value: Option<&str>) -> RequestPathMode {
    match value.map(RequestPathMode::parse) {
        None => RequestPathMode::OFF,
        Some(Ok(mode)) => mode,
        Some(Err(error)) => {
            eprintln!("cmux: ignoring {MODE_ENV}: {error}");
            RequestPathMode::OFF
        }
    }
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
    /// Registry connection holds of 1 ms or more. Holds are timed only while
    /// the setting records, so the field is absent otherwise (never a zero
    /// for what was not measured).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub lock_hold_over_1ms: Option<u64>,
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
            lock_hold_over_1ms: stats
                .mode()
                .records()
                .then(|| count(BlockingKind::LockHoldOver1ms)),
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
