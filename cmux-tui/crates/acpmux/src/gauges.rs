//! What `daemon status` says about the daemon's own cost (`gauges` in `_acpmux/status`): how long
//! each startup phase took and its resident memory, with the bytes queued for each connection
//! (`server/queue_gauge.rs`) beside them. No whole session list is built any more (a list reply
//! costs its page or its changes, `hub/row_log.rs`), so none is counted.
//!
//! On 2026-11-12 a daemon on Leo's Mac grew to 11 GB within 15 minutes of its start, took 93 s
//! from socket-ready to "agents may spawn", and nothing it answered said which phase or which
//! queue held the time or the memory (rework finding E3, `docs/design/acpmux-otp-rework.md`).
//! Every gauge here is a few atomics or a short lock that no request holds, so `daemon status`
//! reads them even while startup runs.

use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock, PoisonError};
use std::time::{Duration, Instant};

/// The daemon's gauges: one per process, as a daemon is.
pub fn global() -> &'static Gauges {
    static GAUGES: OnceLock<Gauges> = OnceLock::new();
    GAUGES.get_or_init(Gauges::new)
}

/// The most startup phases kept: a daemon has about 15; a test process starts many hubs.
const PHASES: usize = 64;

pub struct Gauges {
    /// The first touch: `daemon::run` reads [`global`] first, so this is the daemon's start.
    born: Instant,
    phases: Mutex<Vec<Phase>>,
}

#[derive(Clone)]
struct Phase {
    name: &'static str,
    /// Milliseconds from [`Gauges::born`] to its start.
    at_ms: u64,
    /// Microseconds from [`Gauges::born`] to its start.
    at_us: u64,
    /// Its length; None while it runs. A mark is a phase of 0 ms.
    ms: Option<u64>,
    /// Its length in microseconds; None while it runs. A mark is 0.
    us: Option<u64>,
    /// CPU and scheduler counters from the thread that owns the phase.
    stats: ThreadStats,
    threads_start: Option<Vec<ThreadInfo>>,
    threads_end: Option<Vec<ThreadInfo>>,
    threads_mark: Option<Vec<ThreadInfo>>,
}

#[derive(Clone)]
struct ThreadInfo {
    tid: u64,
    name: String,
    run_ns: Option<u64>,
    wait_ns: Option<u64>,
}

#[cfg(target_os = "linux")]
fn thread_snapshot() -> Vec<ThreadInfo> {
    let mut result = Vec::new();
    let Ok(entries) = std::fs::read_dir("/proc/self/task") else { return result };
    for entry in entries.flatten() {
        let Ok(tid) = entry.file_name().to_string_lossy().parse::<u64>() else { continue };
        let name = std::fs::read_to_string(entry.path().join("comm"))
            .unwrap_or_default()
            .trim()
            .to_owned();
        let schedstat =
            std::fs::read_to_string(entry.path().join("schedstat")).ok().and_then(|text| {
                let mut fields = text.split_whitespace();
                Some((fields.next()?.parse().ok()?, fields.next()?.parse().ok()?))
            });
        let (run_ns, wait_ns) =
            schedstat.map_or((None, None), |(run, wait)| (Some(run), Some(wait)));
        result.push(ThreadInfo { tid, name, run_ns, wait_ns });
    }
    result.sort_by_key(|thread| thread.tid);
    result
}

#[cfg(not(target_os = "linux"))]
fn thread_snapshot() -> Vec<ThreadInfo> {
    Vec::new()
}

fn thread_json(threads: &[ThreadInfo]) -> Value {
    threads
        .iter()
        .map(|thread| {
            (
                format!("{}:{}", thread.tid, thread.name),
                json!({
                    "tid": thread.tid,
                    "name": thread.name,
                    "runNs": thread.run_ns,
                    "waitNs": thread.wait_ns,
                }),
            )
        })
        .collect::<BTreeMap<_, _>>()
        .into_iter()
        .collect::<serde_json::Map<_, _>>()
        .into()
}

