//! The disk budget: keep the home volume under [`TARGET`] used. Pure math
//! and one small file.
//!
//! - A sample (used bytes, total bytes, time) is recorded per pass and on a
//!   cheap tick into a bounded ring file in the store folder.
//! - The fill rate is a least-squares slope over the last day of samples,
//!   with the drops a cleanup made left out, so a cleanup does not read as
//!   a disk that stopped filling.
//! - The forecast is the hours until the disk crosses the budget and the
//!   critical share at that rate. A crossing of the budget within one pass
//!   spacing counts as pressure now: act before trouble.
//! - A pass under budget pressure keeps removing, largest first, until the
//!   projected usage is under the share where pressure starts
//!   ([`Projection`]), then stops.

use std::io::Write;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::policy::{Pressure, Settings};

const MINUTE_MS: u64 = 60 * 1000;
const HOUR_MS: u64 = 60 * MINUTE_MS;

/// The share of the volume the budget keeps free of use: under 75% used.
pub const TARGET: f64 = 0.75;
/// Samples kept: a week at one every five minutes.
pub const MAX_SAMPLES: usize = 2016;
/// The window the fill rate looks at.
pub const WINDOW_MS: u64 = 24 * HOUR_MS;
/// Fewer samples than this, or a span shorter than [`MIN_SPAN_MS`], give no rate.
const MIN_SAMPLES: usize = 3;
const MIN_SPAN_MS: u64 = 30 * MINUTE_MS;
const FILE: &str = "disk-samples.jsonl";

/// One reading of the volume.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Sample {
    pub at_ms: u64,
    pub used: u64,
    pub total: u64,
}

impl Sample {
    pub fn fraction(&self) -> f64 {
        if self.total == 0 { 0.0 } else { self.used as f64 / self.total as f64 }
    }
}

/// The ring file of samples in the store folder.
#[derive(Debug, Clone)]
pub struct Samples {
    path: PathBuf,
}

impl Samples {
    pub fn in_dir(dir: &Path) -> Self {
        Self { path: dir.join(FILE) }
    }

    /// Every sample on file, oldest first. A line that does not parse is skipped.
    pub fn load(&self) -> Vec<Sample> {
        let Ok(text) = std::fs::read_to_string(&self.path) else { return Vec::new() };
        let mut samples: Vec<Sample> =
            text.lines().filter_map(|line| serde_json::from_str(line).ok()).collect();
        samples.sort_by_key(|s| s.at_ms);
        samples
    }

    /// Appends `sample`; past twice [`MAX_SAMPLES`] lines the file is
    /// rewritten with the newest [`MAX_SAMPLES`]. A sample less than a
    /// minute after the last is not kept (a tick and a pass together).
    pub fn record(&self, sample: Sample) -> Result<(), String> {
        let mut samples = self.load();
        if samples.last().is_some_and(|last| sample.at_ms.saturating_sub(last.at_ms) < MINUTE_MS)
            && samples.last().is_some_and(|last| last.at_ms <= sample.at_ms)
        {
            return Ok(());
        }
        if samples.len() >= 2 * MAX_SAMPLES {
            samples.push(sample);
            let keep = samples.len().saturating_sub(MAX_SAMPLES);
            let text: String = samples
                .iter()
                .skip(keep)
                .filter_map(|s| serde_json::to_string(s).ok())
                .map(|line| line + "\n")
                .collect();
            let temporary = self.path.with_extension("tmp");
            std::fs::write(&temporary, text)
                .map_err(|e| format!("{}: {e}", temporary.display()))?;
            return std::fs::rename(&temporary, &self.path)
                .map_err(|e| format!("{}: {e}", self.path.display()));
        }
        let line = serde_json::to_string(&sample).map_err(|e| e.to_string())?;
        let mut file = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.path)
            .map_err(|e| format!("{}: {e}", self.path.display()))?;
        writeln!(file, "{line}").map_err(|e| format!("{}: {e}", self.path.display()))
    }
}

/// How fast the volume fills, and when it crosses the lines.
#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Forecast {
    /// Bytes per hour; `None` without enough samples. Never negative.
    pub fill_bytes_per_hour: Option<f64>,
    /// Hours until the budget share is used (0 when it already is); `None`
    /// when the disk is not filling.
    pub hours_to_target: Option<f64>,
    /// Hours until 90% is used.
    pub hours_to_critical: Option<f64>,
    pub samples: usize,
}

