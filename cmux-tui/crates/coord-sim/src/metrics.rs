//! `coord-sim report RUN_DIR [--out FILE] [--rows] [--commit SHA] [--shape-hash H] [--seed N]`: one JSON of
//! numbers (schema coord-sim-run.v1) from a `coord-sim drive` run.
//!
//! Reads the driver's raw files line by line (their format is documented at the top of drive.rs: events.ndjson,
//! ops.ndjson, proc.ndjson, run.json), keeping only fixed log-bucket histograms and counters, so memory stays
//! constant over multi-GB files (percentiles come from buckets 1 % wide: within 0.5 % of the exact value). Writes
//! RUN_DIR/report.json (or --out) and prints the same JSON; with --rows it prints the report on one line and then
//! its PERF_ROW rows as `{"rows": [...]}` on the last line (the perf cron's coord-sim part reads that line).
//!
//! What each number is, from the driver's fields:
//! - delivery_ms: an agent event's `reader_us - emit_us` (the agent wrote it to a reader first seeing it);
//!   daemon_ms: `daemon_at_ms - emit_us` (to the daemon's store record); behind_schedule_ms: `emit_us - due_us`.
//! - events.lost: events the daemon never stored (`daemon_n == 0`, any source) plus agent events it stored that no
//!   follower saw (`reader_n == 0`); events.duplicated: extra store records (`daemon_n - 1`) plus extra follower
//!   arrivals of an agent event (`reader_n - 1`). Exact counts; each part is also reported on its own, and split
//!   for a run cut off before it drained: never_stored_but_seen (a follower saw it, the store had not caught up)
//!   vs never_stored_unseen; unseen_gap (a later event of the same coordinator was seen: a real miss) vs
//!   unseen_tail (after the coordinator's last seen event: cut-off backlog, or loss in a run that drained);
//!   dup_events counts events seen more than once (duplicated counts the extra copies).
//! - attach_ms: a reader's `open` (`_acpmux/attach` with the transcript) under load; first_paint_ms: the same when
//!   its reply carried at least one event (the reader has something to draw).
//! - scroll: `scroll` ops (one older page), their ms, pages per second of paging time, and ops over 16.7 / 33.3 ms.
//! - typing: a `turn` event (the prompt) to its daemon record (ack_ms) and to a follower seeing it (echo_ms).
//! - daemon: `role == "daemon"` samples: RSS, peak, baseline (the first sample, before the chats load), the RSS
//!   least-squares slope in MB per minute over the run's second half (the leak signal, once the chats have loaded;
//!   the whole-run slope beside it), CPU % (proc.ndjson, else cpu.ndjson; run.json's daemon_cpu_s / daemon_wall_s
//!   as mean_cpu_pct), peak queued MB and status-call ms; per_chat: RSS over the baseline and CPU %, each divided by
//!   the run's open chats (run.json `sessions`, else `coordinators`).
//! - ops: every op name's latency and failures (`ok == false`); follower: summed `notes`, `bytes`, `lagged`.
//!
//! A line that does not parse is counted in `bad_lines`, never fatal: a driver killed mid-write leaves half a line.

use serde::Deserialize;
use serde_json::{Map, Value, json};
use std::collections::BTreeMap;
use std::fs::File;
use std::io::{BufRead, BufReader};
use std::path::Path;

pub const SCHEMA: &str = "coord-sim-run.v1";

pub fn run(args: &[String]) -> Result<(), String> {
    let dir = args
        .first()
        .filter(|a| !a.starts_with("--"))
        .ok_or("usage: coord-sim report RUN_DIR [--out FILE] [--rows] [--fanin DIR]")?;
    let mut report = report(Path::new(dir))?;
    // A fan-in ramp's tables (`coord-sim fanin`) beside the drive run, or in RUN_DIR itself (report() reads those).
    if let Some(f) = crate::flag(args, "--fanin") {
        let section = fanin_section(Path::new(f))?
            .ok_or(format!("{f}: no fanin-summary.json or fanin-table.json"))?;
        if let Some(obj) = report.as_object_mut() {
            obj.insert("fanin".into(), section);
        }
    }
    // What the driver's run.json does not carry: the harness passes it.
    for (flag, key) in [("--commit", "commit"), ("--shape-hash", "shape_hash"), ("--seed", "seed")]
    {
        if let Some(v) = crate::flag(args, flag) {
            let v = v.parse::<u64>().map(|n| json!(n)).unwrap_or_else(|_| json!(v));
            if let Some(cfg) = report.get_mut("config").and_then(Value::as_object_mut) {
                cfg.insert(key.into(), v);
            }
        }
    }
    let text = serde_json::to_string_pretty(&report).map_err(|e| e.to_string())?;
    let out = crate::flag(args, "--out")
        .map(Path::new)
        .map(Path::to_path_buf)
        .unwrap_or_else(|| Path::new(dir).join("report.json"));
    std::fs::write(&out, format!("{text}\n")).map_err(|e| format!("{}: {e}", out.display()))?;
    if args.iter().any(|a| a == "--rows") {
        println!("{}", serde_json::to_string(&report).map_err(|e| e.to_string())?);
        println!(
            "{}",
            serde_json::to_string(&json!({"rows": perf_rows(&report)}))
                .map_err(|e| e.to_string())?
        );
    } else {
        println!("{text}");
    }
    Ok(())
}

