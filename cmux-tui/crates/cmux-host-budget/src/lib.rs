//! The host's CPU and RAM budget (cmuxterm-hq#2995). Agent fan-out through
//! one daemon took Leo's Mac (15 CPUs, 48 GB) to a 15-minute load of 146,
//! with 34.7 of 36.8 GB swap used, and the desktop beachballed. Leo: "cmux
//! next itself should be more cpu and ram aware... maybe even acpmux itself..
//! just warn for now instead of prenveting stuff".
//!
//! So this only warns. The budget is derived from the host itself, never
//! hand-set: the host is over budget while any of these holds:
//! - the 1-minute load is at least `load1_per_core` per core. macOS counts the
//!   performance cores: the `hw.perflevelN.physicalcpu` of every level whose
//!   `hw.perflevelN.name` is not `Efficiency` (M1 to M4: the P-cores; M5: the
//!   Super cores, plus an M5 Pro's Performance cores, so 15 on an M5 Pro and 4
//!   on an M5), else `hw.physicalcpu`. Linux counts the CPUs this process may
//!   use (`nproc`);
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
//! [`evaluate`] is the one place the verdict is made, from a [`Sample`]. A
//! sample ([`HostProbe`]) and the override file ([`load_budget`]) are blocking
//! reads: run them off the async runtime, as [`Meter`] does. acpmux's
//! `daemon status` `host_pressure` and the warning on a turn's acceptance read
//! its meter (feature `tokio`). The macOS app links this crate through
//! cmux-app-ffi: it reads its own [`Meter`] when no daemon answers, judges a
//! verdict again with the memory pressure the system reports ([`with_pressure`]),
//! and turns verdicts into the level it shows ([`Tracker`]). No other copy of
//! the formula exists.

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::io::Read;
use std::path::{Path, PathBuf};

/// Names the override file (module docs).
pub const OVERRIDE_ENV: &str = "ACPMUX_HOST_BUDGET";

/// The largest override file read; a bigger one keeps the defaults.
const MAX_FILE_BYTES: u64 = 64 << 10;

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

/// This host's budget, read from the override file now (blocking: a sample's thread).
pub fn load_budget(host: &str) -> Budget {
    let bytes = override_path().and_then(|p| read_override(&p));
    parse_budget(bytes.as_deref(), host)
}

/// The override file's bytes: only a regular file (a FIFO or a device would
/// block the read) of at most [`MAX_FILE_BYTES`]; `None` keeps the defaults.
/// Unix opens it without blocking and checks the open file, so a FIFO swapped in
/// after a check never blocks the read.
pub fn read_override(path: &Path) -> Option<Vec<u8>> {
    let mut options = std::fs::OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    std::os::unix::fs::OpenOptionsExt::custom_flags(&mut options, libc::O_NONBLOCK);
    let mut file = options.open(path).ok()?;
    let meta = file.metadata().ok()?;
    if !meta.is_file() || meta.len() > MAX_FILE_BYTES {
        tracing::warn!(
            "{}: not a regular file of at most 64 KiB; using the defaults",
            path.display()
        );
        return None;
    }
    let mut bytes = Vec::new();
    (&mut file).take(MAX_FILE_BYTES + 1).read_to_end(&mut bytes).ok()?;
    (bytes.len() as u64 <= MAX_FILE_BYTES).then_some(bytes)
}

/// What the host reports at one moment. `None` where the platform has no reading.
/// It reads from JSON with these field names (absent fields `None`), for a
/// caller that judges given numbers ([`json::evaluate`]).
#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(default)]
pub struct Sample {
    pub load1: Option<f64>,
    /// macOS: the cores of every perf level not named `Efficiency` ([`performance_cores`]).
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
        (Some(level), _) => pressure_word(level),
        (None, Some(psi)) if psi >= f.psi_some_avg10 => "warn",
        (None, Some(_)) => "normal",
        (None, None) => "unknown",
    };
    let mut over = Vec::new();
    if let Some(load) = sample.load1.filter(|l| *l >= load_limit) {
        let kind = if cores_kind == "performance" { "P-cores" } else { "cores" };
        over.push(format!("load1 {load:.1} >= {} ({cores} {kind})", trim(load_limit)));
    }
    if pressure_is_over(pressure, &f.pressure) {
        over.push(memory_reason(pressure));
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
    let warning = warning_line(host, &over);
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

/// The word for a memory-pressure level as macOS numbers it
/// (`kern.memorystatus_vm_pressure_level`, and the same values in
/// `DISPATCH_MEMORYPRESSURE_*`): 1 normal, 2 warn, 4 critical, else unknown.
pub fn pressure_word(level: u32) -> &'static str {
    match level {
        1 => "normal",
        2 => "warn",
        4 => "critical",
        _ => "unknown",
    }
}

/// Whether memory pressure `pressure` is over a formula that allows up to
/// `allowed` (`normal` or `warn`): critical always is, unknown never.
pub fn pressure_is_over(pressure: &str, allowed: &str) -> bool {
    let worst_allowed = if allowed == "warn" { 2 } else { 1 };
    let level = match pressure {
        "warn" => 2,
        "critical" => 4,
        _ => 0,
    };
    level > worst_allowed
}

/// The reason a verdict gives for memory pressure over the formula.
fn memory_reason(pressure: &str) -> String {
    format!("{MEMORY_REASON}{pressure}")
}

/// The start of [`memory_reason`]'s phrase ([`with_pressure`] replaces it).
const MEMORY_REASON: &str = "memory pressure ";

/// The verdict's line for people: `None` while within budget.
fn warning_line(host: &str, over: &[String]) -> Option<String> {
    (!over.is_empty())
        .then(|| format!("host-budget: {host} over its CPU/RAM budget: {}", over.join("; ")))
}

/// `10` for 10.0, `7.5` for 7.5.
fn trim(n: f64) -> String {
    if n.fract() == 0.0 { format!("{n:.0}") } else { format!("{n:.1}") }
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
        if rc == 0 {
            String::from_utf8_lossy(buf.get(..end).unwrap_or_default()).into_owned()
        } else {
            String::new()
        }
    };
    #[cfg(not(unix))]
    let name = std::env::var("COMPUTERNAME").unwrap_or_default();
    short_host_name(&name)
}

/// A host's name as the `hosts` entries key it: before the first dot, trimmed,
/// lowercased; `localhost` when empty.
pub fn short_host_name(name: &str) -> String {
    let short = name.split('.').next().unwrap_or_default().trim().to_ascii_lowercase();
    if short.is_empty() { "localhost".into() } else { short }
}

// Samples on demand and keeps the last verdict (no timer).
mod meter;
pub use meter::{Meter, SAMPLE_WAIT};

// The real host's readings, and the parsers of Linux's `/proc` files.
mod probe;
pub use probe::{
    HostProbe, cpu_busy, parse_loadavg, parse_meminfo_available, parse_meminfo_swap_used,
    parse_proc_stat_cpu, parse_psi_avg60, parse_psi_some_avg10, parse_vmstat_oom_kill,
    parse_vmstat_pswpout, performance_cores,
};

// The level the app shows, which does not flicker, and a verdict judged again
// with a newer memory pressure.
mod level;
pub use level::{LOAD_RELEASE_FRACTION, LOAD_WARN_FRACTION, Level, Reading, Tracker, level_for};
mod rejudge;
pub use rejudge::with_pressure;

// The JSON calls the app's C ABI makes (cmux-app-ffi `host_budget.rs`).
pub mod json;

#[cfg(test)]
mod tests;
