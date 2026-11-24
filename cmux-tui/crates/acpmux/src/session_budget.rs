//! Per-session budgets sized from the host and its lane cap, so one runaway (a build, a `du`, a
//! log) cannot sink the other lanes on a lane host. Leo, 2026-11-24: "we can design out hosts
//! becoming overloaded by building and using our designs and gradually migrating and testing and
//! creating experiments and trialing as we go in order to fan out, and to be solving more and
//! more and finding better and better tradeoffs".
//!
//! One [`Budget`] goes to every scope acpmux makes: a session's harness scope
//! (`session_scope.rs`, `systemd-run -p`) and every agent host and background task scope
//! (`agent_host/scope.rs`, `StartTransientUnit` over `busctl`). Before this, a host or task scope
//! got `TasksMax` alone, so a `cargo build` started with `bg_start` ran with no memory ceiling and
//! full CPU weight (gcp-agent-lane-8, 2026-11-24: one task scope at 10.6 GB, `MemoryMax=infinity`).
//!
//! Sizes, each from the profile's env, then the daemon config (`session.*`), then the daemon's
//! env, then the default below; 0 turns one off:
//! - memory: `ACPMUX_SESSION_MEMORY_MB`, default RAM / lanes x [`LANE_HEADROOM`], at least
//!   [`MEMORY_FLOOR`] and at most half the RAM (half the RAM, as before, with no lane cap);
//!   `MemoryHigh` 9/10 of it (`ACPMUX_SESSION_MEMORY_HIGH_MB`).
//! - lanes: `session.lanes`, else `ACPMUX_HOST_LANES`, else this host's fleet-registry.json
//!   `lanes.max_lanes` (read once per daemon), else none.
//! - CPU: `ACPMUX_SESSION_CPU_WEIGHT` (default 50, systemd's is 100) and a ceiling
//!   `ACPMUX_SESSION_CPU_QUOTA_PCT`, a percent of the whole machine (default 75: one session
//!   never takes every core).
//! - IO: `ACPMUX_SESSION_IO_WEIGHT` (default 50). Where the user manager has no `io`
//!   controller delegated (the lane VMs as of 2026-11-24) systemd keeps it and the kernel
//!   ignores it until it is delegated.
//! - disk: `ACPMUX_SESSION_DISK_MB` / `session.diskMb`, default this host's registry
//!   `lanes.disk_per_lane_gb`, else a tenth of the home filesystem between 2 and 64 GiB. The
//!   kernel has no per-scope disk limit here, so `hub/session_budget_watch.rs` measures it.
//!
//! [`status`] is the `sessionBudgets` object of `daemon status` ([`VERSION`]).
#![cfg_attr(not(target_os = "linux"), allow(dead_code))]

use serde_json::{Value, json};

/// The `sessionBudgets` shape's version in `daemon status`. A reader takes the fields it knows
/// from any version (`budget_line`), so a newer daemon's additions never break an older CLI.
pub(crate) const VERSION: u64 = 1;

/// How many lanes' worth of RAM one session may use: a lane is a coordinator and its helpers,
/// and one of them bursts (a link) while the others idle.
pub(crate) const LANE_HEADROOM: u64 = 2;
/// The least memory a session's default ceiling gives, however many lanes share the host.
pub(crate) const MEMORY_FLOOR: u64 = 2 << 30;
/// The default CPU ceiling, a percent of the machine.
pub(crate) const CPU_QUOTA_PCT: u64 = 75;
/// The default CPU and IO weights (systemd's own are 100).
pub(crate) const CPU_WEIGHT: u64 = 50;
pub(crate) const IO_WEIGHT: u64 = 50;
const MIB: u64 = 1 << 20;
const GIB: u64 = 1 << 30;

/// What the budget is sized from.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub(crate) struct Host {
    /// RAM bytes (0: unknown, memory limits off).
    pub memory: u64,
    /// Swap bytes.
    pub swap: u64,
    /// Online CPUs (0: unknown, the CPU ceiling off).
    pub cores: u64,
    /// The host's lane cap, when known.
    pub lanes: Option<u64>,
    /// Bytes of the filesystem the sessions write (home).
    pub disk_total: u64,
    /// The registry's per-lane disk, bytes.
    pub disk_per_lane: Option<u64>,
}

