//! The shadow admission verdict (cmuxterm-hq#7342): whether a new active
//! session would be deferred on a host, judged from that host's readings.
//! Shadow only: a caller logs it beside the pick it makes, and nothing is
//! refused, deferred or held on it. [`shadow_verdict`] is pure: the time, the
//! readings and the state the last call returned are all inputs, so acpmux's
//! placement, its daemon's create check and lane-place's `sessions` (through
//! `acpmux machine verdict`) give one set of readings the same verdict.
//! `testdata/shadow-verdict-v2.json` pins inputs to verdicts.
//!
//! CPU and memory each get a state: `ok`, `pressured` or `saturated`, or
//! `unknown` while the host reads nothing for it. Each sample is classed first:
//! - CPU is hot at load1 per core >= 1.25 or PSI cpu `some avg10` >= 30; calm
//!   at load1 per core <= 0.90 with PSI cpu, when read, <= 15; else warm.
//! - Memory is severe only at pressure `critical`. It is hot at a swap growth
//!   of 64 MB/min or more, with available (free plus compressible) under 8%,
//!   with swap at least 90% full and available under 15%, or at pressure `warn`
//!   with available under 15%. Pressure `warn` alone is warm: macOS reports it
//!   for long stretches with plenty available, so it saturates nothing by
//!   itself. Calm is pressure `normal` or unread, a swap growth of 16 MB/min or
//!   less or unread, and available read and at least 15%; anything else is
//!   warm. With neither pressure nor available read, only swap growth speaks:
//!   hot at its line, else unknown.
//!
//! A signal enters `saturated` on one severe sample or two hot samples in a row,
//! and leaves it after three calm samples in a row. Outside `saturated`, a hot
//! or warm sample is `pressured` and a calm one is `ok`. A sample counts only
//! [`MIN_SAMPLE_GAP_MS`] or more after the last one counted: the same reading
//! judged again (two placements on one reading), or a host read more often than
//! that, keeps the streaks it had. So a streak means the same span of time
//! whichever caller reads the host and however often.
//!
//! A reading older than [`MAX_HEALTH_AGE_MS`], or none, is `unknown:stale`, and
//! the states stay as they were. `would_defer` holds when the reading is stale
//! or either signal is saturated; `reason` names staleness first, then memory,
//! then CPU. A signal that is `unknown` on a fresh reading defers nothing; the
//! log shows how often that happens.
//!
//! The session cost is reported, not judged: an idle session is charged its RSS
//! and no CPU, an active one its recent CPU and its RSS. `fits` says whether
//! the new session's cost fits under the CPU and memory enter lines.

use serde::{Deserialize, Serialize};

/// Names this formula in every logged line. A change to a threshold, a class
/// rule or the digest's input bumps it, with new golden vectors.
pub const SHADOW_FORMULA_VERSION: &str = "shadow-admission/2";

/// A reading older than this is `unknown:stale`: three missed 60 s peer refreshes.
pub const MAX_HEALTH_AGE_MS: u64 = 180_000;

/// A sample this soon after the last one counted moves no state: half the 60 s
/// peer refresh, so every peer refresh counts and a burst of local reads does not.
pub const MIN_SAMPLE_GAP_MS: u64 = 30_000;

const CPU_HOT_LOAD_PER_CORE: f64 = 1.25;
const CPU_CALM_LOAD_PER_CORE: f64 = 0.90;
const CPU_HOT_PSI: f64 = 30.0;
const CPU_CALM_PSI: f64 = 15.0;
const MEM_LOW_AVAILABLE: f64 = 0.08;
const MEM_CALM_AVAILABLE: f64 = 0.15;
const MEM_SWAP_FULL: f64 = 0.90;
const MEM_HOT_SWAP_GROWTH: f64 = 64.0;
const MEM_CALM_SWAP_GROWTH: f64 = 16.0;
const ENTER_HOT_SAMPLES: u32 = 2;
const LEAVE_CALM_SAMPLES: u32 = 3;

