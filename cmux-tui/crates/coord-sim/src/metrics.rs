//! `coord-sim report RUN_DIR [--out FILE]`: one JSON of numbers (schema coord-sim-run.v1) from a driver run.
//!
//! Reads the driver's raw files line by line, keeping only histograms and per-stream counters, so memory stays
//! constant over multi-GB files (percentiles come from log buckets 1 % wide: within 0.5 % of the exact value).
//! Writes RUN_DIR/report.json (or --out) and prints the same JSON.
//!
//! # Raw format (the driver writes these; every time is wall-clock ms since the Unix epoch)
//!
//! `run.json`: the run's config, one object:
//!   `{"schema":"coord-sim-drive.v1","coordinators":3,"rate":10,"shape_hash":"..","seed":1,"commit":"<sha>",
//!     "target":"acpmux","readers":1,"started_at":ms,"ended_at":ms}` (every key optional; unknown keys kept as-is).
//!
//! `events.ndjson`: event flow, one object per line, `t` says which:
//!   `{"t":"sent","c":C,"seq":N,"at":ms}`               coordinator C's agent wrote its event N into the daemon
//!   `{"t":"attach","c":C,"r":R,"from_seq":N,"at":ms}`  reader R attached to C; it must see every seq >= N
//!   `{"t":"recv","c":C,"r":R,"seq":N,"sent":ms,"at":ms}` reader R saw C's event N (sent = the agent's send time,
//!                                                      carried in the event itself, so no join is needed)
//!   `{"t":"detach","c":C,"r":R,"upto":N,"at":ms}`      reader R left C; it owed every seq <= N (default: the last sent)
//!   Seqs below a reader's from_seq are history replay: not delivery, not lost or duplicated.
//!
//! `ops.ndjson`: timed operations, one per line, `ms` is its duration:
//!   `{"op":"attach","c":C,"r":R,"at":ms,"ms":X,"first_paint_ms":Y}` attach to attached; to the first event shown
//!   `{"op":"page","c":C,"r":R,"at":ms,"ms":X,"rows":N}`              one page of history (the reader scrolling up)
//!   `{"op":"prompt","c":C,"at":ms,"ack_ms":X,"echo_ms":Y}`           a prompt sent: to the daemon's ack, to its echo
//!
//! `proc.ndjson`: process samples, one per line:
//!   `{"at":ms,"role":"daemon|host|agent|reader","pid":P,"rss_kb":N,"cpu_ms":N,"sessions":N}`
//!   cpu_ms is cumulative (user + system); sessions is the daemon's open chats at that moment.
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
        .ok_or("usage: coord-sim report RUN_DIR [--out FILE]")?;
    let report = report(Path::new(dir))?;
    let text = serde_json::to_string_pretty(&report).map_err(|e| e.to_string())?;
    let out = crate::flag(args, "--out")
        .map(Path::new)
        .map(Path::to_path_buf)
        .unwrap_or_else(|| Path::new(dir).join("report.json"));
    std::fs::write(&out, format!("{text}\n")).map_err(|e| format!("{}: {e}", out.display()))?;
    if args.iter().any(|a| a == "--rows") {
        // For the perf cron (scripts/measure/coord-sim-linux.sh): the report on one line, then its rows last.
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

// ---------- lost and duplicated events, per (coordinator, reader) ----------

#[derive(Debug, Default)]
struct Stream {
    from: u64,
    /// The highest seq seen (from - 1 before any).
    max: u64,
    /// Seqs above `from` and below `max` not seen yet, as inclusive ranges in order.
    holes: Vec<(u64, u64)>,
    upto: Option<u64>,
    dup: u64,
    late: u64,
    recv: u64,
}

impl Stream {
    fn new(from: u64) -> Self {
        let from = from.max(1);
        Stream { from, max: from - 1, ..Default::default() }
    }

    fn see(&mut self, seq: u64) -> bool {
        if seq < self.from {
            return false; // history replay
        }
        self.recv += 1;
        if seq > self.max {
            if seq > self.max + 1 {
                self.holes.push((self.max + 1, seq - 1));
            }
            self.max = seq;
            return true;
        }
        match self.holes.iter().position(|(a, b)| *a <= seq && seq <= *b) {
            Some(i) => {
                self.late += 1;
                if let Some((a, b)) = self.holes.get(i).copied() {
                    self.holes.remove(i);
                    if seq < b {
                        self.holes.insert(i, (seq + 1, b));
                    }
                    if a < seq {
                        self.holes.insert(i, (a, seq - 1));
                    }
                }
                true
            }
            None => {
                self.dup += 1;
                false
            }
        }
    }

    /// Seqs owed and never seen, owed up to `upto` (the detach's, else the coordinator's last sent seq).
    fn lost(&self, last_sent: u64) -> u64 {
        let upto = self.upto.unwrap_or(last_sent);
        let holes: u64 = self
            .holes
            .iter()
            .filter(|(a, _)| *a <= upto)
            .map(|(a, b)| (*b).min(upto) - a + 1)
            .sum();
        holes + upto.saturating_sub(self.max)
    }
}

// ---------- the raw lines ----------

#[derive(Deserialize)]
struct EventLine {
    t: String,
    #[serde(default)]
    c: u32,
    #[serde(default)]
    r: u32,
    #[serde(default)]
    seq: u64,
    #[serde(default)]
    from_seq: Option<u64>,
    #[serde(default)]
    upto: Option<u64>,
    #[serde(default)]
    sent: Option<f64>,
    #[serde(default)]
    at: Option<f64>,
}

#[derive(Deserialize)]
struct OpLine {
    op: String,
    #[serde(default)]
    at: Option<f64>,
    #[serde(default)]
    ms: Option<f64>,
    #[serde(default)]
    first_paint_ms: Option<f64>,
    #[serde(default)]
    ack_ms: Option<f64>,
    #[serde(default)]
    echo_ms: Option<f64>,
}

#[derive(Deserialize)]
struct ProcLine {
    at: f64,
    #[serde(default)]
    role: String,
    #[serde(default)]
    pid: u64,
    #[serde(default)]
    rss_kb: Option<f64>,
    #[serde(default)]
    cpu_ms: Option<f64>,
    #[serde(default)]
    sessions: Option<u64>,
}

/// Each line of an NDJSON file, through one reused buffer; a missing file is no lines.
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

// ---------- the report ----------

const FRAME_60: f64 = 1000.0 / 60.0;
const FRAME_30: f64 = 1000.0 / 30.0;

/// Least squares slope of y over x, from running sums.
#[derive(Default)]
struct Slope {
    n: f64,
    sx: f64,
    sy: f64,
    sxx: f64,
    sxy: f64,
}

impl Slope {
    fn add(&mut self, x: f64, y: f64) {
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

pub fn report(dir: &Path) -> Result<Value, String> {
    let mut bad: BTreeMap<&str, u64> = BTreeMap::new();

    // run.json
    let config: Map<String, Value> = match std::fs::read_to_string(dir.join("run.json")) {
        Ok(s) => match serde_json::from_str::<Value>(&s) {
            Ok(Value::Object(m)) => m,
            _ => return Err(format!("{}: not a JSON object", dir.join("run.json").display())),
        },
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Map::new(),
        Err(e) => return Err(format!("{}: {e}", dir.join("run.json").display())),
    };

    // events.ndjson
    let mut delivery = LogHist::default();
    let mut streams: BTreeMap<(u32, u32), Stream> = BTreeMap::new();
    let mut last_sent: BTreeMap<u32, u64> = BTreeMap::new();
    let mut sent = 0u64;
    let (mut t0, mut t1) = (f64::INFINITY, f64::NEG_INFINITY);
    let mut span = |at: Option<f64>| {
        if let Some(a) = at.filter(|a| a.is_finite()) {
            t0 = t0.min(a);
            t1 = t1.max(a);
        }
    };
    let mut bad_events = 0u64;
    let events_present = each_line(&dir.join("events.ndjson"), |l| {
        let Ok(e) = serde_json::from_str::<EventLine>(l) else {
            bad_events += 1;
            return;
        };
        span(e.at);
        match e.t.as_str() {
            "sent" => {
                sent += 1;
                let m = last_sent.entry(e.c).or_insert(0);
                *m = (*m).max(e.seq);
            }
            "attach" => {
                streams.insert((e.c, e.r), Stream::new(e.from_seq.unwrap_or(1)));
            }
            "detach" => {
                let s = streams.entry((e.c, e.r)).or_insert_with(|| Stream::new(1));
                s.upto = Some(e.upto.unwrap_or(s.max));
            }
            "recv" => {
                let s = streams.entry((e.c, e.r)).or_insert_with(|| Stream::new(1));
                let first = s.see(e.seq);
                if first && let (Some(sent), Some(at)) = (e.sent, e.at) {
                    delivery.add((at - sent).max(0.0));
                }
            }
            _ => bad_events += 1,
        }
    })?;
    bad.insert("events", bad_events);
    let (mut lost, mut dup, mut late, mut recv) = (0u64, 0u64, 0u64, 0u64);
    for ((c, _), s) in &streams {
        lost += s.lost(last_sent.get(c).copied().unwrap_or(0));
        dup += s.dup;
        late += s.late;
        recv += s.recv;
    }

    // ops.ndjson
    let (mut attach, mut paint, mut page, mut ack, mut echo) = (
        LogHist::default(),
        LogHist::default(),
        LogHist::default(),
        LogHist::default(),
        LogHist::default(),
    );
    let (mut page_ms_total, mut over_60, mut over_30) = (0.0f64, 0u64, 0u64);
    let mut bad_ops = 0u64;
    let ops_present = each_line(&dir.join("ops.ndjson"), |l| {
        let Ok(o) = serde_json::from_str::<OpLine>(l) else {
            bad_ops += 1;
            return;
        };
        if let Some(a) = o.at.filter(|a| a.is_finite()) {
            t0 = t0.min(a);
            t1 = t1.max(a);
        }
        match o.op.as_str() {
            "attach" => {
                if let Some(ms) = o.ms {
                    attach.add(ms);
                }
                if let Some(ms) = o.first_paint_ms {
                    paint.add(ms);
                }
            }
            "page" => {
                if let Some(ms) = o.ms {
                    page.add(ms);
                    page_ms_total += ms.max(0.0);
                    over_60 += u64::from(ms > FRAME_60);
                    over_30 += u64::from(ms > FRAME_30);
                }
            }
            "prompt" => {
                if let Some(ms) = o.ack_ms {
                    ack.add(ms);
                }
                if let Some(ms) = o.echo_ms {
                    echo.add(ms);
                }
            }
            _ => {} // ops this report does not read yet
        }
    })?;
    bad.insert("ops", bad_ops);

    // proc.ndjson
    let mut daemon_rss = LogHist::default();
    let mut slope = Slope::default();
    let mut peak_rss_kb = 0.0f64;
    let mut baseline_kb: Option<f64> = None;
    let mut per_chat_mb = LogHist::default();
    let mut per_chat_cpu = LogHist::default();
    let mut daemon_cpu = LogHist::default();
    let mut sessions_max = 0u64;
    let mut prev_cpu: BTreeMap<u64, (f64, f64)> = BTreeMap::new();
    let mut role_peak: BTreeMap<String, f64> = BTreeMap::new();
    let mut first_at: Option<f64> = None;
    let mut bad_proc = 0u64;
    let proc_present = each_line(&dir.join("proc.ndjson"), |l| {
        let Ok(p) = serde_json::from_str::<ProcLine>(l) else {
            bad_proc += 1;
            return;
        };
        let rss = p.rss_kb.unwrap_or(0.0);
        let peak = role_peak.entry(p.role.clone()).or_insert(0.0);
        *peak = peak.max(rss);
        if p.role != "daemon" {
            return;
        }
        let t = *first_at.get_or_insert(p.at);
        let sessions = p.sessions.unwrap_or(0);
        sessions_max = sessions_max.max(sessions);
        if p.rss_kb.is_some() {
            daemon_rss.add(rss / 1024.0);
            slope.add((p.at - t) / 60_000.0, rss / 1024.0);
            peak_rss_kb = peak_rss_kb.max(rss);
            if sessions == 0 {
                baseline_kb = Some(baseline_kb.map_or(rss, |b: f64| b.min(rss)));
            }
        }
        let mut cpu_pct = None;
        if let Some(cpu) = p.cpu_ms {
            if let Some((at0, cpu0)) = prev_cpu.insert(p.pid, (p.at, cpu))
                && p.at > at0
            {
                cpu_pct = Some(((cpu - cpu0) / (p.at - at0) * 100.0).max(0.0));
            }
        }
        if let Some(pct) = cpu_pct {
            daemon_cpu.add(pct);
        }
        if sessions > 0 {
            if p.rss_kb.is_some() {
                per_chat_mb
                    .add((rss - baseline_kb.unwrap_or(0.0)).max(0.0) / 1024.0 / sessions as f64);
            }
            if let Some(pct) = cpu_pct {
                per_chat_cpu.add(pct / sessions as f64);
            }
        }
    })?;
    bad.insert("proc", bad_proc);

    let duration_s = if t1 > t0 { Some((t1 - t0) / 1000.0) } else { None };
    let pages_per_s =
        if page_ms_total > 0.0 { Some(page.n() as f64 / (page_ms_total / 1000.0)) } else { None };
    let frac =
        |k: u64| if page.n() > 0 { round3(Some(k as f64 / page.n() as f64)) } else { Value::Null };

    let cfg = |k: &str| config.get(k).cloned().unwrap_or(Value::Null);
    Ok(json!({
        "schema": SCHEMA,
        "config": {
            "coordinators": cfg("coordinators"),
            "rate": cfg("rate"),
            "shape_hash": cfg("shape_hash"),
            "seed": cfg("seed"),
            "commit": cfg("commit"),
            "target": cfg("target"),
            "readers": cfg("readers"),
            "duration_s": round3(duration_s),
            "run": Value::Object(config.clone()),
        },
        "files": {"events": events_present, "ops": ops_present, "proc": proc_present},
        "attach_ms": attach.summary(),
        "first_paint_ms": paint.summary(),
        "scroll": {
            "page_ms": page.summary(),
            "pages_per_s": round3(pages_per_s),
            "over_16_7ms": over_60,
            "over_33_3ms": over_30,
            "jank_16_7_frac": frac(over_60),
            "jank_33_3_frac": frac(over_30),
        },
        "typing": {"ack_ms": ack.summary(), "echo_ms": echo.summary()},
        "delivery_ms": delivery.summary(),
        "events": {
            "sent": sent,
            "received": recv,
            "streams": streams.len(),
            "lost": lost,
            "duplicated": dup,
            "late": late,
        },
        "daemon": {
            "samples": daemon_rss.n(),
            "rss_mb": daemon_rss.summary(),
            "peak_rss_mb": round3(if daemon_rss.n() > 0 { Some(peak_rss_kb / 1024.0) } else { None }),
            "baseline_rss_mb": round3(baseline_kb.map(|b| b / 1024.0)),
            "rss_slope_mb_per_min": round3(slope.slope()),
            "cpu_pct": daemon_cpu.summary(),
            "sessions_max": sessions_max,
        },
        "per_chat": {"rss_mb": per_chat_mb.summary(), "cpu_pct": per_chat_cpu.summary()},
        "peak_rss_mb_by_role": role_peak.iter().map(|(k, v)| (k.clone(), round3(Some(v / 1024.0)))).collect::<Map<_, _>>(),
        "bad_lines": bad,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn run_dir(name: &str, run: &str, events: &str, ops: &str, procs: &str) -> std::path::PathBuf {
        let d =
            std::env::temp_dir().join(format!("coord-sim-metrics-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        for (f, s) in [
            ("run.json", run),
            ("events.ndjson", events),
            ("ops.ndjson", ops),
            ("proc.ndjson", procs),
        ] {
            if !s.is_empty() {
                std::fs::write(d.join(f), s).unwrap();
            }
        }
        d
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
    fn stream_counts_lost_dup_and_late_exactly() {
        let mut s = Stream::new(5);
        assert!(!s.see(3)); // history
        for q in [5, 6, 8, 9, 7, 9, 12, 12] {
            s.see(q);
        }
        assert_eq!((s.dup, s.late, s.recv), (2, 1, 8));
        // owed 5..=14: missing 10, 11, 13, 14
        assert_eq!(s.lost(14), 4);
        s.upto = Some(12);
        assert_eq!(s.lost(14), 2);
    }

    #[test]
    fn hole_split_in_the_middle() {
        let mut s = Stream::new(1);
        s.see(1);
        s.see(10); // hole 2..=9
        s.see(5); // splits into 2..=4, 6..=9
        assert_eq!(s.holes, vec![(2, 4), (6, 9)]);
        assert_eq!(s.lost(10), 7);
    }

    #[test]
    fn report_from_a_fixture_run_dir() {
        let run = r#"{"schema":"coord-sim-drive.v1","coordinators":2,"rate":10,"shape_hash":"abc","seed":7,"commit":"deadbeef","target":"acpmux","readers":1}"#;
        let mut ev = String::new();
        ev.push_str("{\"t\":\"attach\",\"c\":0,\"r\":0,\"from_seq\":1,\"at\":1000}\n");
        ev.push_str("{\"t\":\"attach\",\"c\":1,\"r\":0,\"from_seq\":1,\"at\":1000}\n");
        for seq in 1..=100u64 {
            for c in 0..2 {
                ev.push_str(&format!(
                    "{{\"t\":\"sent\",\"c\":{c},\"seq\":{seq},\"at\":{}}}\n",
                    1000 + seq * 10
                ));
                // coordinator 1 loses seq 50 and duplicates seq 60
                if c == 1 && seq == 50 {
                    continue;
                }
                let lat = seq; // 1..100 ms
                let line = format!(
                    "{{\"t\":\"recv\",\"c\":{c},\"r\":0,\"seq\":{seq},\"sent\":{},\"at\":{}}}\n",
                    1000 + seq * 10,
                    1000 + seq * 10 + lat
                );
                ev.push_str(&line);
                if c == 1 && seq == 60 {
                    ev.push_str(&line);
                }
            }
        }
        ev.push_str("{\"t\":\"recv\",\"c\":0,\"r\":0,\"seq\":3,\"sen"); // half a line from a killed driver
        let mut ops = String::new();
        for i in 1..=20u64 {
            ops.push_str(&format!(
                "{{\"op\":\"attach\",\"c\":0,\"r\":0,\"at\":{},\"ms\":{},\"first_paint_ms\":{}}}\n",
                2000 + i,
                i * 10,
                i * 12
            ));
            ops.push_str(&format!(
                "{{\"op\":\"page\",\"c\":0,\"r\":0,\"at\":{},\"ms\":{},\"rows\":50}}\n",
                3000 + i,
                i * 2
            )); // 2..40
            ops.push_str(&format!(
                "{{\"op\":\"prompt\",\"c\":1,\"at\":{},\"ack_ms\":{},\"echo_ms\":{}}}\n",
                4000 + i,
                i,
                i * 3
            ));
        }
        let mut procs = String::new();
        procs.push_str("{\"at\":0,\"role\":\"daemon\",\"pid\":9,\"rss_kb\":102400,\"cpu_ms\":0,\"sessions\":0}\n");
        for m in 1..=10u64 {
            // +10 MB per minute, 4 sessions, 30 % CPU
            procs.push_str(&format!(
                "{{\"at\":{},\"role\":\"daemon\",\"pid\":9,\"rss_kb\":{},\"cpu_ms\":{},\"sessions\":4}}\n",
                m * 60_000,
                102400 + m * 10240,
                m * 18_000
            ));
        }
        procs.push_str("{\"at\":5,\"role\":\"agent\",\"pid\":11,\"rss_kb\":2048}\n");
        let d = run_dir("fixture", run, &ev, &ops, &procs);
        let r = report(&d).unwrap();

        assert_eq!(r["schema"], SCHEMA);
        assert_eq!(r["config"]["coordinators"], 2);
        assert_eq!(r["config"]["commit"], "deadbeef");
        assert_eq!(r["events"]["sent"], 200);
        assert_eq!(r["events"]["lost"], 1);
        assert_eq!(r["events"]["duplicated"], 1);
        assert_eq!(r["bad_lines"]["events"], 1);
        assert_eq!(r["delivery_ms"]["n"], 199);
        let p95 = r["delivery_ms"]["p95"].as_f64().unwrap();
        assert!((p95 - 95.0).abs() < 1.5, "{p95}");
        let a95 = r["attach_ms"]["p95"].as_f64().unwrap();
        assert!((a95 - 190.0).abs() < 2.0, "{a95}");
        assert_eq!(r["first_paint_ms"]["n"], 20);
        // pages 2..40 ms: over 16.7 => 18..40 (12 values); over 33.3 => 34..40 (4)
        assert_eq!(r["scroll"]["over_16_7ms"], 12);
        assert_eq!(r["scroll"]["over_33_3ms"], 4);
        assert_eq!(r["typing"]["echo_ms"]["n"], 20);
        let slope = r["daemon"]["rss_slope_mb_per_min"].as_f64().unwrap();
        assert!((slope - 10.0).abs() < 0.5, "{slope}");
        assert_eq!(r["daemon"]["peak_rss_mb"].as_f64().unwrap(), 200.0);
        assert_eq!(r["daemon"]["baseline_rss_mb"].as_f64().unwrap(), 100.0);
        assert_eq!(r["daemon"]["sessions_max"], 4);
        let cpu = r["daemon"]["cpu_pct"]["p50"].as_f64().unwrap();
        assert!((cpu - 30.0).abs() < 0.5, "{cpu}");
        let pc = r["per_chat"]["cpu_pct"]["p50"].as_f64().unwrap();
        assert!((pc - 7.5).abs() < 0.1, "{pc}");
        // per chat rss: (10..100 MB over baseline) / 4 => median 12.5..13.75
        let pm = r["per_chat"]["rss_mb"]["p50"].as_f64().unwrap();
        assert!((12.0..14.0).contains(&pm), "{pm}");
        assert_eq!(r["peak_rss_mb_by_role"]["agent"].as_f64().unwrap(), 2.0);

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
        let lost = rows.iter().find(|x| x["name"] == "coord_sim.events.lost").unwrap();
        assert_eq!((lost["p95"].as_f64(), lost["target"].as_f64()), (Some(1.0), Some(0.0)));

        // the CLI writes report.json
        super::run(&[d.to_string_lossy().into_owned()]).unwrap();
        let written: Value =
            serde_json::from_str(&std::fs::read_to_string(d.join("report.json")).unwrap()).unwrap();
        assert_eq!(written["events"]["lost"], 1);
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn empty_run_dir_reports_nulls_not_errors() {
        let d = run_dir("empty", "", "", "", "");
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
        // 2M recv lines through one stream: only counters and fixed histograms are kept.
        let d = run_dir("large", "{}", "", "", "");
        let mut f = std::io::BufWriter::new(File::create(d.join("events.ndjson")).unwrap());
        writeln!(f, "{{\"t\":\"attach\",\"c\":0,\"r\":0,\"from_seq\":1,\"at\":0}}").unwrap();
        for seq in 1..=2_000_000u64 {
            writeln!(f, "{{\"t\":\"sent\",\"c\":0,\"seq\":{seq},\"at\":{seq}}}").unwrap();
            writeln!(
                f,
                "{{\"t\":\"recv\",\"c\":0,\"r\":0,\"seq\":{seq},\"sent\":{seq},\"at\":{}}}",
                seq + seq % 7
            )
            .unwrap();
        }
        drop(f);
        let r = report(&d).unwrap();
        assert_eq!(r["events"]["lost"], 0);
        assert_eq!(r["delivery_ms"]["n"], 2_000_000);
        assert_eq!(r["delivery_ms"]["max"].as_f64().unwrap(), 6.0);
        let _ = std::fs::remove_dir_all(&d);
    }
}
