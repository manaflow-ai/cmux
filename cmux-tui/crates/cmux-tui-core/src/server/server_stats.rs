//! `server-stats`: where the daemon spends its time.

use super::{MAX_SERVER_CONNECTIONS, Mux};
use crate::diagnostics::{SERVER_STATS_SCHEMA, ServerStatsSnapshot};

/// The optional section that reports resource projection spans.
const RESOURCE_PROJECTION: &str = "resource_projection";

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
    }
}

#[cfg(test)]
#[path = "server_stats_tests.rs"]
mod tests;
