//! The summary of a recording: per process kind (summed over its pids) CPU
//! and wakeups, memory at the end and its growth; the agent pages' frames;
//! the longest signpost intervals; and what each source recorded or why it
//! could not. `summary.json` and the printed text say the same.

use std::collections::BTreeMap;

use serde::Serialize;
use serde_json::Value;

use crate::pages::Frames;
use crate::process::Tick;
use crate::signposts::Interval;

/// How many signpost intervals the summary lists.
pub const TOP_INTERVALS: usize = 10;

/// One kind of process over the window, its pids summed at each sample.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct KindRow {
    pub kind: String,
    pub pids: usize,
    pub cpu_pct_mean: f64,
    pub cpu_pct_max: f64,
    pub wakeups_per_s_mean: f64,
    pub memory_mb_end: f64,
    pub memory_mb_growth: f64,
}

/// The kinds, busiest CPU first.
pub fn kinds(ticks: &[Tick]) -> Vec<KindRow> {
    struct Sums {
        pids: std::collections::BTreeSet<i32>,
        cpu: Vec<f64>,
        wakeups: Vec<f64>,
        first_memory: Option<f64>,
        last_memory: f64,
    }
    let mut by_kind: BTreeMap<String, Sums> = BTreeMap::new();
    for tick in ticks {
        let mut at_tick: BTreeMap<&str, (Option<f64>, Option<f64>, f64)> = BTreeMap::new();
        for row in &tick.rows {
            let entry = at_tick.entry(&row.kind).or_insert((None, None, 0.0));
            if let Some(cpu) = row.cpu_pct {
                entry.0 = Some(entry.0.unwrap_or(0.0) + cpu);
            }
            if let Some(wakeups) = row.wakeups_per_s {
                entry.1 = Some(entry.1.unwrap_or(0.0) + wakeups);
            }
            entry.2 += row.memory_mb;
            by_kind
                .entry(row.kind.clone())
                .or_insert_with(|| Sums {
                    pids: Default::default(),
                    cpu: Vec::new(),
                    wakeups: Vec::new(),
                    first_memory: None,
                    last_memory: 0.0,
                })
                .pids
                .insert(row.pid);
        }
        for (kind, (cpu, wakeups, memory)) in at_tick {
            let Some(sums) = by_kind.get_mut(kind) else { continue };
            sums.cpu.extend(cpu);
            sums.wakeups.extend(wakeups);
            sums.first_memory.get_or_insert(memory);
            sums.last_memory = memory;
        }
    }
    let mean = |values: &[f64]| {
        if values.is_empty() { 0.0 } else { values.iter().sum::<f64>() / values.len() as f64 }
    };
    let mut rows: Vec<KindRow> = by_kind
        .into_iter()
        .map(|(kind, sums)| KindRow {
            kind,
            pids: sums.pids.len(),
            cpu_pct_mean: mean(&sums.cpu),
            cpu_pct_max: sums.cpu.iter().copied().fold(0.0, f64::max),
            wakeups_per_s_mean: mean(&sums.wakeups),
            memory_mb_end: sums.last_memory,
            memory_mb_growth: sums.last_memory - sums.first_memory.unwrap_or(sums.last_memory),
        })
        .collect();
    rows.sort_by(|a, b| b.cpu_pct_mean.total_cmp(&a.cpu_pct_mean).then(a.kind.cmp(&b.kind)));
    rows
}

/// The agent pages' frames over the window.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct PageRow {
    /// `frames` lines (one per page per active second at most).
    pub windows: usize,
    pub frames: f64,
    /// Share of frame intervals over 12.5 ms (a missed 120 Hz frame).
    pub miss120_share: f64,
    /// Share of frame intervals over 25 ms (a missed 60 Hz frame).
    pub miss60_share: f64,
    /// The median of the windows' p50: the page's real cadence (16.7 is 60 Hz).
    pub median_p50_ms: f64,
    pub worst_p95_ms: f64,
    pub long_frames: usize,
}

pub fn pages(frames: &[Frames], long_frames: usize) -> PageRow {
    let total: f64 = frames.iter().map(|window| window.n).sum();
    let share = |count: f64| if total > 0.0 { count / total } else { 0.0 };
    let mut p50: Vec<f64> = frames.iter().map(|window| window.p50).collect();
    p50.sort_by(f64::total_cmp);
    let median = match p50.len() {
        0 => 0.0,
        n if n % 2 == 1 => p50[n / 2],
        n => (p50[n / 2 - 1] + p50[n / 2]) / 2.0,
    };
    PageRow {
        windows: frames.len(),
        frames: total,
        miss120_share: share(frames.iter().map(|window| window.miss120).sum()),
        miss60_share: share(frames.iter().map(|window| window.miss60).sum()),
        median_p50_ms: median,
        worst_p95_ms: frames.iter().map(|window| window.p95).fold(0.0, f64::max),
        long_frames,
    }
}