/// One scope's limits; 0 (or None for tasks) is off.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub(crate) struct Budget {
    pub memory_max: u64,
    pub memory_high: u64,
    pub swap_max: u64,
    pub tasks_max: Option<u64>,
    pub cpu_weight: u64,
    /// Percent of one CPU (`CPUQuota=`), so 1200 is 12 cores.
    pub cpu_quota: u64,
    pub io_weight: u64,
    pub disk: u64,
}

/// A session's default memory ceiling on `host`.
pub(crate) fn memory_default(host: &Host) -> u64 {
    let half = host.memory / 2;
    match host.lanes.filter(|n| *n > 0) {
        Some(lanes) => {
            (host.memory / lanes).saturating_mul(LANE_HEADROOM).max(MEMORY_FLOOR).min(half)
        }
        None => half,
    }
}

/// A session's default disk budget on `host` (0: unknown).
pub(crate) fn disk_default(host: &Host) -> u64 {
    host.disk_per_lane
        .filter(|n| *n > 0)
        .unwrap_or_else(|| (host.disk_total / 10).clamp(2 * GIB, 64 * GIB))
        .min(if host.disk_total > 0 { host.disk_total } else { u64::MAX })
}

impl Budget {
    /// The budget on `host` from `get` (a knob reader, `session_scope::knob_reader`).
    pub(crate) fn read(get: &dyn Fn(&str) -> Option<String>, host: &Host) -> Self {
        let knob = |key: &str| get(key).and_then(|v| v.trim().parse::<u64>().ok());
        let mb = |n: u64| n.saturating_mul(MIB);
        let memory_max = knob("ACPMUX_SESSION_MEMORY_MB").map_or_else(|| memory_default(host), mb);
        // Throttled (reclaim, slower allocation) a little before it is killed.
        let high = knob("ACPMUX_SESSION_MEMORY_HIGH_MB").map_or(memory_max / 10 * 9, mb);
        let memory_high = if memory_max > 0 { high.min(memory_max) } else { high };
        let swap_max = knob("ACPMUX_SESSION_SWAP_MB").map_or(host.swap / 4, mb);
        let cpu_weight = knob("ACPMUX_SESSION_CPU_WEIGHT").unwrap_or(CPU_WEIGHT).min(10_000);
        let quota_pct = knob("ACPMUX_SESSION_CPU_QUOTA_PCT").unwrap_or(CPU_QUOTA_PCT).min(100);
        let cpu_quota = host.cores.saturating_mul(quota_pct);
        let io_weight = knob("ACPMUX_SESSION_IO_WEIGHT").unwrap_or(IO_WEIGHT).min(10_000);
        let disk = knob("ACPMUX_SESSION_DISK_MB").map_or_else(|| disk_default(host), mb);
        Self {
            memory_max,
            memory_high,
            swap_max,
            tasks_max: crate::session_scope::tasks_max(get),
            cpu_weight,
            cpu_quota,
            io_weight,
            disk,
        }
    }

    /// The scope properties, `(name, value)` in `systemd-run -p` spelling, the ones that are on.
    /// `TasksMax` is always there (`infinity` when off: a scope without it would get systemd's
    /// `DefaultTasksMax`). Empty when every limit is off: no scope at all.
    pub(crate) fn properties(&self) -> Vec<(&'static str, String)> {
        let on = |v: u64| (v > 0).then(|| v.to_string());
        let limits = [
            ("MemoryMax", on(self.memory_max)),
            ("MemoryHigh", on(self.memory_high)),
            ("MemorySwapMax", on(self.swap_max)),
            ("TasksMax", self.tasks_max.map(|n| n.to_string())),
            ("CPUWeight", on(self.cpu_weight)),
            ("CPUQuota", on(self.cpu_quota).map(|p| format!("{p}%"))),
            ("IOWeight", on(self.io_weight)),
        ];
        if limits.iter().all(|(_, v)| v.is_none()) {
            return Vec::new();
        }
        limits
            .into_iter()
            .filter_map(|(key, value)| match value {
                Some(v) => Some((key, v)),
                None if key == "TasksMax" => Some((key, "infinity".to_owned())),
                None => None,
            })
            .collect()
    }

