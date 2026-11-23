//! `coord-sim surface --target relay`: N coordinators' live records through a real `cmux-relay` on this host.
//!
//! The relay is the self-hosted server (cmux-tui/crates/cmux-relay), started in open mode on a free port. Each
//! coordinator is one slot: a publisher registers it as the daemon would (Register, then Join on each Incoming) and
//! a subscriber connects as a phone would (Connect, Allocated, Join, Ready). The relay forwards opaque binary frames
//! and keeps no history, so resume is end to end as in cmux-remote: the subscriber's first frame on a circuit names
//! the next record it wants, and the publisher sends from there. A record larger than a frame goes in parts of at
//! most `--frame-bytes` (the relay's limit is 64 KiB, as the Noise transport's).
//!
//! The reconnect storm (`--storms K --storm-every S`): every S seconds all subscribers drop their circuits at once
//! and reconnect, as a fleet of phones changing networks does.
//!
//! Measured, into RUN_DIR/relay/: samples.ndjson (one line per delivered record, per reconnect, per relay sample)
//! and summary.json (schema coord-sim-surface.v1):
//!   latency_us    publisher's send of the record's first part to the subscriber's read of its last part
//!   delay_us      the record's scheduled time to its delivery (adds the publisher's backlog and any outage)
//!   lost / dup    records skipped or seen twice by a subscriber (resume makes both 0 unless the relay drops frames)
//!   reconnect_ms  a subscriber's Connect to Ready; unplanned_drops: circuits the relay closed with no storm
//!   relay_peak_rss_mb, relay_cpu_s, relay_cpu_pct  the relay's peak RSS and CPU over the run (getrusage of
//!                 the reaped child: no process scan)

use super::records::{self, Plan};
use super::ws::{Frame, Ws};
use crate::shape::Shape;
use cmux_process::{Child, Command, Stdio};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

const PROTOCOL: u8 = 5;
const HEADER: usize = 8 + 2 + 2 + 8 + 8;