fn startup_thread_table_enabled() -> bool {
    static ENABLED: OnceLock<bool> = OnceLock::new();
    *ENABLED.get_or_init(|| {
        std::env::var("ACPMUX_STARTUP_THREAD_TABLE")
            .is_ok_and(|value| matches!(value.as_str(), "1" | "true" | "yes"))
    })
}

#[derive(Clone, Copy, Default)]
struct ThreadStats {
    cpu_us: u64,
    major_faults: u64,
    minor_faults: u64,
    voluntary_switches: u64,
    involuntary_switches: u64,
}

impl ThreadStats {
    fn delta(self, start: Self) -> Self {
        Self {
            cpu_us: self.cpu_us.saturating_sub(start.cpu_us),
            major_faults: self.major_faults.saturating_sub(start.major_faults),
            minor_faults: self.minor_faults.saturating_sub(start.minor_faults),
            voluntary_switches: self.voluntary_switches.saturating_sub(start.voluntary_switches),
            involuntary_switches: self
                .involuntary_switches
                .saturating_sub(start.involuntary_switches),
        }
    }
}

#[cfg(target_os = "linux")]
fn thread_stats() -> ThreadStats {
    // SAFETY: both structures are plain integer outputs fully initialized by libc.
    let mut usage: libc::rusage = unsafe { std::mem::zeroed() };
    let usage_ok = unsafe { libc::getrusage(libc::RUSAGE_THREAD, &mut usage) } == 0;
    let mut clock = libc::timespec { tv_sec: 0, tv_nsec: 0 };
    let clock_ok = unsafe { libc::clock_gettime(libc::CLOCK_THREAD_CPUTIME_ID, &mut clock) } == 0;
    let cpu_us = if clock_ok {
        u64::try_from(clock.tv_sec)
            .unwrap_or(0)
            .saturating_mul(1_000_000)
            .saturating_add(u64::try_from(clock.tv_nsec).unwrap_or(0) / 1_000)
    } else {
        0
    };
    let value = |value: libc::c_long| u64::try_from(value).unwrap_or(0);
    ThreadStats {
        cpu_us,
        major_faults: usage_ok.then(|| value(usage.ru_majflt)).unwrap_or(0),
        minor_faults: usage_ok.then(|| value(usage.ru_minflt)).unwrap_or(0),
        voluntary_switches: usage_ok.then(|| value(usage.ru_nvcsw)).unwrap_or(0),
        involuntary_switches: usage_ok.then(|| value(usage.ru_nivcsw)).unwrap_or(0),
    }
}

#[cfg(not(target_os = "linux"))]
fn thread_stats() -> ThreadStats {
    ThreadStats::default()
}

/// A running phase: its length is recorded when this drops.
pub struct PhaseGuard {
    gauges: &'static Gauges,
    index: usize,
    started: Instant,
    thread_stats: ThreadStats,
    threads_start: Option<Vec<ThreadInfo>>,
}

impl Drop for PhaseGuard {
    fn drop(&mut self) {
        let ms = millis(self.started.elapsed());
        let us = micros(self.started.elapsed());
        let stats = thread_stats().delta(self.thread_stats);
        let mut phases = self.gauges.phases.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(phase) = phases.get_mut(self.index) {
            phase.ms = Some(ms);
            phase.us = Some(us);
            phase.stats = stats;
            phase.threads_end = self.threads_start.as_ref().map(|_| thread_snapshot());
        }
    }
}

fn millis(d: Duration) -> u64 {
    u64::try_from(d.as_millis()).unwrap_or(u64::MAX)
}

fn micros(d: Duration) -> u64 {
    u64::try_from(d.as_micros()).unwrap_or(u64::MAX)
}

impl Gauges {
    fn new() -> Self {
        Self { born: Instant::now(), phases: Mutex::default() }
    }

