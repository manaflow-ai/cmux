//! `server-stats`: where the daemon spends its time.

use super::{MAX_SERVER_CONNECTIONS, Mux};
use crate::diagnostics::{SERVER_STATS_SCHEMA, ServerStatsSnapshot};

/// The optional section that reports resource projection spans.
const RESOURCE_PROJECTION: &str = "resource_projection";
/// The optional section that reports which thread commits durable writes.
const WRITE_PATH: &str = "write_path";
/// The optional section that reports blocking work on request threads.
const REQUEST_PATH_IO: &str = "request_path_io";
/// The optional section that lists requests that ran past the watchdog
/// threshold (request_watchdog.rs).
const SLOW_REQUESTS: &str = "slow_requests";
/// The optional section that reports request latency by class and the
/// dispatch queue (`request_latency_us`, `dispatch_queue_us`).
const REQUESTS: &str = "requests";
/// The optional section that reports the IPC layer: streams, sequence
/// depths, messages and bytes by kind, parses and write syscalls per
/// message, write stalls, bad_message closes and ring resyncs and laps.
const IPC: &str = "ipc";

/// Read every counter; sections outside `include` stay absent so older SDK
/// decoders, which refuse unknown result fields, keep working.
pub(super) fn server_stats(mux: &Mux, include: Option<&[String]>) -> ServerStatsSnapshot {
    let wants = |section: &str| include.is_some_and(|names| names.iter().any(|n| n == section));
    let requests = wants(REQUESTS).then(|| mux.request_stats().snapshot());
    let (request_latency_us, dispatch_queue_us) =
        requests.map(|requests| (requests.request_latency_us, requests.dispatch_queue_us)).unzip();
    ServerStatsSnapshot {
        schema: SERVER_STATS_SCHEMA,
        uptime_ms: u64::try_from(mux.uptime().as_millis()).unwrap_or(u64::MAX),
        registry_lock: mux.registry_lock_stats(),
        journal_writer: mux.journal_writer_stats(),
        connections: mux.connection_stats().snapshot(MAX_SERVER_CONNECTIONS as u64),
        resource_projection: wants(RESOURCE_PROJECTION).then(|| mux.resource_projection_stats()),
        write_path: wants(WRITE_PATH).then(|| mux.write_path_stats()),
        request_path_io: wants(REQUEST_PATH_IO)
            .then(|| crate::request_path::RequestPathIoSnapshot::of(mux.request_path_stats())),
        slow_requests: wants(SLOW_REQUESTS).then(|| mux.request_watchdog.snapshot()),
        request_latency_us,
        dispatch_queue_us,
        ipc: wants(IPC).then(|| mux.ipc_stats().snapshot()),
    }
}

#[cfg(test)]
#[path = "server_stats_tests.rs"]
mod tests;
