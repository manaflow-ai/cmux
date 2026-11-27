//! One `coord-sim fanin` run: each ramp N on a fresh fleet, its window, its numbers, the summary.

use super::fleet::{self, Daemon, Spawn, aborted};
use super::proc;
use super::rpc::{self, Rpc, now_us};
use super::stats::{r3, ratio, spread_ms};
use serde_json::{Value, json};
use std::collections::{HashMap, VecDeque};
use std::fs::File;
use std::io::{BufWriter, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

pub const TABLE_SCHEMA: &str = "fanin-table.v1";

struct Cfg {
    hosts: usize,
    rate: f64,
    out: PathBuf,
    bin: PathBuf,
    window_s: u64,
    settle_s: u64,
    latency_ms: u64,
    burst_s: u64,
    fanout_rounds: u64,
    agent_hosts: bool,
    attach_workers: usize,
}

fn find_bin(args: &[String]) -> Result<PathBuf, String> {
    if let Some(b) = crate::flag(args, "--acpmux") {
        return Ok(b.into());
    }
    if let Ok(b) = std::env::var("ACPMUX_BIN") {
        return Ok(b.into());
    }
    let path = std::env::var("PATH").unwrap_or_default();
    path.split(':')
        .map(|d| Path::new(d).join("acpmux"))
        .find(|p| p.is_file())
        .ok_or_else(|| "no acpmux binary: pass --acpmux BIN or set ACPMUX_BIN".into())
}

pub fn run(args: &[String]) -> Result<(), String> {
    // The real controller is Leo's: this never starts a fleet there.
    if proc::hostname().contains("cosmic-gray") {
        return Err("refused: fanin starts daemons and sessions, never on cosmic-gray".into());
    }
    let out = PathBuf::from(crate::flag(args, "--out").ok_or("--out RUN_DIR is required")?);
    let sessions: usize = crate::flag_or(args, "--sessions", 2000)?;
    let max_n: usize = crate::flag_or(args, "--max-n", sessions)?;
    let ramps: Vec<usize> = crate::flag(args, "--ramps")
        .unwrap_or("50,200,2000")
        .split(',')
        .filter_map(|r| r.trim().parse().ok())
        .filter(|n| *n > 0 && *n <= sessions.min(max_n))
        .collect();
    if ramps.is_empty() {
        return Err(format!("no ramp at or under --sessions {sessions} / --max-n {max_n}"));
    }
    let cfg = Cfg {
        hosts: crate::flag_or(args, "--hosts", 10usize)?.max(1),
        rate: crate::flag_or(args, "--rate", 1.0 / 3.0)?,
        out: out.clone(),
        bin: find_bin(args)?,
        window_s: crate::flag_or(args, "--window-s", 300)?,
        settle_s: crate::flag_or(args, "--settle-s", 10)?,
        latency_ms: crate::flag_or(args, "--latency-ms", 0)?,
        burst_s: crate::flag_or(args, "--burst-s", 0)?,
        fanout_rounds: crate::flag_or(args, "--fanout-rounds", 3)?,
        agent_hosts: args.iter().any(|a| a == "--agent-hosts"),
        attach_workers: crate::flag_or(args, "--attach-workers", 32usize)?.max(1),
    };
    if cfg.rate <= 0.0 {
        return Err("--rate must be > 0 (events per second per session)".into());
    }
    fleet::private_dir(&out)?;
    fleet::set_state_file(out.join("fanin-state.json"));
    let cap: u64 = crate::flag_or(args, "--wall-clock-cap", 0)?;
    let done = AtomicBool::new(false);
    std::thread::scope(|s| {
        if cap > 0 {
            // The watchdog: past the cap, every daemon still recorded is stopped and the run ends.
            let done = &done;
            s.spawn(move || {
                let until = Instant::now() + Duration::from_secs(cap);
                while Instant::now() < until {
                    if done.load(Ordering::Relaxed) {
                        return;
                    }
                    std::thread::sleep(Duration::from_millis(250));
                }
                fleet::ABORT.store(true, Ordering::Relaxed);
                eprintln!("fanin: wall-clock cap {cap} s passed; tearing down");
                fleet::stop_recorded();
            });
        }
        let r = ramps_run(&cfg, &ramps, &out);
        done.store(true, Ordering::Relaxed);
        r
    })
}

fn ramps_run(cfg: &Cfg, ramps: &[usize], out: &Path) -> Result<(), String> {
    let mut tables = Vec::new();
    for &n in ramps {
        if aborted().is_err() {
            break;
        }
        eprintln!("fanin: ramp {n} sessions on {} hosts", cfg.hosts.min(n));
        let table = match ramp(cfg, n) {
            Ok(t) => t,
            Err(e) => {
                eprintln!("fanin: ramp {n} failed: {e}");
                json!({"schema": TABLE_SCHEMA, "n": n, "error": e})
            }
        };
        println!("FANIN_TABLE {}", table);
        tables.push(table);
    }
    let summary = summarize(cfg, &tables);
    let text = format!("{summary:#}\n");
    std::fs::write(out.join("fanin-summary.json"), &text).map_err(|e| e.to_string())?;
    println!("FANIN_SUMMARY {summary}");
    aborted()
}

/// Every table, and each per-session cost at each N over the first N's.
fn summarize(cfg: &Cfg, tables: &[Value]) -> Value {
    let keys: [(&str, &str); 6] = [
        ("attach_one_p95", "/attach_one_ms/p95"),
        ("attach_p95", "/attach_ms/p95"),
        ("fanin_p95", "/fanin_ms/p95"),
        ("fanout_p95", "/fanout_ms/p95"),
        ("controller_cpu_pct_per_session", "/controller/cpu_pct_per_session"),
        ("controller_rss_kb_per_session", "/controller/rss_kb_per_session"),
    ];
    let base = tables.iter().find(|t| t.get("error").is_none());
    let mut ratios = Vec::new();
    let mut met = true;
    for t in tables {
        let mut row = serde_json::Map::new();
        row.insert("n".into(), t["n"].clone());
        for (name, ptr) in keys {
            let r = ratio(
                t.pointer(ptr).and_then(Value::as_f64),
                base.and_then(|b| b.pointer(ptr)).and_then(Value::as_f64),
            );
            if r.as_f64().is_none_or(|r| r > 1.2) && t["n"] == json!(2000) {
                met = false;
            }
            row.insert(name.into(), r);
        }
        ratios.push(Value::Object(row));
    }
    // Marginal cost between ramps: what each added session costs the controller (constant cost
    // shows as a flat or falling slope; linear-in-N work per session as a rising one).
    let ok: Vec<&Value> = tables.iter().filter(|t| t.get("error").is_none()).collect();
    let slopes: Vec<Value> = ok
        .windows(2)
        .filter_map(|w| {
            let (a, b) = (w.first()?, w.get(1)?);
            let dn = b["n"].as_f64()? - a["n"].as_f64()?;
            let d = |p: &str| Some((b.pointer(p)?.as_f64()? - a.pointer(p)?.as_f64()?) / dn);
            Some(json!({"from": a["n"], "to": b["n"],
                        "rss_kb_per_added_session": d("/controller/rss_kb").map(r3),
                        "cpu_pct_per_added_session": d("/controller/cpu_pct").map(r3)}))
        })
        .collect();
    let reached_2000 = tables.iter().any(|t| t["n"] == json!(2000) && t.get("error").is_none());
    json!({
        "schema": "fanin-summary.v1",
        "hosts": cfg.hosts, "rate_per_session": cfg.rate, "window_s": cfg.window_s,
        "latency_ms": cfg.latency_ms, "agent_hosts": cfg.agent_hosts,
        "machine": proc::machine(),
        "ratio_base_n": base.map(|b| b["n"].clone()),
        "ratios": ratios,
        "controller_slopes": slopes,
        "goal_met_at_2000": reached_2000 && met,
        "tables": tables,
    })
}

/// What the controller's client saw, keyed by session index.
#[derive(Default)]
struct Seen {
    /// (idx, seq) -> (first arrival us, arrivals)
    churn: HashMap<(u64, u64), (u64, u32)>,
    /// (idx, seq) -> the record's `_meta.acpmux.at` (ms) at first arrival: the host daemon's
    /// stamp, which splits a fan-in into the host leg and the link-plus-controller leg.
    churn_at: HashMap<(u64, u64), u64>,
    /// (idx, round) -> (agent receipt us, controller arrival us, arrivals)
    fanout: HashMap<(u64, u64), (u64, u64, u32)>,
    methods: HashMap<String, u64>,
    lagged: u64,
}

/// `key=value` numbers of a `fanin ...` text.
fn fields(text: &str) -> HashMap<&str, u64> {
    text.split_whitespace()
        .filter_map(|w| w.split_once('='))
        .filter_map(|(k, v)| v.parse().ok().map(|v| (k, v)))
        .collect()
}

fn handler(seen: Arc<Mutex<Seen>>) -> rpc::Handler {
    Arc::new(move |at, method, v| {
        let mut s = seen.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        *s.methods.entry(method.to_owned()).or_default() += 1;
        if method == "_acpmux/lagged" {
            s.lagged += v.pointer("/params/dropped").and_then(Value::as_u64).unwrap_or(1);
            return;
        }
        if method != "session/update" {
            return;
        }
        let Some(text) = v.pointer("/params/update/content/text").and_then(Value::as_str) else {
            return;
        };
        if text.starts_with("fanin s=") {
            let f = fields(text);
            if let (Some(i), Some(k)) = (f.get("s"), f.get("k")) {
                let e = s.churn.entry((*i, *k)).or_insert((at, 0));
                e.1 += 1;
                let first = e.1 == 1;
                if first
                    && let Some(mux_at) =
                        v.pointer("/params/_meta/acpmux/at").and_then(Value::as_u64)
                {
                    s.churn_at.insert((*i, *k), mux_at);
                }
            }
        } else if text.starts_with("fanin-rx ") {
            let f = fields(text);
            if let (Some(i), Some(r), Some(t)) = (f.get("s"), f.get("r"), f.get("t")) {
                let e = s.fanout.entry((*i, *r)).or_insert((*t, at, 0));
                e.2 += 1;
            }
        }
    })
}

/// NDJSON writer of one raw file.
struct Nd(BufWriter<File>);

impl Nd {
    fn create(p: &Path) -> Result<Nd, String> {
        File::create(p).map(|f| Nd(BufWriter::new(f))).map_err(|e| format!("{}: {e}", p.display()))
    }
    fn line(&mut self, v: &Value) {
        let _ = writeln!(self.0, "{v}");
    }
}

type Ops = Arc<Mutex<Nd>>;

fn op(
    ops: &Ops,
    name: &str,
    c: u64,
    t0: u64,
    latency_us: u64,
    res: &Result<Value, String>,
    extra: Value,
) {
    let mut l = json!({"op": name, "c": c, "t_us": t0, "latency_us": latency_us,
                       "ok": res.is_ok(), "err": res.as_ref().err()});
    if let (Some(o), Some(x)) = (l.as_object_mut(), extra.as_object()) {
        o.extend(x.clone());
    }
    ops.lock().unwrap_or_else(std::sync::PoisonError::into_inner).line(&l);
}

/// The fleet of one ramp, stopped when it goes out of scope (an error included).
struct Fleet(Vec<Daemon>);

impl Drop for Fleet {
    fn drop(&mut self) {
        fleet::stop_all(&mut self.0);
    }
}

fn name(n_hosts: usize, idx: u64) -> (usize, String) {
    let h = ((idx - 1) as usize) % n_hosts;
    (h, format!("s{idx:05}"))
}

/// Starts the hosts (in parallel) and returns them with their ws ports and peer tokens.
fn start_hosts(
    cfg: &Cfg,
    dir: &Path,
    sock: &Path,
    fanin_dir: &Path,
    h: usize,
) -> Result<Vec<(Daemon, u16, String, String)>, String> {
    let results: Vec<Result<(Daemon, u16, String, String), String>> = std::thread::scope(|s| {
        let handles: Vec<_> = (0..h)
            .map(|i| {
                s.spawn(move || {
                    let port = fleet::free_port()?;
                    let token = fleet::token();
                    let home = dir.join(format!("h{i:02}"));
                    let d = fleet::spawn(Spawn {
                        bin: &cfg.bin,
                        role: "host",
                        name: &format!("h{i:02}"),
                        home: &home,
                        socket: &sock.join(format!("h{i:02}.sock")),
                        fanin_dir,
                        config: json!({"websocket": {"listen": format!("127.0.0.1:{port}"),
                                        "token": token, "tokenRotated": 1}}),
                        agent_hosts: cfg.agent_hosts,
                    })?;
                    let peer = fleet::peer_token(&home)?;
                    Ok((d, port, token, peer))
                })
            })
            .collect();
        handles
            .into_iter()
            .map(|h| h.join().unwrap_or_else(|_| Err("host thread panicked".into())))
            .collect()
    });
    let mut ok = Vec::new();
    let mut first_err = None;
    for r in results {
        match r {
            Ok(x) => ok.push(x),
            Err(e) => first_err = first_err.or(Some(e)),
        }
    }
    match first_err {
        None => Ok(ok),
        Some(e) => {
            let mut ds: Vec<Daemon> = ok.into_iter().map(|x| x.0).collect();
            fleet::stop_all(&mut ds);
            Err(e)
        }
    }
}

/// Creates one host's sessions on its own socket, 16 in flight.
fn create_on_host(
    socket: &Path,
    hi: usize,
    h: usize,
    n: u64,
    fanin_dir: &Path,
    ops: &Ops,
    failed: &std::sync::atomic::AtomicU64,
) {
    type Wait = (u64, u64, Instant, std::sync::mpsc::Receiver<Value>);
    let mine: Vec<u64> = (1..=n).filter(|i| name(h, *i).0 == hi).collect();
    std::thread::scope(|s| {
        let rpc = match Rpc::connect(s, socket, Arc::new(|_, _, _| {})) {
            Ok(r) => r,
            Err(e) => {
                failed.fetch_add(mine.len() as u64, Ordering::Relaxed);
                op(ops, "create", 0, now_us(), 0, &Err(e), json!({"host": hi}));
                return;
            }
        };
        let hello = json!({"protocolVersion": 1, "clientInfo": {"name": "fanin-setup"}});
        let _ = rpc.call("initialize", hello, Duration::from_secs(30));
        let mut q: VecDeque<Wait> = VecDeque::new();
        let finish = |q: &mut VecDeque<Wait>| {
            if let Some((idx, t0, start, rx)) = q.pop_front() {
                let res = rpc::wait(&rx, "session/new", Duration::from_secs(120));
                if res.is_err() {
                    failed.fetch_add(1, Ordering::Relaxed);
                }
                let us = start.elapsed().as_micros() as u64;
                op(ops, "create", idx, t0, us, &res, json!({"host": hi}));
            }
        };
        for idx in mine {
            if aborted().is_err() {
                break;
            }
            let (_, nm) = name(h, idx);
            let cwd = fanin_dir.join("cwd").join(&nm);
            let _ = std::fs::create_dir_all(&cwd);
            let (t0, start) = (now_us(), Instant::now());
            let params = json!({"cwd": cwd, "mcpServers": [], "_meta": {"acpmux": {"name": nm}}});
            match rpc.start("session/new", params) {
                Ok(rx) => q.push_back((idx, t0, start, rx)),
                Err(e) => {
                    failed.fetch_add(1, Ordering::Relaxed);
                    op(ops, "create", idx, t0, 0, &Err(e), json!({"host": hi}));
                }
            }
            if q.len() >= 16 {
                finish(&mut q);
            }
        }
        while !q.is_empty() {
            finish(&mut q);
        }
    });
}

/// Creates every host's sessions, the hosts in parallel; the count that failed.
fn create_sessions(hosts: &[Daemon], n: u64, fanin_dir: &Path, ops: &Ops) -> u64 {
    let h = hosts.len();
    let failed = std::sync::atomic::AtomicU64::new(0);
    std::thread::scope(|s| {
        for (hi, d) in hosts.iter().enumerate() {
            let failed = &failed;
            s.spawn(move || create_on_host(&d.rec.socket, hi, h, n, fanin_dir, ops, failed));
        }
    });
    failed.into_inner()
}

/// One sample line per daemon every 2 s until dropped: RSS from the daemon's own gauges (`_acpmux/status` `gauges.memory.rssBytes`), and how long that status call
/// took. The controller's samples and each host's last are kept for the table.
struct Sampler {
    stop: Arc<AtomicBool>,
    /// (t us, status call us, rss KiB)
    controller: Arc<Mutex<Vec<(u64, u64, u64)>>>,
    /// (host, rss KiB)
    hosts_last: Arc<Mutex<Vec<(String, u64)>>>,
}

impl Drop for Sampler {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
    }
}

