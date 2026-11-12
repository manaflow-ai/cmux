//! What `daemon status` says about the daemon's own cost (`gauges` in `_acpmux/status`): how long
//! each startup phase took, its resident memory, and how often it rebuilt a whole session list,
//! with the bytes queued for each connection (`server/queue_gauge.rs`) beside them.
//!
//! On 2026-11-12 a daemon on Leo's Mac grew to 11 GB within 15 minutes of its start, took 93 s
//! from socket-ready to "agents may spawn", and nothing it answered said which phase or which
//! queue held the time or the memory (rework finding E3, `docs/design/acpmux-otp-rework.md`).
//! Every gauge here is a few atomics or a short lock that no request holds, so `daemon status`
//! reads them even while startup or a list build runs.

use serde_json::{Value, json};
use std::collections::{BTreeMap, VecDeque};
use std::sync::{Mutex, OnceLock, PoisonError};
use std::time::{Duration, Instant};

/// The daemon's gauges: one per process, as a daemon is.
pub fn global() -> &'static Gauges {
    static GAUGES: OnceLock<Gauges> = OnceLock::new();
    GAUGES.get_or_init(Gauges::new)
}

/// How far back "list rebuilds per minute" looks.
const MINUTE: Duration = Duration::from_secs(60);

/// The most startup phases kept: a daemon has about 15; a test process starts many hubs.
const PHASES: usize = 64;

/// The most whole-list variants (`Snapshot::made` names) kept by name.
const VARIANTS: usize = 32;

pub struct Gauges {
    /// The first touch: `daemon::run` reads [`global`] first, so this is the daemon's start.
    born: Instant,
    phases: Mutex<Vec<Phase>>,
    lists: Mutex<Lists>,
}

#[derive(Clone)]
struct Phase {
    name: &'static str,
    /// Milliseconds from [`Gauges::born`] to its start.
    at_ms: u64,
    /// Its length; None while it runs. A mark is a phase of 0 ms.
    ms: Option<u64>,
}

#[derive(Default)]
struct Lists {
    total: u64,
    /// The start of each rebuild within the last [`MINUTE`].
    recent: VecDeque<Instant>,
    last_rows: usize,
    last_bytes: usize,
    last_build_us: u64,
    max_build_us: u64,
    /// Each whole-list variant made from a snapshot (`own masked`, `acp`, ...): count and bytes.
    variants: BTreeMap<&'static str, (u64, u64)>,
}

/// A running phase: its length is recorded when this drops.
pub struct PhaseGuard {
    gauges: &'static Gauges,
    index: usize,
    started: Instant,
}

impl Drop for PhaseGuard {
    fn drop(&mut self) {
        let ms = millis(self.started.elapsed());
        let mut phases = self.gauges.phases.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(phase) = phases.get_mut(self.index) {
            phase.ms = Some(ms);
        }
    }
}

fn millis(d: Duration) -> u64 {
    u64::try_from(d.as_millis()).unwrap_or(u64::MAX)
}

impl Gauges {
    fn new() -> Self {
        Self { born: Instant::now(), phases: Mutex::default(), lists: Mutex::default() }
    }

    /// A startup phase begins now; it ends when the guard drops.
    pub fn phase(&'static self, name: &'static str) -> PhaseGuard {
        let started = Instant::now();
        let mut phases = self.phases.lock().unwrap_or_else(PoisonError::into_inner);
        if phases.len() >= PHASES {
            return PhaseGuard { gauges: self, index: usize::MAX, started };
        }
        phases.push(Phase { name, at_ms: millis(started - self.born), ms: None });
        PhaseGuard { gauges: self, index: phases.len() - 1, started }
    }

    /// A point in startup (`socket ready`, `first list reply`), kept the first time only.
    pub fn mark(&self, name: &'static str) {
        let mut phases = self.phases.lock().unwrap_or_else(PoisonError::into_inner);
        if phases.len() >= PHASES || phases.iter().any(|p| p.name == name) {
            return;
        }
        phases.push(Phase { name, at_ms: millis(self.born.elapsed()), ms: Some(0) });
    }

