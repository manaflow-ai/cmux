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
//!   arrivals of an agent event (`reader_n - 1`). Exact counts; each part is also reported on its own.
//! - attach_ms: a reader's `open` (`_acpmux/attach` with the transcript) under load; first_paint_ms: the same when
//!   its reply carried at least one event (the reader has something to draw).
//! - scroll: `scroll` ops (one older page), their ms, pages per second of paging time, and ops over 16.7 / 33.3 ms.
//! - typing: a `turn` event (the prompt) to its daemon record (ack_ms) and to a follower seeing it (echo_ms).
//! - daemon: `role == "daemon"` samples: RSS, peak, baseline (the first sample, before the chats load), the RSS
//!   least-squares slope in MB per minute (the leak signal), CPU %; per_chat: RSS over the baseline and CPU %, each
//!   divided by the run's open chats (run.json `sessions`, else `coordinators`).
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
        .ok_or("usage: coord-sim report RUN_DIR [--out FILE] [--rows]")?;
    let mut report = report(Path::new(dir))?;
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

/// The report as PERF_ROW objects (webviews/bench/perfRow.ts's shape: name, p50, p95, unit, target, floor, version),
/// which the perf cron stores as webui.coord_sim.<name>. Lower is better for every row; a row with no value is left
/// out. Targets follow perfRow.ts's TARGET_MS rules (a response 100 ms, a load 1000 ms); lost and duplicated events 0.
pub fn perf_rows(r: &Value) -> Vec<Value> {
    let mut rows = Vec::new();
    let dists: [(&str, &Value, &str, Option<f64>, Option<f64>); 9] = [
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
    let ones: [(&str, &Value, &str, Option<f64>, f64, bool); 7] = [
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
                }
                dup_at_readers += e.reader_n.saturating_sub(1);
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
            "open" if o.n.unwrap_or(0) > 0 => paint.add(ms),
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
        if let Some(kb) = p.rss_kb {
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

    let attach =
        ops.get("open").map(|s| s.ms.summary()).unwrap_or_else(|| LogHist::default().summary());
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
            "unseen_by_readers": unseen_by_readers,
            "dup_in_daemon": dup_in_daemon,
            "dup_at_readers": dup_at_readers,
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
            "rss_slope_mb_per_min": round3(slope.slope()),
            "cpu_pct": cpu.summary(),
        },
        "per_chat": {"rss_mb": per_chat_mb.summary(), "cpu_pct": per_chat_cpu.summary()},
        "peak_rss_mb_by_role": role_peak.iter().map(|(k, v)| (k.clone(), round3(Some(v / 1024.0)))).collect::<Map<_, _>>(),
        "ops": ops.iter().map(|(k, s)| (k.clone(), json!({"ms": s.ms.summary(), "failed": s.failed}))).collect::<Map<_, _>>(),
        "bad_lines": bad,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn run_dir(name: &str, files: &[(&str, &str)]) -> std::path::PathBuf {
        let d =
            std::env::temp_dir().join(format!("coord-sim-metrics-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        for (f, s) in files {
            std::fs::write(d.join(f), s).unwrap();
        }
        d
    }

    fn event(
        c: u32,
        seq: u64,
        src: &str,
        emit_us: u64,
        daemon_n: u64,
        reader_us: Option<u64>,
        reader_n: u64,
    ) -> String {
        let daemon_at = if daemon_n > 0 { json!(emit_us / 1000 + 2) } else { Value::Null };
        json!({"c": c, "seq": seq, "k": 0, "kind": "in:agent_message_chunk", "update": if src == "agent" { "agent_message_chunk" } else { src },
            "src": src, "bytes": 100, "due_us": emit_us - 500, "emit_us": emit_us, "daemon_at_ms": daemon_at,
            "daemon_n": daemon_n, "reader_us": reader_us, "reader_n": reader_n})
        .to_string()
            + "\n"
    }

    #[test]
    fn hist_quantiles_are_within_one_percent() {
        let mut h = LogHist::default();
        for v in 1..=1000 {
            h.add(v as f64);
        }
        for (q, want) in [(0.5, 500.0), (0.95, 950.0), (0.99, 990.0)] {
            let got = h.quantile(q).unwrap();
            assert!((got - want).abs() / want < 0.01, "q{q}: {got} vs {want}");
        }
        assert!(h.quantile(1.0).unwrap() <= 1000.0);
        assert!(LogHist::default().quantile(0.5).is_none());
        let mut z = LogHist::default();
        z.add(0.0);
        assert_eq!(z.quantile(0.5), Some(0.0));
    }

    #[test]
    fn slope_of_a_line() {
        let mut s = Slope::default();
        for m in 0..10 {
            s.add(1.7e9 + m as f64, 100.0 + 3.0 * m as f64);
        }
        assert!((s.slope().unwrap() - 3.0).abs() < 1e-6);
    }

    #[test]
    fn report_from_a_fixture_run_dir() {
        let run = r#"{"schema":"coord-sim-drive.v1","coordinators":2,"rate":10,"readers":2,"run_s":30,"sessions":["s0","s1"]}"#;
        let base = 1_763_500_000_000_000u64;
        let mut ev = String::new();
        for seq in 1..=100u64 {
            for c in 0..2u32 {
                let emit = base + seq * 10_000;
                let lat = seq * 1000; // 1..100 ms
                match (c, seq) {
                    (1, 50) => ev.push_str(&event(c, seq, "agent", emit, 0, None, 0)), // lost in the daemon
                    (1, 51) => ev.push_str(&event(c, seq, "agent", emit, 1, None, 0)), // stored, never seen
                    (1, 60) => ev.push_str(&event(c, seq, "agent", emit, 2, Some(emit + lat), 3)), // 1 + 2 extra
                    _ => ev.push_str(&event(c, seq, "agent", emit, 1, Some(emit + lat), 1)),
                }
            }
        }
        for i in 0..10u64 {
            ev.push_str(&event(
                0,
                1000 + i,
                "turn",
                base + i * 1_000_000,
                1,
                Some(base + i * 1_000_000 + (i + 1) * 5000),
                1,
            ));
        }
        ev.push_str("{\"c\":0,\"seq\":3,\"src\":\"age"); // half a line from a killed driver
        let mut ops = String::new();
        for i in 1..=20u64 {
            let t = base + i;
            ops.push_str(&format!("{{\"op\":\"open\",\"reader\":0,\"c\":0,\"t_us\":{t},\"latency_us\":{},\"bytes\":10,\"n\":{},\"ok\":true,\"err\":null}}\n", i * 10_000, if i % 2 == 0 { 5 } else { 0 }));
            ops.push_str(&format!("{{\"op\":\"scroll\",\"reader\":0,\"c\":0,\"t_us\":{t},\"latency_us\":{},\"bytes\":10,\"n\":50,\"ok\":true,\"err\":null}}\n", i * 2000));
        }
        ops.push_str(&format!("{{\"op\":\"scroll\",\"reader\":0,\"c\":0,\"t_us\":{base},\"latency_us\":900000,\"bytes\":0,\"n\":null,\"ok\":false,\"err\":\"timeout\"}}\n"));
        ops.push_str("{\"op\":\"follower\",\"c\":0,\"notes\":120,\"bytes\":5000,\"lagged\":3}\n{\"op\":\"follower\",\"c\":1,\"notes\":100,\"bytes\":4000,\"lagged\":0}\n");
        let mut procs = String::new();
        for m in 0..=10u64 {
            // +10 MB per minute from 100 MB, 30 % CPU; children alongside
            procs.push_str(&format!("{{\"t_us\":{},\"role\":\"daemon\",\"pids\":[9],\"rss_kb\":{},\"cpu_ticks\":0,\"cpu_pct\":30.0}}\n", base + m * 60_000_000, 102_400 + m * 10_240));
            procs.push_str(&format!("{{\"t_us\":{},\"role\":\"children\",\"pids\":[10,11],\"rss_kb\":2048,\"cpu_ticks\":0,\"cpu_pct\":5.0}}\n", base + m * 60_000_000));
        }
        let d = run_dir(
            "fixture",
            &[
                ("run.json", run),
                ("events.ndjson", &ev),
                ("ops.ndjson", &ops),
                ("proc.ndjson", &procs),
            ],
        );
        let r = report(&d).unwrap();

        assert_eq!(r["schema"], SCHEMA);
        assert_eq!(r["config"]["coordinators"], 2);
        assert_eq!(r["config"]["chats"], 2);
        assert_eq!(r["events"]["emitted"]["agent"], 200);
        assert_eq!(r["events"]["emitted"]["turn"], 10);
        assert_eq!(
            (r["events"]["lost_in_daemon"].as_u64(), r["events"]["unseen_by_readers"].as_u64()),
            (Some(1), Some(1))
        );
        assert_eq!(r["events"]["lost"], 2);
        assert_eq!(
            (r["events"]["dup_in_daemon"].as_u64(), r["events"]["dup_at_readers"].as_u64()),
            (Some(1), Some(2))
        );
        assert_eq!(r["events"]["duplicated"], 3);
        assert_eq!(r["bad_lines"]["events"], 1);
        assert_eq!(r["delivery_ms"]["n"], 198);
        let p95 = r["delivery_ms"]["p95"].as_f64().unwrap();
        assert!((p95 - 95.0).abs() < 1.5, "{p95}");
        assert_eq!(r["typing"]["ack_ms"]["n"], 10);
        let echo = r["typing"]["echo_ms"]["p50"].as_f64().unwrap();
        assert!((echo - 25.0).abs() < 0.5, "{echo}");
        let a95 = r["attach_ms"]["p95"].as_f64().unwrap();
        assert!((a95 - 190.0).abs() < 2.0, "{a95}");
        assert_eq!(r["first_paint_ms"]["n"], 10); // the opens whose reply had events
        // pages 2..40 ms: over 16.7 => 18..40 (12); over 33.3 => 34..40 (4); the failed page is no latency
        assert_eq!(r["scroll"]["page_ms"]["n"], 20);
        assert_eq!(r["scroll"]["over_16_7ms"], 12);
        assert_eq!(r["scroll"]["over_33_3ms"], 4);
        assert_eq!(r["ops"]["scroll"]["failed"], 1);
        assert_eq!(r["follower"]["lagged"], 3);
        let slope = r["daemon"]["rss_slope_mb_per_min"].as_f64().unwrap();
        assert!((slope - 10.0).abs() < 0.01, "{slope}");
        assert_eq!(r["daemon"]["peak_rss_mb"].as_f64().unwrap(), 200.0);
        assert_eq!(r["daemon"]["baseline_rss_mb"].as_f64().unwrap(), 100.0);
        let pc = r["per_chat"]["cpu_pct"]["p50"].as_f64().unwrap();
        assert!((pc - 15.0).abs() < 0.2, "{pc}");
        // per chat RSS over the baseline: 0..100 MB / 2 chats, median 25
        let pm = r["per_chat"]["rss_mb"]["p50"].as_f64().unwrap();
        assert!((24.0..26.0).contains(&pm), "{pm}");
        assert_eq!(r["peak_rss_mb_by_role"]["children"].as_f64().unwrap(), 2.0);

        let rows = perf_rows(&r);
        let names: Vec<&str> = rows.iter().filter_map(|x| x["name"].as_str()).collect();
        for want in [
            "coord_sim.delivery_ms",
            "coord_sim.attach_ms",
            "coord_sim.events.lost",
            "coord_sim.events.duplicated",
            "coord_sim.events.lost_or_duplicated",
            "coord_sim.daemon.rss_slope_mb_per_min",
            "coord_sim.per_chat.rss_mb",
            "coord_sim.typing.echo_ms",
            "coord_sim.scroll.over_33ms",
        ] {
            assert!(names.contains(&want), "{want} missing from {names:?}");
        }
        for n in &names {
            assert!(
                n.chars()
                    .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || "._-".contains(c)),
                "{n}"
            );
            assert!(!n.ends_with(".frame") && !n.ends_with(".missed") && !n.ends_with(".dropped"));
        }
        let ld = rows.iter().find(|x| x["name"] == "coord_sim.events.lost_or_duplicated").unwrap();
        assert_eq!((ld["p95"].as_f64(), ld["target"].as_f64()), (Some(5.0), Some(0.0)));

        // the CLI writes report.json, with what the harness passes
        super::run(&[
            d.to_string_lossy().into_owned(),
            "--commit".into(),
            "abc123".into(),
            "--seed".into(),
            "7".into(),
        ])
        .unwrap();
        let written: Value =
            serde_json::from_str(&std::fs::read_to_string(d.join("report.json")).unwrap()).unwrap();
        assert_eq!(written["events"]["lost"], 2);
        assert_eq!(written["config"]["commit"], "abc123");
        assert_eq!(written["config"]["seed"], 7);
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn empty_run_dir_reports_nulls_not_errors() {
        let d = run_dir("empty", &[]);
        let r = report(&d).unwrap();
        assert_eq!(r["files"]["events"], false);
        assert_eq!(r["delivery_ms"]["p95"], Value::Null);
        assert_eq!(r["daemon"]["rss_slope_mb_per_min"], Value::Null);
        assert_eq!(r["events"]["lost"], 0);
        assert!(perf_rows(&r).is_empty(), "an empty run has no rows");
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn large_file_memory_is_constant() {
        // 2M event lines: only counters and fixed histograms are kept.
        let d = run_dir("large", &[("run.json", "{}")]);
        let mut f = std::io::BufWriter::new(File::create(d.join("events.ndjson")).unwrap());
        for seq in 1..=2_000_000u64 {
            let emit = 1_000_000 + seq * 1000;
            writeln!(f, "{{\"c\":0,\"seq\":{seq},\"k\":0,\"src\":\"agent\",\"due_us\":{emit},\"emit_us\":{emit},\"daemon_at_ms\":{},\"daemon_n\":1,\"reader_us\":{},\"reader_n\":1}}", emit / 1000, emit + (seq % 7) * 1000).unwrap();
        }
        drop(f);
        let r = report(&d).unwrap();
        assert_eq!(r["events"]["lost"], 0);
        assert_eq!(r["delivery_ms"]["n"], 2_000_000);
        assert_eq!(r["delivery_ms"]["max"].as_f64().unwrap(), 6.0);
        let _ = std::fs::remove_dir_all(&d);
    }
}