    /// The same properties as `StartTransientUnit` `(name, signature, value)` triples for
    /// `busctl` (`CPUQuota` is `CPUQuotaPerSecUSec` there; `infinity` is `u64::MAX`), with
    /// `OOMPolicy=continue` so a runaway's OOM kill ends that process, not the whole scope.
    pub(crate) fn bus_properties(&self) -> Vec<[String; 3]> {
        let mut out: Vec<[String; 3]> = self
            .properties()
            .into_iter()
            .map(|(key, value)| match key {
                "CPUQuota" => {
                    let pct = value.trim_end_matches('%').parse::<u64>().unwrap_or(0);
                    ["CPUQuotaPerSecUSec".into(), "t".into(), (pct * 10_000).to_string()]
                }
                _ if value == "infinity" => [key.into(), "t".into(), u64::MAX.to_string()],
                _ => [key.into(), "t".into(), value],
            })
            .collect();
        if out.is_empty() {
            // No limits: the host scope still gets its explicit "no task cap".
            out.push(["TasksMax".into(), "t".into(), u64::MAX.to_string()]);
        }
        out.push(["OOMPolicy".into(), "s".into(), "continue".into()]);
        out
    }

    /// The budget as `daemon status` reports it.
    pub(crate) fn json(&self) -> Value {
        json!({
            "memoryMaxBytes": self.memory_max,
            "memoryHighBytes": self.memory_high,
            "swapMaxBytes": self.swap_max,
            "tasksMax": self.tasks_max,
            "cpuWeight": self.cpu_weight,
            "cpuQuotaPercent": self.cpu_quota,
            "ioWeight": self.io_weight,
            "diskBytes": self.disk,
        })
    }
}

/// The daemon's budget, as a host or task scope gets it: no profile env (a host is placed
/// before its session's profile reaches it), the daemon config, then the daemon's env.
pub(crate) fn daemon_budget() -> (Budget, Host) {
    let host = this_host();
    let empty = std::collections::BTreeMap::new();
    let limits = crate::session_scope::daemon_limits();
    let get = crate::session_scope::knob_reader(&empty, limits);
    (Budget::read(&get, &host), host)
}

/// The budget of an agent host or background task scope (`agent_host/scope.rs`): the daemon's,
/// with no default `MemoryHigh` on a host without swap. There the kernel cannot push a scope's
/// anonymous memory anywhere, so a scope over `MemoryHigh` is throttled without end and never
/// reaches `MemoryMax` (gcp-agent-lane-8, 2026-11-24: a 6 GB hog under MemoryMax=2G and
/// MemoryHigh=1.8G sat at 1.79 GB under 96% memory pressure until it was ended; without the
/// throttle it was OOM-killed at 2G in 0.7 s). A set `ACPMUX_SESSION_MEMORY_HIGH_MB` still wins.
pub(crate) fn task_budget() -> (Budget, Host) {
    let host = this_host();
    let empty = std::collections::BTreeMap::new();
    let limits = crate::session_scope::daemon_limits();
    let get = crate::session_scope::knob_reader(&empty, limits);
    (task_budget_from(&get, &host), host)
}

/// [`task_budget`] from a knob reader.
pub(crate) fn task_budget_from(get: &dyn Fn(&str) -> Option<String>, host: &Host) -> Budget {
    let mut budget = Budget::read(get, host);
    if host.swap == 0 && get("ACPMUX_SESSION_MEMORY_HIGH_MB").is_none() {
        budget.memory_high = 0;
    }
    budget
}

/// This machine's [`Host`]. The registry is read once per process; the rest is cheap.
pub(crate) fn this_host() -> Host {
    #[cfg(target_os = "linux")]
    {
        let limits = crate::session_scope::daemon_limits();
        let lanes = limits
            .lanes
            .filter(|n| *n > 0)
            .or_else(|| std::env::var("ACPMUX_HOST_LANES").ok()?.trim().parse().ok())
            .filter(|n| *n > 0)
            .or(registry_lanes().0);
        Host {
            memory: crate::session_scope::physical_memory(),
            swap: crate::session_scope::swap_memory(),
            cores: std::thread::available_parallelism().map_or(0, |n| n.get() as u64),
            lanes,
            disk_total: home_disk().map_or(0, |(total, _)| total),
            disk_per_lane: limits.disk_mb.map(|mb| mb * MIB).or(registry_lanes().1),
        }
    }
    #[cfg(not(target_os = "linux"))]
    Host::default()
}

