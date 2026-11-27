#![cfg(unix)]
//! Daemon socket round-trip bench: the time a frontend waits for one control
//! request to the real cmux-tui server over its local socket, the hop every
//! app and webview action takes.
//!
//! It starts the real server (`server::serve`) on a temp socket, keeps an
//! app-like subscriber attached (`subscribe` with tree events, drained on its
//! own thread), and times five calls a frontend makes most:
//!
//! - `ping`: transport and dispatch alone, the floor;
//! - `identify`: the connect-time handshake read;
//! - `list-workspaces`: the full state read every tree refresh makes;
//! - `send`: terminal input, written to a pty;
//! - `select-workspace`: a layout mutation that fans a tree change out.
//!
//! Every call runs at 1 and 30 workspaces, each under three loads: `idle`;
//! `stream50`, 50 terminals each printing 100 lines a second; and
//! `clients8`, 8 other connections calling `list-workspaces` back to back.
//! The bar is constant cost at scale, so the bench also reports each call's
//! 30 vs 1 workspace p50 ratio.
//!
//! It asserts only that every reply is ok; the numbers are a report. Rows
//! use the perf cron row shape (`{"p50","p95","unit","budget","floor"}`, plus
//! `p99`, `max` and `n`), printed as one `DAEMON-SOCKET-RTT {json}` line and
//! written to `$CMUX_DAEMON_SOCKET_RTT_OUT` and `$FAST_CHECKS_OUT/daemon-socket-rtt.json`
//! when set.
//!
//! cargo test -p cmux-tui-core --release --test daemon_socket_rtt -- --ignored --nocapture
//!
//! Knobs: `CMUX_RTT_SAMPLES` (default 2000 per call and scenario),
//! `CMUX_RTT_STREAMS` (default 50), `CMUX_RTT_CLIENTS` (default 8).

mod support;

use anyhow::{Context, Result, anyhow, bail};
use cmux_tui_core::{Mux, SurfaceId, SurfaceOptions, server};
use serde_json::{Map, Value, json};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};
use support::DaemonMuxOps;

const WARMUP: usize = 100;
const WORKSPACE_COUNTS: [usize; 2] = [1, 30];
/// Ten lines every 100 ms (one `sleep` fork per tick, not per line).
const STREAM_LINE: &str = "while :; do i=0; while [ $i -lt 10 ]; do echo 'rtt-bench streaming output line, eighty columns of text to parse ......'; i=$((i+1)); done; sleep 0.1; done";
/// The p95 a frontend round trip should stay under (report-only).
const BUDGET_P95_US: f64 = 1000.0;
/// The noise floor for comparing two readings of a row.
const FLOOR_US: f64 = 50.0;
/// Constant cost at scale: 30 workspaces may cost at most this times 1.
const SCALE_BUDGET: f64 = 1.5;

fn env_usize(name: &str, default: usize) -> usize {
    std::env::var(name).ok().and_then(|v| v.parse().ok()).filter(|v| *v > 0).unwrap_or(default)
}

struct Client {
    reader: BufReader<UnixStream>,
    writer: UnixStream,
    next_id: u64,
}

impl Client {
    fn connect(path: &Path) -> Result<Self> {
        let stream = UnixStream::connect(path).context("connect daemon socket")?;
        stream.set_read_timeout(Some(Duration::from_secs(20)))?;
        let writer = stream.try_clone()?;
        Ok(Self { reader: BufReader::new(stream), writer, next_id: 1 })
    }

    /// One request and its reply; events pushed in between are skipped.
    fn rpc(&mut self, mut request: Value) -> Result<Value> {
        let id = self.next_id;
        self.next_id += 1;
        if let Some(object) = request.as_object_mut() {
            object.insert("id".to_string(), json!(id));
        }
        let mut line = request.to_string();
        line.push('\n');
        self.writer.write_all(line.as_bytes())?;
        let mut buf = String::new();
        loop {
            buf.clear();
            if self.reader.read_line(&mut buf)? == 0 {
                bail!("daemon closed the socket");
            }
            let reply: Value = serde_json::from_str(&buf)?;
            if reply.get("id").and_then(Value::as_u64) == Some(id) {
                if reply.get("ok") != Some(&Value::Bool(true)) {
                    bail!("request {request} failed: {reply}");
                }
                return Ok(reply);
            }
        }
    }
}

/// Keeps a connection subscribed and drains what it is pushed, as the app does.
struct Subscriber {
    stop: Arc<AtomicBool>,
    events: Arc<AtomicU64>,
    thread: Option<JoinHandle<()>>,
}

impl Subscriber {
    fn start(path: &Path) -> Result<Self> {
        let mut client = Client::connect(path)?;
        client.rpc(json!({"cmd": "subscribe", "tree_events": "coarse"}))?;
        client.reader.get_ref().set_read_timeout(Some(Duration::from_millis(100)))?;
        let stop = Arc::new(AtomicBool::new(false));
        let events = Arc::new(AtomicU64::new(0));
        let (flag, count) = (stop.clone(), events.clone());
        let thread = std::thread::spawn(move || {
            let mut buf = String::new();
            while !flag.load(Ordering::Relaxed) {
                buf.clear();
                match client.reader.read_line(&mut buf) {
                    Ok(0) => break,
                    Ok(_) => {
                        count.fetch_add(1, Ordering::Relaxed);
                    }
                    Err(_) => continue,
                }
            }
        });
        Ok(Self { stop, events, thread: Some(thread) })
    }
}

