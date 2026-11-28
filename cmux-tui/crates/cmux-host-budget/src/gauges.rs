//! Pressure gauges (cmuxterm-hq RFD 0182 B10): every pressure the host knows, in one shape, so one
//! GUI component draws them all and the person sees why work waits.
//!
//! RFD 0182 S1 makes PSI's `{some, full}` × `{avg10, avg60, avg300}` the shape of every pressure
//! signal: CPU, memory, tokens, cache and Mac slots. A [`Gauge`] is that signal as a gauge draws
//! it: a percent (0 = idle, 100 = at the limit; it may pass 100), a level, and one line of numbers.
//! [`gauges`] reads them from a verdict's JSON (acpmux's `daemon status` `host_pressure`, or the
//! app's own [`crate::json::local_verdict`]), each only where its reading is there:
//!
//! - `cpu`: the 1-minute load against the budget's limit (`load1 / load_limit`).
//! - `memory`: `mem_stall` (B1's PSI-shaped estimate) `some.avg10` where the daemon keeps one,
//!   else the share of RAM in use (`1 - available_ram_fraction`). The verdict's memory pressure
//!   word raises its level (macOS's `warn` or `critical` is the system's own judgment).
//! - `tokens`: `token_stall` (B3's gateway `tokenStall`, same shape) `some.avg10`.
//! - `cache`: `cache_faults` `{calls, misses}` (B6): the share of model calls that missed.
//! - `mac_slots`: `mac_slots` `{used, total}`: the share of the fleet's Mac test slots in use.
//!
//! The levels: a PSI-shaped `some.avg10` is `warn` from [`STALL_WARN`] and `critical` from
//! [`STALL_CRITICAL`], or `critical` when `full.avg10` reaches [`STALL_WARN`] (every task waits);
//! a share of a limit is `warn` from [`SHARE_WARN`] and `critical` from 100. Pure; no reads.

use serde::Serialize;
use serde_json::Value;

/// A PSI-shaped `some.avg10` (percent) at or above this is `warn`: AutoSize's line.
pub const STALL_WARN: f64 = 10.0;
/// A PSI-shaped `some.avg10` at or above this is `critical`.
pub const STALL_CRITICAL: f64 = 40.0;
/// A share of a limit (percent) at or above this is `warn`; 100 is `critical`.
pub const SHARE_WARN: f64 = 80.0;
/// A cache miss share at or above this is `warn` (the fleet's is 6.6%, RFD 0182 B6).
pub const MISS_WARN: f64 = 20.0;
/// A cache miss share at or above this is `critical`.
pub const MISS_CRITICAL: f64 = 50.0;

/// One gauge, in the order [`gauges`] gives them.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Gauge {
    /// `cpu`, `memory`, `tokens`, `cache` or `mac_slots`; the app names it.
    pub kind: &'static str,
    /// 0 idle, 100 at the limit (or all of the time stalled); a load past its limit passes 100.
    pub percent: f64,
    /// `normal`, `warn` or `critical`.
    pub level: &'static str,
    /// The numbers behind it, one line: `9.6 / 12 cores`, `stalled 12% of 10 s`.
    pub detail: String,
}

/// Every gauge `verdict` (a `host_pressure` object) has a reading for (module docs).
pub fn gauges(verdict: &Value) -> Vec<Gauge> {
    [cpu(verdict), memory(verdict), tokens(verdict), cache(verdict), mac_slots(verdict)]
        .into_iter()
        .flatten()
        .collect()
}

/// `verdict` with its `gauges` set (a `host_pressure` object; anything else is left alone).
pub fn with_gauges(verdict: &mut Value) {
    let list = gauges(verdict);
    if let Some(obj) = verdict.as_object_mut() {
        obj.insert("gauges".into(), serde_json::to_value(list).unwrap_or(Value::Null));
    }
}

fn num(v: &Value, key: &str) -> Option<f64> {
    v.get(key)?.as_f64().filter(|n| n.is_finite())
}

