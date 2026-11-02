//! The JSON calls of the macOS app's C ABI (`ffi.rs`, header
//! `include/cmux_host_budget_ffi.h`). Each takes and returns the verdict as
//! the JSON acpmux's `daemon status` reports in `host_pressure`, so the app
//! handles a daemon's verdict and its own the same way. None of them panics on
//! any input; a bad input gives `None`.

use crate::{
    Budget, Level, Meter, Reading, Sample, Tracker, evaluate, level_for, pressure_word,
    with_pressure,
};
use serde::Deserialize;
use serde_json::Value;
use std::time::Instant;

/// This host's verdict now, from the process's one [`Meter`] (the app's own
/// when no daemon answers). Blocking: it reads the probe and the override file
/// unless the last verdict is fresh. `None` while another read is in flight.
pub fn local_verdict() -> Option<String> {
    let verdict = Meter::shared().sample_at(Instant::now())?;
    serde_json::to_string(&verdict).ok()
}

/// `verdict` judged again with memory pressure `level` as macOS numbers it
/// (`DISPATCH_MEMORYPRESSURE_*` and `kern.memorystatus_vm_pressure_level`:
/// 1 normal, 2 warn, 4 critical; any other is unknown). [`with_pressure`].
pub fn verdict_with_pressure(verdict: &str, level: u32) -> Option<String> {
    let verdict: Value = serde_json::from_str(verdict).ok()?;
    serde_json::to_string(&with_pressure(&verdict, pressure_word(level))?).ok()
}

/// What [`judge`] reads: a host, its numbers and the swap rate.
#[derive(Deserialize)]
struct Judged {
    host: String,
    sample: Sample,
    #[serde(default)]
    swap_mb_per_min: Option<f64>,
}

/// The verdict for given numbers with the built-in formula:
/// `{"host", "sample": {Sample's fields}, "swap_mb_per_min"}` (the app's Debug
/// Settings sample levels).
pub fn judge(input: &str) -> Option<String> {
    let input: Judged = serde_json::from_str(input).ok()?;
    let verdict = evaluate(&input.host, &input.sample, input.swap_mb_per_min, &Budget::default());
    serde_json::to_string(&verdict).ok()
}

/// The parts of a verdict's JSON the level reads; `None` when it is not one.
pub fn reading(verdict: &str) -> Option<Reading> {
    serde_json::from_str(verdict).ok()
}

/// [`level_for`] of a verdict's JSON.
pub fn level_of(verdict: &str, holding: Level) -> Option<Level> {
    Some(level_for(&reading(verdict)?, holding))
}

/// [`Tracker::feed`] with a verdict's JSON: `None` when it is not a verdict
/// (the tracker is unchanged), else the new level when it changed.
pub fn feed(tracker: &mut Tracker, verdict: &str) -> Option<Option<Level>> {
    Some(tracker.feed(&reading(verdict)?))
}

#[cfg(test)]
#[path = "json_tests.rs"]
mod tests;