/// A daemon the sampler reads: role, name, socket.
type Target = (&'static str, String, PathBuf);
/// (idx, round, latency us, ok) of each fan-out a collector saw.
type FanoutDone = Arc<Mutex<Vec<(u64, u64, u64, bool)>>>;

/// The daemon's resident KiB from its own gauges, and the status call's ms.
/// Also its fan-out gauge (`gauges.fanout`: a window of the last 1024 events, so a 2 s series of
/// it shows a burst the end-of-run reading has forgotten).
fn gauge_rss(rpc: &Rpc) -> (Option<u64>, f64, Value) {
    let t = Instant::now();
    let r = rpc.call("_acpmux/status", json!({}), Duration::from_secs(30));
    let ms = t.elapsed().as_secs_f64() * 1000.0;
    let v = r.ok();
    let kb = v
        .as_ref()
        .and_then(|v| v.pointer("/gauges/memory/rssBytes").and_then(Value::as_u64))
        .map(|b| b / 1024);
    let gauge = |p: &str| v.as_ref().and_then(|v| v.pointer(p)).cloned().unwrap_or(Value::Null);
    // The per-connection feeds and the hub's one notice loop (`gauges.rs`).
    (kb, ms, json!({"fanout": gauge("/gauges/fanout"), "notices": gauge("/gauges/peerNotices")}))
}

fn sampler<'s>(
    s: &'s std::thread::Scope<'s, '_>,
    path: &Path,
    targets: Vec<Target>,
) -> Result<Sampler, String> {
    let mut nd = Nd::create(path)?;
    let stop = Arc::new(AtomicBool::new(false));
    let samples = Arc::new(Mutex::new(Vec::new()));
    let hosts_last = Arc::new(Mutex::new(Vec::new()));
    let (st, sm, hl) = (stop.clone(), samples.clone(), hosts_last.clone());
    let tck = proc::clk_tck();
    s.spawn(move || {
        std::thread::scope(|s2| {
            let conns: Vec<Option<Rpc>> =
                targets.iter().map(|t| Rpc::connect(s2, &t.2, Arc::new(|_, _, _| {})).ok()).collect();
            let mut prev: Option<(u64, u64)> = None;
            while !st.load(Ordering::Relaxed) {
                let mut last = Vec::new();
                for ((role, name, _), conn) in targets.iter().zip(&conns) {
                    let t = now_us();
                    let (rss, status_ms, gauges) =
                        conn.as_ref().map_or((None, 0.0, Value::Null), gauge_rss);
                    nd.line(&json!({"t_us": t, "role": role, "name": name, "rss_kb": rss,
                                    "status_ms": (status_ms * 10.0).round() / 10.0,
                                    "fanout": gauges["fanout"], "notices": gauges["notices"]}));
                    if *role == "daemon" {
                        let st_us = (status_ms * 1000.0) as u64;
                        sm.lock().unwrap_or_else(std::sync::PoisonError::into_inner).push((t, st_us, rss.unwrap_or(0)));
                    } else {
                        last.push((name.clone(), rss.unwrap_or(0)));
                    }
                }
                *hl.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = last;
                let t = now_us();
                let ticks = proc::self_ticks();
                let pct = prev.map(|(pt, pticks)| {
                    let dt = t.saturating_sub(pt) as f64 / 1e6;
                    if dt > 0.0 { ticks.saturating_sub(pticks) as f64 / tck / dt * 100.0 } else { 0.0 }
                });
                prev = Some((t, ticks));
                nd.line(&json!({"t_us": t, "role": "client", "name": "coord-sim", "rss_kb": proc::self_rss_kb(),
                                "cpu_ticks": ticks, "cpu_pct": pct.map(|p| (p * 10.0).round() / 10.0)}));
                let _ = nd.0.flush();
                for _ in 0..20 {
                    if st.load(Ordering::Relaxed) {
                        break;
                    }
                    std::thread::sleep(Duration::from_millis(100));
                }
            }
        });
    });
    Ok(Sampler { stop, controller: samples, hosts_last })
}