/// Bytes per hour the volume fills, from the samples in the last
/// [`WINDOW_MS`] before `now_ms`. The series is rebuilt from its rises only
/// (a drop is a cleanup, not a disk that emptied), then a least-squares
/// line is fitted through it. `None` for fewer than 3 samples or under 30
/// minutes of them.
pub fn fill_rate(samples: &[Sample], now_ms: u64) -> Option<f64> {
    let start = now_ms.saturating_sub(WINDOW_MS);
    let window: Vec<&Sample> =
        samples.iter().filter(|s| s.at_ms >= start && s.at_ms <= now_ms).collect();
    let (first, last) = (window.first()?, window.last()?);
    if window.len() < MIN_SAMPLES || last.at_ms.saturating_sub(first.at_ms) < MIN_SPAN_MS {
        return None;
    }
    // Hours since the first sample, and the running sum of rises in bytes.
    let mut points = Vec::with_capacity(window.len());
    let mut cumulative = 0.0f64;
    let mut previous = first.used;
    for sample in &window {
        cumulative += sample.used.saturating_sub(previous) as f64;
        previous = sample.used;
        points.push(((sample.at_ms - first.at_ms) as f64 / HOUR_MS as f64, cumulative));
    }
    let n = points.len() as f64;
    let mean_x = points.iter().map(|p| p.0).sum::<f64>() / n;
    let mean_y = points.iter().map(|p| p.1).sum::<f64>() / n;
    let variance: f64 = points.iter().map(|p| (p.0 - mean_x).powi(2)).sum();
    if variance <= f64::EPSILON {
        return None;
    }
    let covariance: f64 = points.iter().map(|p| (p.0 - mean_x) * (p.1 - mean_y)).sum();
    Some((covariance / variance).max(0.0))
}

/// Hours until `fraction` of `total` is used, given `used` now and a fill
/// rate: 0 when already there, `None` when the disk is not filling.
pub fn hours_until(fraction: f64, used: u64, total: u64, rate: Option<f64>) -> Option<f64> {
    let line = fraction * total as f64;
    if used as f64 >= line {
        return Some(0.0);
    }
    let rate = rate.filter(|rate| *rate > 0.0)?;
    Some((line - used as f64) / rate)
}

/// The forecast at `now`: the newest sample stands for the volume now.
pub fn forecast(samples: &[Sample], now_ms: u64, used: u64, total: u64) -> Forecast {
    let rate = fill_rate(samples, now_ms);
    Forecast {
        fill_bytes_per_hour: rate,
        hours_to_target: hours_until(TARGET, used, total, rate),
        hours_to_critical: hours_until(0.90, used, total, rate),
        samples: samples.len(),
    }
}

/// The least time between two automatic passes at `used_fraction`: 6 hours
/// under 70%, 30 minutes from 70%, 10 minutes from 80%, 3 minutes from 90%.
pub fn spacing_ms(used_fraction: f64) -> u64 {
    if used_fraction >= 0.90 {
        3 * MINUTE_MS
    } else if used_fraction >= 0.80 {
        10 * MINUTE_MS
    } else if used_fraction >= 0.70 {
        30 * MINUTE_MS
    } else {
        6 * HOUR_MS
    }
}

/// What the numbers say about the next pass.
#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Plan {
    pub used_fraction: f64,
    /// The pressure the ages are taken at: the disk's, raised to at least
    /// `High` by a predicted crossing of the budget.
    pub pressure: Pressure,
    pub spacing_ms: u64,
    /// The volume is at or over the budget.
    pub over_budget: bool,
    /// It is not yet, but the forecast crosses it within `spacing_ms`.
    pub predicted: bool,
}

impl Plan {
    /// A pass removes until the projection is under budget (and then stops).
    pub fn budget_pressure(&self) -> bool {
        self.over_budget || self.predicted || self.pressure != Pressure::Normal
    }
}

/// The plan for a volume `used_fraction` full with `forecast`.
pub fn plan(settings: &Settings, used_fraction: f64, forecast: &Forecast) -> Plan {
    let spacing = spacing_ms(used_fraction);
    let over_budget = used_fraction >= TARGET;
    let predicted = !over_budget
        && forecast.hours_to_target.is_some_and(|hours| hours * (HOUR_MS as f64) <= spacing as f64);
    let mut pressure = settings.pressure(used_fraction);
    if predicted && pressure == Pressure::Normal {
        pressure = Pressure::High;
    }
    // Acting early shortens the wait for the next look too.
    let spacing = if predicted { spacing.min(spacing_ms(settings.high)) } else { spacing };
    Plan { used_fraction, pressure, spacing_ms: spacing, over_budget, predicted }
}

/// The running total of a pass under budget pressure: how much it has
/// freed, and whether the projected usage is already under the line.
#[derive(Debug, Clone, Copy)]
pub struct Projection {
    pub used: u64,
    pub total: u64,
    /// Stop when the projected share is under this (where pressure starts).
    pub stop_below: f64,
    pub freed: u64,
}

impl Projection {
    pub fn new(used: u64, total: u64, stop_below: f64) -> Self {
        Self { used, total, stop_below, freed: 0 }
    }

    pub fn add(&mut self, freed: u64) {
        self.freed = self.freed.saturating_add(freed);
    }

    /// The projected used share after what was freed.
    pub fn fraction(&self) -> f64 {
        if self.total == 0 {
            return 0.0;
        }
        self.used.saturating_sub(self.freed) as f64 / self.total as f64
    }

    pub fn done(&self) -> bool {
        self.fraction() < self.stop_below
    }
}

#[cfg(test)]
#[path = "budget_tests.rs"]
mod tests;
