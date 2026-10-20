//! Decaying use counts per hit target: opens (Raycast / Alfred frecency,
//! 3-day half-life) and focus history (1-hour half-life), so a place the
//! user keeps going back to, or was just in, ranks first among equals.

use std::collections::HashMap;

/// How a [`Frecency`] decays and how many points it is worth.
#[derive(Clone, Copy, Debug)]
pub(crate) struct Decay {
    pub half_life_ms: f64,
    /// Points per unit of decayed count.
    pub points: f64,
    /// The most points a target gets.
    pub cap: f64,
}

/// Opens: half-life 3 days, 100 points each, at most 200 (design 7.3).
pub(crate) const OPENS: Decay =
    Decay { half_life_ms: 3.0 * 86_400_000.0, points: 100.0, cap: 200.0 };
/// Focus: half-life 1 hour, 75 points each, at most 150.
pub(crate) const FOCUS: Decay = Decay { half_life_ms: 3_600_000.0, points: 75.0, cap: 150.0 };

/// At most this many targets are kept; the weakest go first.
const MAX_TARGETS: usize = 4096;

#[derive(Clone, Debug, Default, serde::Serialize, serde::Deserialize)]
pub(crate) struct Frecency {
    /// Target -> (decayed count at `last_ms`, `last_ms`).
    entries: HashMap<String, (f64, i64)>,
}

impl Frecency {
    pub fn record(&mut self, target: &str, now_ms: i64, decay: Decay) {
        let value = self.value(target, now_ms, decay) + 1.0;
        self.entries.insert(target.to_owned(), (value, now_ms));
        if self.entries.len() > MAX_TARGETS {
            let mut values: Vec<(f64, String)> = self
                .entries
                .keys()
                .map(|key| (self.value(key, now_ms, decay), key.clone()))
                .collect();
            values.sort_by(|a, b| a.0.total_cmp(&b.0));
            for (_, key) in values.into_iter().take(self.entries.len() - MAX_TARGETS) {
                self.entries.remove(&key);
            }
        }
    }

    fn value(&self, target: &str, now_ms: i64, decay: Decay) -> f64 {
        self.entries.get(target).map_or(0.0, |&(value, last_ms)| {
            let age = (now_ms - last_ms).max(0) as f64;
            value * 0.5f64.powf(age / decay.half_life_ms)
        })
    }

    /// The score bonus of `target` now.
    pub fn bonus(&self, target: &str, now_ms: i64, decay: Decay) -> f64 {
        if self.entries.is_empty() {
            return 0.0;
        }
        (self.value(target, now_ms, decay) * decay.points).min(decay.cap)
    }
}