/// A new session's cost when the caller gives none, until shadow data gives
/// a per-harness prior: one core and 1 GiB.
pub const NEW_SESSION_PRIOR: SessionCost = SessionCost { cpu_cores: 1.0, rss_bytes: 1 << 30 };

/// The memory pressure levels a reading may name.
const MEM_PRESSURE_LEVELS: [&str; 4] = ["normal", "warn", "critical", "unknown"];

fn known_pressure<'de, D: serde::Deserializer<'de>>(d: D) -> Result<Option<String>, D::Error> {
    let value = Option::<String>::deserialize(d)?;
    match value {
        Some(p) if !MEM_PRESSURE_LEVELS.contains(&p.as_str()) => Err(serde::de::Error::custom(
            format!("mem_pressure {p:?} is not one of {}", MEM_PRESSURE_LEVELS.join(", ")),
        )),
        value => Ok(value),
    }
}

/// One host's readings, as `acpmux machine verdict` reads them on stdin. Every
/// field may be left out; an unknown field is an error, so a caller's typo
/// fails loudly instead of judging a host with a reading missing.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct ShadowInputs {
    pub host: String,
    /// The caller's clock, in ms since the epoch. The CLI fills it in when it
    /// is left out; the function treats none as a reading of unknown age.
    pub now_ms: Option<u64>,
    /// When the host took the sample (not when it was relayed), in ms.
    pub health_at_ms: Option<u64>,
    /// The cores the load is measured against (performance cores on Apple
    /// silicon, the CPUs this process may use on Linux).
    pub cores: Option<u32>,
    pub load1: Option<f64>,
    /// Linux `/proc/pressure/cpu` `some avg10`.
    pub psi_cpu_some_avg10: Option<f64>,
    /// `normal`, `warn`, `critical` or `unknown`; any other value is an error,
    /// so a misspelled `critical` never reads as a milder pressure.
    #[serde(deserialize_with = "known_pressure")]
    pub mem_pressure: Option<String>,
    /// Free plus compressible memory as a fraction of the total (Linux MemAvailable).
    pub available_fraction: Option<f64>,
    pub ram_total_bytes: Option<u64>,
    pub swap_used_bytes: Option<u64>,
    pub swap_total_bytes: Option<u64>,
    pub swap_growth_mb_per_min: Option<f64>,
    /// The sessions with a running harness on the host.
    pub sessions: Vec<SessionLoad>,
    /// The new session's cost; [`NEW_SESSION_PRIOR`] when left out.
    pub new_session: Option<SessionCost>,
    /// The `next` of this host's last verdict.
    pub previous: Option<ShadowState>,
}

/// One running session: `active` is a turn or a background process in the
/// last 10 minutes; `cpu_cores` its recent CPU (EWMA over 5 minutes).
#[derive(Debug, Clone, Copy, Default, PartialEq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct SessionLoad {
    pub active: bool,
    pub cpu_cores: f64,
    pub rss_bytes: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SessionCost {
    pub cpu_cores: f64,
    pub rss_bytes: u64,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SignalState {
    Ok,
    Pressured,
    Saturated,
    #[default]
    Unknown,
}

/// One signal's state and the streak that moves it.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Track {
    pub state: SignalState,
    /// Hot samples in a row, outside `saturated`.
    pub hot: u32,
    /// Calm samples in a row, inside `saturated`.
    pub calm: u32,
}

/// What a caller keeps per host between two verdicts and passes back as `previous`.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct ShadowState {
    /// The sample the states last moved on.
    pub sample_at_ms: Option<u64>,
    pub cpu: Track,
    pub mem: Track,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct CpuView {
    pub state: SignalState,
    pub load_per_core: Option<f64>,
    pub psi_some_avg10: Option<f64>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct MemView {
    pub state: SignalState,
    pub pressure: Option<String>,
    pub available_fraction: Option<f64>,
    pub swap_used_fraction: Option<f64>,
    pub swap_growth_mb_per_min: Option<f64>,
}

/// What the host's running sessions cost (module docs).
#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
pub struct Cost {
    pub active_sessions: u32,
    pub idle_sessions: u32,
    pub cpu_cores: f64,
    pub rss_bytes: u64,
}

/// Whether the new session fits under each enter line; `None` without the reading.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct Fits {
    pub cpu: Option<bool>,
    pub mem: Option<bool>,
}

