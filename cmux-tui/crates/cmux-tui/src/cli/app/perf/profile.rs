//! `cmux perf profile [--seconds N] [--out FILE.json] [--label L] [--probe]`.
//!
//! For `--seconds` it reads, side by side on their own threads and connections:
//! - the host: CPU, RAM, GPU and disk of the app's processes (host.rs);
//! - a main-thread probe every 100 ms: `agent.acpmux` (answered on the main actor) minus
//!   `system.ping` (answered off it) is the main thread's queue time; a probe over 50 ms is a
//!   stall (Release, coarse: 10 Hz);
//! - each visible chat page's own frames, long tasks and layout shift (`agent.chat.perf`,
//!   Release; the web page only);
//! - main-thread hang files the app writes for every 2 s hang (Release, macOS);
//! - and in a Debug build the native timers: `debug.frames` (every frame's interval and main
//!   thread time), `debug.hangs` (every stall with its attribution), `debug.layout_counters`,
//!   `debug.tab_switch` and `debug.workspace_switch`.
//!
//! `--probe` also drives the interactive elements and times each: tab and workspace switch
//! (there and back), the sidebar (hide and show), the command palette (open and close) and
//! typing into a terminal `cmux perf sim` made (it types into no terminal of the person's).
//! It takes `--probe-samples` (default 30) timed samples per action, spread over the window,
//! after one warmup round (two samples per action) it drops; when the rounds need longer than
//! `--seconds`, the profile runs on until they are done and says so. Each action reports p50
//! and p95; a p95 from fewer than 20 samples is marked low-n and judged by no budget.

use std::collections::{BTreeMap, BTreeSet};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::{Map, Value, json};

use super::super::super::OutputMode;
use super::super::GlobalArgs;
use super::ProfileArgs;
use super::host;
use super::report::{
    FRAME_BUDGET_MS, LAYOUT_SHIFT_BUDGET, Metric, RESPONSE_BUDGET_MS, Report, SCHEMA, STALL_MS,
    Source,
};
use super::stats;

const REQUEST_TIMEOUT: Duration = Duration::from_secs(5);
const PROBE_EVERY: Duration = Duration::from_millis(100);
/// At most this many visible chat pages are measured at once.
const MAX_CHATS: usize = 3;
/// `agent.chat.perf` measures at most a minute.
const CHAT_MAX_SECONDS: u64 = 60;

/// One main-thread probe: both round trips in ms.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(super) struct Probe {
    pub ping_ms: f64,
    pub main_ms: Option<f64>,
}

impl Probe {
    /// The main thread's own share: the main-actor round trip less the off-main one.
    pub fn queue_ms(&self) -> Option<f64> {
        self.main_ms.map(|main| (main - self.ping_ms).max(0.0))
    }
}

/// One timed interaction (`--probe`).
#[derive(Debug, Clone, PartialEq)]
pub(super) struct Interaction {
    pub element: &'static str,
    pub ms: f64,
    pub ok: bool,
    /// The first round's: timed, kept in the details, left out of the metrics.
    pub warmup: bool,
}

/// The `--probe` rounds for `samples` timed samples per action: one warmup round, then two
/// samples per action a round (there and back; two terminals typed into).
pub(super) fn probe_rounds(samples: usize) -> usize {
    1 + samples.div_ceil(2)
}

/// When round `index` of `rounds` is due: spread evenly from the window's start.
pub(super) fn round_due(index: usize, rounds: usize, window: Duration) -> Duration {
    if rounds == 0 { Duration::ZERO } else { window.mul_f64(index as f64 / rounds as f64) }
}

pub(super) fn call(stream: &mut UnixStream, method: &str, params: Value) -> Option<Value> {
    match super::super::exchange(stream, method, params, REQUEST_TIMEOUT) {
        Ok(Ok(value)) => Some(value),
        _ => None,
    }
}

fn timed(stream: &mut UnixStream, method: &str, params: Value) -> (f64, Option<Value>) {
    let start = Instant::now();
    let value = call(stream, method, params);
    (start.elapsed().as_secs_f64() * 1000.0, value)
}

/// Methods the app registered (`system.identify`'s `methods`).
pub(super) fn method_set(identify: &Value) -> BTreeSet<String> {
    identify["methods"]
        .as_array()
        .map(|methods| methods.iter().filter_map(Value::as_str).map(str::to_owned).collect())
        .unwrap_or_default()
}

