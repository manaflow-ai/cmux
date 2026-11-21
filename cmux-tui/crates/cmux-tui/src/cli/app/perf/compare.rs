//! `cmux perf compare BEFORE.json AFTER.json`: every metric of two reports side by side, the
//! change, and a verdict against its budget (fixed, broke, within, over) or, without a budget,
//! its trend (better, worse, same). A change under 5% (or under a hundredth) is noise.

use std::fmt::Write as _;
use std::path::Path;

use serde::Serialize;
use serde_json::json;

use super::super::super::OutputMode;
use super::super::GlobalArgs;
use super::report::{self, Better, Metric, Report};

/// A relative change smaller than this is noise.
pub(super) const NOISE: f64 = 0.05;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub(super) enum Trend {
    Better,
    Worse,
    Same,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub(super) enum Verdict {
    /// Over budget before, within after.
    Fixed,
    /// Within budget before, over after.
    Broke,
    Within,
    Over,
    /// No budget: the trend decides.
    Better,
    Worse,
    Same,
    /// One side has no value.
    Unmeasured,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub(super) struct Row {
    pub key: String,
    pub group: String,
    pub label: String,
    pub unit: String,
    pub before: Option<f64>,
    pub after: Option<f64>,
    pub delta: Option<f64>,
    pub change_pct: Option<f64>,
    pub budget: Option<f64>,
    pub better: Better,
    pub trend: Option<Trend>,
    pub verdict: Verdict,
}

pub(super) fn trend(better: Better, before: f64, after: f64) -> Trend {
    let delta = after - before;
    let scale = before.abs().max(after.abs());
    if delta.abs() < 0.01 || (scale > 0.0 && delta.abs() / scale < NOISE) {
        return Trend::Same;
    }
    let lower = delta < 0.0;
    if lower == (better == Better::Lower) { Trend::Better } else { Trend::Worse }
}

pub(super) fn row(before: Option<&Metric>, after: Option<&Metric>) -> Option<Row> {
    let shape = after.or(before)?;
    let (b, a) = (before.and_then(|m| m.value), after.and_then(|m| m.value));
    let budget = shape.budget;
    let (delta, change_pct, trend) = match (b, a) {
        (Some(b), Some(a)) => (
            Some(super::stats::round(a - b, 3)),
            (b != 0.0).then(|| super::stats::round((a - b) * 100.0 / b.abs(), 1)),
            Some(trend(shape.better, b, a)),
        ),
        _ => (None, None, None),
    };
    let verdict = match (
        report::within(shape.better, budget, b),
        report::within(shape.better, budget, a),
        trend,
    ) {
        (_, _, None) => Verdict::Unmeasured,
        (Some(false), Some(true), _) => Verdict::Fixed,
        (Some(true), Some(false), _) => Verdict::Broke,
        (Some(true), Some(true), _) => Verdict::Within,
        (Some(false), Some(false), _) => Verdict::Over,
        (_, _, Some(Trend::Better)) => Verdict::Better,
        (_, _, Some(Trend::Worse)) => Verdict::Worse,
        (_, _, Some(Trend::Same)) => Verdict::Same,
    };
    Some(Row {
        key: shape.key.clone(),
        group: shape.group.clone(),
        label: shape.label.clone(),
        unit: shape.unit.clone(),
        before: b,
        after: a,
        delta,
        change_pct,
        budget,
        better: shape.better,
        trend,
        verdict,
    })
}

/// One row per metric key in either report, in `after`'s order, then `before`'s leftovers.
pub(super) fn compare(before: &Report, after: &Report) -> Vec<Row> {
    let mut rows: Vec<Row> =
        after.metrics.iter().filter_map(|m| row(before.metric(&m.key), Some(m))).collect();
    rows.extend(
        before
            .metrics
            .iter()
            .filter(|m| after.metric(&m.key).is_none())
            .filter_map(|m| row(Some(m), None)),
    );
    rows
}

pub(super) fn load(path: &Path) -> Result<Report, serde_json::Value> {
    let messages = &crate::localization::catalog().app_control.perf;
    let text = std::fs::read_to_string(path).map_err(|error| {
        super::local_error(
            "perf.unreadable",
            super::fill(
                messages.unreadable,
                &[("path", path.display().to_string()), ("error", error.to_string())],
            ),
        )
    })?;
    serde_json::from_str::<Report>(&text)
        .ok()
        .filter(|report| report.schema == report::SCHEMA)
        .ok_or_else(|| {
            super::local_error(
                "perf.not_a_report",
                messages.not_a_report.replace("{path}", &path.display().to_string()),
            )
        })
}

fn verdict_word(verdict: Verdict) -> &'static str {
    let messages = &crate::localization::catalog().app_control.perf;
    match verdict {
        Verdict::Fixed => messages.verdict_fixed,
        Verdict::Broke => messages.verdict_broke,
        Verdict::Within => messages.verdict_within,
        Verdict::Over => messages.verdict_over,
        Verdict::Better => messages.verdict_better,
        Verdict::Worse => messages.verdict_worse,
        Verdict::Same => messages.verdict_same,
        Verdict::Unmeasured => messages.verdict_unmeasured,
    }
}

fn trend_word(trend: Option<Trend>) -> &'static str {
    let messages = &crate::localization::catalog().app_control.perf;
    match trend {
        Some(Trend::Better) => messages.verdict_better,
        Some(Trend::Worse) => messages.verdict_worse,
        Some(Trend::Same) | None => "",
    }
}