/// Bump when what a row measures changes (the perf cron then rebases the row instead of calling it a regression).
pub const ROWS_VERSION: u32 = 1;

/// (name, distribution, unit, target, floor) of one p50/p95 row.
type DistRow<'a> = (&'a str, &'a Value, &'a str, Option<f64>, Option<f64>);
/// (name, count, unit, target, floor, whether the run measured it) of one single-value row.
type OneRow<'a> = (&'a str, &'a Value, &'a str, Option<f64>, f64, bool);

/// The report as PERF_ROW objects (webviews/bench/perfRow.ts's shape: name, p50, p95, unit, target, floor, version),
/// which the perf cron stores as webui.coord_sim.<name>. Lower is better for every row; a row with no value is left
/// out. Targets follow perfRow.ts's TARGET_MS rules (a response 100 ms, a load 1000 ms); lost and duplicated events 0.
pub fn perf_rows(r: &Value) -> Vec<Value> {
    let mut rows = Vec::new();
    let dists: [DistRow; 9] = [
        ("delivery_ms", &r["delivery_ms"], "ms", Some(100.0), None),
        ("attach_ms", &r["attach_ms"], "ms", Some(1000.0), None),
        ("first_paint_ms", &r["first_paint_ms"], "ms", Some(1000.0), None),
        ("page_ms", &r["scroll"]["page_ms"], "ms", None, None),
        ("typing.ack_ms", &r["typing"]["ack_ms"], "ms", Some(100.0), None),
        ("typing.echo_ms", &r["typing"]["echo_ms"], "ms", Some(100.0), None),
        ("daemon.cpu_pct", &r["daemon"]["cpu_pct"], "%", None, Some(5.0)),
        ("per_chat.rss_mb", &r["per_chat"]["rss_mb"], "MB", None, Some(1.0)),
        ("per_chat.cpu_pct", &r["per_chat"]["cpu_pct"], "%", None, Some(2.0)),
    ];
    for (name, d, unit, target, floor) in dists {
        let (Some(p50), Some(p95)) = (d["p50"].as_f64(), d["p95"].as_f64()) else { continue };
        let mut row = json!({"name": format!("coord_sim.{name}"), "p50": p50, "p95": p95, "unit": unit, "version": ROWS_VERSION});
        if let Some(t) = target {
            row["target"] = json!(t);
        }
        if let Some(f) = floor {
            row["floor"] = json!(f);
        }
        rows.push(row);
    }
    // Only a run that read events can say none were lost.
    let events = r["files"]["events"].as_bool() == Some(true);
    // Lost plus duplicated: the one count NOW shows (each is also its own row).
    let lost_or_dup = match (r["events"]["lost"].as_u64(), r["events"]["duplicated"].as_u64()) {
        (Some(l), Some(d)) => json!(l + d),
        _ => Value::Null,
    };
    let ones: [OneRow; 7] = [
        ("events.lost_or_duplicated", &lost_or_dup, "events", Some(0.0), 0.5, events),
        ("events.lost", &r["events"]["lost"], "events", Some(0.0), 0.5, events),
        ("events.duplicated", &r["events"]["duplicated"], "events", Some(0.0), 0.5, events),
        ("delivery_p99_ms", &r["delivery_ms"]["p99"], "ms", None, 10.0, true),
        (
            "scroll.over_33ms",
            &r["scroll"]["over_33_3ms"],
            "ops",
            None,
            2.0,
            r["scroll"]["page_ms"]["n"].as_u64() > Some(0),
        ),
        ("daemon.peak_rss_mb", &r["daemon"]["peak_rss_mb"], "MB", None, 5.0, true),
        (
            "daemon.rss_slope_mb_per_min",
            &r["daemon"]["rss_slope_mb_per_min"],
            "MB/min",
            None,
            1.0,
            true,
        ),
    ];
    for (name, v, unit, target, floor, has) in ones {
        let Some(v) = v.as_f64().filter(|_| has) else { continue };
        let mut row = json!({"name": format!("coord_sim.{name}"), "p50": v, "p95": v, "unit": unit, "floor": floor,
                             "version": ROWS_VERSION});
        if let Some(t) = target {
            row["target"] = json!(t);
        }
        rows.push(row);
    }
    if r["fanin"].is_object() {
        fanin_rows(&r["fanin"], &mut rows);
    }
    rows
}

// ---------- a constant-memory histogram ----------

/// Values in ms (or any unit) in log buckets 1 % wide from 1e-3 up; 0 and below go to bucket 0.
#[derive(Debug, Clone)]
pub struct LogHist {
    counts: Vec<u64>,
    n: u64,
    sum: f64,
    max: f64,
}

