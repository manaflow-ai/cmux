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
//! - IO: `ACPMUX_SESSION_IO_WEIGHT` (default 50). It takes effect only where the user manager
//!   has the `io` controller delegated (`Delegate=` on `user@.service`) and a block device runs a
//!   weight policy (iocost `enable=1` in the root `io.cost.qos`, or the `bfq` scheduler); else
//!   systemd keeps the property and the kernel ignores it. [`IoState`] says which, in
//!   `sessionBudgets.io` (version 2), so an inert weight shows instead of passing for a limit.
//!   The lane VMs delegate no `io` and run `none` with iocost off, and stay that way: with both
//!   turned on (2026-11-24, scripts/measure/session-budget-runaway/io.sh, a 4 GB writer) the
//!   weight reached the scope (`io.weight default 10`) but a neighbor's 4 KB fsync was no better,
//!   median p50/p99 25/271 ms with it against 35/213 ms without: the ext4 journal, not the
//!   device share, is what the neighbor waits on. No bandwidth cap (`IOWriteBandwidthMax`)
//!   either: a capped writer's dirty pages sit in the journal commit every neighbor's fsync waits
//!   on, and a 100 MB/s cap took the neighbor's fsync p99 from 231-336 ms to 779-859 ms. The disk
//!   watcher (`hub/session_budget_watch.rs`) is the session's disk limit.
//! - disk: `ACPMUX_SESSION_DISK_MB` / `session.diskMb`, default this host's registry
//!   `lanes.disk_per_lane_gb`, else a tenth of the home filesystem between 2 and 64 GiB. The
//!   kernel has no per-scope disk limit here, so `hub/session_budget_watch.rs` measures it.
//!
//! [`status`] is the `sessionBudgets` object of `daemon status` ([`VERSION`]).
#![cfg_attr(not(target_os = "linux"), allow(dead_code))]

use serde_json::{Value, json};

/// The `sessionBudgets` shape's version in `daemon status`. A reader takes the fields it knows
/// from any version (`budget_line`), so a newer daemon's additions never break an older CLI.
///
/// 2 (2026-11-24): `io`, whether the IO weight takes effect.
pub(crate) const VERSION: u64 = 2;

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
    /// Whether an `IOWeight` takes effect here.
    pub io: IoState,
}

/// Whether the kernel honors a scope's `IOWeight` on this host.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub(crate) struct IoState {
    /// The user manager's cgroup (`user@UID.service`) has the `io` controller: systemd's
    /// `Delegate=` for `user@.service` names it. None: not under a user manager (unknown).
    pub delegated: Option<bool>,
    /// A block device's weight policy: iocost on, else bfq. None: no device has one, so
    /// `io.weight` is accepted and ignored.
    pub policy: Option<IoPolicy>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum IoPolicy {
    Iocost,
    Bfq,
}

impl IoPolicy {
    fn name(self) -> &'static str {
        match self {
            Self::Iocost => "iocost",
            Self::Bfq => "bfq",
        }
    }
}

impl IoState {
    /// From `/proc/self/cgroup` (`cgroup`), a reader of a cgroup file under `/sys/fs/cgroup`
    /// (`cg`), the root `io.cost.qos` and each non-loop device's scheduler line.
    pub(crate) fn from(
        cgroup: &str,
        cg: &dyn Fn(&str) -> Option<String>,
        cost_qos: &str,
        schedulers: &[String],
    ) -> Self {
        let path = cgroup.lines().find_map(|l| l.strip_prefix("0::")).unwrap_or("");
        let manager = path
            .split('/')
            .position(|part| part.starts_with("user@") && part.ends_with(".service"))
            .map(|i| path.split('/').take(i + 1).collect::<Vec<_>>().join("/"));
        let delegated = manager.map(|dir| {
            cg(&format!("{dir}/cgroup.controllers"))
                .is_some_and(|c| c.split_whitespace().any(|name| name == "io"))
        });
        let iocost = cost_qos.lines().any(|l| l.split_whitespace().any(|w| w == "enable=1"));
        let bfq = schedulers.iter().any(|s| s.contains("[bfq]"));
        let policy = if iocost {
            Some(IoPolicy::Iocost)
        } else if bfq {
            Some(IoPolicy::Bfq)
        } else {
            None
        };
        Self { delegated, policy }
    }

    /// This process's state: a few small sysfs reads, no cache (a `daemon-reexec` can delegate
    /// `io` while the daemon runs).
    pub(crate) fn here() -> Self {
        #[cfg(target_os = "linux")]
        {
            let read = |p: &str| std::fs::read_to_string(p).ok();
            let cg = |rel: &str| read(&format!("/sys/fs/cgroup{rel}"));
            let schedulers: Vec<String> = std::fs::read_dir("/sys/block")
                .into_iter()
                .flatten()
                .flatten()
                .filter(|e| !e.file_name().to_string_lossy().starts_with("loop"))
                .take(64)
                .filter_map(|e| read(&format!("{}/queue/scheduler", e.path().display())))
                .collect();
            Self::from(
                &read("/proc/self/cgroup").unwrap_or_default(),
                &cg,
                &read("/sys/fs/cgroup/io.cost.qos").unwrap_or_default(),
                &schedulers,
            )
        }
        #[cfg(not(target_os = "linux"))]
        Self::default()
    }

    /// Whether a scope's `IOWeight` takes effect (None: unknown).
    pub(crate) fn effective(&self) -> Option<bool> {
        self.delegated.map(|d| d && self.policy.is_some())
    }

    pub(crate) fn json(&self) -> Value {
        json!({
            "delegated": self.delegated,
            "policy": self.policy.map(IoPolicy::name),
            "weightEffective": self.effective(),
        })
    }
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
            io: IoState::here(),
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
/// from, whether the IO weight takes effect (`io`, version 2), whether the disk watcher runs,
/// and each measured scope's use (`use`, from `hub/session_budget_watch.rs`).
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
        "io": host.io.json(),
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
    // Version 2's `io`: the weight, and why it does nothing when it does nothing. An older
    // daemon has no `io`, and its line stays as it was.
    let weight = per.get("ioWeight").and_then(Value::as_u64).filter(|w| *w > 0);
    if let (Some(io), Some(weight)) = (v.get("io"), weight) {
        line.push_str(&format!(", io weight {weight}"));
        let inert = match (io.get("delegated").and_then(Value::as_bool), io.get("policy")) {
            (Some(false), _) => Some("io not delegated"),
            (Some(true), Some(Value::Null)) => Some("no iocost or bfq"),
            _ => None,
        };
        if let Some(why) = inert {
            line.push_str(&format!(" (inert: {why})"));
        }
    }
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
