//! Sample collections and percentile summaries.

use serde::Serialize;

#[derive(Debug, Clone, Serialize)]
pub struct Summary {
    pub n: usize,
    pub p50: f64,
    pub p95: f64,
    pub p99: f64,
    pub min: f64,
    pub max: f64,
    pub mean: f64,
}

/// Nearest-rank percentile over a sorted slice.
fn rank(sorted: &[f64], q: f64) -> f64 {
    let idx = ((q * sorted.len() as f64).ceil() as usize).clamp(1, sorted.len()) - 1;
    sorted[idx]
}

pub fn summarize(v: &[f64]) -> Option<Summary> {
    if v.is_empty() {
        return None;
    }
    let mut s = v.to_vec();
    s.sort_by(|a, b| a.total_cmp(b));
    let r = |x: f64| (x * 1000.0).round() / 1000.0;
    Some(Summary {
        n: s.len(),
        p50: r(rank(&s, 0.50)),
        p95: r(rank(&s, 0.95)),
        p99: r(rank(&s, 0.99)),
        min: r(s[0]),
        max: r(s[s.len() - 1]),
        mean: r(s.iter().sum::<f64>() / s.len() as f64),
    })
}

pub fn p50(v: &[f64]) -> Option<f64> {
    summarize(v).map(|s| s.p50)
}

/// Per-stage host timings in milliseconds.
#[derive(Default, Clone)]
pub struct StageSamples {
    pub capture: Vec<f64>,
    pub convert: Vec<f64>,
    pub encode: Vec<f64>,
    pub damage_to_capture: Vec<f64>,
    pub damage_to_send: Vec<f64>,
    pub encode_to_sent: Vec<f64>,
    pub inject_to_damage: Vec<f64>,
    pub capture_px: Vec<f64>,
    pub frames: u64,
    pub keyframes: u64,
    pub bytes: u64,
}

impl StageSamples {
    pub fn take(&mut self) -> Self {
        std::mem::take(self)
    }

    pub fn summary_json(&self) -> serde_json::Value {
        serde_json::json!({
            "frames": self.frames,
            "keyframes": self.keyframes,
            "bytes": self.bytes,
            "capture_ms": summarize(&self.capture),
            "capture_megapixels": summarize(&self.capture_px),
            "convert_ms": summarize(&self.convert),
            "encode_ms": summarize(&self.encode),
            "damage_to_capture_ms": summarize(&self.damage_to_capture),
            "encode_to_sent_ms": summarize(&self.encode_to_sent),
            "damage_to_send_ms": summarize(&self.damage_to_send),
            "inject_to_damage_ms": summarize(&self.inject_to_damage),
        })
    }
}