/// This host's registry `lanes.max_lanes` and `lanes.disk_per_lane_gb` (bytes), read once.
fn registry_lanes() -> (Option<u64>, Option<u64>) {
    static LANES: std::sync::OnceLock<(Option<u64>, Option<u64>)> = std::sync::OnceLock::new();
    *LANES.get_or_init(|| {
        let registry = crate::placement::load_registry();
        let name = crate::host_pressure::host_name();
        lanes_of(registry.as_ref(), &name)
    })
}

/// `name`'s (a host name, maybe with its domain) `(max_lanes, disk_per_lane_gb bytes)`.
pub(crate) fn lanes_of(registry: Option<&Value>, name: &str) -> (Option<u64>, Option<u64>) {
    let Some(hosts) = crate::placement::lane_hosts(registry) else { return (None, None) };
    let short = name.split('.').next().unwrap_or(name);
    let Some(lanes) = crate::placement::registry_lanes(&hosts, name)
        .or_else(|| crate::placement::registry_lanes(&hosts, short))
    else {
        return (None, None);
    };
    let max = lanes.get("max_lanes").and_then(Value::as_f64).filter(|n| n.is_finite() && *n >= 1.0);
    let disk =
        lanes.get("disk_per_lane_gb").and_then(Value::as_f64).filter(|n| n.is_finite() && *n > 0.0);
    (max.map(|n| n as u64), disk.map(|gb| (gb * GIB as f64) as u64))
}

/// The home filesystem's `(total, available)` bytes.
pub(crate) fn home_disk() -> Option<(u64, u64)> {
    #[cfg(unix)]
    {
        use std::os::unix::ffi::OsStrExt;
        let home = dirs::home_dir()?;
        let path = std::ffi::CString::new(home.as_os_str().as_bytes()).ok()?;
        // SAFETY: a zeroed statvfs is a valid out value; `path` is NUL-terminated.
        let mut st: libc::statvfs = unsafe { std::mem::zeroed() };
        // SAFETY: as above.
        if unsafe { libc::statvfs(path.as_ptr(), &mut st) } != 0 {
            return None;
        }
        let frsize = st.f_frsize as u64;
        Some((st.f_blocks as u64 * frsize, st.f_bavail as u64 * frsize))
    }
    #[cfg(not(unix))]
    None
}

/// `daemon status`'s `sessionBudgets`: the version, the per-scope budget (a session's harness
/// scope; `perTaskScope` for agent host and background task scopes), what it was sized
/// from, whether the disk watcher runs, and each measured scope's use (`use`, from
/// `hub/session_budget_watch.rs`).
pub(crate) fn status(budget: &Budget, task: &Budget, host: &Host, watch: Value) -> Value {
    json!({
        "version": VERSION,
        "perScope": budget.json(),
        "perTaskScope": task.json(),
        "sizedFrom": {
            "memoryBytes": host.memory,
            "cores": host.cores,
            "lanes": host.lanes,
            "diskBytes": host.disk_total,
        },
        "watch": watch,
    })
}

/// `daemon status`'s one line for `sessionBudgets` (any version; None when absent: an older
/// daemon).
pub(crate) fn budget_line(v: &Value) -> Option<String> {
    let per = v.get("perScope")?;
    let gib = |key: &str| {
        per.get(key).and_then(Value::as_u64).map_or("off".to_owned(), |b| {
            if b == 0 { "off".to_owned() } else { format!("{:.1}G", b as f64 / GIB as f64) }
        })
    };
    let quota = per.get("cpuQuotaPercent").and_then(Value::as_u64).filter(|n| *n > 0);
    let lanes = v.pointer("/sizedFrom/lanes").and_then(Value::as_u64);
    let watch = v.get("watch");
    let over = watch
        .and_then(|w| w.get("use"))
        .and_then(Value::as_array)
        .map_or(0, |u| u.iter().filter(|s| s["state"] != "ok").count());
    let mut line = format!(
        "mem {} (high {}), cpu {} weight {}, disk {}",
        gib("memoryMaxBytes"),
        gib("memoryHighBytes"),
        quota.map_or("no ceiling".to_owned(), |q| format!("{q}%")),
        per.get("cpuWeight").and_then(Value::as_u64).unwrap_or(0),
        gib("diskBytes"),
    );
    if let Some(lanes) = lanes {
        line.push_str(&format!(", sized for {lanes} lanes"));
    }
    if over > 0 {
        line.push_str(&format!(", {over} scope(s) over"));
    }
    Some(line)
}

#[cfg(test)]
#[path = "session_budget_tests.rs"]
mod tests;