const LH_MIN: f64 = 1e-3;
const LH_STEP: f64 = 1.01;
const LH_BUCKETS: usize = 2600; // 1e-3 * 1.01^2600 ~ 1.8e8: past two days in ms

impl Default for LogHist {
    fn default() -> Self {
        LogHist { counts: vec![0; LH_BUCKETS], n: 0, sum: 0.0, max: f64::NEG_INFINITY }
    }
}

impl LogHist {
    pub fn add(&mut self, v: f64) {
        if !v.is_finite() {
            return;
        }
        let b = if v <= LH_MIN {
            0
        } else {
            (((v / LH_MIN).ln() / LH_STEP.ln()) as usize + 1).min(LH_BUCKETS - 1)
        };
        if let Some(c) = self.counts.get_mut(b) {
            *c += 1;
        }
        self.n += 1;
        self.sum += v;
        if v > self.max {
            self.max = v;
        }
    }

    pub fn n(&self) -> u64 {
        self.n
    }

    /// The q-quantile (0..=1), nearest rank, as its bucket's geometric middle; None when empty.
    pub fn quantile(&self, q: f64) -> Option<f64> {
        if self.n == 0 {
            return None;
        }
        let rank = ((q * self.n as f64).ceil() as u64).clamp(1, self.n);
        let mut seen = 0;
        for (b, c) in self.counts.iter().enumerate() {
            seen += c;
            if seen >= rank {
                if b == 0 {
                    return Some(0.0);
                }
                let lo = LH_MIN * LH_STEP.powi(b as i32 - 1);
                return Some((lo * LH_STEP.sqrt()).min(self.max));
            }
        }
        Some(self.max)
    }

    pub fn summary(&self) -> Value {
        if self.n == 0 {
            return json!({"n": 0, "p50": null, "p95": null, "p99": null, "max": null, "mean": null});
        }
        json!({
            "n": self.n,
            "p50": round3(self.quantile(0.50)),
            "p95": round3(self.quantile(0.95)),
            "p99": round3(self.quantile(0.99)),
            "max": round3(Some(self.max)),
            "mean": round3(Some(self.sum / self.n as f64)),
        })
    }
}

fn round3(v: Option<f64>) -> Value {
    match v {
        Some(x) if x.is_finite() => json!((x * 1000.0).round() / 1000.0),
        _ => Value::Null,
    }
}

// ---------- the driver's raw lines ----------

#[derive(Deserialize)]
struct EventLine {
    #[serde(default)]
    src: String,
    #[serde(default)]
    c: u64,
    #[serde(default)]
    due_us: Option<u64>,
    #[serde(default)]
    emit_us: Option<u64>,
    #[serde(default)]
    daemon_at_ms: Option<u64>,
    #[serde(default)]
    daemon_n: u64,
    #[serde(default)]
    reader_us: Option<u64>,
    #[serde(default)]
    reader_n: u64,
}

#[derive(Deserialize)]
struct OpLine {
    op: String,
    #[serde(default)]
    t_us: Option<u64>,
    #[serde(default)]
    latency_us: Option<u64>,
    #[serde(default)]
    n: Option<u64>,
    #[serde(default)]
    ok: Option<bool>,
    #[serde(default)]
    notes: Option<u64>,
    #[serde(default)]
    bytes: Option<u64>,
    #[serde(default)]
    lagged: Option<u64>,
}

#[derive(Deserialize)]
struct ProcLine {
    t_us: u64,
    #[serde(default)]
    role: String,
    #[serde(default)]
    rss_kb: Option<f64>,
    #[serde(default)]
    cpu_pct: Option<f64>,
    #[serde(default)]
    queued_bytes: Option<f64>,
    #[serde(default)]
    status_ms: Option<f64>,
}

/// cpu.ndjson: the daemon's CPU % sampled on its own clock (the driver writes it beside proc.ndjson).
#[derive(Deserialize)]
struct CpuLine {
    #[serde(default)]
    cpu_pct: Option<f64>,
}

/// Each line of an NDJSON file, through one reused buffer; a missing file is no lines (Ok(false)).
fn each_line(path: &Path, mut f: impl FnMut(&str)) -> Result<bool, String> {
    let file = match File::open(path) {
        Ok(f) => f,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(false),
        Err(e) => return Err(format!("{}: {e}", path.display())),
    };
    let mut r = BufReader::with_capacity(1 << 20, file);
    let mut line = String::new();
    loop {
        line.clear();
        let n = r.read_line(&mut line).map_err(|e| format!("{}: {e}", path.display()))?;
        if n == 0 {
            return Ok(true);
        }
        let l = line.trim();
        if !l.is_empty() {
            f(l);
        }
    }
}

const FRAME_60: f64 = 1000.0 / 60.0;
const FRAME_30: f64 = 1000.0 / 30.0;