    /// A startup phase begins now; it ends when the guard drops.
    pub fn phase(&'static self, name: &'static str) -> PhaseGuard {
        let started = Instant::now();
        let mut phases = self.phases.lock().unwrap_or_else(PoisonError::into_inner);
        if phases.len() >= PHASES {
            return PhaseGuard {
                gauges: self,
                index: usize::MAX,
                started,
                thread_stats: thread_stats(),
                threads_start: None,
            };
        }
        phases.push(Phase {
            name,
            at_ms: millis(started - self.born),
            at_us: micros(started - self.born),
            ms: None,
            us: None,
            stats: ThreadStats::default(),
            threads_start: None,
            threads_end: None,
            threads_mark: None,
        });
        let threads_start =
            (startup_thread_table_enabled() && name == "hub construct").then(thread_snapshot);
        if let Some(phase) = phases.last_mut() {
            phase.threads_start = threads_start.clone();
        }
        PhaseGuard {
            gauges: self,
            index: phases.len() - 1,
            started,
            thread_stats: thread_stats(),
            threads_start,
        }
    }

    /// A point in startup (`socket ready`, `first list reply`), kept the first time only.
    pub fn mark(&self, name: &'static str) {
        let mut phases = self.phases.lock().unwrap_or_else(PoisonError::into_inner);
        if phases.len() >= PHASES || phases.iter().any(|p| p.name == name) {
            return;
        }
        phases.push(Phase {
            name,
            at_ms: millis(self.born.elapsed()),
            at_us: micros(self.born.elapsed()),
            ms: Some(0),
            us: Some(0),
            stats: ThreadStats::default(),
            threads_start: None,
            threads_end: None,
            threads_mark: (startup_thread_table_enabled() && name == "requests ready")
                .then(thread_snapshot),
        });
    }

    /// `gauges` in `_acpmux/status`, but for the connections' queues, which the server adds.
    pub fn status(&self) -> Value {
        let phases: Vec<Value> = {
            let phases = self.phases.lock().unwrap_or_else(PoisonError::into_inner);
            phases
                .iter()
                .map(|p| {
                    json!({
                        "name": p.name,
                        "atMs": p.at_ms,
                        "atUs": p.at_us,
                        "ms": p.ms,
                        "us": p.us,
                        "cpuUs": p.stats.cpu_us,
                        "majorFaults": p.stats.major_faults,
                        "minorFaults": p.stats.minor_faults,
                        "voluntarySwitches": p.stats.voluntary_switches,
                        "involuntarySwitches": p.stats.involuntary_switches,
                        "threadsStart": p.threads_start.as_deref().map(thread_json),
                        "threadsEnd": p.threads_end.as_deref().map(thread_json),
                        "threads": p.threads_mark.as_deref().map(thread_json),
                    })
                })
                .collect()
        };
        json!({
            "uptimeMs": millis(self.born.elapsed()),
            "startup": phases,
            "memory": memory(),
            "peerLists": peer_lists().status(),
        })
    }
}

/// Peers' lists (whole, or a follow's patch) a link handed the hub's one notice loop that it has
/// not taken yet: counted by the link that sends one (`peer_runtime_io.rs`) and by the loop that
/// takes it (`hub/peer_grace.rs`). The hub's notice channel is bounded by notices, not bytes, so a
/// loop slower than the lists coming in holds every one of them.
pub fn peer_lists() -> &'static PeerLists {
    static LISTS: OnceLock<PeerLists> = OnceLock::new();
    LISTS.get_or_init(PeerLists::default)
}

#[derive(Default)]
pub struct PeerLists {
    lists: AtomicU64,
    bytes: AtomicU64,
    peak_lists: AtomicU64,
    peak_bytes: AtomicU64,
}

impl PeerLists {
    /// A list of `bytes` of row text is on its way into the queue.
    pub fn queued(&self, bytes: u64) {
        let lists = self.lists.fetch_add(1, Ordering::Relaxed) + 1;
        let bytes = self.bytes.fetch_add(bytes, Ordering::Relaxed) + bytes;
        self.peak_lists.fetch_max(lists, Ordering::Relaxed);
        self.peak_bytes.fetch_max(bytes, Ordering::Relaxed);
    }