/// The `count` longest intervals, longest first.
pub fn top_intervals(intervals: &[Interval], count: usize) -> Vec<&Interval> {
    let mut sorted: Vec<&Interval> = intervals.iter().collect();
    sorted.sort_by(|a, b| b.ms.total_cmp(&a.ms));
    sorted.truncate(count);
    sorted
}

/// Whether a source recorded, and what or why not.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Source {
    pub name: &'static str,
    pub ok: bool,
    pub detail: String,
}

impl Source {
    pub fn ok(name: &'static str, detail: impl Into<String>) -> Self {
        Self { name, ok: true, detail: detail.into() }
    }

    pub fn unavailable(name: &'static str, reason: impl Into<String>) -> Self {
        Self { name, ok: false, detail: reason.into() }
    }
}

/// `{name: {status, detail}}` of the sources, for summary.json and the trace metadata.
pub fn sources_json(sources: &[Source]) -> Value {
    let map = sources
        .iter()
        .map(|source| {
            let status = if source.ok { "ok" } else { "unavailable" };
            (source.name.to_owned(), serde_json::json!({"status": status, "detail": source.detail}))
        })
        .collect();
    Value::Object(map)
}

/// The printed summary of a `summary.json` value.
pub fn text(summary: &Value) -> String {
    let get = |path: &[&str]| path.iter().try_fold(summary, |value, key| value.get(key));
    let str_of = |path: &[&str]| get(path).and_then(Value::as_str).unwrap_or("?").to_owned();
    let num = |value: &Value, key: &str| value.get(key).and_then(Value::as_f64).unwrap_or(0.0);
    let mut out = format!(
        "cmux perf record: {} ({} {}), {:.1} s from {}\n",
        str_of(&["app"]),
        str_of(&["bundle_id"]),
        str_of(&["version"]),
        get(&["seconds"]).and_then(Value::as_f64).unwrap_or(0.0),
        str_of(&["start"]),
    );
    out.push_str("\nsources\n");
    if let Some(Value::Object(sources)) = get(&["sources"]) {
        for (name, source) in sources {
            let status = source.get("status").and_then(Value::as_str).unwrap_or("?");
            let detail = source.get("detail").and_then(Value::as_str).unwrap_or("");
            out.push_str(&format!("  {name:<10} {status:<12} {detail}\n"));
        }
    }
    let rate = str_of(&["wakeups_name"]);
    let memory = str_of(&["memory_name"]);
    let processes = get(&["processes"]).and_then(Value::as_array).cloned().unwrap_or_default();
    if !processes.is_empty() {
        out.push_str(&format!(
            "\nprocesses (summed per kind)\n  {:<22} {:>4} {:>9} {:>8} {:>15} {:>14} {:>9}\n",
            "kind",
            "pids",
            "cpu% mean",
            "cpu% max",
            rate,
            format!("{memory} end"),
            "growth"
        ));
        for row in &processes {
            out.push_str(&format!(
                "  {:<22} {:>4} {:>9.1} {:>8.1} {:>15.1} {:>14.1} {:>+9.1}\n",
                row.get("kind").and_then(Value::as_str).unwrap_or("?"),
                row.get("pids").and_then(Value::as_u64).unwrap_or(0),
                num(row, "cpu_pct_mean"),
                num(row, "cpu_pct_max"),
                num(row, "wakeups_per_s_mean"),
                num(row, "memory_mb_end"),
                num(row, "memory_mb_growth"),
            ));
        }
    }
    if let Some(pages) = get(&["pages"]).filter(|pages| pages.is_object()) {
        out.push_str(&format!(
            "\nagent pages\n  {} frame windows, {:.0} frames, {:.1}% missed a 120 Hz frame, {:.1}% missed a 60 Hz frame\n  median p50 {:.1} ms, worst p95 {:.1} ms, {} long frames (over 100 ms)\n",
            pages.get("windows").and_then(Value::as_u64).unwrap_or(0),
            num(pages, "frames"),
            num(pages, "miss120_share") * 100.0,
            num(pages, "miss60_share") * 100.0,
            num(pages, "median_p50_ms"),
            num(pages, "worst_p95_ms"),
            pages.get("long_frames").and_then(Value::as_u64).unwrap_or(0),
        ));
    }
    let top = get(&["signposts", "top"]).and_then(Value::as_array).cloned().unwrap_or_default();
    if !top.is_empty() {
        out.push_str("\nlongest signpost intervals\n");
        for interval in &top {
            out.push_str(&format!(
                "  {:>9.2} ms  {}  ({})\n",
                num(interval, "ms"),
                interval.get("name").and_then(Value::as_str).unwrap_or("?"),
                interval.get("category").and_then(Value::as_str).unwrap_or("?"),
            ));
        }
    }
    out.push_str(&format!("\ntrace: {}\nopen it in https://ui.perfetto.dev\n", str_of(&["trace"])));
    out
}