/// The relay process, ended with its handle (cmux_process::Child signals and reaps it on drop).
fn start_relay(bin: &str) -> Result<Child, String> {
    Command::new(bin)
        .args([
            "--allow-open",
            "--bind",
            "127.0.0.1:0",
            "--control-idle-timeout-seconds",
            "3600",
            "--idle-timeout-seconds",
            "3600",
            "--max-allocations-per-second-per-slot",
            "1000",
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("{bin}: {e}"))
}

fn control(ws: &mut Ws, value: Value) -> Result<(), String> {
    ws.send_text(&value.to_string())
}

fn read_control(ws: &mut Ws) -> Result<Value, String> {
    loop {
        match ws.read()? {
            Frame::Text(t) => {
                let v: Value = serde_json::from_str(&t).map_err(|e| format!("control: {e}"))?;
                if v["type"] == "error" {
                    return Err(format!("relay error: {v}"));
                }
                return Ok(v);
            }
            Frame::Binary(_) => continue,
            Frame::Closed => return Err("control: closed".into()),
        }
    }
}

fn now_us(epoch: Instant) -> u64 {
    epoch.elapsed().as_micros() as u64
}

/// One record ready to send: its scheduled offset (us from the start) and its bytes.
struct Item {
    at_us: u64,
    bytes: Vec<u8>,
}

enum Sample {
    Delivery { coord: u32, idx: u64, bytes: usize, latency_us: u64, delay_us: u64 },
    Reconnect { coord: u32, ms: f64, planned: bool },
    Relay { at_ms: u64, rss_kb: u64, cpu_ms: u64 },
}

struct Shared {
    epoch: Instant,
    addr: String,
    frame_bytes: usize,
    done: AtomicBool,
    storms: AtomicU64,
}

fn publisher(sh: Arc<Shared>, coord: u32, items: Arc<Vec<Item>>) -> Result<(), String> {
    let slot = format!("coord-sim-{coord}");
    let mut ctl = Ws::connect(&sh.addr, "/v1/relay", 0x1000 + coord as u64)?;
    control(
        &mut ctl,
        json!({ "type": "register", "protocol": PROTOCOL, "slot": slot, "ticket": "coord-sim" }),
    )?;
    let reg = read_control(&mut ctl)?;
    if reg["type"] != "registered" {
        return Err(format!("register: {reg}"));
    }
    ctl.set_read_timeout(Some(Duration::from_secs(1)))?;
    // The registration lasts `lease_seconds` unless renewed: a ping every third of it, as the real daemon does
    // (cmux-remote's `registration_liveness`). Without it the slot goes offline mid-run and a reconnect is refused.
    let lease = reg["lease_seconds"].as_u64().unwrap_or(30);
    let heartbeat = Duration::from_secs((lease / 3).max(1));
    let mut pinger = ctl.try_clone()?;
    let stop = AtomicBool::new(false);
    thread::scope(|beat| {
        beat.spawn(|| {
            let mut nonce = 0u64;
            let mut last = Instant::now();
            while !stop.load(Ordering::Relaxed) && !sh.done.load(Ordering::Relaxed) {
                thread::sleep(Duration::from_millis(100));
                if last.elapsed() >= heartbeat {
                    nonce += 1;
                    last = Instant::now();
                    if pinger
                        .send_text(&json!({ "type": "ping", "nonce": nonce }).to_string())
                        .is_err()
                    {
                        break;
                    }
                }
            }
        });
        let served = serve_circuits(&sh, coord, &slot, &items, &mut ctl);
        stop.store(true, Ordering::Relaxed);
        served
    })?;
    ctl.close();
    Ok(())
}

/// Joins every circuit the relay offers this publisher's slot and sends it the records from the index it asks for.
fn serve_circuits(
    sh: &Shared,
    coord: u32,
    slot: &str,
    items: &[Item],
    ctl: &mut Ws,
) -> Result<(), String> {
    let mut circuits = 0u64;
    while !sh.done.load(Ordering::Relaxed) {
        let incoming = match read_control(ctl) {
            Ok(v) => v,
            Err(e)
                if e.contains("timed out")
                    || e.contains("would block")
                    || e.contains("Resource temporarily") =>
            {
                continue;
            }
            Err(e) => return Err(e),
        };
        if incoming["type"] != "incoming" {
            continue;
        }
        circuits += 1;
        let mut c = Ws::connect(&sh.addr, "/v1/relay", 0x2000 + coord as u64 * 1000 + circuits)?;
        control(
            &mut c,
            json!({
                "type": "join", "protocol": PROTOCOL, "slot": slot, "circuit": incoming["circuit"], "lane": incoming["lane"],
                "generation": incoming["generation"], "ticket": incoming["join_ticket"], "role": "daemon",
            }),
        )?;
        let ready = match read_control(&mut c) {
            Ok(v) => v,
            Err(_) => continue,
        };
        if ready["type"] != "ready" {
            continue;
        }
        let from = match c.read() {
            Ok(Frame::Binary(b)) if b.len() >= 8 => {
                u64::from_be_bytes(b.get(..8).and_then(|h| h.try_into().ok()).ok_or("resume")?)
            }
            _ => continue,
        };
        // A reader on the circuit notices the relay closing it while this thread writes.
        let closed = AtomicBool::new(false);
        let mut reader = c.try_clone()?;
        reader.set_read_timeout(None)?;
        thread::scope(|circuit| {
            circuit.spawn(|| {
                while let Ok(Frame::Binary(_) | Frame::Text(_)) = reader.read() {}
                closed.store(true, Ordering::Relaxed);
            });
            for (idx, item) in items.iter().enumerate().skip(from as usize) {
                if closed.load(Ordering::Relaxed) || sh.done.load(Ordering::Relaxed) {
                    break;
                }
                let now = now_us(sh.epoch);
                if item.at_us > now {
                    thread::sleep(Duration::from_micros(item.at_us - now));
                }
                let sent = now_us(sh.epoch);
                let chunk = sh.frame_bytes.saturating_sub(HEADER).max(1);
                let parts = item.bytes.len().div_ceil(chunk).max(1);
                let mut failed = false;
                for p in 0..parts {
                    let body = item
                        .bytes
                        .get(p * chunk..((p + 1) * chunk).min(item.bytes.len()))
                        .unwrap_or(&[]);
                    let mut frame = Vec::with_capacity(HEADER + body.len());
                    frame.extend_from_slice(&(idx as u64).to_be_bytes());
                    frame.extend_from_slice(&(p as u16).to_be_bytes());
                    frame.extend_from_slice(&(parts as u16).to_be_bytes());
                    frame.extend_from_slice(&sent.to_be_bytes());
                    frame.extend_from_slice(&item.at_us.to_be_bytes());
                    frame.extend_from_slice(body);
                    if c.send_binary(&frame).is_err() {
                        failed = true;
                        break;
                    }
                }
                if failed {
                    break;
                }
            }
            // Sent everything (or lost the circuit): wait for the subscriber to hang up or the next Incoming.
            while !closed.load(Ordering::Relaxed) && !sh.done.load(Ordering::Relaxed) {
                thread::sleep(Duration::from_millis(20));
            }
            c.shutdown();
        });
    }
    Ok(())
}

fn subscriber(
    sh: Arc<Shared>,
    coord: u32,
    total: u64,
    tx: mpsc::Sender<Sample>,
    storm_slot: Arc<Mutex<Option<Ws>>>,
    deadline: Instant,
) -> Result<(u64, u64, u64), String> {
    let slot = format!("coord-sim-{coord}");
    let (mut expected, mut lost, mut dup) = (0u64, 0u64, 0u64);
    let mut generation = 1u64;
    let mut first = true;
    while expected < total && Instant::now() < deadline {
        let storms_before = sh.storms.load(Ordering::Relaxed);
        let began = Instant::now();
        let mut ctl =
            Ws::connect(&sh.addr, "/v1/relay", 0x3000 + coord as u64 * 1000 + generation)?;
        control(
            &mut ctl,
            json!({
                "type": "connect", "protocol": PROTOCOL, "slot": slot, "ticket": "coord-sim",
                "lane": "interactive", "generation": generation, "accepts_parked": true,
            }),
        )?;
        let alloc = loop {
            let v = read_control(&mut ctl)?;
            if v["type"] != "parked" {
                break v;
            }
        };
        if alloc["type"] != "allocated" {
            return Err(format!("connect: {alloc}"));
        }
        let mut c = Ws::connect(&sh.addr, "/v1/relay", 0x4000 + coord as u64 * 1000 + generation)?;
        control(
            &mut c,
            json!({
                "type": "join", "protocol": PROTOCOL, "slot": slot, "circuit": alloc["circuit"], "lane": alloc["lane"],
                "generation": alloc["generation"], "ticket": alloc["join_ticket"], "role": "client",
            }),
        )?;
        let ready = read_control(&mut c)?;
        if ready["type"] != "ready" {
            return Err(format!("join: {ready}"));
        }
        if !first {
            let _ = tx.send(Sample::Reconnect {
                coord,
                ms: began.elapsed().as_secs_f64() * 1000.0,
                planned: true,
            });
        }
        first = false;
        c.send_binary(&expected.to_be_bytes())?;
        c.set_read_timeout(Some(Duration::from_secs(30)))?;
        if let Ok(mut s) = storm_slot.lock() {
            *s = c.try_clone().ok();
        }
        let mut parts_seen = 0u16;
        let mut bytes = 0usize;
        loop {
            match c.read() {
                Ok(Frame::Binary(f)) if f.len() >= HEADER => {
                    let field = |a: usize, b: usize| f.get(a..b).unwrap_or(&[]);
                    let idx = u64::from_be_bytes(field(0, 8).try_into().unwrap_or([0; 8]));
                    let part = u16::from_be_bytes(field(8, 10).try_into().unwrap_or([0; 2]));
                    let parts = u16::from_be_bytes(field(10, 12).try_into().unwrap_or([0; 2]));
                    let sent = u64::from_be_bytes(field(12, 20).try_into().unwrap_or([0; 8]));
                    let at = u64::from_be_bytes(field(20, 28).try_into().unwrap_or([0; 8]));
                    if part == 0 {
                        parts_seen = 0;
                        bytes = 0;
                    }
                    parts_seen += 1;
                    bytes += f.len() - HEADER;
                    if part + 1 < parts {
                        continue;
                    }
                    if parts_seen != parts {
                        lost += 1; // A record whose parts did not all arrive.
                    }
                    if idx < expected {
                        dup += 1;
                        continue;
                    }
                    if idx > expected {
                        lost += idx - expected;
                    }
                    expected = idx + 1;
                    let now = now_us(sh.epoch);
                    let _ = tx.send(Sample::Delivery {
                        coord,
                        idx,
                        bytes,
                        latency_us: now.saturating_sub(sent),
                        delay_us: now.saturating_sub(at),
                    });
                    if expected >= total {
                        break;
                    }
                }
                Ok(Frame::Binary(_) | Frame::Text(_)) => {}
                Ok(Frame::Closed) | Err(_) => {
                    if sh.storms.load(Ordering::Relaxed) == storms_before {
                        let _ = tx.send(Sample::Reconnect { coord, ms: 0.0, planned: false });
                    }
                    break;
                }
            }
            if Instant::now() > deadline {
                break;
            }
        }
        if let Ok(mut s) = storm_slot.lock() {
            *s = None;
        }
        c.close();
        ctl.close();
        generation += 1;
    }
    Ok((expected, lost, dup))
}

/// The reaped children's peak RSS (KiB) and CPU seconds, from getrusage(RUSAGE_CHILDREN): the relay's own, read
/// after it is waited for (the run starts no other child).
fn children_usage() -> (u64, f64) {
    // SAFETY: getrusage writes one rusage into the zeroed value it is handed, and reads nothing else.
    let mut usage: libc::rusage = unsafe { std::mem::zeroed() };
    if unsafe { libc::getrusage(libc::RUSAGE_CHILDREN, &mut usage) } != 0 {
        return (0, 0.0);
    }
    let secs = |t: libc::timeval| t.tv_sec as f64 + t.tv_usec as f64 / 1e6;
    (usage.ru_maxrss.max(0) as u64, secs(usage.ru_utime) + secs(usage.ru_stime))
}

struct Totals {
    delivered: u64,
    lost: u64,
    dup: u64,
    errors: Vec<String>,
    wall_s: f64,
    total_records: u64,
    total_bytes: u64,
}

pub fn pct(sorted: &[f64], p: f64) -> f64 {
    if sorted.is_empty() {
        return 0.0;
    }
    let i = ((sorted.len() as f64 - 1.0) * p).round() as usize;
    sorted.get(i.min(sorted.len() - 1)).copied().unwrap_or(0.0)
}

pub fn run(args: &[String]) -> Result<(), String> {
    let shape = Shape::load(crate::flag(args, "--shape"))?;
    let mut plan = Plan::from_args(args)?;
    plan.history = 0;
    let bin = crate::flag(args, "--relay-bin").unwrap_or("cmux-relay").to_string();
    let out = crate::flag(args, "--out").unwrap_or("coord-sim-run").to_string();
    let storms: u64 = crate::flag_or(args, "--storms", 0u64)?;
    let storm_every: f64 = crate::flag_or(args, "--storm-every", 5.0f64)?;
    let frame_bytes: usize = crate::flag_or(args, "--frame-bytes", 60 * 1024usize)?;
    let label = crate::flag(args, "--label").unwrap_or("").to_string();
    let dir = format!(
        "{out}/relay{}",
        if label.is_empty() { String::new() } else { format!("-{label}") }
    );
    std::fs::create_dir_all(&dir).map_err(|e| format!("{dir}: {e}"))?;

    let chats = records::chats(&shape, &plan);
    let mut relay = start_relay(&bin)?;
    let stderr = relay.stderr.take().ok_or("relay: no stderr")?;
    // Every thread of the run belongs to this scope, and the relay to the run: both end before it returns.
    let (samples, totals) = thread::scope(|scope| -> Result<(Vec<Sample>, Totals), String> {
        let (addr_tx, addr_rx) = mpsc::channel();
        scope.spawn(move || {
            for line in BufReader::new(stderr).lines().map_while(Result::ok) {
                if let Some(addr) = line.strip_prefix("cmux-relay listening on ") {
                    let _ = addr_tx.send(addr.trim().to_string());
                }
                eprintln!("  relay: {line}");
            }
        });
        let addr = addr_rx
            .recv_timeout(Duration::from_secs(30))
            .map_err(|_| "relay: no 'listening on' line in 30 s".to_string())?;
        let sh = Arc::new(Shared {
            epoch: Instant::now(),
            addr,
            frame_bytes,
            done: AtomicBool::new(false),
            storms: AtomicU64::new(0),
        });
        let lead_us = 2_000_000u64; // Two seconds for every circuit to come up before the first record is due.
        let deadline = Instant::now() + Duration::from_secs_f64(plan.live_s + 120.0);
        let (tx, rx) = mpsc::channel::<Sample>();

        let samples_path = format!("{dir}/samples.ndjson");
        let writer = {
            let path = samples_path.clone();
            scope.spawn(move || -> Result<Vec<Sample>, String> {
            let mut f = std::io::BufWriter::new(
                std::fs::File::create(&path).map_err(|e| format!("{path}: {e}"))?,
            );
            let mut kept = Vec::new();
            for s in rx {
                let line = match &s {
                    Sample::Delivery { coord, idx, bytes, latency_us, delay_us } => json!({
                        "t": "delivery", "target": "relay", "coord": coord, "idx": idx, "bytes": bytes,
                        "latency_us": latency_us, "delay_us": delay_us }),
                    Sample::Reconnect { coord, ms, planned } => {
                        json!({ "t": "reconnect", "target": "relay", "coord": coord, "ms": ms, "planned": planned })
                    }
                    Sample::Relay { at_ms, rss_kb, cpu_ms } => {
                        json!({ "t": "relay", "target": "relay", "at_ms": at_ms, "peak_rss_kb": rss_kb, "cpu_ms": cpu_ms })
                    }
                };
                writeln!(f, "{line}").map_err(|e| e.to_string())?;
                kept.push(s);
            }
            f.flush().map_err(|e| e.to_string())?;
            Ok(kept)
        })
        };

        let mut pubs = Vec::new();
        let mut subs = Vec::new();
        let mut storm_slots = Vec::new();
        let mut total_records = 0u64;
        let mut total_bytes = 0u64;
        for (i, chat) in chats.iter().enumerate() {
            let items: Vec<Item> = chat
                .live
                .iter()
                .map(|(at, r)| Item {
                    at_us: lead_us + at * 1000,
                    bytes: r.to_string().into_bytes(),
                })
                .collect();
            total_records += items.len() as u64;
            total_bytes += items.iter().map(|i| i.bytes.len() as u64).sum::<u64>();
            let total = items.len() as u64;
            let items = Arc::new(items);
            let s = sh.clone();
            pubs.push(scope.spawn(move || publisher(s, i as u32, items)));
            let slot = Arc::new(Mutex::new(None));
            storm_slots.push(slot.clone());
            let (s, t) = (sh.clone(), tx.clone());
            subs.push(scope.spawn(move || {
                // The daemon registers first, as on a real machine; a phone that comes early is parked.
                thread::sleep(Duration::from_millis(200));
                subscriber(s, i as u32, total, t, slot, deadline)
            }));
        }
        // The storm: every subscriber's circuit dropped at once, `storms` times.
        let storm = {
            let s = sh.clone();
            let slots = storm_slots.clone();
            scope.spawn(move || {
                for _ in 0..storms {
                    thread::sleep(Duration::from_secs_f64(storm_every));
                    if s.done.load(Ordering::Relaxed) {
                        break;
                    }
                    s.storms.fetch_add(1, Ordering::Relaxed);
                    for slot in &slots {
                        if let Ok(mut g) = slot.lock()
                            && let Some(ws) = g.take()
                        {
                            ws.shutdown();
                        }
                    }
                }
            })
        };
        let tx_end = tx.clone();
        drop(tx);
        let mut delivered = 0u64;
        let (mut lost, mut dup) = (0u64, 0u64);
        let mut errors = Vec::new();
        for (i, h) in subs.into_iter().enumerate() {
            match h.join() {
                Ok(Ok((e, l, d))) => {
                    delivered += e;
                    lost += l;
                    dup += d;
                }
                Ok(Err(e)) => errors.push(format!("subscriber {i}: {e}")),
                Err(_) => errors.push(format!("subscriber {i}: panicked")),
            }
        }
        let wall_s = sh.epoch.elapsed().as_secs_f64();
        sh.done.store(true, Ordering::Relaxed);
        let _ = storm.join();
        for (i, h) in pubs.into_iter().enumerate() {
            match h.join() {
                Ok(Err(e)) => errors.push(format!("publisher {i}: {e}")),
                Err(_) => errors.push(format!("publisher {i}: panicked")),
                _ => {}
            }
        }
        let _ = relay.kill();
        let _ = relay.wait();
        let (rss_kb, cpu_s) = children_usage();
        let _ = tx_end.send(Sample::Relay {
            at_ms: sh.epoch.elapsed().as_millis() as u64,
            rss_kb,
            cpu_ms: (cpu_s * 1000.0) as u64,
        });
        drop(tx_end);
        let samples = writer.join().map_err(|_| "sample writer panicked".to_string())??;
        Ok((samples, Totals { delivered, lost, dup, errors, wall_s, total_records, total_bytes }))
    })?;
    let Totals { delivered, lost, dup, errors, wall_s, total_records, total_bytes } = totals;

    let mut lat = Vec::new();
    let mut delay = Vec::new();
    let mut reconnects = Vec::new();
    let mut unplanned = 0u64;
    let (mut peak_rss_mb, mut cpu_ms) = (0.0f64, 0u64);
    for s in &samples {
        match s {
            Sample::Delivery { latency_us, delay_us, .. } => {
                lat.push(*latency_us as f64 / 1000.0);
                delay.push(*delay_us as f64 / 1000.0);
            }
            Sample::Reconnect { ms, planned: true, .. } => reconnects.push(*ms),
            Sample::Reconnect { planned: false, .. } => unplanned += 1,
            Sample::Relay { rss_kb, cpu_ms: ms, .. } => {
                peak_rss_mb = *rss_kb as f64 / 1024.0;
                cpu_ms = *ms;
            }
        }
    }
    for v in [&mut lat, &mut delay, &mut reconnects] {
        v.sort_by(|a, b| a.total_cmp(b));
    }
    let cpu_pct = cpu_ms as f64 / 1000.0 / wall_s.max(0.001) * 100.0;
    let dist = |v: &[f64]| json!({ "n": v.len(), "p50": pct(v, 0.5), "p95": pct(v, 0.95), "p99": pct(v, 0.99), "max": v.last().copied().unwrap_or(0.0) });
    let summary = json!({
        "schema": "coord-sim-surface.v1", "target": "relay", "label": label,
        "coordinators": plan.coordinators, "rate": plan.rate, "seconds": plan.live_s, "seed": plan.seed,
        "storms": storms, "storm_every_s": storm_every, "frame_bytes": frame_bytes,
        "records": total_records, "record_bytes": total_bytes, "delivered": delivered, "lost": lost, "dup": dup,
        "records_per_s": total_records as f64 / plan.live_s.max(0.001), "mb_per_s": total_bytes as f64 / 1e6 / plan.live_s.max(0.001),
        "latency_ms": dist(&lat), "delay_ms": dist(&delay), "reconnect_ms": dist(&reconnects),
        "unplanned_drops": unplanned, "wall_s": wall_s,
        "relay_peak_rss_mb": peak_rss_mb, "relay_cpu_s": cpu_ms as f64 / 1000.0,
        "relay_cpu_pct": cpu_pct, "errors": errors,
    });
    let path = format!("{dir}/summary.json");
    std::fs::write(&path, serde_json::to_string_pretty(&summary).map_err(|e| e.to_string())?)
        .map_err(|e| format!("{path}: {e}"))?;
    println!("{summary}");
    let tag = if label.is_empty() { format!("c{}", plan.coordinators) } else { label.clone() };
    for (name, v, unit) in
        [("latency", &lat, "ms"), ("delay", &delay, "ms"), ("reconnect", &reconnects, "ms")]
    {
        if !v.is_empty() {
            println!(
                "PERF_ROW {}",
                json!({ "name": format!("coord_sim.relay.{tag}.{name}"), "p50": pct(v, 0.5), "p95": pct(v, 0.95), "unit": unit })
            );
        }
    }
    if delivered < total_records || lost > 0 || dup > 0 || !errors.is_empty() {
        return Err(format!(
            "relay: delivered {delivered}/{total_records}, lost {lost}, dup {dup}, errors {errors:?} (summary in {path})"
        ));
    }
    Ok(())
}