/// The verdict `acpmux machine verdict` prints and the shadow log carries.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct ShadowVerdict {
    pub formula_version: &'static str,
    pub host: String,
    pub would_defer: bool,
    /// `unknown:stale`, `saturated:mem`, `saturated:cpu` or `ok`.
    pub reason: &'static str,
    pub cpu: CpuView,
    pub mem: MemView,
    /// `None` when the reading or the caller's clock is missing.
    pub health_age_s: Option<u64>,
    pub cost: Cost,
    pub fits: Fits,
    /// Pass back as the next call's `previous` for this host.
    pub next: ShadowState,
    /// `fnv1a64:` and 16 hex digits over the inputs without `now_ms`.
    pub inputs_digest: String,
    /// `fnv1a64:` and 16 hex digits over only the readings that decide the
    /// verdict: no clock, no sample time, no `previous` (`pressure_digest.rs`).
    pub pressure_digest: String,
    /// The host up to its first dot, lowercased (`host_short`).
    pub host_short: String,
}

/// How one sample reads for one signal (module docs).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Class {
    Unknown,
    Calm,
    Warm,
    Hot,
    Severe,
}

/// The shadow verdict for one host's readings (module docs).
pub fn shadow_verdict(inputs: &ShadowInputs) -> ShadowVerdict {
    let previous = inputs.previous.unwrap_or_default();
    let health_age_ms = match (inputs.now_ms, inputs.health_at_ms) {
        (Some(now), Some(at)) => Some(now.saturating_sub(at)),
        _ => None,
    };
    let stale = health_age_ms.is_none_or(|age| age > MAX_HEALTH_AGE_MS);

    let load_per_core = match (inputs.load1, inputs.cores.filter(|c| *c > 0)) {
        (Some(load), Some(cores)) if load.is_finite() => Some(load / f64::from(cores)),
        _ => None,
    };
    let swap_used_fraction = match (inputs.swap_used_bytes, inputs.swap_total_bytes) {
        (Some(used), Some(total)) if total > 0 => {
            Some((used as f64 / total as f64).clamp(0.0, 1.0))
        }
        _ => None,
    };

    let next = if stale {
        previous
    } else if let (Some(last), Some(at)) = (previous.sample_at_ms, inputs.health_at_ms)
        && at < last.saturating_add(MIN_SAMPLE_GAP_MS)
    {
        previous
    } else {
        ShadowState {
            sample_at_ms: inputs.health_at_ms,
            cpu: step(previous.cpu, cpu_class(load_per_core, inputs.psi_cpu_some_avg10)),
            mem: step(
                previous.mem,
                mem_class(
                    inputs.mem_pressure.as_deref(),
                    inputs.available_fraction,
                    swap_used_fraction,
                    inputs.swap_growth_mb_per_min,
                ),
            ),
        }
    };

    let reason = if stale {
        "unknown:stale"
    } else if next.mem.state == SignalState::Saturated {
        "saturated:mem"
    } else if next.cpu.state == SignalState::Saturated {
        "saturated:cpu"
    } else {
        "ok"
    };

    let cost = session_cost(&inputs.sessions);
    let new = inputs.new_session.unwrap_or(NEW_SESSION_PRIOR);
    let fits = Fits {
        cpu: match (inputs.load1, inputs.cores.filter(|c| *c > 0)) {
            (Some(load), Some(cores)) => {
                Some(f64::from(cores) * CPU_HOT_LOAD_PER_CORE - load >= new.cpu_cores)
            }
            _ => None,
        },
        mem: match (inputs.available_fraction, inputs.ram_total_bytes) {
            (Some(avail), Some(total)) => {
                Some((avail - MEM_LOW_AVAILABLE) * total as f64 >= new.rss_bytes as f64)
            }
            _ => None,
        },
    };

    ShadowVerdict {
        formula_version: SHADOW_FORMULA_VERSION,
        host: inputs.host.clone(),
        would_defer: reason != "ok",
        reason,
        cpu: CpuView {
            state: next.cpu.state,
            load_per_core: load_per_core.map(|l| round(l, 1000.0)),
            psi_some_avg10: inputs.psi_cpu_some_avg10,
        },
        mem: MemView {
            state: next.mem.state,
            pressure: inputs.mem_pressure.clone(),
            available_fraction: inputs.available_fraction,
            swap_used_fraction: swap_used_fraction.map(|s| round(s, 1000.0)),
            swap_growth_mb_per_min: inputs.swap_growth_mb_per_min,
        },
        health_age_s: health_age_ms.map(|ms| ms / 1000),
        cost,
        fits,
        next,
        inputs_digest: inputs_digest(inputs),
        pressure_digest: crate::pressure_digest(inputs),
        host_short: crate::host_short(&inputs.host),
    }
}

