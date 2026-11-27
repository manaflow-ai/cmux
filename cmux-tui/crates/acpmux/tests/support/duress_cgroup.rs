//! What the daemon's cgroup and the host hold through a leg's window, sampled once a second by
//! the presence sampler (`duress_host150.rs`): the cgroup's charge split into anon, file, dirty
//! and writeback pages (`memory.stat`), its `memory.events` and reclaim (`pgscan`, `pgsteal`),
//! the processes it holds and their RSS, its `memory.pressure` and `cpu.pressure`, the host's
//! `/proc/pressure`, and how long the daemon's threads waited for a CPU (`schedstat`). Where PSI
//! cannot be read (a kernel booted without it) the row says why instead of a bare null.
//!
//! Why: the bigchat leg's daemon answered a trivial request in ~500 ms at p99 while it recorded
//! ~10k `memory.high` events; this row says what the cgroup's charge was made of and whether
//! the daemon was waiting on reclaim, on a CPU or on neither.
use super::*;

/// The `memory.stat` keys kept: the charge's parts and the reclaim counters.
const STAT_KEYS: [&str; 13] = [
    "anon",
    "file",
    "file_dirty",
    "file_writeback",
    "shmem",
    "sock",
    "slab",
    "kernel_stack",
    "pgscan",
    "pgsteal",
    "workingset_refault_file",
    "workingset_refault_anon",
    "pgmajfault",
];
/// One timeline point every this many samples, so a 90 s window keeps ~18 points.
const TIMELINE_EVERY: u64 = 5;

/// The `some avg10` (or `full avg10`) of a PSI file, or why it could not be read.
pub(super) fn psi(path: &Path, line: &str) -> Result<f64, String> {
    let text = std::fs::read_to_string(path).map_err(|e| format!("{}: {e}", path.display()))?;
    text.lines()
        .find(|l| l.starts_with(line))
        .and_then(|l| l.split_whitespace().find_map(|f| f.strip_prefix("avg10=")?.parse().ok()))
        .ok_or_else(|| format!("{}: no {line} avg10 in {:?}", path.display(), text.trim()))
}

fn stat(dir: &Path) -> BTreeMap<String, u64> {
    std::fs::read_to_string(dir.join("memory.stat"))
        .unwrap_or_default()
        .lines()
        .filter_map(|l| {
            let (k, v) = l.split_once(' ')?;
            STAT_KEYS.contains(&k).then(|| Some((k.to_owned(), v.trim().parse().ok()?)))?
        })
        .collect()
}

fn read_u64(path: &Path) -> Option<u64> {
    std::fs::read_to_string(path).ok()?.trim().parse().ok()
}

fn events(dir: &Path) -> BTreeMap<String, u64> {
    std::fs::read_to_string(dir.join("memory.events"))
        .unwrap_or_default()
        .lines()
        .filter_map(|l| {
            let (k, v) = l.split_once(' ')?;
            Some((k.to_owned(), v.trim().parse().ok()?))
        })
        .collect()
}

/// The cgroup's processes, how many are the daemon's own threads' process, and their RSS.
fn procs(dir: &Path) -> (usize, u64) {
    let pids: Vec<u32> = std::fs::read_to_string(dir.join("cgroup.procs"))
        .unwrap_or_default()
        .lines()
        .filter_map(|l| l.trim().parse().ok())
        .collect();
    let rss = pids.iter().filter_map(|p| rss_kib(*p)).sum();
    (pids.len(), rss)
}

fn status_kib(pid: u32, key: &str) -> Option<u64> {
    std::fs::read_to_string(format!("/proc/{pid}/status")).ok()?.lines().find_map(|l| {
        l.strip_prefix(key)?.strip_prefix(':')?.trim().trim_end_matches("kB").trim().parse().ok()
    })
}

#[derive(Default)]
pub(super) struct Track {
    dir: Option<PathBuf>,
    n: u64,
    started: Option<Instant>,
    last_wait: Option<(Instant, u64)>,
    events0: BTreeMap<String, u64>,
    stat0: BTreeMap<String, u64>,
    max: BTreeMap<String, f64>,
    psi_errors: BTreeSet<String>,
    timeline: Vec<Value>,
    last: BTreeMap<String, u64>,
    last_events: BTreeMap<String, u64>,
}

impl Track {
    pub(super) fn new(dir: Option<PathBuf>) -> Self {
        let events0 = dir.as_deref().map(events).unwrap_or_default();
        let stat0 = dir.as_deref().map(stat).unwrap_or_default();
        Self { dir, events0, stat0, started: Some(Instant::now()), ..Self::default() }
    }

    fn keep_max(&mut self, key: &str, v: f64) {
        let m = self.max.entry(key.to_owned()).or_insert(v);
        *m = m.max(v);
    }

    fn psi_into(
        &mut self,
        key: &str,
        path: &Path,
        line: &str,
        point: &mut serde_json::Map<String, Value>,
    ) {
        match psi(path, line) {
            Ok(v) => {
                self.keep_max(key, v);
                point.insert(key.into(), json!(v));
            }
            Err(e) => {
                self.psi_errors.insert(e);
            }
        }
    }