impl Drop for Subscriber {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

/// `clients8`: other connections calling `list-workspaces` back to back.
struct Hammer {
    stop: Arc<AtomicBool>,
    calls: Arc<AtomicU64>,
    threads: Vec<JoinHandle<Result<()>>>,
}

impl Hammer {
    fn start(path: &Path, clients: usize) -> Result<Self> {
        let stop = Arc::new(AtomicBool::new(false));
        let calls = Arc::new(AtomicU64::new(0));
        let mut threads = Vec::new();
        for _ in 0..clients {
            let mut client = Client::connect(path)?;
            let (flag, count) = (stop.clone(), calls.clone());
            threads.push(std::thread::spawn(move || {
                while !flag.load(Ordering::Relaxed) {
                    client.rpc(json!({"cmd": "list-workspaces"}))?;
                    count.fetch_add(1, Ordering::Relaxed);
                }
                Ok(())
            }));
        }
        Ok(Self { stop, calls, threads })
    }

    fn finish(mut self) -> Result<u64> {
        self.stop.store(true, Ordering::Relaxed);
        for thread in self.threads.drain(..) {
            thread.join().map_err(|_| anyhow!("hammer thread panicked"))??;
        }
        Ok(self.calls.load(Ordering::Relaxed))
    }
}

struct Daemon {
    mux: Arc<Mux>,
    socket: PathBuf,
    /// The `cat` terminal `send` writes to.
    send_target: Value,
    /// Every terminal the bench made, closed when it ends.
    surfaces: Vec<SurfaceId>,
}

impl Drop for Daemon {
    fn drop(&mut self) {
        for surface in self.surfaces.drain(..) {
            let _ = self.mux.close_surface(surface);
        }
    }
}

fn start_daemon(workspaces: usize) -> Result<Daemon> {
    let name = format!("rtt-{}-{workspaces}", std::process::id());
    // Every terminal is a `cat` that drains its input, so `send` never fills a pty.
    let options = SurfaceOptions {
        command: Some(vec!["/bin/sh".into(), "-c".into(), "exec cat >/dev/null".into()]),
        ..Default::default()
    };
    let mux = Mux::new(name.as_str(), options);
    let socket = std::env::temp_dir().join(name).join("s.sock");
    server::serve(mux.clone(), Some(socket.clone()))?;
    let mut surfaces = Vec::with_capacity(workspaces);
    for _ in 0..workspaces {
        surfaces.push(mux.new_workspace(None, Some((80, 24)))?.id);
    }
    let first = surfaces.first().copied().context("no workspace")?;
    let send_target = serde_json::to_value(first)?;
    Ok(Daemon { mux, socket, send_target, surfaces })
}

/// `stream50`: terminals in the active workspace, each printing 100 lines a second.
fn start_streams(daemon: &mut Daemon, count: usize) -> Result<()> {
    for _ in 0..count {
        let argv = vec!["/bin/sh".to_string(), "-c".to_string(), STREAM_LINE.to_string()];
        let placed =
            daemon.mux.run_command_surface(argv, None, false, None, None, Some((80, 24)))?;
        daemon.surfaces.push(placed.surface);
    }
    Ok(())
}

fn calls(send_target: &Value) -> Vec<(&'static str, Value)> {
    vec![
        ("ping", json!({"cmd": "ping"})),
        ("identify", json!({"cmd": "identify"})),
        ("list_workspaces", json!({"cmd": "list-workspaces"})),
        ("send", json!({"cmd": "send", "surface": send_target, "text": "rtt\r"})),
        ("select_workspace", json!({"cmd": "select-workspace", "delta": 1})),
    ]
}

struct Stats {
    p50: f64,
    p95: f64,
    p99: f64,
    max: f64,
    n: usize,
}

fn percentile(sorted: &[u64], q: f64) -> f64 {
    let last = sorted.len().saturating_sub(1);
    let rank = ((last as f64) * q).round() as usize;
    sorted.get(rank.min(last)).map_or(0.0, |ns| (*ns as f64 / 100.0).round() / 10.0)
}

fn stats(mut samples_ns: Vec<u64>) -> Stats {
    samples_ns.sort_unstable();
    Stats {
        p50: percentile(&samples_ns, 0.50),
        p95: percentile(&samples_ns, 0.95),
        p99: percentile(&samples_ns, 0.99),
        max: percentile(&samples_ns, 1.0),
        n: samples_ns.len(),
    }
}

fn measure(client: &mut Client, request: &Value, samples: usize) -> Result<Stats> {
    for _ in 0..WARMUP {
        client.rpc(request.clone())?;
    }
    let mut out = Vec::with_capacity(samples);
    for _ in 0..samples {
        let request = request.clone();
        let start = Instant::now();
        client.rpc(request)?;
        out.push(u64::try_from(start.elapsed().as_nanos()).unwrap_or(u64::MAX));
    }
    Ok(stats(out))
}

fn row(stats: &Stats) -> Value {
    json!({
        "p50": stats.p50, "p95": stats.p95, "p99": stats.p99, "max": stats.max, "n": stats.n,
        "unit": "us", "budget": BUDGET_P95_US, "floor": FLOOR_US,
    })
}

/// Runs one daemon at `workspaces` through every load; returns its rows.
fn run_scale(
    workspaces: usize,
    samples: usize,
    streams: usize,
    clients: usize,
) -> Result<Map<String, Value>> {
    let mut daemon = start_daemon(workspaces)?;
    let subscriber = Subscriber::start(&daemon.socket)?;
    let mut client = Client::connect(&daemon.socket)?;
    let calls = calls(&daemon.send_target);
    let mut rows = Map::new();
    let mut table = Vec::new();
    for load in ["idle", "clients8", "stream50"] {
        let hammer = match load {
            "clients8" => Some(Hammer::start(&daemon.socket, clients)?),
            "stream50" => {
                start_streams(&mut daemon, streams)?;
                std::thread::sleep(Duration::from_millis(500));
                None
            }
            _ => None,
        };
        let events_before = subscriber.events.load(Ordering::Relaxed);
        let started = Instant::now();
        for (name, request) in &calls {
            let s = measure(&mut client, request, samples)?;
            table.push(format!(
                "{workspaces:>3} ws  {load:<9} {name:<17} p50 {:>8.1}  p95 {:>8.1}  p99 {:>8.1}  max {:>9.1} us",
                s.p50, s.p95, s.p99, s.max
            ));
            rows.insert(format!("daemon_socket.{name}.{load}.ws{workspaces}"), row(&s));
        }
        let secs = started.elapsed().as_secs_f64().max(1e-9);
        let pushed = subscriber.events.load(Ordering::Relaxed) - events_before;
        let background = match hammer {
            Some(h) => format!(", background list-workspaces {:.0}/s", h.finish()? as f64 / secs),
            None => String::new(),
        };
        table.push(format!(
            "{workspaces:>3} ws  {load:<9} subscriber events {:.0}/s{background}",
            pushed as f64 / secs
        ));
    }
    drop(subscriber);
    for line in table {
        println!("{line}");
    }
    Ok(rows)
}

#[test]
#[ignore = "bench: cargo test -p cmux-tui-core --release --test daemon_socket_rtt -- --ignored --nocapture"]
fn daemon_socket_round_trip() -> Result<()> {
    let samples = env_usize("CMUX_RTT_SAMPLES", 2000);
    let streams = env_usize("CMUX_RTT_STREAMS", 50);
    let clients = env_usize("CMUX_RTT_CLIENTS", 8);
    let mut rows = Map::new();
    for workspaces in WORKSPACE_COUNTS {
        rows.extend(run_scale(workspaces, samples, streams, clients)?);
    }
    // Constant cost at scale: each call's 30 vs 1 workspace p50, per load.
    let mut ratios = Map::new();
    for (key, value) in &rows {
        let Some(base) = key.strip_suffix(".ws1") else { continue };
        let at = |k: &str| rows.get(k).and_then(|r| r.get("p50")).and_then(Value::as_f64);
        if let (Some(one), Some(thirty)) =
            (value.get("p50").and_then(Value::as_f64), at(&format!("{base}.ws30")))
        {
            let ratio = (thirty / one.max(0.1) * 100.0).round() / 100.0;
            println!("scale {base}: p50 {one:.1} -> {thirty:.1} us at 30 workspaces ({ratio}x)");
            ratios.insert(
                format!("{base}.scale_30_vs_1"),
                json!({"p50": ratio, "p95": ratio, "unit": "x", "budget": SCALE_BUDGET, "floor": 0.25}),
            );
        }
    }
    rows.extend(ratios);
    let report = json!({
        "bench": "daemon-socket-rtt",
        "version": 1,
        "samples": samples,
        "streams": streams,
        "clients": clients,
        "cpus": std::thread::available_parallelism().map_or(0, |n| n.get()),
        "rows": rows,
    });
    println!("DAEMON-SOCKET-RTT {report}");
    let body = serde_json::to_vec_pretty(&report)?;
    if let Ok(path) = std::env::var("CMUX_DAEMON_SOCKET_RTT_OUT") {
        std::fs::write(&path, &body).with_context(|| format!("write {path}"))?;
    }
    // cmux-ci keeps what a command writes to $FAST_CHECKS_OUT as the run's artifact.
    if let Ok(dir) = std::env::var("FAST_CHECKS_OUT") {
        let path = Path::new(&dir).join("daemon-socket-rtt.json");
        std::fs::write(&path, &body).with_context(|| format!("write {}", path.display()))?;
    }
    Ok(())
}