/// The conversation tabs shown right now: the selected tab of each pane in each window's
/// workspace. A hidden chat draws no frames, so only these can be measured.
pub(super) fn visible_chat_tabs(snapshot: &Value) -> Vec<String> {
    let topology = &snapshot["topology"];
    let shown: BTreeSet<&str> = topology["windows"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|window| window["workspace"].as_str())
        .collect();
    let mut tabs = Vec::new();
    for workspace in topology["workspaces"].as_array().into_iter().flatten() {
        let id = workspace["id"].as_str().unwrap_or_default();
        if !shown.is_empty() && !shown.contains(id) {
            continue;
        }
        for screen in workspace["screens"].as_array().into_iter().flatten() {
            for pane in screen["panes"].as_array().into_iter().flatten() {
                for tab in pane["tabs"].as_array().into_iter().flatten() {
                    if tab["kind"] == "conversation"
                        && tab["selected"] == true
                        && let Some(id) = tab["id"].as_str()
                        && !id.starts_with("pending_")
                    {
                        tabs.push(id.to_owned());
                    }
                }
            }
        }
    }
    tabs
}

fn number_array(value: &Value) -> Vec<f64> {
    value
        .as_array()
        .map(|items| items.iter().filter_map(Value::as_f64).collect())
        .unwrap_or_default()
}

/// Frame metrics from `debug.frames`' stop report (raw intervals when present, else its own
/// percentiles).
pub(super) fn frame_metrics(frames: Option<&Value>) -> Vec<Metric> {
    const SRC: &str = "debug.frames";
    let m = |key: &str, label: &str, unit: &str| Metric::new(key, "frames", label, unit, SRC);
    let intervals = frames.map(|f| number_array(&f["intervals_ms"])).unwrap_or_default();
    let main = frames.map(|f| number_array(&f["main_ms"])).unwrap_or_default();
    let field = |key: &str| frames.and_then(|f| f[key].as_f64());
    let summary = stats::summarize(&intervals, FRAME_BUDGET_MS);
    let main_summary = stats::summarize(&main, FRAME_BUDGET_MS);
    let pick = |from_raw: Option<f64>, key: &str| from_raw.or_else(|| field(key));
    vec![
        m("frames.count", "frames", "")
            .higher_is_better()
            .value(pick(summary.map(|s| s.count as f64), "frames")),
        m("frames.p50_ms", "frame p50", "ms")
            .budget(FRAME_BUDGET_MS)
            .value(pick(summary.map(|s| s.p50), "p50_ms")),
        m("frames.p95_ms", "frame p95", "ms")
            .budget(FRAME_BUDGET_MS)
            .value(pick(summary.map(|s| s.p95), "p95_ms")),
        m("frames.p99_ms", "frame p99", "ms")
            .budget(FRAME_BUDGET_MS)
            .value(pick(summary.map(|s| s.p99), "p99_ms")),
        m("frames.over_budget_pct", "frames over 8.33 ms", "%")
            .budget(1.0)
            .value(summary.map(|s| s.over_pct())),
        m("frames.longest_ms", "longest frame", "ms")
            .budget(FRAME_BUDGET_MS * 2.0)
            .value(pick(summary.map(|s| s.max), "max_ms")),
        m("frames.main_p95_ms", "main thread per frame p95", "ms")
            .budget(FRAME_BUDGET_MS / 2.0)
            .value(pick(main_summary.map(|s| s.p95), "main_p95_ms")),
    ]
}