/// Least squares slope of y over x, from running sums (x centred on its first value for precision).
#[derive(Default)]
struct Slope {
    x0: Option<f64>,
    n: f64,
    sx: f64,
    sy: f64,
    sxx: f64,
    sxy: f64,
}

impl Slope {
    fn add(&mut self, x: f64, y: f64) {
        let x = x - *self.x0.get_or_insert(x);
        self.n += 1.0;
        self.sx += x;
        self.sy += y;
        self.sxx += x * x;
        self.sxy += x * y;
    }
    fn slope(&self) -> Option<f64> {
        let d = self.n * self.sxx - self.sx * self.sx;
        if self.n < 2.0 || d.abs() < 1e-12 {
            None
        } else {
            Some((self.n * self.sxy - self.sx * self.sy) / d)
        }
    }
}

#[derive(Default)]
struct OpStats {
    ms: LogHist,
    failed: u64,
}

fn ms_between(later_us: Option<u64>, earlier_us: Option<u64>) -> Option<f64> {
    Some(later_us? as f64 / 1000.0 - earlier_us? as f64 / 1000.0)
}

pub fn report(dir: &Path) -> Result<Value, String> {
    let config: Map<String, Value> = match std::fs::read_to_string(dir.join("run.json")) {
        Ok(s) => match serde_json::from_str::<Value>(&s) {
            Ok(Value::Object(m)) => m,
            _ => return Err(format!("{}: not a JSON object", dir.join("run.json").display())),
        },
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Map::new(),
        Err(e) => return Err(format!("{}: {e}", dir.join("run.json").display())),
    };
    let chats = config
        .get("sessions")
        .and_then(|s| {
            s.as_array().map(|a| a.len() as u64).or_else(|| s.as_object().map(|o| o.len() as u64))
        })
        .filter(|n| *n > 0)
        .or_else(|| config.get("coordinators").and_then(Value::as_u64))
        .unwrap_or(0);
    let mut bad: BTreeMap<&str, u64> = BTreeMap::new();
    let (mut t0, mut t1) = (u64::MAX, 0u64);

    // events.ndjson
    let (mut delivery, mut daemon_ms, mut behind, mut ack, mut echo) = (
        LogHist::default(),
        LogHist::default(),
        LogHist::default(),
        LogHist::default(),
        LogHist::default(),
    );
    let mut emitted: BTreeMap<String, u64> = BTreeMap::new();
    let (
        mut lost_in_daemon,
        mut unseen_by_readers,
        mut dup_in_daemon,
        mut dup_at_readers,
        mut received,
    ) = (0u64, 0u64, 0u64, 0u64, 0u64);
    // Unseen agent events split by where they sit in their coordinator's stream: one followed by a later event a
    // follower did see is a gap (a real miss); one after the last seen event is the run's tail (cut off before the
    // followers drained, or lost at the end: a run that drains has none). The driver writes each coordinator's
    // events in seq order, so a per-coordinator running count is enough (memory: one entry per coordinator).
    let mut pending_unseen: BTreeMap<u64, u64> = BTreeMap::new();
    let (mut unseen_gap, mut dup_events) = (0u64, 0u64);
    let (mut never_stored_seen, mut never_stored_unseen) = (0u64, 0u64);
    let mut bad_events = 0u64;
    let events_present = each_line(&dir.join("events.ndjson"), |l| {
        let Ok(e) = serde_json::from_str::<EventLine>(l) else {
            bad_events += 1;
            return;
        };
        if let Some(t) = e.emit_us {
            t0 = t0.min(t);
            t1 = t1.max(t);
        }
        *emitted.entry(e.src.clone()).or_insert(0) += 1;
        lost_in_daemon += u64::from(e.daemon_n == 0);
        if e.daemon_n == 0 {
            // Seen by a follower but missing from the store: the store had not caught up when the run ended.
            never_stored_seen += u64::from(e.reader_n > 0);
            never_stored_unseen += u64::from(e.reader_n == 0);
        }
        dup_in_daemon += e.daemon_n.saturating_sub(1);
        if let Some(ms) = ms_between(e.emit_us, e.due_us) {
            behind.add(ms.max(0.0));
        }
        let to_daemon = e.daemon_at_ms.zip(e.emit_us).map(|(d, t)| d as f64 - t as f64 / 1000.0);
        let to_reader = ms_between(e.reader_us, e.emit_us);
        match e.src.as_str() {
            "agent" => {
                if e.daemon_n > 0 && e.reader_n == 0 {
                    unseen_by_readers += 1;
                    *pending_unseen.entry(e.c).or_insert(0) += 1;
                } else if e.reader_n > 0 {
                    unseen_gap += pending_unseen.remove(&e.c).unwrap_or(0);
                }
                dup_at_readers += e.reader_n.saturating_sub(1);
                dup_events += u64::from(e.reader_n > 1);
                received += u64::from(e.reader_n > 0);
                if let Some(ms) = to_reader {
                    delivery.add(ms.max(0.0));
                }
                if let Some(ms) = to_daemon {
                    daemon_ms.add(ms.max(0.0));
                }
            }
            "turn" => {
                if let Some(ms) = to_daemon {
                    ack.add(ms.max(0.0));
                }
                if let Some(ms) = to_reader {
                    echo.add(ms.max(0.0));
                }
            }
            _ => {}
        }
    })?;
    bad.insert("events", bad_events);
    let lost = lost_in_daemon + unseen_by_readers;
    let duplicated = dup_in_daemon + dup_at_readers;
    let unseen_tail: u64 = pending_unseen.values().sum();

    // ops.ndjson
    let mut ops: BTreeMap<String, OpStats> = BTreeMap::new();
    let mut paint = LogHist::default();
    let (mut page_ms_total, mut over_60, mut over_30) = (0.0f64, 0u64, 0u64);
    let (mut notes, mut note_bytes, mut lagged, mut followers) = (0u64, 0u64, 0u64, 0u64);
    let mut bad_ops = 0u64;
    let ops_present = each_line(&dir.join("ops.ndjson"), |l| {
        let Ok(o) = serde_json::from_str::<OpLine>(l) else {
            bad_ops += 1;
            return;
        };
        if o.op == "follower" {
            followers += 1;
            notes += o.notes.unwrap_or(0);
            note_bytes += o.bytes.unwrap_or(0);
            lagged += o.lagged.unwrap_or(0);
            return;
        }
        if let Some(t) = o.t_us {
            t0 = t0.min(t);
            t1 = t1.max(t);
        }
        let Some(lat) = o.latency_us else { return };
        let ms = lat as f64 / 1000.0;
        let s = ops.entry(o.op.clone()).or_default();
        if o.ok == Some(false) {
            s.failed += 1;
            return; // a failed call's time is not a latency
        }
        s.ms.add(ms);
        match o.op.as_str() {
            "open" | "attach" if o.n.unwrap_or(0) > 0 => paint.add(ms),
            "scroll" => {
                page_ms_total += ms;
                over_60 += u64::from(ms > FRAME_60);
                over_30 += u64::from(ms > FRAME_30);
            }
            _ => {}
        }
    })?;
    bad.insert("ops", bad_ops);

    // proc.ndjson
    let (mut rss, mut cpu, mut per_chat_mb, mut per_chat_cpu) =
        (LogHist::default(), LogHist::default(), LogHist::default(), LogHist::default());
    let mut slope = Slope::default();
    let mut peak_kb = 0.0f64;
    let mut baseline_kb: Option<f64> = None;
    let mut role_peak: BTreeMap<String, f64> = BTreeMap::new();
    let mut status_ms = LogHist::default();
    let mut peak_queued_b: Option<f64> = None;
    let (mut daemon_t0, mut daemon_t1) = (u64::MAX, 0u64);
    let mut bad_proc = 0u64;
    let proc_present = each_line(&dir.join("proc.ndjson"), |l| {
        let Ok(p) = serde_json::from_str::<ProcLine>(l) else {
            bad_proc += 1;
            return;
        };
        if let Some(kb) = p.rss_kb {
            let peak = role_peak.entry(p.role.clone()).or_insert(0.0);
            *peak = peak.max(kb);
        }
        if p.role != "daemon" {
            return;
        }
        if let Some(b) = p.queued_bytes {
            peak_queued_b = Some(peak_queued_b.unwrap_or(0.0).max(b));
        }
        if let Some(ms) = p.status_ms {
            status_ms.add(ms.max(0.0));
        }
        if let Some(kb) = p.rss_kb {
            daemon_t0 = daemon_t0.min(p.t_us);
            daemon_t1 = daemon_t1.max(p.t_us);
            let base = *baseline_kb.get_or_insert(kb);
            rss.add(kb / 1024.0);
            slope.add(p.t_us as f64 / 60_000_000.0, kb / 1024.0);
            peak_kb = peak_kb.max(kb);
            if chats > 0 {
                per_chat_mb.add((kb - base).max(0.0) / 1024.0 / chats as f64);
            }
        }
        if let Some(pct) = p.cpu_pct {
            cpu.add(pct.max(0.0));
            if chats > 0 {
                per_chat_cpu.add(pct.max(0.0) / chats as f64);
            }
        }
    })?;
    bad.insert("proc", bad_proc);

    // The whole-run slope counts the chats loading (first minutes: RSS climbs as transcripts arrive), which is not a
    // leak. The leak signal is the slope over the run's second half, by then the chats are loaded: a second pass
    // over proc.ndjson (a few samples a second, small) once the first has found the time range.
    let mut steady = Slope::default();
    if daemon_t1 > daemon_t0 {
        let mid = daemon_t0 + (daemon_t1 - daemon_t0) / 2;
        each_line(&dir.join("proc.ndjson"), |l| {
            if let Ok(p) = serde_json::from_str::<ProcLine>(l)
                && p.role == "daemon"
                && p.t_us >= mid
                && let Some(kb) = p.rss_kb
            {
                steady.add(p.t_us as f64 / 60_000_000.0, kb / 1024.0);
            }
        })?;
    }

    // cpu.ndjson: the daemon's CPU % when proc.ndjson carries none.
    let mut bad_cpu = 0u64;
    let proc_cpu = cpu.n() > 0;
    if !proc_cpu {
        each_line(&dir.join("cpu.ndjson"), |l| {
            let Ok(c) = serde_json::from_str::<CpuLine>(l) else {
                bad_cpu += 1;
                return;
            };
            if let Some(pct) = c.cpu_pct {
                cpu.add(pct.max(0.0));
                if chats > 0 {
                    per_chat_cpu.add(pct.max(0.0) / chats as f64);
                }
            }
        })?;
        bad.insert("cpu", bad_cpu);
    }
    // run.json's whole-run CPU: daemon CPU seconds over wall seconds.
    let mean_cpu_pct = config
        .get("daemon_cpu_s")
        .and_then(Value::as_f64)
        .zip(config.get("daemon_wall_s").and_then(Value::as_f64))
        .filter(|(_, w)| *w > 0.0)
        .map(|(c, w)| c / w * 100.0);

    let attach = ops
        .get("open")
        .or_else(|| ops.get("attach"))
        .map(|s| s.ms.summary())
        .unwrap_or_else(|| LogHist::default().summary());
    let scroll = ops
        .get("scroll")
        .map(|s| (s.ms.summary(), s.ms.n()))
        .unwrap_or_else(|| (LogHist::default().summary(), 0));
    let frac =
        |k: u64| if scroll.1 > 0 { round3(Some(k as f64 / scroll.1 as f64)) } else { Value::Null };
    let pages_per_s =
        if page_ms_total > 0.0 { Some(scroll.1 as f64 / (page_ms_total / 1000.0)) } else { None };
    let duration_s = if t1 > t0 { Some((t1 - t0) as f64 / 1e6) } else { None };
    let cfg = |k: &str| config.get(k).cloned().unwrap_or(Value::Null);
    let has_rss = rss.n() > 0;
    let fanin = fanin_section(dir)?.unwrap_or(Value::Null);
    Ok(json!({
        "schema": SCHEMA,
        "config": {
            "coordinators": cfg("coordinators"),
            "rate": cfg("rate"),
            "readers": cfg("readers"),
            "shape_hash": cfg("shape_hash"),
            "seed": cfg("seed"),
            "commit": cfg("commit"),
            "target": cfg("target"),
            "run_s": cfg("run_s"),
            "chats": chats,
            "duration_s": round3(duration_s),
        },
        "files": {"events": events_present, "ops": ops_present, "proc": proc_present},
        "delivery_ms": delivery.summary(),
        "daemon_ms": daemon_ms.summary(),
        "behind_schedule_ms": behind.summary(),
        "events": {
            "emitted": emitted,
            "received": received,
            "lost": lost,
            "duplicated": duplicated,
            "lost_in_daemon": lost_in_daemon,
            "never_stored_but_seen": never_stored_seen,
            "never_stored_unseen": never_stored_unseen,
            "unseen_by_readers": unseen_by_readers,
            "unseen_gap": unseen_gap,
            "unseen_tail": unseen_tail,
            "dup_in_daemon": dup_in_daemon,
            "dup_at_readers": dup_at_readers,
            "dup_events": dup_events,
        },
        "follower": {"followers": followers, "notes": notes, "bytes": note_bytes, "lagged": lagged},
        "attach_ms": attach,
        "first_paint_ms": paint.summary(),
        "scroll": {
            "page_ms": scroll.0,
            "pages_per_s": round3(pages_per_s),
            "over_16_7ms": over_60,
            "over_33_3ms": over_30,
            "jank_16_7_frac": frac(over_60),
            "jank_33_3_frac": frac(over_30),
        },
        "typing": {"ack_ms": ack.summary(), "echo_ms": echo.summary()},
        "daemon": {
            "samples": rss.n(),
            "rss_mb": rss.summary(),
            "peak_rss_mb": round3(has_rss.then_some(peak_kb / 1024.0)),
            "baseline_rss_mb": round3(baseline_kb.map(|b| b / 1024.0)),
            "rss_slope_mb_per_min": round3(steady.slope()),
            "rss_slope_whole_run_mb_per_min": round3(slope.slope()),
            "cpu_pct": cpu.summary(),
            "cpu_source": if proc_cpu { "proc.ndjson" } else if cpu.n() > 0 { "cpu.ndjson" } else { "none" },
            "mean_cpu_pct": round3(mean_cpu_pct),
            "peak_queued_mb": round3(peak_queued_b.map(|b| b / 1_048_576.0)),
            "status_call_ms": status_ms.summary(),
        },
        "per_chat": {"rss_mb": per_chat_mb.summary(), "cpu_pct": per_chat_cpu.summary()},
        "peak_rss_mb_by_role": role_peak.iter().map(|(k, v)| (k.clone(), round3(Some(v / 1024.0)))).collect::<Map<_, _>>(),
        "ops": ops.iter().map(|(k, s)| (k.clone(), json!({"ms": s.ms.summary(), "failed": s.failed}))).collect::<Map<_, _>>(),
        "bad_lines": bad,
        "fanin": fanin,
    }))
}

