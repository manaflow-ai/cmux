//! `pressure_digest`: a digest of only the readings that decide the shadow
//! verdict (cmuxterm-hq#7342), so two placers that read the same host the same
//! way log the same digest even though each keeps its own clock and hysteresis.
//!
//! `inputs_digest` covers the whole input, `health_at_ms` and `previous`
//! included, so it matches only when two callers judged one sample with one
//! previous state. The daemon and lane-place each keep their own state and
//! sample on their own clocks, so in the first 24 h no row pair shared it.
//! This digest leaves those out and keeps the pressure readings.
//!
//! The canonical text is one compact JSON object, keys sorted, with these
//! members, each left out when it is missing or cannot move the verdict:
//! - `host`: the short host name ([`host_short`]), always present.
//! - `cores`: when over 0 (the formula ignores 0).
//! - `load1`, `psi_cpu_some_avg10`, `available_fraction`,
//!   `swap_growth_mb_per_min`: when finite.
//! - `mem_pressure`: when present and not `unknown` (the formula reads
//!   `unknown` as no reading).
//! - `swap_used_fraction`: used / total, clamped to 0..=1, when the total is
//!   over 0. The formula reads swap only as this fraction, so a probe's bytes
//!   and the daemon's bytes digest alike when their fraction does.
//!
//! Rounding: every non-integer is written with exactly three decimals
//! (`{:.3}` here, `%.3f` in Python; both round the exact binary value half to
//! even), then its trailing zeros and point are dropped, and `-0` reads `0`.
//! Three decimals: load averages carry two, and the formula's lines sit at two
//! (`0.90`, `0.15`, `1.25`). Integers are written as integers, strings as JSON
//! strings with non-ASCII kept. Left out on purpose: `now_ms`,
//! `health_at_ms`, `previous`, `ram_total_bytes` (only `fits` reads it),
//! `sessions` and `new_session` (only the cost reads them).
//!
//! The hash is FNV-1a 64 over the text's UTF-8 bytes, written `fnv1a64:` and
//! 16 hex digits, as `inputs_digest` is. lane-place's
//! `shadow_admission.pressure_digest` is the same function;
//! `testdata/pressure-digest-v1.json` pins both to the same digests.

use crate::shadow::ShadowInputs;
use std::collections::BTreeMap;

/// A host name as both logs carry it: trimmed, up to its first dot, ASCII
/// letters lowercased, so a full DNS name and the short name read the same.
pub fn host_short(host: &str) -> String {
    let host = host.trim();
    host.split('.').next().unwrap_or_default().to_ascii_lowercase()
}

/// The canonical text [`pressure_digest`] hashes (module docs).
pub fn canonical_pressure(inputs: &ShadowInputs) -> String {
    let mut members: BTreeMap<&str, String> = BTreeMap::new();
    let string = |s: &str| serde_json::to_string(s).unwrap_or_default();
    members.insert("host", string(&host_short(&inputs.host)));
    if let Some(cores) = inputs.cores.filter(|c| *c > 0) {
        members.insert("cores", cores.to_string());
    }
    for (key, value) in [
        ("load1", inputs.load1),
        ("psi_cpu_some_avg10", inputs.psi_cpu_some_avg10),
        ("available_fraction", inputs.available_fraction),
        ("swap_growth_mb_per_min", inputs.swap_growth_mb_per_min),
    ] {
        if let Some(v) = value.filter(|v| v.is_finite()) {
            members.insert(key, three_decimals(v));
        }
    }
    if let Some(p) = inputs.mem_pressure.as_deref().filter(|p| *p != "unknown") {
        members.insert("mem_pressure", string(p));
    }
    if let (Some(used), Some(total)) = (inputs.swap_used_bytes, inputs.swap_total_bytes)
        && total > 0
    {
        let fraction = (used as f64 / total as f64).clamp(0.0, 1.0);
        members.insert("swap_used_fraction", three_decimals(fraction));
    }
    let body: Vec<String> = members.iter().map(|(k, v)| format!("{}:{v}", string(k))).collect();
    format!("{{{}}}", body.join(","))
}

/// FNV-1a 64 over [`canonical_pressure`] (module docs).
pub fn pressure_digest(inputs: &ShadowInputs) -> String {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for b in canonical_pressure(inputs).bytes() {
        hash ^= u64::from(b);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    format!("fnv1a64:{hash:016x}")
}

/// `{:.3}` with trailing zeros and point dropped; `-0` reads `0`.
fn three_decimals(v: f64) -> String {
    let text = format!("{v:.3}");
    let text = text.trim_end_matches('0').trim_end_matches('.');
    if text == "-0" { "0".to_owned() } else { text.to_owned() }
}

#[cfg(test)]
#[path = "pressure_digest_tests.rs"]
mod tests;
