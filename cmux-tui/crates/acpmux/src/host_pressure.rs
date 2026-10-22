//! The host's CPU and RAM budget (cmuxterm-hq#2995). Agent fan-out through
//! one daemon took Leo's Mac (15 CPUs, 48 GB) to a 15-minute load of 146,
//! with 34.7 of 36.8 GB swap used, and the desktop beachballed. Leo: "cmux
//! next itself should be more cpu and ram aware... maybe even acpmux itself..
//! just warn for now instead of prenveting stuff".
//!
//! So this only warns. The budget is derived from the host itself, never
//! hand-set: the host is over budget while any of these holds:
//! - the 1-minute load is at least `load1_per_core` per core, counting
//!   performance cores (`hw.perflevel0.physicalcpu`, else `hw.physicalcpu`)
//!   on macOS and the CPUs this process may use (`nproc`) on Linux;
//! - memory pressure is above `pressure` (macOS
//!   `kern.memorystatus_vm_pressure_level`: 1 normal, 2 warn, 4 critical; Linux
//!   `/proc/pressure/memory` `some avg10` at or above `psi_some_avg10` is warn);
//! - available RAM is under `min_available_ram_fraction` of the total;
//! - swap grows faster than `swap_growth_mb_per_min` (pages swapped out: macOS
//!   `vm_stat` Swapouts, Linux `/proc/vmstat` pswpout).
//!
//! The formula's defaults are built in. An optional file, `$ACPMUX_HOST_BUDGET`
//! or else `~/.config/cmux/host-budget.json`, overrides them: `{"enforce",
//! "formula": {..}, "hosts": {"<host>": {..}}}`, the same keys as leo-workspace
//! `machines/host-budget.json`, which lane-place reads. `enforce` is reported,
//! not acted on: nothing is refused, queued or held.
//!
//! [`evaluate`] is the one place the verdict is made, from a [`Sample`]. The
//! daemon samples only when asked (a turn starts, `daemon status`), at most once
//! per `sample_seconds`, and keeps no timer (`Meter`).

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::path::PathBuf;
use std::sync::Mutex;
use std::time::{Duration, Instant};

/// Names the override file (module docs).
pub const OVERRIDE_ENV: &str = "ACPMUX_HOST_BUDGET";

/// A swap baseline older than this gives no rate; the next sample starts a new one.
const SWAP_WINDOW: Duration = Duration::from_secs(600);

const MIB: f64 = 1024.0 * 1024.0;

/// How the budget follows from the host (module docs). Field names are the
/// shared file's keys.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Formula {
    /// Over when the 1-minute load is at least `cores * load1_per_core`.
    pub load1_per_core: f64,
    /// `performance` (performance cores on Apple silicon, else physical, else
    /// logical) or `logical` (every CPU).
    pub cores: String,
    /// The highest memory-pressure level within budget: `normal` or `warn`.
    pub pressure: String,
    /// Linux: `/proc/pressure/memory` `some avg10` at or above this is `warn`.
    pub psi_some_avg10: f64,
    /// Over when available RAM is under this fraction of the total.
    pub min_available_ram_fraction: f64,
    /// Over when swap-outs grow faster than this.
    pub swap_growth_mb_per_min: f64,
    /// The shortest time between two samples; a verdict is reused within it.
    pub sample_seconds: f64,
}

impl Default for Formula {
    fn default() -> Self {
        Self {
            load1_per_core: 1.0,
            cores: "performance".into(),
            pressure: "normal".into(),
            psi_some_avg10: 10.0,
            min_available_ram_fraction: 0.10,
            swap_growth_mb_per_min: 64.0,
            sample_seconds: 3.0,
        }
    }
}

/// The formula in force on this host, and whether the file asks for holds
/// (not implemented: reported only).
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Budget {
    pub enforce: bool,
    pub formula: Formula,
}