    /// A whole session list was built (`hub/list_guard.rs`): `rows` rows, `bytes` of text.
    pub fn list_rebuilt(&self, rows: usize, bytes: usize, build: Duration) {
        let now = Instant::now();
        let mut lists = self.lists.lock().unwrap_or_else(PoisonError::into_inner);
        lists.total += 1;
        lists.recent.push_back(now);
        while lists.recent.front().is_some_and(|at| now.duration_since(*at) > MINUTE) {
            lists.recent.pop_front();
        }
        let us = u64::try_from(build.as_micros()).unwrap_or(u64::MAX);
        (lists.last_rows, lists.last_bytes, lists.last_build_us) = (rows, bytes, us);
        lists.max_build_us = lists.max_build_us.max(us);
    }

    /// A whole-list variant `name` of `bytes` was made from a snapshot (`Snapshot::made`).
    pub fn list_variant(&self, name: &'static str, bytes: usize) {
        let mut lists = self.lists.lock().unwrap_or_else(PoisonError::into_inner);
        if lists.variants.len() >= VARIANTS && !lists.variants.contains_key(name) {
            return;
        }
        let entry = lists.variants.entry(name).or_default();
        entry.0 += 1;
        entry.1 += bytes as u64;
    }

    /// `gauges` in `_acpmux/status`, but for the connections' queues, which the server adds.
    pub fn status(&self) -> Value {
        let phases: Vec<Value> = {
            let phases = self.phases.lock().unwrap_or_else(PoisonError::into_inner);
            phases.iter().map(|p| json!({"name": p.name, "atMs": p.at_ms, "ms": p.ms})).collect()
        };
        let lists = {
            let mut lists = self.lists.lock().unwrap_or_else(PoisonError::into_inner);
            let now = Instant::now();
            while lists.recent.front().is_some_and(|at| now.duration_since(*at) > MINUTE) {
                lists.recent.pop_front();
            }
            let variants: serde_json::Map<String, Value> = lists
                .variants
                .iter()
                .map(|(name, (count, bytes))| {
                    ((*name).to_owned(), json!({"made": count, "bytes": bytes}))
                })
                .collect();
            json!({
                "total": lists.total,
                "lastMinute": lists.recent.len(),
                "lastRows": lists.last_rows,
                "lastBytes": lists.last_bytes,
                "lastBuildUs": lists.last_build_us,
                "maxBuildUs": lists.max_build_us,
                "variants": variants,
            })
        };
        json!({
            "uptimeMs": millis(self.born.elapsed()),
            "startup": phases,
            "memory": memory(),
            "listRebuilds": lists,
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
        gauges.list_rebuilt(3, 120, Duration::from_micros(40));
        gauges.list_variant("own masked", 100);
        gauges.list_variant("own masked", 100);
        let status = gauges.status();
        let phases = status["startup"].as_array().unwrap();
        assert_eq!(phases.len(), 2, "{status}");
        assert_eq!(phases[0]["name"], "store load");
        assert!(phases[0]["ms"].as_u64().unwrap() >= 5, "{status}");
        assert_eq!(phases[1]["name"], "socket ready");
        assert_eq!(phases[1]["ms"], 0);
        assert_eq!(status["listRebuilds"]["total"], 1);
        assert_eq!(status["listRebuilds"]["lastMinute"], 1);
        assert_eq!(status["listRebuilds"]["variants"]["own masked"]["made"], 2);
        assert_eq!(status["listRebuilds"]["variants"]["own masked"]["bytes"], 200);
        #[cfg(any(target_os = "linux", target_os = "macos"))]
        assert!(status["memory"]["rssBytes"].as_u64().unwrap() > 0, "{status}");
    }
}
