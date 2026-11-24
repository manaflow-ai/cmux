//! Shared report calculations for the live share latency harness and staging flow.
//!
//! The fake-room tests from cmux#52169 include this file directly, and the
//! staging CLI does the same. Keeping the calculations here makes both reports
//! use the same upper-median, nearest-rank p95, rounding, and strict bound.

/// Leo's one-second share bound, in milliseconds.
pub const BOUND_MS: f64 = 1_000.0;

/// The one-decimal display rounding used by the #52169 Duration report.
pub fn rounded_ms(value: f64) -> f64 {
    (value * 10.0).round() / 10.0
}

/// A latency summary. `within_1s` tests p95. `all_samples_within_1s` preserves
/// #52169's assertion that the maximum sample stays under the bound.
#[derive(Debug, Clone)]
pub struct Summary {
    pub n: usize,
    pub p50_ms: f64,
    pub p95_ms: f64,
    pub max_ms: f64,
    pub within_1s: bool,
    pub all_samples_within_1s: bool,
}

/// Summarize non-negative, finite millisecond samples.
///
/// p50 deliberately uses the harness's upper median (`sorted[n / 2]`). p95 is
/// nearest rank, `ceil(.95 * n)`, with one-based rank indexing. Bound checks use
/// raw values before display rounding.
pub fn summarize(samples: &[f64]) -> Result<Summary, String> {
    if samples.is_empty() {
        return Err(String::from("no samples received"));
    }
    if samples.iter().any(|value| !value.is_finite() || *value < 0.0) {
        return Err(String::from("samples must be finite and non-negative"));
    }
    let mut sorted = samples.to_vec();
    sorted.sort_by(f64::total_cmp);
    let p50_raw = sorted[sorted.len() / 2];
    let rank = (sorted.len() * 95).div_ceil(100);
    let p95_raw = sorted[rank - 1];
    let max_raw = sorted[sorted.len() - 1];
    Ok(Summary {
        n: samples.len(),
        p50_ms: rounded_ms(p50_raw),
        p95_ms: rounded_ms(p95_raw),
        max_ms: rounded_ms(max_raw),
        within_1s: p95_raw < BOUND_MS,
        all_samples_within_1s: max_raw < BOUND_MS,
    })
}
