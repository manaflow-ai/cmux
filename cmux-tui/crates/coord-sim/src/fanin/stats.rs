//! Exact percentiles of a ramp's samples (a ramp holds at most a few hundred thousand).

use serde_json::{Value, json};

/// `{n, p50, p95, p99, max}` of `samples` in ms, three decimals; `{n: 0}` when empty.
pub fn spread_ms(samples: &[f64]) -> Value {
    if samples.is_empty() {
        return json!({"n": 0});
    }
    let mut v = samples.to_vec();
    v.sort_by(f64::total_cmp);
    let q = |p: f64| {
        let i = ((v.len() as f64 - 1.0) * p).round() as usize;
        v.get(i.min(v.len() - 1)).copied().map_or(Value::Null, r3)
    };
    json!({"n": v.len(), "p50": q(0.5), "p95": q(0.95), "p99": q(0.99),
           "max": v.last().copied().map_or(Value::Null, r3)})
}

pub fn r3(x: f64) -> Value {
    json!((x * 1000.0).round() / 1000.0)
}

/// `a / b` rounded to three decimals, null when either is missing or `b` is 0.
pub fn ratio(a: Option<f64>, b: Option<f64>) -> Value {
    match (a, b) {
        (Some(a), Some(b)) if b > 0.0 => r3(a / b),
        _ => Value::Null,
    }
}

#[cfg(test)]
#[path = "stats_tests.rs"]
mod tests;