fn cpu_class(load_per_core: Option<f64>, psi: Option<f64>) -> Class {
    let psi = psi.filter(|p| p.is_finite());
    if load_per_core.is_none() && psi.is_none() {
        return Class::Unknown;
    }
    if load_per_core.is_some_and(|l| l >= CPU_HOT_LOAD_PER_CORE)
        || psi.is_some_and(|p| p >= CPU_HOT_PSI)
    {
        return Class::Hot;
    }
    let load_calm = load_per_core.is_none_or(|l| l <= CPU_CALM_LOAD_PER_CORE);
    let psi_calm = psi.is_none_or(|p| p <= CPU_CALM_PSI);
    if load_calm && psi_calm { Class::Calm } else { Class::Warm }
}

fn mem_class(
    pressure: Option<&str>,
    available: Option<f64>,
    swap_used: Option<f64>,
    growth: Option<f64>,
) -> Class {
    let pressure = pressure.filter(|p| *p != "unknown");
    let available = available.filter(|a| a.is_finite());
    let growing = growth.is_some_and(|g| g >= MEM_HOT_SWAP_GROWTH);
    if pressure.is_none() && available.is_none() {
        return if growing { Class::Hot } else { Class::Unknown };
    }
    if pressure == Some("critical") {
        return Class::Severe;
    }
    let short = |line: f64| available.is_some_and(|a| a < line);
    let low = short(MEM_CALM_AVAILABLE);
    if growing
        || short(MEM_LOW_AVAILABLE)
        || (swap_used.is_some_and(|s| s >= MEM_SWAP_FULL) && low)
        || (pressure == Some("warn") && low)
    {
        return Class::Hot;
    }
    let calm = pressure.is_none_or(|p| p == "normal")
        && growth.is_none_or(|g| g <= MEM_CALM_SWAP_GROWTH)
        && available.is_some_and(|a| a >= MEM_CALM_AVAILABLE);
    if calm { Class::Calm } else { Class::Warm }
}

/// One sample's move of one signal (module docs).
fn step(prev: Track, class: Class) -> Track {
    let saturated = prev.state == SignalState::Saturated;
    let at = |state| Track { state, hot: 0, calm: 0 };
    match class {
        Class::Severe => at(SignalState::Saturated),
        Class::Unknown if saturated => at(SignalState::Saturated),
        Class::Unknown => at(SignalState::Unknown),
        Class::Hot | Class::Warm if saturated => at(SignalState::Saturated),
        Class::Hot => {
            let hot = prev.hot.saturating_add(1);
            if hot >= ENTER_HOT_SAMPLES {
                at(SignalState::Saturated)
            } else {
                Track { state: SignalState::Pressured, hot, calm: 0 }
            }
        }
        Class::Warm => at(SignalState::Pressured),
        Class::Calm if saturated => {
            let calm = prev.calm.saturating_add(1);
            if calm >= LEAVE_CALM_SAMPLES {
                at(SignalState::Ok)
            } else {
                Track { state: SignalState::Saturated, hot: 0, calm }
            }
        }
        Class::Calm => at(SignalState::Ok),
    }
}

