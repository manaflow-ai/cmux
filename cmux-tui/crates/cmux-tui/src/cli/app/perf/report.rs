//! The `cmux perf profile` report: a flat list of metrics, each with its unit, which way is
//! better, its budget against a 120 Hz frame and the source it came from, plus the sources
//! themselves (whether each answered, and whether it exists in a Release build).

use std::collections::BTreeMap;
use std::fmt::Write as _;

use serde::{Deserialize, Serialize};
use serde_json::Value;

pub(super) const SCHEMA: &str = "cmux.perf.report/1";
/// One frame at 120 Hz.
pub(super) const FRAME_BUDGET_MS: f64 = 1000.0 / 120.0;
/// Input to the next frame at 60 Hz: the most an interaction may take and still feel instant.
pub(super) const RESPONSE_BUDGET_MS: f64 = 1000.0 / 60.0;
/// A main-thread stall the probe counts: six 120 Hz frames.
pub(super) const STALL_MS: f64 = 50.0;
/// Web layout shift (CLS) the page may have and still be stable.
pub(super) const LAYOUT_SHIFT_BUDGET: f64 = 0.1;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub(super) enum Better {
    Lower,
    Higher,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub(super) struct Metric {
    /// Stable key, compared across reports (`frames.p95_ms`).
    pub key: String,
    /// Table section: frames, stalls, layout, responsiveness, host.
    pub group: String,
    pub label: String,
    pub unit: String,
    /// `None`: not measured (its source says why).
    pub value: Option<f64>,
    pub better: Better,
    pub budget: Option<f64>,
    /// A key of [`Report::sources`].
    pub source: String,
    /// How many samples a percentile came from; under [`super::stats::LOW_N`] it is low-n.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub samples: Option<usize>,
}

impl Metric {
    pub fn new(key: &str, group: &str, label: &str, unit: &str, source: &str) -> Self {
        Self {
            key: key.into(),
            group: group.into(),
            label: label.into(),
            unit: unit.into(),
            value: None,
            better: Better::Lower,
            budget: None,
            source: source.into(),
            samples: None,
        }
    }

    /// The percentile came from this many samples.
    pub fn samples(mut self, samples: Option<usize>) -> Self {
        self.samples = samples;
        self
    }

    /// Too few samples for the percentile to say much (see [`super::stats::LOW_N`]).
    pub fn low_n(&self) -> bool {
        self.samples.is_some_and(super::stats::low_n)
    }

    pub fn value(mut self, value: Option<f64>) -> Self {
        self.value =
            value.filter(|value| value.is_finite()).map(|value| super::stats::round(value, 3));
        self
    }

    pub fn budget(mut self, budget: f64) -> Self {
        self.budget = Some(budget);
        self
    }

    pub fn higher_is_better(mut self) -> Self {
        self.better = Better::Higher;
        self
    }

    /// Whether `value` meets the budget (`None` without one or without a value).
    pub fn within(&self, value: Option<f64>) -> Option<bool> {
        within(self.better, self.budget, value)
    }
}

pub(super) fn within(better: Better, budget: Option<f64>, value: Option<f64>) -> Option<bool> {
    let (budget, value) = (budget?, value?);
    Some(match better {
        Better::Lower => value <= budget,
        Better::Higher => value >= budget,
    })
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(super) struct Source {
    /// It answered in this run.
    pub available: bool,
    /// It exists in a Release (and NIGHTLY) build.
    pub release: bool,
    pub note: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub(super) struct Report {
    pub schema: String,
    pub label: Option<String>,
    pub created_unix: u64,
    pub seconds: u64,
    /// `system.identify`'s pid, version, build, bundle id and socket (no method list).
    pub app: Value,
    pub sources: BTreeMap<String, Source>,
    pub metrics: Vec<Metric>,
    /// The raw readings behind the metrics (stall records, switch lists, counters).
    pub details: Value,
    pub notes: Vec<String>,
}

impl Report {
    pub fn metric(&self, key: &str) -> Option<&Metric> {
        self.metrics.iter().find(|metric| metric.key == key)
    }
}

/// A number for the table: up to two decimals, no trailing zeros.
pub(super) fn show(value: Option<f64>) -> String {
    match value {
        None => "-".into(),
        Some(value) if value.fract() == 0.0 && value.abs() < 1e15 => format!("{value:.0}"),
        Some(value) => {
            let text = format!("{value:.2}");
            text.trim_end_matches('0').trim_end_matches('.').to_owned()
        }
    }
}

fn pad(text: &str, width: usize) -> String {
    let len = text.chars().count();
    if len >= width { text.to_owned() } else { format!("{text}{}", " ".repeat(width - len)) }
}

/// The report as the table `cmux perf profile` prints.
pub(super) fn human(report: &Report) -> String {
    let messages = &crate::localization::catalog().app_control.perf;
    let mut out = String::new();
    let app = &report.app;
    let _ = writeln!(
        out,
        "{}",
        super::fill(
            messages.profile_header,
            &[
                ("label", report.label.clone().unwrap_or_else(|| "-".into())),
                ("seconds", report.seconds.to_string()),
                ("bundle", app["bundle_id"].as_str().unwrap_or("?").to_owned()),
                ("version", app["version"].as_str().unwrap_or("?").to_owned()),
                ("pid", app["pid"].to_string()),
            ],
        )
    );
    let mut group = "";
    let width =
        report.metrics.iter().map(|metric| metric.label.chars().count()).max().unwrap_or(10);
    for metric in &report.metrics {
        if metric.group != group {
            group = &metric.group;
            let _ = writeln!(out, "\n{group}");
        }
        let value = match metric.value {
            None => "-".into(),
            Some(_) => format!("{} {}", show(metric.value), metric.unit),
        };
        let budget = match metric.budget {
            None => String::new(),
            Some(budget) => {
                let sign = if metric.better == Better::Lower { "<=" } else { ">=" };
                format!("{sign} {} {}", show(Some(budget)), metric.unit)
            }
        };
        let low_n;
        let status = match metric.within(metric.value) {
            _ if metric.low_n() && metric.value.is_some() => {
                low_n = super::fill(
                    messages.status_low_n,
                    &[("n", metric.samples.unwrap_or(0).to_string())],
                );
                low_n.as_str()
            }
            Some(true) => messages.status_ok,
            Some(false) => messages.status_over,
            None => "",
        };
        let release = report.sources.get(&metric.source).is_some_and(|source| source.release);
        let source = format!("{}{}", metric.source, if release { "" } else { " (Debug)" });
        let _ = writeln!(
            out,
            "  {} {} {} {} {}",
            pad(&metric.label, width),
            pad(&value, 14),
            pad(&budget, 16),
            pad(status, 9),
            source
        );
    }
    let missing: Vec<_> = report.sources.iter().filter(|(_, source)| !source.available).collect();
    if !missing.is_empty() {
        let _ = writeln!(out, "\n{}", messages.unmeasured_header);
        for (name, source) in missing {
            let _ = writeln!(out, "  {name}: {}", source.note);
        }
    }
    for note in &report.notes {
        let _ = writeln!(out, "\n{note}");
    }
    out
}