/// The budget for `host` from the override file's bytes (`None`: no file).
/// Keys the file leaves out, or gives a value of the wrong kind or out of
/// range, keep the built-in default.
pub fn parse_budget(bytes: Option<&[u8]>, host: &str) -> Budget {
    let mut budget = Budget::default();
    let Some(bytes) = bytes else { return budget };
    let file: Value = match serde_json::from_slice(bytes) {
        Ok(v) => v,
        Err(e) => {
            tracing::warn!("host budget file not read, using the defaults: {e}");
            return budget;
        }
    };
    budget.enforce = file.get("enforce").and_then(Value::as_bool).unwrap_or(false);
    let host_keys = file.get("hosts").and_then(|h| h.get(host));
    for layer in [file.get("formula"), host_keys].into_iter().flatten() {
        let Some(keys) = layer.as_object() else { continue };
        for (key, value) in keys {
            apply_key(&mut budget.formula, key, value);
        }
    }
    budget
}

/// Sets one formula key when its value is usable.
fn apply_key(f: &mut Formula, key: &str, value: &Value) {
    let positive = value.as_f64().filter(|n| n.is_finite() && *n > 0.0);
    let fraction = value.as_f64().filter(|n| (0.0..=1.0).contains(n));
    let word = value.as_str();
    match key {
        "load1_per_core" => positive.map(|n| f.load1_per_core = n),
        "psi_some_avg10" => positive.map(|n| f.psi_some_avg10 = n),
        "swap_growth_mb_per_min" => positive.map(|n| f.swap_growth_mb_per_min = n),
        "sample_seconds" => positive.map(|n| f.sample_seconds = n),
        "min_available_ram_fraction" => fraction.map(|n| f.min_available_ram_fraction = n),
        "cores" => {
            word.filter(|w| matches!(*w, "performance" | "logical")).map(|w| f.cores = w.into())
        }
        "pressure" => {
            word.filter(|w| matches!(*w, "normal" | "warn")).map(|w| f.pressure = w.into())
        }
        _ => None,
    };
}

/// The override file's path: `$ACPMUX_HOST_BUDGET`, else `~/.config/cmux/host-budget.json`.
pub fn override_path() -> Option<PathBuf> {
    match std::env::var_os(OVERRIDE_ENV).filter(|v| !v.is_empty()) {
        Some(path) => Some(PathBuf::from(path)),
        None => dirs::home_dir().map(|h| h.join(".config/cmux/host-budget.json")),
    }
}

/// This host's budget, read from the override file now.
pub fn load_budget(host: &str) -> Budget {
    let bytes = override_path().and_then(|p| std::fs::read(p).ok());
    parse_budget(bytes.as_deref(), host)
}

/// What the host reports at one moment. `None` where the platform has no reading.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Sample {
    pub load1: Option<f64>,
    /// macOS `hw.perflevel0.physicalcpu`.
    pub performance_cores: Option<u32>,
    /// macOS `hw.physicalcpu`.
    pub physical_cores: Option<u32>,
    /// The CPUs this process may use (`nproc`).
    pub logical_cpus: u32,
    /// macOS `kern.memorystatus_vm_pressure_level` (1, 2 or 4).
    pub vm_pressure_level: Option<u32>,
    /// Linux `/proc/pressure/memory` `some avg10`.
    pub psi_some_avg10: Option<f64>,
    pub available_ram_fraction: Option<f64>,
    /// Bytes swapped out since boot.
    pub swapout_bytes: Option<u64>,
}

/// Reads a [`Sample`]; tests inject their own.
pub trait Probe: Send + Sync {
    fn sample(&self) -> Sample;
}

/// The verdict, in the shape lane-place's `host-budget --json` prints (shared keys).
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Verdict {
    pub host: String,
    /// The cores the load is measured against, and which kind they are.
    pub cores: u32,
    pub cores_kind: &'static str,
    pub load1: Option<f64>,
    pub load_limit: f64,
    /// `normal`, `warn`, `critical`, or `unknown`.
    pub pressure: &'static str,
    pub available_ram_fraction: Option<f64>,
    /// `None` until two samples at least `sample_seconds` apart.
    pub swap_mb_per_min: Option<f64>,
    /// Why it is over budget, one phrase each; empty when within it.
    pub over: Vec<String>,
    pub ok: bool,
    /// One line for people, when over budget.
    pub warning: Option<String>,
    /// The file asks for holds; this build only warns.
    pub enforce: bool,
    pub formula: Formula,
}

