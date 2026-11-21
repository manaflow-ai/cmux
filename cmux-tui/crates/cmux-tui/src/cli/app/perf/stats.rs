//! Percentiles and summaries over samples (milliseconds, percent, bytes).

/// Below this many samples a p95 is the top value or next to it: one outlier decides it. Such a
/// p95 is marked low-n and gets no budget verdict.
pub(super) const LOW_N: usize = 20;

/// `count` samples are too few for a p95.
pub(super) fn low_n(count: usize) -> bool {
    count < LOW_N
}

/// The nearest-rank percentile `p` (0 to 100) of `sorted` (ascending); `None` when empty.
pub(super) fn percentile(sorted: &[f64], p: f64) -> Option<f64> {
    if sorted.is_empty() {
        return None;
    }
    let rank = ((p / 100.0) * sorted.len() as f64).ceil() as usize;
    Some(sorted[rank.clamp(1, sorted.len()) - 1])
}

/// One series summarized against a budget (a value over `budget` misses it).
#[derive(Debug, Clone, Copy, PartialEq)]
pub(super) struct Summary {
    pub count: usize,
    pub p50: f64,
    pub p95: f64,
    pub p99: f64,
    pub max: f64,
    pub mean: f64,
    pub total: f64,
    /// How many values are over the budget.
    pub over: usize,
}

impl Summary {
    /// The share of values over the budget, in percent.
    pub fn over_pct(&self) -> f64 {
        if self.count == 0 { 0.0 } else { self.over as f64 * 100.0 / self.count as f64 }
    }
}

/// `values` summarized; `None` when there are none. Non-finite values are dropped.
pub(super) fn summarize(values: &[f64], budget: f64) -> Option<Summary> {
    let mut sorted: Vec<f64> = values.iter().copied().filter(|value| value.is_finite()).collect();
    if sorted.is_empty() {
        return None;
    }
    sorted.sort_by(f64::total_cmp);
    let total: f64 = sorted.iter().sum();
    Some(Summary {
        count: sorted.len(),
        p50: percentile(&sorted, 50.0)?,
        p95: percentile(&sorted, 95.0)?,
        p99: percentile(&sorted, 99.0)?,
        max: *sorted.last()?,
        mean: total / sorted.len() as f64,
        total,
        over: sorted.iter().filter(|value| **value > budget).count(),
    })
}

/// `value` rounded to `places` decimals (reports stay readable and diffable).
pub(super) fn round(value: f64, places: i32) -> f64 {
    let scale = 10f64.powi(places);
    (value * scale).round() / scale
}