fn session_cost(sessions: &[SessionLoad]) -> Cost {
    let mut cost = Cost { active_sessions: 0, idle_sessions: 0, cpu_cores: 0.0, rss_bytes: 0 };
    for s in sessions {
        cost.rss_bytes = cost.rss_bytes.saturating_add(s.rss_bytes);
        if s.active {
            cost.active_sessions = cost.active_sessions.saturating_add(1);
            if s.cpu_cores.is_finite() && s.cpu_cores > 0.0 {
                cost.cpu_cores += s.cpu_cores;
            }
        } else {
            cost.idle_sessions = cost.idle_sessions.saturating_add(1);
        }
    }
    cost.cpu_cores = round(cost.cpu_cores, 1000.0);
    cost
}

/// FNV-1a (64-bit) over the inputs' canonical text ([`canonical_inputs`]): two
/// callers that judged the same sample with the same previous state log the
/// same digest, whatever language they are written in.
pub fn inputs_digest(inputs: &ShadowInputs) -> String {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for b in canonical_inputs(inputs).bytes() {
        hash ^= u64::from(b);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    format!("fnv1a64:{hash:016x}")
}

/// The inputs as the digest reads them: compact JSON without `now_ms`, object
/// keys sorted, null members and empty arrays left out, and every number
/// written with six decimals and its trailing zeros (and point) dropped, so
/// `205`, `205.0` and `205.0000001` all read `205` (`-0` reads `0`). Strings
/// are JSON strings with non-ASCII kept as is.
pub fn canonical_inputs(inputs: &ShadowInputs) -> String {
    let keyed = ShadowInputs { now_ms: None, ..inputs.clone() };
    let value = serde_json::to_value(&keyed).unwrap_or_default();
    let mut out = String::new();
    write_canonical(&value, &mut out);
    out
}

fn write_canonical(value: &serde_json::Value, out: &mut String) {
    use serde_json::Value;
    match value {
        Value::Null => out.push_str("null"),
        Value::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
        Value::Number(n) => out.push_str(&canonical_number(n)),
        Value::String(s) => out.push_str(&serde_json::to_string(s).unwrap_or_default()),
        Value::Array(items) => {
            out.push('[');
            for (i, item) in items.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                write_canonical(item, out);
            }
            out.push(']');
        }
        Value::Object(map) => {
            let mut keys: Vec<&String> = map
                .iter()
                .filter(|(_, v)| !v.is_null() && v.as_array().is_none_or(|a| !a.is_empty()))
                .map(|(k, _)| k)
                .collect();
            keys.sort();
            out.push('{');
            for (i, k) in keys.into_iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                out.push_str(&serde_json::to_string(k).unwrap_or_default());
                out.push(':');
                write_canonical(&map[k], out);
            }
            out.push('}');
        }
    }
}

fn canonical_number(n: &serde_json::Number) -> String {
    if let Some(i) = n.as_u64() {
        return i.to_string();
    }
    if let Some(i) = n.as_i64() {
        return i.to_string();
    }
    let text = format!("{:.6}", n.as_f64().unwrap_or(0.0));
    let text = text.trim_end_matches('0').trim_end_matches('.');
    if text == "-0" { "0".to_owned() } else { text.to_owned() }
}

fn round(n: f64, scale: f64) -> f64 {
    (n * scale).round() / scale
}

#[cfg(test)]
#[path = "shadow_tests.rs"]
mod tests;