/// The verdict for `host` from one sample and the swap rate since the last
/// one. Pure: lane-place and the app mirror this.
pub fn evaluate(
    host: &str,
    sample: &Sample,
    swap_mb_per_min: Option<f64>,
    budget: &Budget,
) -> Verdict {
    let f = &budget.formula;
    let (cores, cores_kind) =
        match (f.cores.as_str(), sample.performance_cores, sample.physical_cores) {
            ("performance", Some(n), _) if n > 0 => (n, "performance"),
            ("performance", _, Some(n)) if n > 0 => (n, "physical"),
            _ => (sample.logical_cpus.max(1), "logical"),
        };
    let load_limit = f64::from(cores) * f.load1_per_core;
    let pressure = match (sample.vm_pressure_level, sample.psi_some_avg10) {
        (Some(1), _) => "normal",
        (Some(2), _) => "warn",
        (Some(4), _) => "critical",
        (Some(_), _) => "unknown",
        (None, Some(psi)) if psi >= f.psi_some_avg10 => "warn",
        (None, Some(_)) => "normal",
        (None, None) => "unknown",
    };
    let mut over = Vec::new();
    if let Some(load) = sample.load1.filter(|l| *l >= load_limit) {
        let kind = if cores_kind == "performance" { "P-cores" } else { "cores" };
        over.push(format!("load1 {load:.1} >= {} ({cores} {kind})", trim(load_limit)));
    }
    let worst_allowed = if f.pressure == "warn" { 2 } else { 1 };
    let level = match pressure {
        "warn" => 2,
        "critical" => 4,
        _ => 0,
    };
    if level > worst_allowed {
        over.push(format!("memory pressure {pressure}"));
    }
    if let Some(avail) = sample.available_ram_fraction.filter(|a| *a < f.min_available_ram_fraction)
    {
        over.push(format!(
            "available RAM {:.0}% < {:.0}%",
            avail * 100.0,
            f.min_available_ram_fraction * 100.0
        ));
    }
    if let Some(rate) = swap_mb_per_min.filter(|r| *r > f.swap_growth_mb_per_min) {
        over.push(format!("swap +{rate:.0} MB/min"));
    }
    let ok = over.is_empty();
    let warning =
        (!ok).then(|| format!("host-budget: {host} over its CPU/RAM budget: {}", over.join("; ")));
    Verdict {
        host: host.to_owned(),
        cores,
        cores_kind,
        load1: sample.load1.map(|l| (l * 100.0).round() / 100.0),
        load_limit,
        pressure,
        available_ram_fraction: sample
            .available_ram_fraction
            .map(|a| (a * 1000.0).round() / 1000.0),
        swap_mb_per_min: swap_mb_per_min.map(|r| r.round()),
        over,
        ok,
        warning,
        enforce: budget.enforce,
        formula: f.clone(),
    }
}

/// `10` for 10.0, `7.5` for 7.5.
fn trim(n: f64) -> String {
    if n.fract() == 0.0 { format!("{n:.0}") } else { format!("{n:.1}") }
}

/// Samples on demand, at most once per `sample_seconds`, and remembers the swap
/// baseline between samples. No timer: a verdict is made only when one is asked for.
pub struct Meter {
    host: String,
    probe: Box<dyn Probe>,
    budget: Box<dyn Fn(&str) -> Budget + Send + Sync>,
    state: Mutex<MeterState>,
}

#[derive(Default)]
struct MeterState {
    /// When the last fresh verdict was made, and it.
    cached: Option<(Instant, Verdict)>,
    /// The swap-out counter at the last sample that had one.
    swap: Option<(Instant, u64)>,
}

impl Meter {
    /// This host, its own probe, and the override file read at each fresh sample.
    pub fn for_this_host() -> Self {
        Self::new(host_name(), Box::new(HostProbe), Box::new(load_budget))
    }