/// The whole listing (one read) and the paged one (`limit` 100, following `nextCursor`): ms each,
/// rows, pages.
fn listing(rpc: &Rpc, ops: &Ops) -> (Option<f64>, Option<f64>, u64, u64) {
    let (t0, start) = (now_us(), Instant::now());
    let res = rpc.call("_acpmux/sessions", json!({}), Duration::from_secs(60));
    let whole_us = start.elapsed().as_micros() as u64;
    let rows =
        res.as_ref().ok().and_then(|v| v["sessions"].as_array()).map_or(0, |a| a.len() as u64);
    op(ops, "list", 0, t0, whole_us, &res, json!({"n": rows}));
    let (t1, start) = (now_us(), Instant::now());
    let (mut pages, mut paged_rows, mut cursor, mut ok) = (0u64, 0u64, Value::Null, true);
    while pages < 1000 {
        let mut p = json!({"limit": 100});
        if !cursor.is_null() {
            p["cursor"] = cursor.clone();
        }
        match rpc.call("_acpmux/sessions", p, Duration::from_secs(60)) {
            Ok(v) => {
                pages += 1;
                paged_rows += v["sessions"].as_array().map_or(0, |a| a.len() as u64);
                cursor = v.get("nextCursor").cloned().unwrap_or(Value::Null);
                if cursor.is_null() {
                    break;
                }
            }
            Err(_) => {
                ok = false;
                break;
            }
        }
    }
    let paged_us = start.elapsed().as_micros() as u64;
    let res = if ok { Ok(Value::Null) } else { Err("a page failed".to_owned()) };
    op(ops, "list_paged", 0, t1, paged_us, &res, json!({"n": paged_rows, "pages": pages}));
    (
        Some(whole_us as f64 / 1000.0),
        ok.then_some(paged_us as f64 / 1000.0),
        rows.max(paged_rows),
        pages,
    )
}

