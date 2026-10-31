//! `server-stats`: where the daemon spends its time.

use super::{MAX_SERVER_CONNECTIONS, Mux};
use crate::diagnostics::{SERVER_STATS_SCHEMA, ServerStatsSnapshot};

/// The optional section that reports resource projection spans.
const RESOURCE_PROJECTION: &str = "resource_projection";
/// The optional section that reports which thread commits durable writes.
const WRITE_PATH: &str = "write_path";
/// The optional section that reports the registry and state locks by site.
const LOCKS: &str = "locks";
/// The optional section that counts the session's queued agent hook events
/// and those `reset-state` dropped (`diagnostics::HookQueueSnapshot`).
const HOOK_QUEUE: &str = "hook_queue";

/// Read every counter; sections outside `include` stay absent so older SDK
/// decoders, which refuse unknown result fields, keep working.
pub(super) fn server_stats(mux: &Mux, include: Option<&[String]>) -> ServerStatsSnapshot {
    let wants = |section: &str| include.is_some_and(|names| names.iter().any(|n| n == section));
    ServerStatsSnapshot {
        schema: SERVER_STATS_SCHEMA,
        uptime_ms: u64::try_from(mux.uptime().as_millis()).unwrap_or(u64::MAX),
        registry_lock: mux.registry_lock_stats(),
        journal_writer: mux.journal_writer_stats(),
        connections: mux.connection_stats().snapshot(MAX_SERVER_CONNECTIONS as u64),
        resource_projection: wants(RESOURCE_PROJECTION).then(|| mux.resource_projection_stats()),
        write_path: wants(WRITE_PATH).then(|| mux.write_path_stats()),
        locks: wants(LOCKS).then(|| mux.lock_detail_stats()),
        hook_queue: wants(HOOK_QUEUE)
            .then(|| {
                mux.connection_stats().socket().map(crate::diagnostics::HookQueueSnapshot::beside)
            })
            .flatten(),
    }
}

#[cfg(test)]
#[path = "server_stats_tests.rs"]
mod tests;