/// The chat pages' frames and layout shift (`agent.chat.perf`, one report per page): the
/// worst page's percentiles, all pages' counts.
pub(super) fn chat_metrics(chats: &[Value]) -> Vec<Metric> {
    const SRC: &str = "agent.chat.perf";
    let measured: Vec<&Value> =
        chats.iter().filter(|chat| chat["unmeasured_reason"].is_null()).collect();
    let worst = |path: &[&str]| -> Option<f64> {
        measured
            .iter()
            .filter_map(|chat| {
                path.iter().try_fold(*chat, |at, key| Some(&at[*key])).and_then(Value::as_f64)
            })
            .reduce(f64::max)
    };
    let sum = |path: &[&str]| -> Option<f64> {
        let values: Vec<f64> = measured
            .iter()
            .filter_map(|chat| {
                path.iter().try_fold(*chat, |at, key| Some(&at[*key])).and_then(Value::as_f64)
            })
            .collect();
        (!values.is_empty()).then(|| values.iter().sum())
    };
    let frames = |key: &str, label: &str, unit: &str| Metric::new(key, "frames", label, unit, SRC);
    let layout = |key: &str, label: &str, unit: &str| Metric::new(key, "layout", label, unit, SRC);
    let stalls = |key: &str, label: &str, unit: &str| Metric::new(key, "stalls", label, unit, SRC);
    vec![
        frames("chat.frames", "chat page frames", "")
            .higher_is_better()
            .value(sum(&["frames", "count"])),
        frames("chat.frame_p50_ms", "chat page frame p50", "ms")
            .budget(FRAME_BUDGET_MS)
            .value(worst(&["frames", "interval_p50_ms"])),
        frames("chat.frame_p95_ms", "chat page frame p95", "ms")
            .budget(FRAME_BUDGET_MS)
            .value(worst(&["frames", "interval_p95_ms"])),
        frames("chat.frame_p99_ms", "chat page frame p99", "ms")
            .budget(FRAME_BUDGET_MS)
            .value(worst(&["frames", "interval_p99_ms"])),
        frames("chat.frames_over_33_ms", "chat frames over 33 ms", "")
            .budget(0.0)
            .value(sum(&["frames", "over_33_ms"])),
        frames("chat.longest_frame_ms", "chat longest frame", "ms")
            .budget(FRAME_BUDGET_MS * 2.0)
            .value(worst(&["frames", "interval_max_ms"])),
        stalls("chat.long_tasks", "chat long tasks (>50 ms)", "")
            .budget(0.0)
            .value(sum(&["long_tasks", "count"])),
        stalls("chat.longest_task_ms", "chat longest task", "ms")
            .budget(STALL_MS)
            .value(worst(&["long_tasks", "longest_ms"])),
        layout("chat.layout_shift", "chat layout shift (CLS)", "")
            .budget(LAYOUT_SHIFT_BUDGET)
            .value(worst(&["layout_shift", "sum"])),
        layout("chat.layout_shifts", "chat layout shifts", "")
            .value(sum(&["layout_shift", "count"])),
    ]
}