fn signed(value: f64) -> String {
    format!("{}{}", if value > 0.0 { "+" } else { "" }, report::show(Some(value)))
}

fn pad(text: &str, width: usize) -> String {
    let len = text.chars().count();
    if len >= width { text.to_owned() } else { format!("{text}{}", " ".repeat(width - len)) }
}

/// The side-by-side table.
pub(super) fn human(before: &Report, after: &Report, rows: &[Row]) -> String {
    let messages = &crate::localization::catalog().app_control.perf;
    let mut out = String::new();
    let label = |report: &Report| report.label.clone().unwrap_or_else(|| "-".into());
    let _ = writeln!(
        out,
        "{}",
        super::fill(messages.compare_header, &[("before", label(before)), ("after", label(after))])
    );
    let width = rows.iter().map(|row| row.label.chars().count()).max().unwrap_or(10);
    let mut group = "";
    for row in rows {
        if row.group != group {
            group = &row.group;
            let _ = writeln!(out, "\n{group}");
        }
        let delta = match (row.delta, row.change_pct) {
            (Some(delta), Some(pct)) => format!("{} ({}%)", signed(delta), signed(pct)),
            (Some(delta), None) => signed(delta),
            _ => "-".into(),
        };
        let budget = row.budget.map(|b| report::show(Some(b))).unwrap_or_default();
        let mut verdict = verdict_word(row.verdict).to_owned();
        if matches!(row.verdict, Verdict::Within | Verdict::Over) {
            let trend = trend_word(row.trend);
            if !trend.is_empty() {
                verdict = format!("{verdict}, {trend}");
            }
        }
        let _ = writeln!(
            out,
            "  {} {} {} {} {} {} {}",
            pad(&row.label, width),
            pad(&report::show(row.before), 10),
            pad(&report::show(row.after), 10),
            pad(&row.unit, 4),
            pad(&delta, 20),
            pad(&budget, 7),
            verdict
        );
    }
    let count = |verdict: Verdict| rows.iter().filter(|row| row.verdict == verdict).count();
    let _ = writeln!(
        out,
        "\n{}",
        super::fill(
            messages.compare_summary,
            &[
                ("fixed", count(Verdict::Fixed).to_string()),
                ("broke", count(Verdict::Broke).to_string()),
                (
                    "better",
                    rows.iter().filter(|row| row.trend == Some(Trend::Better)).count().to_string()
                ),
                (
                    "worse",
                    rows.iter().filter(|row| row.trend == Some(Trend::Worse)).count().to_string()
                ),
                (
                    "over",
                    rows.iter()
                        .filter(
                            |row| report::within(row.better, row.budget, row.after) == Some(false)
                        )
                        .count()
                        .to_string()
                ),
            ],
        )
    );
    out
}

pub(super) fn report_json(before: &Report, after: &Report, rows: &[Row]) -> serde_json::Value {
    json!({
        "schema": "cmux.perf.compare/1",
        "before": { "label": before.label, "app": before.app, "created_unix": before.created_unix },
        "after": { "label": after.label, "app": after.app, "created_unix": after.created_unix },
        "rows": rows,
    })
}

pub(super) fn run(global: &GlobalArgs, before: &Path, after: &Path) -> i32 {
    let (before, after) = match (load(before), load(after)) {
        (Ok(before), Ok(after)) => (before, after),
        (Err(error), _) | (_, Err(error)) => {
            return super::super::super::wire::print_local_error(&error, global.output, 2);
        }
    };
    let rows = compare(&before, &after);
    print_comparison(global.output, &before, &after, &rows)
}

pub(super) fn print_comparison(
    output: OutputMode,
    before: &Report,
    after: &Report,
    rows: &[Row],
) -> i32 {
    match output {
        OutputMode::Human => {
            print!("{}", human(before, after, rows));
            0
        }
        _ => super::super::super::wire::print_local_success(
            &report_json(before, after, rows),
            output,
        ),
    }
}
