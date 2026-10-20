//! Opens per hit target, decaying with a 3-day half-life (Raycast / Alfred
//! style), so a place the user keeps going back to ranks first among equals.

use std::collections::HashMap;

const HALF_LIFE_MS: f64 = 3.0 * 86_400_000.0;
/// Points per unit of decayed opens, and the cap (design 7.3).
const POINTS: f64 = 100.0;
const CAP: f64 = 300.0;

#[derive(Clone, Debug, Default, serde::Serialize, serde::Deserialize)]
pub(crate) struct Frecency {
    /// Target -> (decayed opens at `last_ms`, `last_ms`).
    entries: HashMap<String, (f64, i64)>,
}

impl Frecency {
    pub fn record(&mut self, target: &str, now_ms: i64) {
        let value = self.value(target, now_ms) + 1.0;
        self.entries.insert(target.to_owned(), (value, now_ms));
    }

    fn value(&self, target: &str, now_ms: i64) -> f64 {
        self.entries.get(target).map_or(0.0, |&(value, last_ms)| {
            let age = (now_ms - last_ms).max(0) as f64;
            value * 0.5f64.powf(age / HALF_LIFE_MS)
        })
    }

    /// The score bonus of `target` now.
    pub fn bonus(&self, target: &str, now_ms: i64) -> f64 {
        if self.entries.is_empty() {
            return 0.0;
        }
        (self.value(target, now_ms) * POINTS).min(CAP)
    }
}