    pub fn new(
        host: String,
        probe: Box<dyn Probe>,
        budget: Box<dyn Fn(&str) -> Budget + Send + Sync>,
    ) -> Self {
        Self { host, probe, budget, state: Mutex::default() }
    }

    /// The verdict now (one from the last `sample_seconds` when there is one).
    pub fn verdict(&self) -> Verdict {
        self.verdict_at(Instant::now())
    }

    pub fn verdict_at(&self, now: Instant) -> Verdict {
        let mut state = self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        if let Some((at, v)) = &state.cached
            && now.saturating_duration_since(*at).as_secs_f64() < v.formula.sample_seconds
        {
            return v.clone();
        }
        let budget = (self.budget)(&self.host);
        let sample = self.probe.sample();
        let rate = match (sample.swapout_bytes, state.swap) {
            (Some(bytes), Some((at, before))) => {
                let elapsed = now.saturating_duration_since(at);
                (elapsed.as_secs_f64() >= budget.formula.sample_seconds && elapsed <= SWAP_WINDOW)
                    .then(|| {
                        bytes.saturating_sub(before) as f64 / MIB / (elapsed.as_secs_f64() / 60.0)
                    })
            }
            _ => None,
        };
        if let Some(bytes) = sample.swapout_bytes {
            state.swap = Some((now, bytes));
        }
        let v = evaluate(&self.host, &sample, rate, &budget);
        let was_ok = state.cached.as_ref().is_none_or(|(_, before)| before.ok);
        if let Some(line) = v.warning.as_deref().filter(|_| was_ok) {
            tracing::warn!("{line}");
        } else if v.ok && !was_ok {
            tracing::info!("host-budget: {} is within its CPU/RAM budget again", self.host);
        }
        state.cached = Some((now, v.clone()));
        v
    }
}

/// This machine's short name (`cosmic-gray` for `cosmic-gray.local`), the key
/// of its `hosts` entry.
pub fn host_name() -> String {
    #[cfg(unix)]
    let name = {
        let mut buf = [0u8; 256];
        // SAFETY: a writable buffer of the length passed; gethostname writes at most that many bytes.
        let rc = unsafe { libc::gethostname(buf.as_mut_ptr().cast(), buf.len()) };
        let end = buf.iter().position(|b| *b == 0).unwrap_or(buf.len());
        if rc == 0 { String::from_utf8_lossy(&buf[..end]).into_owned() } else { String::new() }
    };
    #[cfg(not(unix))]
    let name = std::env::var("COMPUTERNAME").unwrap_or_default();
    let short = name.split('.').next().unwrap_or_default().trim().to_ascii_lowercase();
    if short.is_empty() { "localhost".into() } else { short }
}

/// The real host's readings.
pub struct HostProbe;

impl Probe for HostProbe {
    fn sample(&self) -> Sample {
        let logical_cpus = std::thread::available_parallelism().map_or(1, |n| n.get() as u32);
        platform::sample(logical_cpus)
    }
}

#[cfg(target_os = "macos")]
mod platform {
    use super::Sample;

    pub(super) fn sample(logical_cpus: u32) -> Sample {
        let mut load = [0f64; 3];
        // SAFETY: `load` has room for the 3 values asked for.
        let load1 = (unsafe { libc::getloadavg(load.as_mut_ptr(), 3) } >= 1).then_some(load[0]);
        let count = |name: &std::ffi::CStr| {
            sysctl_i32(name).and_then(|n| u32::try_from(n).ok()).filter(|n| *n > 0)
        };
        Sample {
            load1,
            performance_cores: count(c"hw.perflevel0.physicalcpu"),
            physical_cores: count(c"hw.physicalcpu"),
            logical_cpus,
            vm_pressure_level: count(c"kern.memorystatus_vm_pressure_level"),
            psi_some_avg10: None,
            // The "System-wide memory free percentage" memory_pressure prints.
            available_ram_fraction: sysctl_i32(c"kern.memorystatus_level")
                .map(|p| f64::from(p) / 100.0),
            swapout_bytes: swapout_bytes(),
        }
    }

