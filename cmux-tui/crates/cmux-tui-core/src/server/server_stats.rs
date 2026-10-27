//! `server-stats`: where the daemon spends its time. Also `server-threads`
//! and `server-blocking` (the plan's `server.threads` and
//! `server.blocking`, p02-threads-203): the thread registry, work lanes and
//! blocking site table of `cmux_threads`, each read from one snapshot and
//! rendered after every lock is released.

use cmux_threads::blocking::{self, BlockingMode, BlockingSnapshot};
use cmux_threads::process_role::{self, DarwinBackground, TaskRole};
use cmux_threads::work::{Lane, LaneStats};
use cmux_threads::{LiveQos, ThreadInfo};
use std::collections::HashMap;

use super::client_registry::ConnectionFacts;
use super::request_spans::{RequestMethod, lock_op_name};
use super::{MAX_SERVER_CONNECTIONS, Mux};
use crate::diagnostics::{LockTableSnapshot, SERVER_STATS_SCHEMA, ServerStatsSnapshot};

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
/// The optional section that reports wait and hold by class (frontend,
/// program, automation) on the registry, connection and state locks
/// (`priority_gate`).
const LOCK_CLASSES: &str = "lock_classes";
/// The optional section that reports the IPC layer: streams, sequence
/// depths, messages and bytes by kind, parses and write syscalls per
/// message, write stalls and bad_message closes.
const IPC: &str = "ipc";
/// The optional section that reports request latency, handler time and lock
/// wait by method (`ipc_methods`, request_spans.rs). It is not `ipc`: that
/// section counts the IPC layer itself (streams, frames, parses, syscalls).
const IPC_METHODS: &str = "ipc_methods";

/// Read every counter; sections outside `include` stay absent so older SDK
/// decoders, which refuse unknown result fields, keep working.
pub(super) fn server_stats(mux: &Mux, include: Option<&[String]>) -> ServerStatsSnapshot {
    let wants = |section: &str| include.is_some_and(|names| names.iter().any(|n| n == section));
    let requests = wants(REQUESTS).then(|| mux.request_stats().snapshot());
    let (request_latency_us, dispatch_queue_us) =
        requests.map(|requests| (requests.request_latency_us, requests.dispatch_queue_us)).unzip();
    ServerStatsSnapshot {
        schema: SERVER_STATS_SCHEMA,
        uptime_ms: uptime_ms(mux),
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
        lock_classes: wants(LOCK_CLASSES).then(|| mux.lock_class_stats()),
        ipc: wants(IPC).then(|| mux.ipc_stats().snapshot()),
        ipc_methods: wants(IPC_METHODS)
            .then(|| mux.request_stats().methods().snapshot(RequestMethod::of_slot)),
    }
}

/// The `debug-daemon-locks` result. `schema` grows only when a field
/// changes meaning.
#[derive(Clone, Debug, serde::Serialize)]
pub(super) struct DaemonLocksSnapshot {
    schema: u32,
    uptime_ms: u64,
    locks: Vec<LockTableSnapshot>,
}

const DAEMON_LOCKS_SCHEMA: u32 = 1;

/// Why `debug-daemon-locks` was refused.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum DaemonLocksRefused {
    /// A WebSocket or remote relay client asked.
    NotLocal,
}

impl std::fmt::Display for DaemonLocksRefused {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            DaemonLocksRefused::NotLocal => "daemon lock stats require a trusted local connection",
        })
    }
}

impl std::error::Error for DaemonLocksRefused {}

pub(super) fn daemon_locks(mux: &Mux) -> DaemonLocksSnapshot {
    DaemonLocksSnapshot {
        schema: DAEMON_LOCKS_SCHEMA,
        uptime_ms: uptime_ms(mux),
        locks: mux
            .daemon_lock_tables()
            .into_iter()
            .map(|(lock, table)| table.snapshot(lock, &lock_op_name))
            .collect(),
    }
}

/// Why `server-threads` or `server-blocking` was refused.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum ThreadDiagnosticsRefused {
    /// A WebSocket or remote relay client asked.
    NotLocal,
}

impl std::fmt::Display for ThreadDiagnosticsRefused {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            ThreadDiagnosticsRefused::NotLocal => {
                "daemon thread diagnostics require a trusted local connection"
            }
        })
    }
}

impl std::error::Error for ThreadDiagnosticsRefused {}

const SERVER_THREADS_SCHEMA: u32 = 1;
const SERVER_BLOCKING_SCHEMA: u32 = 1;

/// The `server-threads` result: the process, every registered thread, and
/// the work lanes. `schema` grows only when a field changes meaning.
#[derive(Clone, Debug, serde::Serialize)]
pub(super) struct ServerThreadsSnapshot {
    schema: u32,
    uptime_ms: u64,
    process: ProcessRow,
    threads: Vec<ThreadRow>,
    lanes: Vec<LaneRow>,
}