fn ramp(cfg: &Cfg, n: usize) -> Result<Value, String> {
    // Every thread of the ramp (clients' readers, sampler, proxies, fan-out collectors) is owned by
    // this scope; the proxies stop once the ramp's daemons are gone.
    let stop = AtomicBool::new(false);
    std::thread::scope(|s| {
        let r = ramp_in(s, cfg, n, &stop);
        stop.store(true, Ordering::Relaxed);
        r
    })
}

/// The controller daemon's resident and peak KiB from its own gauges.
fn gauge_mem(rpc: &Rpc) -> (u64, u64) {
    let st = rpc.call("_acpmux/status", json!({}), Duration::from_secs(30)).unwrap_or(Value::Null);
    let kb = |p: &str| st.pointer(p).and_then(Value::as_u64).map_or(0, |b| b / 1024);
    (kb("/gauges/memory/rssBytes"), kb("/gauges/memory/peakRssBytes"))
}

fn ramp_in<'s>(
    s: &'s std::thread::Scope<'s, '_>,
    cfg: &Cfg,
    n: usize,
    stop: &'s AtomicBool,
) -> Result<Value, String> {
    let h = cfg.hosts.min(n);
    let dir = cfg.out.join(format!("n{n}"));
    let fanin_dir = dir.join("agents");
    let sock = std::env::temp_dir().join(format!("fanin-{}-{n}", std::process::id()));
    for d in [&dir, &fanin_dir.join("tx"), &fanin_dir.join("cwd"), &sock] {
        fleet::private_dir(d)?;
    }
    std::fs::write(fanin_dir.join("ctl"), "0").map_err(|e| e.to_string())?;
    let ops: Ops = Arc::new(Mutex::new(Nd::create(&dir.join("ops.ndjson"))?));
    let mut gaps: Vec<String> = Vec::new();
    let ramp_start = Instant::now();

    // Hosts, then their sessions.
    let hosts = start_hosts(cfg, &dir, &sock, &fanin_dir, h)?;
    let hosts_ms = ramp_start.elapsed().as_millis() as u64;
    let mut fleet_guard = Fleet(Vec::new());
    let mut host_meta = Vec::new();
    for (d, port, token, peer) in hosts {
        host_meta.push((d.rec.name.clone(), d.pid(), port, token, peer, d.rec.socket.clone()));
        fleet_guard.0.push(d);
    }
    let created_at = Instant::now();
    let create_failed = create_sessions(&fleet_guard.0, n as u64, &fanin_dir, &ops);
    let create_ms = created_at.elapsed().as_millis() as u64;
    aborted()?;
    if create_failed > 0 {
        gaps.push(format!("{create_failed} of {n} session/new failed on the hosts"));
    }

    // The controller, its peers the hosts (through the latency proxy when asked).
    let mut peers = serde_json::Map::new();
    for (name, _, port, token, peer, _) in &host_meta {
        let port = if cfg.latency_ms > 0 {
            fleet::proxy(s, *port, Duration::from_millis(cfg.latency_ms), stop)?
        } else {
            *port
        };
        peers.insert(
            name.clone(),
            json!({"url": format!("ws://127.0.0.1:{port}"), "token": token, "peerToken": peer}),
        );
    }
    let ctrl_spawned = Instant::now();
    let ctrl = fleet::spawn(Spawn {
        bin: &cfg.bin,
        role: "controller",
        name: "controller",
        home: &dir.join("controller"),
        socket: &sock.join("ctrl.sock"),
        fanin_dir: &fanin_dir,
        config: json!({"peers": peers}),
        agent_hosts: cfg.agent_hosts,
    })?;
    let ctrl_rec = ctrl.rec.clone();
    let ctrl_pid = ctrl.pid();
    fleet_guard.0.push(ctrl);
    let mut targets: Vec<Target> = vec![("daemon", "controller".into(), ctrl_rec.socket.clone())];
    targets.extend(host_meta.iter().map(|(name, .., sock)| ("host", name.clone(), sock.clone())));
    let samp = sampler(s, &dir.join("proc.ndjson"), targets)?;

    // The app: one client of the controller.
    let seen = Arc::new(Mutex::new(Seen::default()));
    let rpc = Rpc::connect(s, &ctrl_rec.socket, handler(seen.clone()))?;
    rpc.call(
        "initialize",
        json!({"protocolVersion": 1, "clientInfo": {"name": "coord-sim-fanin"}}),
        Duration::from_secs(30),
    )?;
    // The controller's memory with its peers configured, before their sessions are listed.
    let rss_baseline = gauge_mem(&rpc).0;

    // Every peer connected and every session listed.
    let ready_limit = Duration::from_secs(120 + n as u64 / 10);
    let mut ready_ms = None;
    let mut last_status = Value::Null;
    let mut last_dial: Option<Instant> = None;
    while ctrl_spawned.elapsed() < ready_limit {
        aborted()?;
        if let Ok(st) = rpc.call("_acpmux/status", json!({}), Duration::from_secs(30)) {
            let peers = st["peers"].as_array().cloned().unwrap_or_default();
            let connected = peers.iter().filter(|p| p["connected"] == true).count();
            let remote = st["remoteSessions"].as_u64().unwrap_or(0) as usize;
            last_status = json!({"peersConnected": connected, "remoteSessions": remote});
            if connected >= h && remote >= n {
                ready_ms = Some(ctrl_spawned.elapsed().as_millis() as u64);
                break;
            }
            // A peer is dialed when something uses it (acpmux #56640): open one chat on each
            // host not linked yet, as the app does when a person opens a chat there. The
            // controller starts its peers only after serving its first client, so a dial sent
            // right after `initialize` can find no peer to dial: it is asked again every 5 s
            // until that host's link is up. The results do not count; the attach pass measures.
            if last_dial.is_none_or(|at| at.elapsed() >= Duration::from_secs(5)) {
                last_dial = Some(Instant::now());
                let up = |hi: usize| {
                    let host = format!("h{hi:02}");
                    peers.iter().any(|p| p["name"] == host.as_str() && p["connected"] == true)
                };
                std::thread::scope(|s| {
                    for hi in (0..h).filter(|&hi| !up(hi)) {
                        let rpc = &rpc;
                        s.spawn(move || {
                            let (_, nm) = name(h, hi as u64 + 1);
                            let _ = rpc.call(
                                "_acpmux/attach",
                                json!({"sessionId": format!("h{hi:02}/{nm}"), "limit": 0, "waitLogs": false}),
                                Duration::from_secs(30),
                            );
                        });
                    }
                });
            }
        }
        std::thread::sleep(Duration::from_millis(250));
    }
    if ready_ms.is_none() {
        gaps.push(format!("controller not ready in {} s: {last_status}", ready_limit.as_secs()));
    }

    // The fleet listing, at rest.
    let (list_ms, list_paged_ms, list_rows, list_pages) = listing(&rpc, &ops);

    // Attach every session through the controller.
    let attach_samples: Mutex<Vec<f64>> = Mutex::new(Vec::new());
    let attach_errors: Mutex<Vec<String>> = Mutex::new(Vec::new());
    let attach_started = Instant::now();
    std::thread::scope(|s| {
        for w in 0..cfg.attach_workers {
            let (rpc, ops, samples, errors) = (&rpc, &ops, &attach_samples, &attach_errors);
            s.spawn(move || {
                let mut idx = w as u64 + 1;
                while idx <= n as u64 && aborted().is_ok() {
                    let (hi, nm) = name(h, idx);
                    let (t0, start) = (now_us(), Instant::now());
                    let res = rpc.call("_acpmux/attach",
                        json!({"sessionId": format!("h{hi:02}/{nm}"), "limit": 0, "waitLogs": false}),
                        Duration::from_secs(60));
                    let us = start.elapsed().as_micros() as u64;
                    op(ops, "attach", idx, t0, us, &res, json!({}));
                    match res {
                        Ok(_) => samples.lock().unwrap_or_else(std::sync::PoisonError::into_inner).push(us as f64 / 1000.0),
                        Err(e) => errors.lock().unwrap_or_else(std::sync::PoisonError::into_inner).push(e),
                    }
                    idx += cfg.attach_workers as u64;
                }
            });
        }
    });
    let attach_all_ms = attach_started.elapsed().as_millis() as u64;
    let attach_samples = attach_samples.into_inner().unwrap_or_default();
    let attach_errors = attach_errors.into_inner().unwrap_or_default();
    if !attach_errors.is_empty() {
        gaps.push(format!(
            "{} of {n} attaches failed; first: {}",
            attach_errors.len(),
            attach_errors.first().map_or("", String::as_str)
        ));
    }
    aborted()?;

    // Churn, settle, then the window.
    let period_ms = (1000.0 / cfg.rate).round().max(1.0) as u64;
    std::fs::write(fanin_dir.join("ctl"), period_ms.to_string()).map_err(|e| e.to_string())?;
    std::thread::sleep(Duration::from_secs(cfg.settle_s));
    let win_start_us = now_us();
    let win_start = Instant::now();
    let window = Duration::from_secs(cfg.window_s);
    let mut attach_one = Vec::new();
    let mut list_window = Vec::new();
    let mut fanout_sent: Vec<(u64, u64, u64)> = Vec::new(); // (idx, round, sent us)
    let fanout_done: FanoutDone = Arc::new(Mutex::new(Vec::new())); // (idx, round, latency us, ok)
    let mut collectors = Vec::new();
    let mut next_round = 1u64;
    let mut burst_on = false;
    let mut last_attach = Instant::now() - Duration::from_secs(60);
    let mut last_list = Instant::now();
    let one = format!("h00/{}", name(h, 1).1);
    while win_start.elapsed() < window {
        aborted()?;
        let el = win_start.elapsed();
        if last_attach.elapsed() >= Duration::from_secs(5) {
            last_attach = Instant::now();
            let (t0, start) = (now_us(), Instant::now());
            let res = rpc.call(
                "_acpmux/attach",
                json!({"sessionId": one, "limit": 400, "maxBytes": 131072, "waitLogs": false}),
                Duration::from_secs(60),
            );
            let us = start.elapsed().as_micros() as u64;
            let events = res
                .as_ref()
                .ok()
                .and_then(|v| v["events"].as_array())
                .map_or(0, |a| a.len() as u64);
            op(&ops, "attach_one", 1, t0, us, &res, json!({"n": events}));
            if res.is_ok() {
                attach_one.push(us as f64 / 1000.0);
            }
        }
        if last_list.elapsed() >= Duration::from_secs(15) {
            last_list = Instant::now();
            if let (Some(ms), _, _, _) = listing(&rpc, &ops) {
                list_window.push(ms);
            }
        }
        // Fan-out round r at r/(rounds+1) of the window: one prompt to every session at once.
        if next_round <= cfg.fanout_rounds
            && el >= window.mul_f64(next_round as f64 / (cfg.fanout_rounds + 1) as f64)
        {
            let round = next_round;
            next_round += 1;
            let mut rxs = Vec::new();
            for idx in 1..=n as u64 {
                let (hi, nm) = name(h, idx);
                let sent = now_us();
                let started = Instant::now();
                match rpc.start(
                    "session/prompt",
                    json!({"sessionId": format!("h{hi:02}/{nm}"),
                    "prompt": [{"type": "text", "text": format!("fanout r={round}")}]}),
                ) {
                    Ok(rx) => rxs.push((idx, started, rx)),
                    Err(e) => op(&ops, "prompt", idx, sent, 0, &Err(e), json!({"round": round})),
                }
                fanout_sent.push((idx, round, sent));
            }
            let (ops2, done) = (ops.clone(), fanout_done.clone());
            collectors.push(s.spawn(move || {
                let deadline = Instant::now() + Duration::from_secs(180);
                for (idx, started, rx) in rxs {
                    let left = deadline
                        .saturating_duration_since(Instant::now())
                        .max(Duration::from_millis(1));
                    let res = rpc::wait(&rx, "session/prompt", left);
                    let us = started.elapsed().as_micros() as u64;
                    op(&ops2, "prompt", idx, 0, us, &res, json!({"round": round}));
                    done.lock().unwrap_or_else(std::sync::PoisonError::into_inner).push((
                        idx,
                        round,
                        us,
                        res.is_ok(),
                    ));
                }
            }));
        }
        if cfg.burst_s > 0 && !burst_on && el + Duration::from_secs(cfg.burst_s) >= window {
            burst_on = true;
            let burst = (period_ms / 10).max(1);
            std::fs::write(fanin_dir.join("ctl"), burst.to_string()).map_err(|e| e.to_string())?;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    let win_s = win_start.elapsed().as_secs_f64();
    let win_end_us = now_us();
    let rss_end = gauge_mem(&rpc);
    std::fs::write(fanin_dir.join("ctl"), "0").map_err(|e| e.to_string())?;
    // In-flight events land.
    std::thread::sleep(Duration::from_secs(10));
    for c in collectors {
        let _ = c.join();
    }
    let gauges = fleet::status_json(&ctrl_rec);
    let hosts_last =
        samp.hosts_last.lock().unwrap_or_else(std::sync::PoisonError::into_inner).clone();
    let ctrl_samples =
        samp.controller.lock().unwrap_or_else(std::sync::PoisonError::into_inner).clone();
    drop(samp);

    // Raw events: every churn event emitted in the window, and every fan-out prompt.
    let seen = std::mem::take(&mut *seen.lock().unwrap_or_else(std::sync::PoisonError::into_inner));
    let mut ev = Nd::create(&dir.join("events.ndjson"))?;
    let (mut fanin, mut emitted, mut lost, mut dup) = (Vec::new(), 0u64, 0u64, 0u64);
    for idx in 1..=n as u64 {
        let p = fanin_dir.join("tx").join(format!("s{idx:05}.tx"));
        let Ok(text) = std::fs::read_to_string(&p) else { continue };
        for l in text.lines() {
            let mut it = l.split_whitespace().filter_map(|x| x.parse::<u64>().ok());
            let (Some(seq), Some(t)) = (it.next(), it.next()) else { continue };
            if t < win_start_us || t > win_end_us {
                continue;
            }
            emitted += 1;
            let got = seen.churn.get(&(idx, seq));
            match got {
                Some((at, k)) => {
                    fanin.push(at.saturating_sub(t) as f64 / 1000.0);
                    dup += u64::from(k.saturating_sub(1));
                }
                None => lost += 1,
            }
            ev.line(&json!({"c": idx, "seq": seq, "src": "agent", "emit_us": t, "daemon_n": 1,
                            "reader_us": got.map(|g| g.0), "reader_n": got.map_or(0, |g| g.1),
                            "mux_at_ms": seen.churn_at.get(&(idx, seq))}));
        }
    }
    let (mut fanout, mut fanout_back, mut fanout_lost, mut fanout_dup) =
        (Vec::new(), Vec::new(), 0u64, 0u64);
    for (idx, round, sent) in &fanout_sent {
        let got = seen.fanout.get(&(*idx, *round));
        match got {
            Some((rx, back, k)) => {
                fanout.push(rx.saturating_sub(*sent) as f64 / 1000.0);
                fanout_back.push(back.saturating_sub(*sent) as f64 / 1000.0);
                fanout_dup += u64::from(k.saturating_sub(1));
            }
            None => fanout_lost += 1,
        }
        ev.line(&json!({"c": idx, "seq": round, "src": "turn", "emit_us": sent, "daemon_n": 1,
                        "reader_us": got.map(|g| g.0), "reader_n": got.map_or(0, |g| g.2)}));
    }
    let _ = ev.0.flush();
    let done = fanout_done.lock().unwrap_or_else(std::sync::PoisonError::into_inner).clone();
    let prompt_ms: Vec<f64> = done.iter().filter(|d| d.3).map(|d| d.2 as f64 / 1000.0).collect();
    let prompt_failed = done.iter().filter(|d| !d.3).count();
    if prompt_failed > 0 {
        gaps.push(format!("{prompt_failed} of {} fan-out prompts failed or timed out", done.len()));
    }
    if emitted > 0 && lost * 100 > emitted {
        gaps.push(format!(
            "{lost} of {emitted} churn events never reached the controller's client"
        ));
    }
    if seen.lagged > 0 {
        gaps.push(format!(
            "client lagged: {} notices dropped by the controller's fan-out",
            seen.lagged
        ));
    }

    // Controller cost over the window.
    let tck = proc::clk_tck();
    // The controller's CPU over its whole life (acpmux has no CPU gauge): reaped-children ticks
    // across its reap. Then the hosts, together.
    let life_s = ctrl_spawned.elapsed().as_secs_f64();
    let ctrl_cpu_s = match fleet_guard.0.pop() {
        Some(d) if d.pid() == ctrl_pid => d.stop_measured(tck),
        Some(other) => {
            fleet_guard.0.push(other);
            0.0
        }
        None => 0.0,
    };
    let hosts_cpu_s = fleet::stop_all(&mut fleet_guard.0) / tck;
    let cpu_pct = if life_s > 0.0 { ctrl_cpu_s / life_s * 100.0 } else { 0.0 };
    let rss_max =
        ctrl_samples.iter().filter(|s| s.0 >= win_start_us).map(|s| s.2).max().unwrap_or(rss_end.0);
    let rss_per = rss_end.0.saturating_sub(rss_baseline) as f64 / n as f64;
    let host_rss: Vec<f64> = hosts_last.iter().map(|x| x.1 as f64).collect();
    let g = |p: &str| gauges.pointer(p).cloned().unwrap_or(Value::Null);

    let run = json!({"schema": "coord-sim-fanin.v1", "coordinators": n, "rate": cfg.rate, "readers": 1,
                     "run_s": cfg.window_s, "hosts": h, "latency_ms": cfg.latency_ms});
    std::fs::write(dir.join("run.json"), format!("{run:#}\n")).map_err(|e| e.to_string())?;
    let table = json!({
        "schema": TABLE_SCHEMA,
        "n": n, "hosts": h, "rate_per_session": cfg.rate, "window_s": r3(win_s),
        "latency_ms": cfg.latency_ms, "agent_hosts": cfg.agent_hosts,
        "setup_ms": {"hosts": hosts_ms, "create": create_ms, "controller_ready": ready_ms,
                     "attach_all": attach_all_ms},
        "create_failed": create_failed,
        "attach_ms": spread_ms(&attach_samples), "attach_failed": attach_errors.len(),
        "attach_one_ms": spread_ms(&attach_one),
        "list": {"whole_ms_at_rest": list_ms.map(r3), "paged_ms_at_rest": list_paged_ms.map(r3),
                 "rows": list_rows, "pages": list_pages, "whole_ms_window": spread_ms(&list_window)},
        "fanin_ms": spread_ms(&fanin),
        "fanout_ms": spread_ms(&fanout), "fanout_back_ms": spread_ms(&fanout_back),
        "prompt_ms": spread_ms(&prompt_ms),
        "events": {"emitted": emitted, "lost": lost, "dup": dup,
                   "fanout_sent": fanout_sent.len(), "fanout_lost": fanout_lost, "fanout_dup": fanout_dup,
                   "client_lagged": seen.lagged},
        "controller": {"cpu_pct": r3(cpu_pct), "cpu_pct_per_session": r3(cpu_pct / n as f64),
                       "cpu_s_life": r3(ctrl_cpu_s), "life_s": r3(life_s), "cpu_basis": "whole life",
                       "hosts_cpu_s_life": r3(hosts_cpu_s),
                       "rss_kb_baseline": rss_baseline, "rss_kb": rss_end.0, "rss_kb_window_max": rss_max,
                       "rss_kb_peak": rss_end.1, "rss_kb_per_session": r3(rss_per)},
        "hosts_rss_kb": {"mean": host_rss.iter().sum::<f64>().max(0.0) / host_rss.len().max(1) as f64,
                         "max": host_rss.iter().copied().fold(0.0, f64::max)},
        "gauges": {"attach_p95_ms": g("/gauges/attach/p95Ms"), "fanout_p95_ms": g("/gauges/fanout/p95Ms")},
        "client_methods": seen.methods,
        "gaps": gaps,
    });
    std::fs::write(dir.join("fanin-table.json"), format!("{table:#}\n"))
        .map_err(|e| e.to_string())?;
    std::fs::write(dir.join("controller-status.json"), format!("{gauges:#}\n"))
        .map_err(|e| e.to_string())?;
    drop(rpc);
    drop(fleet_guard);
    let _ = std::fs::remove_dir_all(&sock);
    Ok(table)
}

#[cfg(test)]
#[path = "ramp_tests.rs"]
mod tests;