    /// The loop took a list of `bytes`. Saturating: a test may send a list no link counted.
    pub fn taken(&self, bytes: u64) {
        let less = |by: u64| move |v: u64| Some(v.saturating_sub(by));
        let _ = self.lists.fetch_update(Ordering::Relaxed, Ordering::Relaxed, less(1));
        let _ = self.bytes.fetch_update(Ordering::Relaxed, Ordering::Relaxed, less(bytes));
    }

    fn status(&self) -> Value {
        json!({
            "lists": self.lists.load(Ordering::Relaxed),
            "bytes": self.bytes.load(Ordering::Relaxed),
            "peakLists": self.peak_lists.load(Ordering::Relaxed),
            "peakBytes": self.peak_bytes.load(Ordering::Relaxed),
        })
    }
}

/// `gauges` in `_acpmux/status`: [`Gauges::status`] with each connection's queue.
pub fn daemon_status() -> Value {
    let mut status = global().status();
    if let Some(fields) = status.as_object_mut() {
        fields.insert("queues".into(), crate::server::queue_gauge::status());
    }
    status
}

/// This process's resident bytes now and at its peak; null where unknown.
pub fn memory() -> Value {
    json!({"rssBytes": rss_bytes(), "peakRssBytes": peak_rss_bytes()})
}

#[cfg(target_os = "linux")]
fn rss_bytes() -> Option<u64> {
    let status = std::fs::read_to_string("/proc/self/status").ok()?;
    let line = status.lines().find(|l| l.starts_with("VmRSS:"))?;
    let kib: u64 = line.split_whitespace().nth(1)?.parse().ok()?;
    Some(kib * 1024)
}

#[cfg(target_os = "macos")]
fn rss_bytes() -> Option<u64> {
    // SAFETY: proc_taskinfo is plain integers; proc_pidinfo fills at most `size` bytes of it.
    let mut info: libc::proc_taskinfo = unsafe { std::mem::zeroed() };
    let size = std::mem::size_of::<libc::proc_taskinfo>() as libc::c_int;
    // SAFETY: the pointer is to a live local of `size` bytes.
    let got = unsafe {
        libc::proc_pidinfo(
            std::process::id() as libc::c_int,
            libc::PROC_PIDTASKINFO,
            0,
            (&mut info as *mut libc::proc_taskinfo).cast(),
            size,
        )
    };
    (got == size).then_some(info.pti_resident_size)
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
fn rss_bytes() -> Option<u64> {
    None
}

#[cfg(unix)]
fn peak_rss_bytes() -> Option<u64> {
    // SAFETY: rusage is plain integers, for which all zeroes is a valid value.
    let mut usage: libc::rusage = unsafe { std::mem::zeroed() };
    // SAFETY: the pointer is to a live local that getrusage fills in.
    if unsafe { libc::getrusage(libc::RUSAGE_SELF, &mut usage) } != 0 {
        return None;
    }
    // KiB on Linux, bytes on macOS.
    let unit = if cfg!(target_os = "macos") { 1 } else { 1024 };
    u64::try_from(usage.ru_maxrss).ok().map(|v| v * unit)
}

#[cfg(not(unix))]
fn peak_rss_bytes() -> Option<u64> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_phase_reports_its_length_and_a_mark_only_its_first_time() {
        let gauges: &'static Gauges = Box::leak(Box::new(Gauges::new()));
        {
            let _phase = gauges.phase("store load");
            std::thread::sleep(Duration::from_millis(5));
        }
        gauges.mark("socket ready");
        gauges.mark("socket ready");
        let status = gauges.status();
        let phases = status["startup"].as_array().unwrap();
        assert_eq!(phases.len(), 2, "{status}");
        assert_eq!(phases[0]["name"], "store load");
        assert!(phases[0]["ms"].as_u64().unwrap() >= 5, "{status}");
        assert_eq!(phases[1]["name"], "socket ready");
        assert_eq!(phases[1]["ms"], 0);
        #[cfg(any(target_os = "linux", target_os = "macos"))]
        assert!(status["memory"]["rssBytes"].as_u64().unwrap() > 0, "{status}");
    }
}