#[derive(Clone, Debug, serde::Serialize)]
struct ProcessRow {
    pid: u32,
    /// The Mach task role (macOS); `None` on Linux.
    role: Option<&'static str>,
    /// The raw `task_role_t` when it is outside the named set.
    role_raw: Option<i32>,
    /// The daemon's two PRIO_DARWIN_BG flags; `None` on Linux.
    darwin_bg: Option<DarwinBgRow>,
}

/// `process_role::DarwinBackground`: either flag suppresses the process.
#[derive(Clone, Copy, Debug, serde::Serialize)]
struct DarwinBgRow {
    /// Set by the daemon on itself (`process_role::set_role`).
    internal: bool,
    /// Set by its parent by pid, or inherited from a suppressed parent; only
    /// another process can clear it.
    external: bool,
}

#[derive(Clone, Debug, serde::Serialize)]
struct ThreadRow {
    name: String,
    tid: Option<u64>,
    declared: &'static str,
    desired: &'static str,
    /// The QoS the thread last applied, `None` before any change succeeded.
    effective: Option<&'static str>,
    /// macOS: the QoS class the kernel reports (a table name,
    /// `unspecified`, or the raw class as `0x..`).
    requested_qos: Option<String>,
    /// Linux: the thread's nice value.
    nice: Option<i32>,
    /// The scheduler priority now (macOS `pth_curpri`, Linux 20 + nice).
    priority: Option<i32>,
    refused_changes: u32,
    /// Whether the kernel's value is the desired QoS; `None` when it could
    /// not be read.
    matches: Option<bool>,
    /// The connection a connection thread (reader or request thread) works
    /// for; `None` for every other thread.
    connection: Option<ConnectionRow>,
}

/// The connection a thread works for (`QosSlot::work_for` with its client
/// id): the facts its client class comes from, and the class, so the QoS
/// audit judges the person's connection threads apart from automation's
/// (p02-threads RUN-4). The facts are `null` once the connection is gone.
#[derive(Clone, Debug, serde::Serialize)]
struct ConnectionRow {
    client: u64,
    transport: Option<&'static str>,
    remote_device: Option<bool>,
    origin: Option<&'static str>,
    peer_pid: Option<u32>,
    class: Option<&'static str>,
}

impl ConnectionRow {
    fn of(client: u64, facts: Option<&ConnectionFacts>) -> Self {
        ConnectionRow {
            client,
            transport: facts.map(|facts| facts.transport),
            remote_device: facts.map(|facts| facts.remote_device),
            origin: facts.map(|facts| facts.origin),
            peer_pid: facts.and_then(|facts| facts.peer_pid),
            class: facts.map(|facts| facts.class),
        }
    }
}

impl ThreadRow {
    fn of(info: ThreadInfo, connections: &HashMap<u64, ConnectionFacts>) -> Self {
        let (requested_qos, nice, matches) = match info.live {
            LiveQos::Class(qos) => (Some(qos.as_str().to_owned()), None, Some(qos == info.desired)),
            LiveQos::Unspecified => (Some("unspecified".to_owned()), None, Some(false)),
            LiveQos::Other(raw) => (Some(format!("{raw:#04x}")), None, Some(false)),
            LiveQos::Nice(nice) => (None, Some(nice), Some(nice == info.desired.linux_nice())),
            LiveQos::Unknown => (None, None, None),
        };
        ThreadRow {
            name: info.name,
            tid: info.tid,
            declared: info.declared.as_str(),
            desired: info.desired.as_str(),
            effective: info.effective.map(|qos| qos.as_str()),
            requested_qos,
            nice,
            priority: info.priority,
            refused_changes: info.refused_changes,
            matches,
            connection: info
                .owner
                .map(|client| ConnectionRow::of(client, connections.get(&client))),
        }
    }
}

#[derive(Clone, Debug, serde::Serialize)]
struct LaneRow {
    lane: &'static str,
    pending: usize,
    running: usize,
    blocked: usize,
    workers: usize,
    idle_workers: usize,
    workers_started: u64,
    workers_exited: u64,
    wakeups: u64,
    spawn_failures: u64,
    panics: u64,
    shutdown_raises: u64,
    shutdown_raise_refusals: u64,
}