    /// One sample: the daemon `pid`, and the slowest `_acpmux/peers` read since the last one.
    pub(super) fn sample(&mut self, pid: u32, read_ms_max: Option<f64>) {
        let mut point = serde_json::Map::new();
        let at = self.started.map_or(0.0, |s| s.elapsed().as_secs_f64());
        point.insert("t".into(), json!((at * 10.0).round() / 10.0));
        if let Some(dir) = self.dir.clone() {
            if let Some(c) = read_u64(&dir.join("memory.current")) {
                self.keep_max("memoryCurrentKib", (c >> 10) as f64);
                point.insert("currentKib".into(), json!(c >> 10));
            }
            let s = stat(&dir);
            for k in ["anon", "file", "file_dirty", "file_writeback", "shmem", "sock", "slab"] {
                if let Some(v) = s.get(k) {
                    self.keep_max(&format!("{k}Kib"), (*v >> 10) as f64);
                    point.insert(format!("{k}Kib"), json!(*v >> 10));
                }
            }
            for k in ["pgscan", "pgsteal", "pgmajfault", "workingset_refault_file"] {
                if let (Some(v), Some(p)) = (s.get(k), self.last.get(k)) {
                    point.insert(format!("{k}Delta"), json!(v.saturating_sub(*p)));
                }
            }
            let e = events(&dir);
            if let (Some(h), Some(p)) = (e.get("high"), self.last_events.get("high")) {
                let d = h.saturating_sub(*p);
                self.keep_max("highEventsPerSample", d as f64);
                point.insert("highEventsDelta".into(), json!(d));
            }
            self.last = s;
            self.last_events = e;
            let (n, rss) = procs(&dir);
            self.keep_max("cgroupProcs", n as f64);
            self.keep_max("cgroupProcsRssKib", rss as f64);
            point.insert("procs".into(), json!(n));
            point.insert("procsRssKib".into(), json!(rss));
            self.psi_into(
                "cgroupMemorySomeAvg10",
                &dir.join("memory.pressure"),
                "some",
                &mut point,
            );
            self.psi_into(
                "cgroupMemoryFullAvg10",
                &dir.join("memory.pressure"),
                "full",
                &mut point,
            );
            self.psi_into("cgroupCpuSomeAvg10", &dir.join("cpu.pressure"), "some", &mut point);
            self.psi_into("cgroupIoSomeAvg10", &dir.join("io.pressure"), "some", &mut point);
        }
        for (k, f) in [
            ("hostCpuSomeAvg10", "cpu"),
            ("hostMemorySomeAvg10", "memory"),
            ("hostIoSomeAvg10", "io"),
        ] {
            self.psi_into(k, &PathBuf::from(format!("/proc/pressure/{f}")), "some", &mut point);
        }
        if let Some(r) = rss_kib(pid) {
            point.insert("daemonRssKib".into(), json!(r));
        }
        if let Some(s) = status_kib(pid, "VmSwap") {
            self.keep_max("daemonSwapKib", s as f64);
            point.insert("daemonSwapKib".into(), json!(s));
        }
        // The daemon's own heap against its mapped files, resident and swapped: what of it is
        // past the ceiling (`RssAnon` + `VmSwap` is its anonymous working set).
        for (key, field) in [("daemonRssAnonKib", "RssAnon"), ("daemonRssFileKib", "RssFile")] {
            if let Some(v) = status_kib(pid, field) {
                self.keep_max(key, v as f64);
                point.insert(key.into(), json!(v));
            }
        }
        if let (Some(a), Some(s)) = (status_kib(pid, "RssAnon"), status_kib(pid, "VmSwap")) {
            self.keep_max("daemonAnonPlusSwapKib", (a + s) as f64);
        }
        let wait = starved::runqueue_wait_ns(pid);
        let now = Instant::now();
        if let Some((t0, w0)) = self.last_wait {
            let ms_per_s = wait.saturating_sub(w0) as f64
                / 1e6
                / now.duration_since(t0).as_secs_f64().max(0.001);
            self.keep_max("daemonRunqueueWaitMsPerSec", ms_per_s);
            point.insert("runqWaitMsPerSec".into(), json!(ms_per_s.round()));
        }
        self.last_wait = Some((now, wait));
        if let Some(ms) = read_ms_max {
            point.insert("peersReadMaxMs".into(), json!(ms.round()));
        }
        if self.n.is_multiple_of(TIMELINE_EVERY) {
            self.timeline.push(Value::Object(point));
        }
        self.n += 1;
    }

    /// The row's `cgroup` field.
    pub(super) fn report(&self) -> Value {
        let end_events = self.dir.as_deref().map(events).unwrap_or_default();
        let end_stat = self.dir.as_deref().map(stat).unwrap_or_default();
        let delta = |a: &BTreeMap<String, u64>, b: &BTreeMap<String, u64>| {
            b.iter()
                .map(|(k, v)| (k.clone(), json!(v.saturating_sub(a.get(k).copied().unwrap_or(0)))))
                .collect::<serde_json::Map<_, _>>()
        };
        json!({
            "dir": self.dir.as_ref().map(|d| d.display().to_string()),
            "memoryHigh": self.dir.as_deref().and_then(|d| std::fs::read_to_string(d.join("memory.high")).ok()).map(|s| s.trim().to_owned()),
            "samples": self.n,
            "max": self.max,
            "eventsDelta": delta(&self.events0, &end_events),
            "reclaimDelta": delta(&self.stat0, &end_stat)
                .into_iter()
                .filter(|(k, _)| k.starts_with("pg") || k.starts_with("workingset"))
                .collect::<serde_json::Map<_, _>>(),
            "psiUnreadable": self.psi_errors.iter().take(4).collect::<Vec<_>>(),
            "timeline": self.timeline,
        })
    }
}