    fn sysctl_i32(name: &std::ffi::CStr) -> Option<i32> {
        let mut value: libc::c_int = 0;
        let mut size = size_of::<libc::c_int>();
        // SAFETY: the name is NUL-terminated and `value`/`size` describe valid storage.
        let ok = unsafe {
            libc::sysctlbyname(
                name.as_ptr(),
                (&raw mut value).cast(),
                &raw mut size,
                std::ptr::null_mut(),
                0,
            )
        } == 0;
        ok.then_some(value)
    }

    /// `vm_stat`'s Swapouts (pages) in bytes.
    fn swapout_bytes() -> Option<u64> {
        // One send right for the daemon's life, not one per sample.
        static HOST: std::sync::OnceLock<libc::mach_port_t> = std::sync::OnceLock::new();
        // SAFETY: no arguments; returns this host's name port.
        #[allow(deprecated)]
        let host = *HOST.get_or_init(|| unsafe { libc::mach_host_self() });
        // SAFETY: an all-zero vm_statistics64 is a valid value of this plain C struct.
        let mut stats: libc::vm_statistics64 = unsafe { std::mem::zeroed() };
        let mut count = libc::HOST_VM_INFO64_COUNT;
        // SAFETY: `stats` is HOST_VM_INFO64_COUNT integers of writable storage, as `count` says.
        let rc = unsafe {
            libc::host_statistics64(
                host,
                libc::HOST_VM_INFO64,
                (&raw mut stats).cast(),
                &raw mut count,
            )
        };
        // SAFETY: sysconf has no preconditions.
        let page = unsafe { libc::sysconf(libc::_SC_PAGESIZE) };
        (rc == libc::KERN_SUCCESS && page > 0).then(|| stats.swapouts.saturating_mul(page as u64))
    }
}

#[cfg(target_os = "linux")]
mod platform {
    use super::Sample;

    pub(super) fn sample(logical_cpus: u32) -> Sample {
        let read = |path: &str| std::fs::read_to_string(path).ok();
        let load1 = read("/proc/loadavg").and_then(|s| s.split_whitespace().next()?.parse().ok());
        let psi = read("/proc/pressure/memory").and_then(|s| psi_some_avg10(&s));
        let available = read("/proc/meminfo").and_then(|s| {
            let kb = |key: &str| {
                s.lines().find_map(|l| {
                    l.strip_prefix(key)?.trim().trim_end_matches("kB").trim().parse::<f64>().ok()
                })
            };
            let total = kb("MemTotal:").filter(|t| *t > 0.0)?;
            Some(kb("MemAvailable:")? / total)
        });
        // SAFETY: sysconf has no preconditions.
        let page = unsafe { libc::sysconf(libc::_SC_PAGESIZE) };
        let swapout_bytes = read("/proc/vmstat")
            .and_then(|s| {
                s.lines().find_map(|l| l.strip_prefix("pswpout ")?.trim().parse::<u64>().ok())
            })
            .filter(|_| page > 0)
            .map(|pages| pages.saturating_mul(page as u64));
        Sample {
            load1,
            performance_cores: None,
            physical_cores: None,
            logical_cpus,
            vm_pressure_level: None,
            psi_some_avg10: psi,
            available_ram_fraction: available,
            swapout_bytes,
        }
    }

    /// `some avg10=1.23 avg60=... total=...` → 1.23.
    pub(super) fn psi_some_avg10(text: &str) -> Option<f64> {
        let line = text.lines().find(|l| l.starts_with("some "))?;
        line.split_whitespace().find_map(|w| w.strip_prefix("avg10=")?.parse().ok())
    }
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
mod platform {
    use super::Sample;

    pub(super) fn sample(logical_cpus: u32) -> Sample {
        Sample { logical_cpus, ..Sample::default() }
    }
}

#[cfg(test)]
#[path = "host_pressure_tests.rs"]
mod tests;