impl LaneRow {
    fn of(stats: LaneStats) -> Self {
        LaneRow {
            lane: match stats.lane {
                Lane::Files => "files",
                Lane::System => "system",
                Lane::Cpu => "cpu",
            },
            pending: stats.pending,
            running: stats.running,
            blocked: stats.blocked,
            workers: stats.workers,
            idle_workers: stats.idle_workers,
            workers_started: stats.workers_started,
            workers_exited: stats.workers_exited,
            wakeups: stats.wakeups,
            spawn_failures: stats.spawn_failures,
            panics: stats.panics,
            shutdown_raises: stats.shutdown_raises,
            shutdown_raise_refusals: stats.shutdown_raise_refusals,
        }
    }
}

/// Renders `server-threads` from its snapshots; reads nothing itself.
fn threads_snapshot(
    uptime_ms: u64,
    role: Option<TaskRole>,
    darwin_bg: Option<DarwinBackground>,
    threads: Vec<ThreadInfo>,
    connections: &HashMap<u64, ConnectionFacts>,
    lanes: [LaneStats; 3],
) -> ServerThreadsSnapshot {
    let mut threads: Vec<ThreadRow> =
        threads.into_iter().map(|info| ThreadRow::of(info, connections)).collect();
    threads.sort_by(|a, b| a.name.cmp(&b.name).then(a.tid.cmp(&b.tid)));
    ServerThreadsSnapshot {
        schema: SERVER_THREADS_SCHEMA,
        uptime_ms,
        process: ProcessRow {
            pid: std::process::id(),
            role: role.map(|role| role.as_str().unwrap_or("other")),
            role_raw: match role {
                Some(TaskRole::Other(raw)) => Some(raw),
                _ => None,
            },
            darwin_bg: darwin_bg
                .map(|bg| DarwinBgRow { internal: bg.internal, external: bg.external }),
        },
        threads,
        lanes: lanes.into_iter().map(LaneRow::of).collect(),
    }
}

/// `server-threads`: the registry snapshot (one lock held for its row
/// reads, as Chromium's `ThreadIdNameManager`), the facts of the
/// connections its threads work for (the client registry's lock, taken
/// after the thread registry's is released), the lanes' counters, the task
/// role and PRIO_DARWIN_BG, rendered after every lock is released.
pub(super) fn server_threads(mux: &Mux) -> ServerThreadsSnapshot {
    let threads = cmux_threads::snapshot();
    let connections =
        mux.control_clients.connection_facts(threads.iter().filter_map(|info| info.owner));
    threads_snapshot(
        uptime_ms(mux),
        process_role::current(),
        process_role::darwin_background(),
        threads,
        &connections,
        mux.work.stats(),
    )
}

/// The `server-blocking` result: the blocking calls made where blocking is
/// disallowed, by call site, most frequent first.
#[derive(Clone, Debug, serde::Serialize)]
pub(super) struct ServerBlockingSnapshot {
    schema: u32,
    uptime_ms: u64,
    /// `record` or `panic` (Debug builds only; Release always records).
    mode: &'static str,
    /// Distinct sites kept before a violation counts only in `overflow`.
    site_capacity: usize,
    overflow: u64,
    sites: Vec<SiteRow>,
}

#[derive(Clone, Debug, serde::Serialize)]
struct SiteRow {
    file: &'static str,
    line: u32,
    column: u32,
    kinds: Vec<&'static str>,
    count: u64,
    lane_sync: bool,
}

/// Renders `server-blocking` from its snapshot; reads nothing itself.
fn blocking_snapshot(
    uptime_ms: u64,
    mode: BlockingMode,
    snapshot: BlockingSnapshot,
) -> ServerBlockingSnapshot {
    ServerBlockingSnapshot {
        schema: SERVER_BLOCKING_SCHEMA,
        uptime_ms,
        mode: match mode {
            BlockingMode::Record => "record",
            BlockingMode::Panic => "panic",
        },
        site_capacity: blocking::SITE_CAPACITY,
        overflow: snapshot.overflow,
        sites: snapshot
            .sites
            .into_iter()
            .map(|site| SiteRow {
                file: site.file,
                line: site.line,
                column: site.column,
                kinds: site.kinds.iter().map(|kind| kind.as_str()).collect(),
                count: site.count,
                lane_sync: site.lane_sync,
            })
            .collect(),
    }
}

/// `server-blocking`: the site table's atomics; takes no lock.
pub(super) fn server_blocking(mux: &Mux) -> ServerBlockingSnapshot {
    blocking_snapshot(uptime_ms(mux), blocking::mode(), blocking::snapshot())
}

fn uptime_ms(mux: &Mux) -> u64 {
    u64::try_from(mux.uptime().as_millis()).unwrap_or(u64::MAX)
}

#[cfg(test)]
#[path = "server_threads_tests.rs"]
mod threads_tests;

#[cfg(test)]
#[path = "server_stats_tests.rs"]
mod tests;

#[cfg(test)]
#[path = "server_stats_ipc_tests.rs"]
mod ipc_tests;
