//! The shape of a coordinator chat: the JSON `coord_shape_probe.py` prints (schema coord-shape.v1).
//!
//! Only counts and log2 histograms: bucket `b` holds values in `[2^(b-1), 2^b)`, bucket 0 holds 0.
//! The generator samples from these; no transcript content ever reaches this crate.

// Shared model of the coord-sim subcommands: each of gen, agent, drive, degen, fanin and report reads its own
// part (and the coord-shape.v1 schema fields stay whole), so one subcommand's build leaves the rest unread.
#![allow(dead_code)]

use crate::rng::Rng;
use serde::Deserialize;
use std::collections::BTreeMap;

#[derive(Debug, Clone, Default, Deserialize)]
pub struct Hist {
    #[serde(default)]
    pub n: u64,
    #[serde(default)]
    pub sum: u64,
    #[serde(default)]
    pub max: u64,
    #[serde(default)]
    pub log2: BTreeMap<String, u64>,
}

impl Hist {
    pub fn mean(&self) -> f64 {
        if self.n == 0 { 0.0 } else { self.sum as f64 / self.n as f64 }
    }

    /// One value drawn from the histogram: a bucket by its count, then uniform inside it, capped at `max`.
    pub fn sample(&self, rng: &mut Rng) -> u64 {
        let total: u64 = self.log2.values().sum();
        if total == 0 {
            return self.mean() as u64;
        }
        let mut pick = rng.below(total);
        for (b, c) in &self.log2 {
            if pick < *c {
                let b: u32 = b.parse().unwrap_or(0);
                if b == 0 {
                    return 0;
                }
                let lo = 1u64 << (b - 1);
                let hi = (1u64 << b.min(63)).max(lo + 1);
                let v = lo + rng.below(hi - lo);
                return if self.max > 0 { v.min(self.max) } else { v };
            }
            pick -= c;
        }
        self.max
    }
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct PerSession {
    #[serde(default)]
    pub events: Hist,
    #[serde(default)]
    pub bytes: Hist,
    #[serde(default)]
    pub duration_s: Hist,
    #[serde(default)]
    pub user_turns: Hist,
    #[serde(default)]
    pub tool_calls: Hist,
    #[serde(default)]
    pub subagent_events: Hist,
    #[serde(default)]
    pub compaction_events: Hist,
    #[serde(default)]
    pub peak_events_1s: Hist,
    #[serde(default)]
    pub peak_events_10s: Hist,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct Rates {
    #[serde(default)]
    pub p50: u64,
    #[serde(default)]
    pub p95: u64,
    #[serde(default)]
    pub p99: u64,
    #[serde(default)]
    pub p999: u64,
    #[serde(default)]
    pub max: u64,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct Acpmux {
    #[serde(default)]
    pub sessions: u64,
    #[serde(default)]
    pub per_session: PerSession,
    #[serde(default)]
    pub event_bytes: Hist,
    /// "dir:kind" (dir in/out/mux) -> size histogram; its `n` is the kind's count.
    #[serde(default)]
    pub kind_bytes: BTreeMap<String, Hist>,
    #[serde(default)]
    pub session_update_bytes: BTreeMap<String, Hist>,
    #[serde(default)]
    pub tool_call_kinds: BTreeMap<String, u64>,
    #[serde(default)]
    pub content_blocks: BTreeMap<String, u64>,
    #[serde(default)]
    pub gap_ms: Hist,
    #[serde(default)]
    pub burst_len_50ms: Hist,
    #[serde(default)]
    pub global_events_per_s: Rates,
    #[serde(default)]
    pub active_sessions_per_min: Rates,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct Shape {
    #[serde(default)]
    pub schema: String,
    #[serde(default)]
    pub acpmux: Acpmux,
    #[serde(default)]
    pub attachment_bytes: Hist,
}

/// The shape built in: Leo's coordinator sessions (his Mac, 2026-11-19, histograms only): 556 sessions, the largest
/// 6.1 GB / 4.55M events, one session at 9,063 events in a second, up to 105 sessions active in a minute.
/// "1x" in the driver means this shape's rates. `shapes/lane-host.json` is a GCP lane host's, for comparison.
pub const DEFAULT_SHAPE: &str = include_str!("../shapes/leo-peak.json");

impl Shape {
    pub fn parse(text: &str) -> Result<Shape, String> {
        let s: Shape = serde_json::from_str(text).map_err(|e| format!("shape: {e}"))?;
        if s.schema != "coord-shape.v1" {
            return Err(format!("shape: schema {:?}, want coord-shape.v1", s.schema));
        }
        Ok(s)
    }

    pub fn load(path: Option<&str>) -> Result<Shape, String> {
        match path {
            Some(p) => Shape::parse(&std::fs::read_to_string(p).map_err(|e| format!("{p}: {e}"))?),
            None => Shape::parse(DEFAULT_SHAPE),
        }
    }

    /// Event kinds with their weights (the count of each), the mix the generator draws from.
    pub fn kind_mix(&self) -> Vec<(String, u64)> {
        self.acpmux
            .kind_bytes
            .iter()
            .map(|(k, h)| (k.clone(), h.n))
            .filter(|(_, n)| *n > 0)
            .collect()
    }
}