/// Stall metrics from the probe (Release) and `debug.hangs`' records (Debug).
pub(super) fn stall_metrics(probes: &[Probe], hangs: Option<&Value>) -> Vec<Metric> {
    let queue: Vec<f64> = probes.iter().filter_map(Probe::queue_ms).collect();
    let probe = stats::summarize(&queue, STALL_MS);
    let p =
        |key: &str, label: &str, unit: &str| Metric::new(key, "stalls", label, unit, "probe.main");
    let records: Vec<f64> = hangs
        .map(|h| {
            h["records"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(|r| r["duration_ms"].as_f64())
                .collect()
        })
        .unwrap_or_default();
    let h =
        |key: &str, label: &str, unit: &str| Metric::new(key, "stalls", label, unit, "debug.hangs");
    let has_hangs = hangs.is_some();
    vec![
        p("probe.main_p50_ms", "main thread wait p50", "ms")
            .budget(FRAME_BUDGET_MS)
            .value(probe.map(|s| s.p50)),
        p("probe.main_p95_ms", "main thread wait p95", "ms")
            .budget(FRAME_BUDGET_MS)
            .value(probe.map(|s| s.p95)),
        p("probe.main_p99_ms", "main thread wait p99", "ms")
            .budget(RESPONSE_BUDGET_MS)
            .value(probe.map(|s| s.p99)),
        p("probe.stalls", "probe stalls (>50 ms)", "")
            .budget(0.0)
            .value(probe.map(|s| s.over as f64)),
        p("probe.longest_ms", "probe longest wait", "ms")
            .budget(STALL_MS)
            .value(probe.map(|s| s.max)),
        h("stalls.count", "stalls", "")
            .budget(0.0)
            .value(has_hangs.then_some(records.len() as f64)),
        h("stalls.total_ms", "stall time", "ms")
            .budget(0.0)
            .value(has_hangs.then(|| records.iter().sum())),
        h("stalls.longest_ms", "longest stall", "ms")
            .budget(STALL_MS)
            .value(records.iter().copied().reduce(f64::max).or(has_hangs.then_some(0.0))),
    ]
}

/// The stall records grouped by kind, and the longest five with what they were doing.
pub(super) fn stall_attributions(hangs: &Value) -> Value {
    let records: Vec<&Value> = hangs["records"].as_array().into_iter().flatten().collect();
    let mut kinds: BTreeMap<String, (usize, f64)> = BTreeMap::new();
    for record in &records {
        let kind = record["kind"].as_str().unwrap_or("unknown").to_owned();
        let entry = kinds.entry(kind).or_default();
        entry.0 += 1;
        entry.1 += record["duration_ms"].as_f64().unwrap_or(0.0);
    }
    let mut longest = records.clone();
    longest.sort_by(|a, b| {
        b["duration_ms"]
            .as_f64()
            .unwrap_or(0.0)
            .total_cmp(&a["duration_ms"].as_f64().unwrap_or(0.0))
    });
    json!({
        "by_kind": kinds.iter().map(|(kind, (count, ms))| json!({ "kind": kind, "count": count, "total_ms": stats::round(*ms, 1) })).collect::<Vec<_>>(),
        "longest": longest.into_iter().take(5).map(|r| json!({
            "duration_ms": r["duration_ms"], "cpu_ms": r["cpu_ms"], "kind": r["kind"],
            "frames": r["frame_details"].as_array().map(|f| f.iter().take(8).cloned().collect::<Vec<_>>()).unwrap_or_else(|| number_array(&r["frames"]).into_iter().map(Value::from).collect()),
        })).collect::<Vec<_>>(),
        "over_budget": hangs["over_budget"].as_array().map(|items| items.iter().rev().take(10).cloned().collect::<Vec<_>>()),
    })
}

/// One parsed hang file the app writes for a 2 s hang (Release too).
#[derive(Debug, Clone, PartialEq)]
pub(super) struct HangFile {
    pub duration_ms: f64,
    pub ongoing: bool,
    pub frames: Vec<String>,
}

/// The header's duration and the main thread's first frames (HangEpisodeRecorder's format).
pub(super) fn parse_hang_file(text: &str) -> Option<HangFile> {
    let mut duration = None;
    let mut ongoing = false;
    let mut frames = Vec::new();
    let mut in_main = false;
    for line in text.lines() {
        if let Some(rest) = line.strip_prefix("duration: ") {
            let number: String = rest
                .chars()
                .skip_while(|c| !c.is_ascii_digit())
                .take_while(|c| c.is_ascii_digit() || *c == '.')
                .collect();
            duration = number.parse::<f64>().ok().map(|seconds| seconds * 1000.0);
        } else if line == "state: blocked" {
            ongoing = true;
        } else if line.starts_with("main thread (") {
            in_main = true;
        } else if in_main {
            if !line.starts_with("  ") || frames.len() >= 8 {
                break;
            }
            let frame =
                line.trim_start().trim_start_matches(|c: char| c.is_ascii_digit()).trim_start();
            frames.push(frame.to_owned());
        }
    }
    Some(HangFile { duration_ms: duration?, ongoing, frames })
}

fn hang_dir(bundle_id: &str) -> Option<PathBuf> {
    let home = std::env::var_os("HOME")?;
    Some(PathBuf::from(home).join("Library/Logs").join(bundle_id).join("hangs"))
}

/// Hang files written since `since`.
fn hang_files(dir: &Path, since: SystemTime) -> Vec<HangFile> {
    let Ok(entries) = std::fs::read_dir(dir) else { return Vec::new() };
    entries
        .flatten()
        .filter(|entry| entry.file_name().to_string_lossy().starts_with("hang-"))
        .filter(|entry| entry.metadata().and_then(|m| m.modified()).is_ok_and(|at| at >= since))
        .filter_map(|entry| std::fs::read_to_string(entry.path()).ok())
        .filter_map(|text| parse_hang_file(&text))
        .collect()
}

/// Count deltas between two `debug.layout_counters` readings (numbers only).
pub(super) fn counter_delta(before: &Value, after: &Value) -> Map<String, Value> {
    let mut out = Map::new();
    if let Some(after) = after.as_object() {
        for (key, value) in after {
            if let Some(now) = value.as_f64() {
                let was = before[key].as_f64().unwrap_or(0.0);
                out.insert(key.clone(), json!(stats::round(now - was, 3)));
            }
        }
    }
    out
}

/// One switch's time from `debug.tab_switch` / `debug.workspace_switch`: intent to the
/// commit's end (the frame that shows it), else to the commit, else to the apply.
pub(super) fn switch_times(report: Option<&Value>) -> Vec<f64> {
    report
        .and_then(|r| r["switches"].as_array())
        .into_iter()
        .flatten()
        .filter_map(|s| {
            s["commit_end_ms"]
                .as_f64()
                .or_else(|| s["commit_ms"].as_f64())
                .or_else(|| s["apply_ms"].as_f64())
        })
        .collect()
}

pub(super) fn responsiveness_metrics(
    interactions: &[Interaction],
    tab_switch: Option<&Value>,
    workspace_switch: Option<&Value>,
) -> Vec<Metric> {
    let rtt = |element: &str| -> Option<stats::Summary> {
        let values: Vec<f64> = interactions
            .iter()
            .filter(|i| i.element == element && i.ok && !i.warmup)
            .map(|i| i.ms)
            .collect();
        stats::summarize(&values, RESPONSE_BUDGET_MS)
    };
    let tab = stats::summarize(&switch_times(tab_switch), RESPONSE_BUDGET_MS);
    let workspace = stats::summarize(&switch_times(workspace_switch), RESPONSE_BUDGET_MS);
    // Each element: its p50 (no budget: the typical case) and then its p95 (against the budget,
    // with the sample count so a p95 of a few samples reads as low-n).
    let pair = |key: &str, label: &str, source: &str, summary: Option<stats::Summary>| {
        let p50_key = format!("{}_p50_ms", key.trim_end_matches("_ms"));
        [
            Metric::new(&p50_key, "responsiveness", &format!("{label} p50"), "ms", source)
                .value(summary.map(|s| s.p50))
                .samples(summary.map(|s| s.count)),
            Metric::new(key, "responsiveness", &format!("{label} p95"), "ms", source)
                .budget(RESPONSE_BUDGET_MS)
                .value(summary.map(|s| s.p95))
                .samples(summary.map(|s| s.count)),
        ]
    };
    let mut metrics = Vec::new();
    metrics.extend(pair(
        "resp.terminal_typing_ms",
        "terminal typing (send to answer)",
        "action.run",
        rtt("terminal"),
    ));
    metrics.push(
        Metric::new(
            "resp.composer_typing_ms",
            "responsiveness",
            "composer typing p95",
            "ms",
            "composer",
        )
        .budget(RESPONSE_BUDGET_MS),
    );
    metrics.extend(pair("resp.tab_switch_rtt_ms", "tab switch (action)", "action.run", rtt("tab")));
    metrics.extend(pair("resp.tab_switch_ms", "tab switch to frame", "debug.tab_switch", tab));
    metrics.extend(pair(
        "resp.workspace_switch_rtt_ms",
        "workspace switch (action)",
        "action.run",
        rtt("workspace"),
    ));
    metrics.extend(pair(
        "resp.workspace_switch_ms",
        "workspace switch to frame",
        "debug.workspace_switch",
        workspace,
    ));
    metrics.extend(pair(
        "resp.sidebar_ms",
        "sidebar toggle (action)",
        "action.run",
        rtt("sidebar"),
    ));
    metrics.extend(pair(
        "resp.palette_ms",
        "command palette (action)",
        "action.run",
        rtt("palette"),
    ));
    metrics
}

pub(super) fn host_metrics(summary: &host::HostSummary) -> Vec<Metric> {
    let m = |key: &str, label: &str, unit: &str| Metric::new(key, "host", label, unit, "host");
    vec![
        m("host.cpu_avg_pct", "CPU average (100 = one core)", "%").value(summary.cpu_avg_pct),
        m("host.cpu_peak_pct", "CPU peak second", "%").value(summary.cpu_peak_pct),
        m("host.rss_peak_mb", "resident memory peak", "MB").value(summary.rss_peak_mb),
        m("host.footprint_peak_mb", "physical footprint peak", "MB")
            .value(summary.footprint_peak_mb),
        m("host.disk_read_mb", "disk read", "MB").value(summary.disk_read_mb),
        m("host.disk_write_mb", "disk written", "MB").value(summary.disk_write_mb),
        m("host.gpu_avg_pct", "GPU busy average (host)", "%").value(summary.gpu_avg_pct),
        m("host.gpu_peak_pct", "GPU busy peak (host)", "%").value(summary.gpu_peak_pct),
        m("host.processes", "app process read", "").value(summary.processes_peak),
    ]
}

/// The interactions `--probe` drives, there and back so the app ends as it started.
const ROUNDS: &[(&str, &str, &str)] = &[
    ("tab", "nextSurface", "prevSurface"),
    ("workspace", "nextSidebarTab", "prevSidebarTab"),
    ("sidebar", "toggleSidebar", "toggleSidebar"),
    ("palette", "commandPalette", "commandPalette"),
];

fn drive(stream: &mut UnixStream, terminals: &[String], warmup: bool, out: &mut Vec<Interaction>) {
    for (element, there, back) in ROUNDS {
        for action in [there, back] {
            let (ms, value) =
                timed(stream, "action.run", json!({ "action": action, "origin": "script" }));
            out.push(Interaction { element, ms, ok: value.is_some(), warmup });
            std::thread::sleep(Duration::from_millis(150));
        }
    }
    for tab in terminals.iter().take(2) {
        let (ms, value) = timed(
            stream,
            "action.run",
            json!({ "action": "terminal.sendText", "args": { "text": " " }, "target": format!("tab:{tab}"), "focus": false, "origin": "script" }),
        );
        out.push(Interaction { element: "terminal", ms, ok: value.is_some(), warmup });
    }
}

fn source(available: bool, release: bool, note: &str) -> Source {
    Source { available, release, note: note.into() }
}

fn now_unix() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

/// Profiles the app behind `global`'s socket for `args.seconds`.
pub(super) fn collect(global: &GlobalArgs, args: &ProfileArgs) -> Result<Report, Value> {
    // Every helper thread (host sampler, chat pages) belongs to this scope and is joined in it.
    std::thread::scope(|scope| collect_in(scope, global, args))
}

fn collect_in<'scope, 'env>(
    scope: &'scope std::thread::Scope<'scope, 'env>,
    global: &GlobalArgs,
    args: &ProfileArgs,
) -> Result<Report, Value> {
    let messages = &crate::localization::catalog().app_control.perf;
    let mut stream = super::super::connect_command(global)?;
    let identify =
        match super::super::exchange(&mut stream, "system.identify", json!({}), REQUEST_TIMEOUT) {
            Ok(Ok(value)) => value,
            Ok(Err(error)) => return Err(error),
            Err(error) => return Err(super::local_error("perf.no_answer", error)),
        };
    let methods = method_set(&identify);
    let has = |name: &str| methods.contains(name);
    let pid = identify["pid"].as_i64().unwrap_or(0) as i32;
    let bundle_id = identify["bundle_id"].as_str().unwrap_or_default().to_owned();
    let debug = has("debug.frames");
    let seconds = args.seconds;
    let started_wall = SystemTime::now();

    // Debug-only timers start first so they cover the whole window.
    let frames_on =
        debug && call(&mut stream, "debug.frames", json!({ "action": "start" })).is_some();
    let hangs_base = has("debug.hangs")
        .then(|| call(&mut stream, "debug.hangs", json!({ "limit": 1 })))
        .flatten()
        .map(|h| {
            h["records"]
                .as_array()
                .and_then(|r| r.last())
                .and_then(|r| r["sequence"].as_u64())
                .unwrap_or(0)
        });
    let layout_before = has("debug.layout_counters")
        .then(|| call(&mut stream, "debug.layout_counters", json!({})))
        .flatten();
    let tab_timer = has("debug.tab_switch")
        && call(&mut stream, "debug.tab_switch", json!({ "action": "start" })).is_some();
    let workspace_timer = has("debug.workspace_switch")
        && call(&mut stream, "debug.workspace_switch", json!({ "action": "start" })).is_some();

    let sampler = host::Sampler::start(scope, pid);
    let chats = if has("agent.chat.perf") {
        call(&mut stream, "snapshot.get", json!({}))
            .map(|s| visible_chat_tabs(&s))
            .unwrap_or_default()
    } else {
        Vec::new()
    };
    let chat_seconds = seconds.min(CHAT_MAX_SECONDS);
    let chat_threads: Vec<_> = chats
        .iter()
        .take(MAX_CHATS)
        .map(|tab| {
            let (global, tab) = (global.clone(), tab.clone());
            scope.spawn(move || {
                let mut stream = super::super::connect_command(&global).ok()?;
                let mut report = match super::super::exchange(
                    &mut stream,
                    "agent.chat.perf",
                    json!({ "tab": tab, "seconds": chat_seconds }),
                    Duration::from_secs(chat_seconds + 20),
                ) {
                    Ok(Ok(report)) => report,
                    _ => return None,
                };
                report["tab"] = json!(tab);
                Some(report)
            })
        })
        .collect();

    let terminals = super::sim::state_terminal_tabs(global);
    let start = Instant::now();
    let deadline = start + Duration::from_secs(seconds);
    let has_main_probe = has("agent.acpmux");
    let mut probes = Vec::new();
    let mut interactions = Vec::new();
    let window = Duration::from_secs(seconds);
    let rounds = if args.probe { probe_rounds(args.probe_samples) } else { 0 };
    let mut rounds_done = 0;
    // The window, and past it the probe rounds still to take.
    while Instant::now() < deadline || rounds_done < rounds {
        if crate::shutdown_requested() {
            break;
        }
        let tick = Instant::now();
        let (ping_ms, ping) = timed(&mut stream, "system.ping", json!({}));
        if ping.is_none() {
            probes.push(Probe { ping_ms, main_ms: None });
        } else {
            let main_ms = has_main_probe.then(|| timed(&mut stream, "agent.acpmux", json!({})).0);
            probes.push(Probe { ping_ms, main_ms });
        }
        if rounds_done < rounds && start.elapsed() >= round_due(rounds_done, rounds, window) {
            drive(&mut stream, &terminals, rounds_done == 0, &mut interactions);
            rounds_done += 1;
        }
        if let Some(rest) = PROBE_EVERY.checked_sub(tick.elapsed()) {
            std::thread::sleep(rest);
        }
    }

    let elapsed = start.elapsed();

    let frames = frames_on
        .then(|| call(&mut stream, "debug.frames", json!({ "action": "stop", "raw": true })))
        .flatten();
    let hangs =
        hangs_base.and_then(|after| call(&mut stream, "debug.hangs", json!({ "after": after })));
    let layout_after =
        layout_before.as_ref().and_then(|_| call(&mut stream, "debug.layout_counters", json!({})));
    let tab_switch = tab_timer
        .then(|| call(&mut stream, "debug.tab_switch", json!({ "action": "stop" })))
        .flatten();
    let workspace_switch = workspace_timer
        .then(|| call(&mut stream, "debug.workspace_switch", json!({ "action": "stop" })))
        .flatten();
    let samples = sampler.finish();
    let chat_reports: Vec<Value> =
        chat_threads.into_iter().filter_map(|t| t.join().ok().flatten()).collect();
    let hang_files = if cfg!(target_os = "macos") && !bundle_id.is_empty() {
        hang_dir(&bundle_id).map(|dir| hang_files(&dir, started_wall))
    } else {
        None
    };

    let mut metrics = Vec::new();
    metrics.extend(frame_metrics(frames.as_ref()));
    metrics.extend(chat_metrics(&chat_reports).into_iter().filter(|m| m.group == "frames"));
    metrics.extend(stall_metrics(&probes, hangs.as_ref()));
    metrics.push(
        Metric::new("stalls.hang_files", "stalls", "hangs over 2 s (hang files)", "", "hang_files")
            .budget(0.0)
            .value(hang_files.as_ref().map(|files| files.len() as f64)),
    );
    metrics.extend(chat_metrics(&chat_reports).into_iter().filter(|m| m.group == "stalls"));
    metrics.extend(chat_metrics(&chat_reports).into_iter().filter(|m| m.group == "layout"));
    let layout_delta = match (&layout_before, &layout_after) {
        (Some(before), Some(after)) => Some(counter_delta(before, after)),
        _ => None,
    };
    for (key, label) in [
        ("layout_root_layouts", "native layout passes"),
        ("workspace_applies", "workspace applies"),
        ("pane_snapshots", "pane snapshots"),
        ("topology_sends", "topology sends"),
    ] {
        metrics.push(
            Metric::new(&format!("layout.{key}"), "layout", label, "", "debug.layout_counters")
                .value(layout_delta.as_ref().and_then(|d| d.get(key)).and_then(Value::as_f64)),
        );
    }
    metrics.extend(responsiveness_metrics(
        &interactions,
        tab_switch.as_ref(),
        workspace_switch.as_ref(),
    ));
    metrics.extend(host_metrics(&host::summarize(&samples)));

    let mut sources = BTreeMap::new();
    let debug_note = messages.debug_only;
    sources.insert(
        "probe.main".into(),
        source(has_main_probe && !probes.is_empty(), true, messages.src_probe),
    );
    sources.insert(
        "agent.chat.perf".into(),
        source(
            !chat_reports.is_empty(),
            true,
            if has("agent.chat.perf") { messages.src_no_chat } else { messages.src_missing },
        ),
    );
    sources.insert(
        "action.run".into(),
        source(
            !interactions.is_empty(),
            true,
            if args.probe { messages.src_action } else { messages.src_needs_probe },
        ),
    );
    sources.insert("composer".into(), source(false, false, messages.src_composer));
    sources.insert("host".into(), source(!samples.is_empty(), true, messages.src_host));
    sources
        .insert("hang_files".into(), source(hang_files.is_some(), true, messages.src_hang_files));
    for (name, on) in [
        ("debug.frames", frames.is_some()),
        ("debug.hangs", hangs.is_some()),
        ("debug.layout_counters", layout_delta.is_some()),
        ("debug.tab_switch", tab_switch.is_some()),
        ("debug.workspace_switch", workspace_switch.is_some()),
    ] {
        sources.insert(name.into(), source(on, false, debug_note));
    }

    let mut notes = Vec::new();
    if !debug {
        notes.push(messages.note_release.to_owned());
    }
    if args.probe && terminals.is_empty() {
        notes.push(messages.note_no_sim_terminal.to_owned());
    }
    if args.probe && elapsed > window + Duration::from_secs(1) {
        notes.push(super::fill(
            messages.note_probe_extended,
            &[
                ("rounds", rounds_done.to_string()),
                ("elapsed", format!("{:.0}", elapsed.as_secs_f64())),
                ("seconds", seconds.to_string()),
            ],
        ));
    }
    let mut app = identify;
    if let Some(object) = app.as_object_mut() {
        object.remove("methods");
    }
    Ok(Report {
        schema: SCHEMA.into(),
        label: args.label.clone(),
        created_unix: now_unix(),
        seconds,
        app,
        sources,
        metrics,
        details: json!({
            "probes": probes.len(),
            "elapsed_s": stats::round(elapsed.as_secs_f64(), 1),
            "probe_rounds": rounds_done,
            "probe_samples": args.probe.then_some(args.probe_samples),
            "chats": chat_reports.iter().map(|c| json!({ "tab": c["tab"], "frames": c["frames"], "long_tasks": c["long_tasks"], "layout_shift": c["layout_shift"], "unmeasured_reason": c["unmeasured_reason"] })).collect::<Vec<_>>(),
            "stalls": hangs.as_ref().map(stall_attributions),
            "hang_files": hang_files.as_ref().map(|files| files.iter().map(|f| json!({ "duration_ms": f.duration_ms, "ongoing": f.ongoing, "frames": f.frames })).collect::<Vec<_>>()),
            "layout_counters": layout_delta,
            "tab_switches": tab_switch.as_ref().map(|t| t["switches"].clone()),
            "workspace_switches": workspace_switch.as_ref().map(|t| t["switches"].clone()),
            "interactions": interactions.iter().map(|i| json!({ "element": i.element, "ms": stats::round(i.ms, 2), "ok": i.ok, "warmup": i.warmup })).collect::<Vec<_>>(),
            "frame_layouts": frames.as_ref().map(|f| { let mut f = f.clone(); if let Some(o) = f.as_object_mut() { o.remove("intervals_ms"); o.remove("main_ms"); } f }),
        }),
        notes,
    })
}

/// Writes `report` to `out` (pretty JSON).
pub(super) fn write(report: &Report, out: &Path) -> Result<(), Value> {
    let messages = &crate::localization::catalog().app_control.perf;
    let text = serde_json::to_string_pretty(report).unwrap_or_default();
    std::fs::write(out, text + "\n").map_err(|error| {
        super::local_error(
            "perf.write_failed",
            super::fill(
                messages.write_failed,
                &[("path", out.display().to_string()), ("error", error.to_string())],
            ),
        )
    })
}

pub(super) fn run(global: &GlobalArgs, args: &ProfileArgs) -> i32 {
    let report = match collect(global, args) {
        Ok(report) => report,
        Err(error) => {
            return super::super::super::wire::print_local_error(&error, global.output, 3);
        }
    };
    if let Some(out) = &args.out
        && let Err(error) = write(&report, out)
    {
        return super::super::super::wire::print_local_error(&error, global.output, 1);
    }
    match global.output {
        OutputMode::Human => {
            print!("{}", super::report::human(&report));
            if let Some(out) = &args.out {
                println!(
                    "\n{}",
                    super::fill(messages_wrote(), &[("path", out.display().to_string())])
                );
            }
            0
        }
        _ => super::super::super::wire::print_local_success(
            &serde_json::to_value(&report).unwrap_or_default(),
            global.output,
        ),
    }
}

fn messages_wrote() -> &'static str {
    crate::localization::catalog().app_control.perf.wrote
}