// ---------- the fan-in ramp (`coord-sim fanin`, goal sessions-2000-attached) ----------

/// The fan-in section from a ramp root (fanin-summary.json, every N) or one ramp's dir (fanin-table.json); None
/// when DIR has neither. Per N: attach p95 through the controller, the fleet listing (whole and paged, at rest and
/// during churn), fan-out p50/p95/max (one prompt to all N: controller send to agent receipt), fan-in p95, lost and
/// duplicated, controller CPU % and RSS MB per session; across the ramp, the least-squares slope of each per-session
/// cost over N (per 1,000 sessions: flat is constant cost, rising is work that grows with the fleet) and the
/// marginal cost of each added session (fanin-summary.v1 controller_slopes).
pub fn fanin_section(dir: &Path) -> Result<Option<Value>, String> {
    let read = |p: &Path| -> Result<Option<Value>, String> {
        match std::fs::read_to_string(p) {
            Ok(t) => {
                serde_json::from_str(&t).map(Some).map_err(|e| format!("{}: {e}", p.display()))
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(format!("{}: {e}", p.display())),
        }
    };
    // A summary's tables are inline (`tables`) or beside it: `n<N>.fanin-table.json` (a committed results dir) or
    // `n<N>/fanin-table.json` (a ramp's out dir).
    let beside = || -> Result<Vec<Value>, String> {
        let mut found: Vec<(u64, Value)> = Vec::new();
        let entries = std::fs::read_dir(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            let path = if name.ends_with(".fanin-table.json") {
                entry.path()
            } else if entry.path().is_dir() {
                entry.path().join("fanin-table.json")
            } else {
                continue;
            };
            if let Some(t) = read(&path)?.filter(|t| t["schema"] == "fanin-table.v1") {
                found.push((t["n"].as_u64().unwrap_or(0), t));
            }
        }
        found.sort_by_key(|(n, _)| *n);
        Ok(found.into_iter().map(|(_, t)| t).collect())
    };
    let (summary, tables) = match read(&dir.join("fanin-summary.json"))? {
        Some(s) => {
            let t = match s["tables"].as_array() {
                Some(t) if !t.is_empty() => t.clone(),
                _ => beside()?,
            };
            (Some(s), t)
        }
        None => match read(&dir.join("fanin-table.json"))? {
            Some(t) => (None, vec![t]),
            None => {
                let t = beside()?;
                if t.is_empty() {
                    return Ok(None);
                }
                (None, t)
            }
        },
    };
    let f = |t: &Value, ptr: &str| t.pointer(ptr).and_then(Value::as_f64);
    let num = |v: Option<f64>| round3(v);
    let mut per_n = Vec::new();
    let (mut rss_slope, mut cpu_slope) = (Slope::default(), Slope::default());
    for t in &tables {
        let n = t["n"].as_u64().unwrap_or(0);
        if t.get("error").is_some_and(|e| !e.is_null()) {
            per_n.push(json!({"n": n, "error": t["error"]}));
            continue;
        }
        let rss_mb = f(t, "/controller/rss_kb_per_session").map(|k| k / 1024.0);
        let cpu = f(t, "/controller/cpu_pct_per_session");
        if let Some(v) = rss_mb {
            rss_slope.add(n as f64 / 1000.0, v);
        }
        if let Some(v) = cpu {
            cpu_slope.add(n as f64 / 1000.0, v);
        }
        let lost = f(t, "/events/lost").unwrap_or(0.0) + f(t, "/events/fanout_lost").unwrap_or(0.0);
        let dup = f(t, "/events/dup").unwrap_or(0.0) + f(t, "/events/fanout_dup").unwrap_or(0.0);
        per_n.push(json!({
            "n": n,
            "hosts": t["hosts"],
            "attach_ms": {"p50": num(f(t, "/attach_ms/p50")), "p95": num(f(t, "/attach_ms/p95")), "max": num(f(t, "/attach_ms/max")),
                          "failed": t["attach_failed"]},
            "attach_one_p95_ms": num(f(t, "/attach_one_ms/p95")),
            "list_ms": {"whole_at_rest": num(f(t, "/list/whole_ms_at_rest")), "paged_at_rest": num(f(t, "/list/paged_ms_at_rest")),
                        "whole_under_churn_p95": num(f(t, "/list/whole_ms_window/p95")), "rows": t["list"]["rows"]},
            "fanout_ms": {"p50": num(f(t, "/fanout_ms/p50")), "p95": num(f(t, "/fanout_ms/p95")), "max": num(f(t, "/fanout_ms/max"))},
            "fanin_ms": {"p50": num(f(t, "/fanin_ms/p50")), "p95": num(f(t, "/fanin_ms/p95"))},
            "events": {"lost": lost, "duplicated": dup, "client_lagged": t["events"]["client_lagged"]},
            "controller": {"cpu_pct_per_session": num(cpu), "rss_mb_per_session": num(rss_mb),
                           "rss_mb": num(f(t, "/controller/rss_kb").map(|k| k / 1024.0)),
                           "cpu_pct": num(f(t, "/controller/cpu_pct")),
                           // "whole life": CPU seconds over the daemon's life (setup included), not the window;
                           // acpmux has no CPU gauge yet
                           "cpu_basis": t["controller"].get("cpu_basis").cloned().unwrap_or(json!("whole life"))},
            "gaps": t["gaps"],
        }));
    }
    Ok(Some(json!({
        "schema": "coord-sim-fanin.v1",
        "ramps": per_n,
        "slope_per_1000_sessions": {"controller_rss_mb_per_session": num(rss_slope.slope()),
                                    "controller_cpu_pct_per_session": num(cpu_slope.slope())},
        "marginal": summary.as_ref().map(|s| s["controller_slopes"].clone()).unwrap_or(Value::Null),
        "ratios": summary.as_ref().map(|s| s["ratios"].clone()).unwrap_or(Value::Null),
        "goal_met_at_2000": summary.as_ref().map(|s| s["goal_met_at_2000"].clone()).unwrap_or(Value::Null),
    })))
}

/// The fan-in section's PERF_ROW rows: coord_sim.fanin.n<N>.<metric>, and the slopes across the ramp.
fn fanin_rows(fanin: &Value, rows: &mut Vec<Value>) {
    let row = |name: String,
               p50: f64,
               p95: f64,
               unit: &str,
               floor: Option<f64>,
               target: Option<f64>| {
        let mut r =
            json!({"name": name, "p50": p50, "p95": p95, "unit": unit, "version": ROWS_VERSION});
        if let Some(fl) = floor {
            r["floor"] = json!(fl);
        }
        if let Some(t) = target {
            r["target"] = json!(t);
        }
        r
    };
    for t in fanin["ramps"].as_array().map(Vec::as_slice).unwrap_or(&[]) {
        let Some(n) = t["n"].as_u64() else { continue };
        if !t["error"].is_null() {
            continue;
        }
        let p = format!("coord_sim.fanin.n{n}");
        let dist = [("attach_ms", "/attach_ms", Some(1000.0)), ("fanout_ms", "/fanout_ms", None)];
        for (name, ptr, target) in dist {
            let g = |k: &str| t.pointer(&format!("{ptr}/{k}")).and_then(Value::as_f64);
            if let (Some(p50), Some(p95)) = (g("p50"), g("p95")) {
                rows.push(row(format!("{p}.{name}"), p50, p95, "ms", None, target));
            }
        }
        let ones = [
            ("fanout_max_ms", "/fanout_ms/max", "ms", 10.0, None),
            ("list_ms", "/list_ms/whole_at_rest", "ms", 5.0, None),
            ("list_paged_ms", "/list_ms/paged_at_rest", "ms", 5.0, None),
            ("list_under_churn_ms", "/list_ms/whole_under_churn_p95", "ms", 5.0, None),
            ("controller_rss_mb_per_session", "/controller/rss_mb_per_session", "MB", 0.05, None),
            // whole-life CPU (setup included): acpmux has no CPU gauge yet
            (
                "controller_life_cpu_pct_per_session",
                "/controller/cpu_pct_per_session",
                "%",
                0.01,
                None,
            ),
        ];
        for (name, ptr, unit, floor, target) in ones {
            if let Some(v) = t.pointer(ptr).and_then(Value::as_f64) {
                rows.push(row(format!("{p}.{name}"), v, v, unit, Some(floor), target));
            }
        }
        let ld = t["events"]["lost"].as_f64().unwrap_or(0.0)
            + t["events"]["duplicated"].as_f64().unwrap_or(0.0);
        rows.push(row(format!("{p}.lost_or_duplicated"), ld, ld, "events", Some(0.5), Some(0.0)));
    }
    for (name, unit, floor) in [
        ("controller_rss_mb_per_session", "MB", 0.05),
        ("controller_cpu_pct_per_session", "%", 0.01),
    ] {
        if let Some(v) = fanin["slope_per_1000_sessions"][name].as_f64() {
            let name = name.replace("controller_cpu", "controller_life_cpu");
            // A falling per-session cost is good news: the row is the rise only (the cron judges lower as better).
            let v = v.max(0.0);
            rows.push(row(
                format!("coord_sim.fanin.slope.{name}_per_ksession"),
                v,
                v,
                unit,
                Some(floor),
                None,
            ));
        }
    }
}

#[cfg(test)]
#[path = "metrics_tests.rs"]
mod tests;