fn round1(v: f64) -> f64 {
    (v * 10.0).round() / 10.0
}

fn share_level(percent: f64, warn: f64, critical: f64) -> &'static str {
    if percent >= critical {
        "critical"
    } else if percent >= warn {
        "warn"
    } else {
        "normal"
    }
}

fn worse(a: &'static str, b: &'static str) -> &'static str {
    let rank = |l: &str| match l {
        "critical" => 2,
        "warn" => 1,
        _ => 0,
    };
    if rank(b) > rank(a) { b } else { a }
}

/// A PSI-shaped `{some, full}` object's gauge: `some.avg10`, raised by `full.avg10`.
fn stall(kind: &'static str, v: &Value) -> Option<Gauge> {
    let some = num(v.get("some")?, "avg10")?.clamp(0.0, 100.0);
    let full = v.get("full").and_then(|f| num(f, "avg10")).unwrap_or(0.0);
    let mut level = share_level(some, STALL_WARN, STALL_CRITICAL);
    if full >= STALL_WARN {
        level = "critical";
    }
    let detail = format!("stalled {}% of 10 s", round1(some));
    Some(Gauge { kind, percent: round1(some), level, detail })
}

fn cpu(v: &Value) -> Option<Gauge> {
    let load = num(v, "load1")?;
    let limit = num(v, "load_limit").filter(|l| *l > 0.0)?;
    let percent = round1((load / limit * 100.0).max(0.0));
    let cores = if v.get("cores_kind").and_then(Value::as_str) == Some("performance") {
        "P-cores"
    } else {
        "cores"
    };
    Some(Gauge {
        kind: "cpu",
        percent,
        level: share_level(percent, SHARE_WARN, 100.0),
        detail: format!("load {} / {} {cores}", round1(load), round1(limit)),
    })
}

fn memory(v: &Value) -> Option<Gauge> {
    let word = match v.get("pressure").and_then(Value::as_str) {
        Some("critical") => "critical",
        Some("warn") => "warn",
        _ => "normal",
    };
    if let Some(mut g) = v.get("mem_stall").and_then(|s| stall("memory", s)) {
        g.level = worse(g.level, word);
        return Some(g);
    }
    let available = num(v, "available_ram_fraction")?.clamp(0.0, 1.0);
    let percent = round1((1.0 - available) * 100.0);
    Some(Gauge {
        kind: "memory",
        percent,
        // RAM in use is not pressure by itself (the page cache fills it); only the system's word,
        // or almost none left, raises it.
        level: worse(word, share_level(percent, 95.0, 101.0)),
        detail: format!("{}% in use", round1(percent)),
    })
}

fn tokens(v: &Value) -> Option<Gauge> {
    stall("tokens", v.get("token_stall")?)
}

fn cache(v: &Value) -> Option<Gauge> {
    let c = v.get("cache_faults")?;
    let calls = c.get("calls")?.as_u64().filter(|n| *n > 0)?;
    let misses = c.get("misses")?.as_u64()?.min(calls);
    let percent = round1(misses as f64 / calls as f64 * 100.0);
    Some(Gauge {
        kind: "cache",
        percent,
        level: share_level(percent, MISS_WARN, MISS_CRITICAL),
        detail: format!("{misses} of {calls} calls missed"),
    })
}

fn mac_slots(v: &Value) -> Option<Gauge> {
    let m = v.get("mac_slots")?;
    let total = m.get("total")?.as_u64().filter(|n| *n > 0)?;
    let used = m.get("used")?.as_u64()?;
    let percent = round1(used as f64 / total as f64 * 100.0);
    Some(Gauge {
        kind: "mac_slots",
        percent,
        level: share_level(percent, SHARE_WARN, 100.0),
        detail: format!("{used} of {total} in use"),
    })
}

#[cfg(test)]
#[path = "gauges_tests.rs"]
mod tests;
