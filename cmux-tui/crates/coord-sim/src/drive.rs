//! `coord-sim drive`: N coordinators at once against a real, isolated acpmux daemon, with readers.
//!
//!   coord-sim drive --coordinators N --rate X --target acpmux --out RUN_DIR
//!                   [--scripts DIR] [--acpmux BIN] [--readers R] [--duration S]
//!                   [--synth-seconds S] [--seed N] [--shape FILE] [--drain S]
//!
//! Drain: after the script's last op is due, the run waits up to `--drain` seconds (default 120)
//! for every turn to end (its prompt answered, so the agent's updates before it are stored) and
//! every driver-made `turn`/`send` to be stored as a `mux:user_message`, with the store's tag
//! count still for 3 s. `run.json` says `drained` and `drain_s`. A run that did not drain counts
//! its unstored events as `cut_off`, not `lost_in_daemon` (`summary.json`).
//!
//! What it does: starts its own acpmux daemon (`drive/daemon.rs`: scratch HOME and ACPMUX_HOME
//! under RUN_DIR/scratch, its own socket, cleared environment, never the host's daemon) with one
//! harness `sim<i>` per coordinator running `coord-sim agent --script <script i>`; creates N
//! sessions; attaches a follower to each; starts R switching readers (`drive/readers.rs`); then
//! at one shared t0 every coordinator runs its script: a `session/prompt` per turn (the agent
//! streams the turn's events on schedule), and each `send_to` op as a real `acpmux send
//! --no-wait` from a CLI process. At the end it stops the daemon (SIGTERM, which writes its
//! store) and joins what the agents emitted, what the daemon stored and what the followers saw.
//!
//! Scripts: `--scripts DIR` takes every `*.ndjson` in DIR in name order (coordinator i gets file
//! i mod count); without it, `drive/synth.rs` writes stand-in burst scripts at the shape's 1x
//! peaks to RUN_DIR/scripts. Rate "10x" (or "10") divides every script time by 10.
//!
//! # RUN_DIR raw format (the contract with `metrics`)
//!
//! Every time is epoch microseconds (`*_us`) from this host's clock, except `daemon_at_ms`
//! (the daemon's own record time, epoch milliseconds). Absent values are `null`.
//!
//! `events.ndjson`, one line per emitted event:
//! `{"c","seq","k","kind","update","src","bytes","due_us","emit_us","daemon_at_ms","daemon_n","reader_us","reader_n"}`
//! - `c` coordinator, `seq` script seq, `k` index inside a subagent op (else 0). (c, seq, k) is
//!   the event's id, carried in its payload as the tag `[[cs:C:SEQ:K:EMIT_US]]`.
//! - `src`: "agent" (a `session/update` the stand-in agent sent), "turn" (the driver's prompt
//!   for a `user_turn`), "send" (an `acpmux send` for a `send_to`; it lands in session `to`).
//! - `due_us` when the script said (t0 + at_ms / rate); `emit_us` when it actually went out.
//! - `daemon_at_ms` the earliest store record holding the tag (agent: an `in` record; turn and
//!   send: a `mux:user_message`); `daemon_n` how many such records (1 expected; 0 is lost).
//! - `reader_us` the first arrival at a follower; `reader_n` arrivals over all followers
//!   (1 expected for an agent event).
//!
//! `ops.ndjson`, one line per reader or driver call:
//! `{"op","reader","c","t_us","latency_us","bytes","n","ok","err"}`; `op` is one of
//! `session_new`, `follow_attach`, `list`, `open`, `detach`, `scroll`, `search` (readers),
//! `turn` (a prompt until its turn ended), `send` (the `acpmux send --no-wait` call until it
//! returned), `cancel`. `reader` is null for the driver; `c` null for `list`. `n` counts the
//! reply's `events` or `sessions`. Lines with `"op":"follower"` give each follower's totals
//! (`notes`, `bytes`, `lagged`: `_acpmux/lagged` notifications, i.e. records the daemon dropped
//! for a slow reader); `"op":"reader_live_notes"` a switcher's live notification count.
//!
//! `proc.ndjson`, every 250 ms, the daemon's own gauges (`_acpmux/status`; this tool reads no
//! other process's /proc): `{"t_us","role":"daemon","rss_kb","peak_rss_kb","status_ms","ok",
//! "queued_bytes","queues"}`. `status_ms` is that call's latency (the daemon's responsiveness
//! under the load), `queued_bytes` the bytes waiting in all connections' outbound queues, `queues`
//! the daemon's per-connection detail as it reports it.
//!
//! `run.json`: the parameters, the session ids, `daemon_cpu_s` (the daemon's whole CPU time,
//! user + system, from this process's reaped-children times; the `acpmux send` calls are in it
//! too) and `daemon_wall_s`. `daemon.pid`: the daemon's pid, for an outside sampler.
//! `summary.json`: the numbers this command prints (a convenience; `metrics` reads the raw files).

mod daemon;
mod readers;
mod rpc;
mod synth;

use crate::agent::{self, EmitRecord, RUN_PREFIX, Tag, find_tags, now_us, parse_rate, tag};
use crate::event::{Op, SimEvent, filler};
use crate::{flag, flag_or};
use rpc::{Conn, Reply};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::io::{BufRead, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// The shared `ops.ndjson` writer.
#[derive(Clone)]
pub struct Ops(Arc<Mutex<std::io::BufWriter<std::fs::File>>>);

impl Ops {
    pub fn raw(&self, v: Value) {
        if let Ok(mut w) = self.0.lock() {
            let _ = writeln!(w, "{v}");
        }
    }

    pub fn op(&self, op: &str, reader: Option<u32>, c: u32, t0: u64, r: &Result<Reply, String>) {
        let lat = now_us().saturating_sub(t0);
        let (bytes, n, err) = match r {
            Ok(r) => {
                let n = ["/result/events", "/result/sessions", "/result/hits"]
                    .iter()
                    .find_map(|p| r.v.pointer(p).and_then(Value::as_array).map(Vec::len));
                (r.bytes, n, None)
            }
            Err(e) => (0, None, Some(e.chars().take(300).collect::<String>())),
        };
        self.raw(json!({"op": op, "reader": reader, "c": (c != u32::MAX).then_some(c), "t_us": t0,
            "latency_us": lat, "bytes": bytes, "n": n, "ok": err.is_none(), "err": err}));
    }

    fn flush(&self) {
        if let Ok(mut w) = self.0.lock() {
            let _ = w.flush();
        }
    }
}

struct Args {
    n: u32,
    rate: f64,
    out: PathBuf,
    scripts: Option<String>,
    acpmux: PathBuf,
    readers: u32,
    duration_s: u64,
    drain_s: u64,
    synth_s: u64,
    seed: u64,
    shape: Option<String>,
}

fn args(a: &[String]) -> Result<Args, String> {
    let target = flag(a, "--target").unwrap_or("acpmux");
    if target != "acpmux" {
        return Err(format!("--target {target}: only acpmux is driven so far"));
    }
    let acpmux =
        match flag(a, "--acpmux").map(String::from).or_else(|| std::env::var("ACPMUX_BIN").ok()) {
            Some(p) => PathBuf::from(p),
            None => which("acpmux")
                .ok_or("--acpmux BIN (or ACPMUX_BIN) is required: no acpmux on PATH")?,
        };
    Ok(Args {
        n: flag_or(a, "--coordinators", 3)?,
        rate: parse_rate(flag(a, "--rate").unwrap_or("1"))?,
        out: PathBuf::from(flag(a, "--out").ok_or("--out RUN_DIR is required")?),
        scripts: flag(a, "--scripts").map(String::from),
        acpmux,
        readers: flag_or(a, "--readers", 4)?,
        duration_s: flag_or(a, "--duration", 600)?,
        drain_s: flag_or(a, "--drain", 120)?,
        synth_s: flag_or(a, "--synth-seconds", 60)?,
        seed: flag_or(a, "--seed", 1)?,
        shape: flag(a, "--shape").map(String::from),
    })
}

fn which(name: &str) -> Option<PathBuf> {
    std::env::var_os("PATH")?
        .to_str()?
        .split(':')
        .map(|d| Path::new(d).join(name))
        .find(|p| p.is_file())
}

fn write_ndjson<T: serde::Serialize>(path: &Path, rows: &[T]) -> Result<(), String> {
    let f = std::fs::File::create(path).map_err(|e| format!("{}: {e}", path.display()))?;
    let mut w = std::io::BufWriter::new(f);
    for r in rows {
        serde_json::to_writer(&mut w, r).map_err(|e| e.to_string())?;
        w.write_all(b"\n").map_err(|e| e.to_string())?;
    }
    w.flush().map_err(|e| e.to_string())
}

/// The scripts, one per coordinator, as files (the agents read them).
fn scripts(a: &Args) -> Result<Vec<PathBuf>, String> {
    if let Some(dir) = &a.scripts {
        let mut files: Vec<PathBuf> = std::fs::read_dir(dir)
            .map_err(|e| format!("{dir}: {e}"))?
            .flatten()
            .map(|e| e.path())
            .filter(|p| p.extension().is_some_and(|x| x == "ndjson"))
            .collect();
        files.sort();
        if files.is_empty() {
            return Err(format!("{dir}: no *.ndjson scripts"));
        }
        return Ok((0..a.n as usize).filter_map(|i| files.get(i % files.len()).cloned()).collect());
    }
    let shape = crate::shape::Shape::load(a.shape.as_deref())?;
    let dir = a.out.join("scripts");
    std::fs::create_dir_all(&dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    (0..a.n)
        .map(|c| {
            let p = dir.join(format!("coord-{c:03}.ndjson"));
            write_ndjson(&p, &synth::script(&shape, c, a.n, a.synth_s, a.seed))?;
            Ok(p)
        })
        .collect()
}

pub fn run(argv: &[String]) -> Result<(), String> {
    let a = args(argv)?;
    std::fs::create_dir_all(&a.out).map_err(|e| format!("{}: {e}", a.out.display()))?;
    let out = std::fs::canonicalize(&a.out).map_err(|e| e.to_string())?;
    let script_files = scripts(&a)?;
    let scripts: Vec<Vec<SimEvent>> = script_files
        .iter()
        .map(|p| agent::read_script(&p.display().to_string()))
        .collect::<Result<_, _>>()?;
    let me = std::env::current_exe().map_err(|e| format!("current exe: {e}"))?;
    let scratch = out.join("scratch");
    let emit_dir = out.join("emit");
    let last_ms = scripts.iter().filter_map(|s| s.last().map(|e| e.at_ms)).max().unwrap_or(0);
    let run_s = ((last_ms as f64 / a.rate / 1000.0) as u64 + 10).min(a.duration_s);
    let harnesses: Vec<daemon::Harness> = script_files
        .iter()
        .enumerate()
        .map(|(c, p)| daemon::Harness {
            name: format!("sim{c}"),
            argv: vec![
                me.display().to_string(),
                "agent".into(),
                "--script".into(),
                p.display().to_string(),
                "--rate".into(),
                a.rate.to_string(),
                "--coord".into(),
                c.to_string(),
                "--emit-log".into(),
                emit_dir.display().to_string(),
            ],
        })
        .collect();
    // Every thread of the run (readers, coordinators, the sampler, connection readers) belongs
    // to this scope; stopping the daemon closes every connection, so the scope always ends.
    let stop = Arc::new(AtomicBool::new(false));
    let cpu0 = daemon::children_cpu_s();
    let started = std::time::Instant::now();
    let (acpmux_home, socket, result) = std::thread::scope(|s| -> Result<_, String> {
        let mut d =
            daemon::Daemon::start(s, &a.acpmux, &scratch, &harnesses, &out.join("daemon.log"))?;
        // For an outside sampler (a CI script's pidstat); this tool reads no other process.
        let _ = std::fs::write(out.join("daemon.pid"), d.pid.to_string());
        let result = drive(s, &a, &out, &d, &scripts, run_s, &stop);
        stop.store(true, Ordering::Relaxed);
        std::thread::sleep(Duration::from_secs(1));
        d.stop();
        Ok((d.acpmux_home.clone(), d.socket.clone(), result))
    })?;
    let wall_s = started.elapsed().as_secs_f64();
    let cpu_s = match (cpu0, daemon::children_cpu_s()) {
        (Some(a), Some(b)) => Some(((b - a) * 100.0).round() / 100.0),
        _ => None,
    };
    let (sessions, followers, ops, drain) = result?;
    // Every follower's totals, then the join.
    let seen: Vec<(Tag, u64)> = followers
        .iter()
        .flat_map(|(c, f)| {
            let s = f.seen.lock().map(|mut s| std::mem::take(&mut *s)).unwrap_or_default();
            ops.raw(json!({"op": "follower", "c": c, "notes": s.notes, "bytes": s.bytes, "lagged": s.lagged}));
            s.tags
        })
        .collect();
    ops.flush();
    let mut emits = read_emits(&emit_dir)?;
    emits.extend(DRIVER_EMITS.lock().map(|mut e| std::mem::take(&mut *e)).unwrap_or_default());
    let store = scan_store(&acpmux_home);
    let rows = join(&emits, &store, &seen);
    write_ndjson(&out.join("events.ndjson"), &rows)?;
    let run = json!({"schema": "coord-sim-drive.v1", "coordinators": a.n, "rate": a.rate, "readers": a.readers,
        "run_s": run_s, "drained": drain.drained, "drain_s": drain.secs, "drain_cap_s": a.drain_s, "daemon_cpu_s": cpu_s, "daemon_wall_s": (wall_s * 100.0).round() / 100.0, "scripts": script_files, "sessions": sessions, "acpmux": a.acpmux,
        "socket": socket, "acpmux_home": acpmux_home});
    std::fs::write(out.join("run.json"), run.to_string()).map_err(|e| e.to_string())?;
    let summary = summarize(&out)?;
    std::fs::write(
        out.join("summary.json"),
        serde_json::to_string_pretty(&summary).unwrap_or_default(),
    )
    .map_err(|e| e.to_string())?;
    println!("{summary}");
    Ok(())
}

static DRIVER_EMITS: Mutex<Vec<EmitRecord>> = Mutex::new(Vec::new());

fn driver_emit(r: EmitRecord) {
    if let Ok(mut e) = DRIVER_EMITS.lock() {
        e.push(r);
    }
}

type Followers = Vec<(u32, readers::Follower)>;

fn drive<'s>(
    s: &'s std::thread::Scope<'s, '_>,
    a: &Args,
    out: &Path,
    d: &daemon::Daemon,
    scripts: &[Vec<SimEvent>],
    run_s: u64,
    stop: &Arc<AtomicBool>,
) -> Result<(Vec<String>, Followers, Ops, Drain), String> {
    let f = std::fs::File::create(out.join("ops.ndjson")).map_err(|e| e.to_string())?;
    let ops = Ops(Arc::new(Mutex::new(std::io::BufWriter::new(f))));
    let control = Conn::connect(s, &d.socket, Box::new(|_, _| {}))?;
    control
        .call(
            "initialize",
            json!({"protocolVersion": 1, "clientCapabilities": {}}),
            Duration::from_secs(30),
        )
        .ok();
    let work = out.join("scratch").join("work");
    std::fs::create_dir_all(&work).map_err(|e| e.to_string())?;
    let mut sessions = Vec::new();
    for c in 0..a.n {
        let t = now_us();
        let r = control.call(
            "session/new",
            json!({"cwd": work, "mcpServers": [], "_meta": {"acpmux": {"harness": format!("sim{c}")}}}),
            Duration::from_secs(60),
        );
        ops.op("session_new", None, c, t, &r);
        let sid =
            r?.v.pointer("/result/sessionId")
                .and_then(Value::as_str)
                .ok_or("session/new: no sessionId")?
                .to_owned();
        sessions.push(sid);
    }
    let mut followers = Vec::new();
    for (c, sid) in sessions.iter().enumerate() {
        followers.push((c as u32, readers::follow(s, &d.socket, c as u32, sid, &ops)?));
    }
    let sampler = daemon::sample(s, d, out.join("proc.ndjson"), stop.clone());
    let indexed: Vec<(u32, String)> =
        sessions.iter().cloned().enumerate().map(|(c, s)| (c as u32, s)).collect();
    let switchers: Vec<_> = (0..a.readers)
        .map(|r| {
            readers::switcher(s, &d.socket, r, indexed.clone(), ops.clone(), stop.clone(), a.seed)
        })
        .collect();
    let t0 = now_us() + 1_000_000;
    let deadline = t0 + run_s * 1_000_000;
    // Turns still running at the deadline may end until here; then the store must catch up.
    let drain_end = deadline + a.drain_s * 1_000_000;
    eprintln!(
        "coord-sim drive: {} coordinators at {}x, {} readers, up to {run_s} s",
        a.n, a.rate, a.readers
    );
    let mut threads = Vec::new();
    for (c, script) in scripts.iter().enumerate() {
        let c = c as u32;
        let sid = sessions.get(c as usize).cloned().unwrap_or_default();
        threads.push(turns(
            s,
            &d.socket,
            c,
            sid,
            script.clone(),
            a.rate,
            t0,
            deadline,
            drain_end,
            ops.clone(),
        )?);
        let targets = sessions.clone();
        threads.push(sends(s, d, c, targets, script.clone(), a.rate, t0, deadline, ops.clone()));
    }
    for t in threads {
        let _ = t.join();
    }
    let drain = wait_drained(&d.acpmux_home, drain_end);
    eprintln!("coord-sim drive: drained={} after {:.1} s", drain.drained, drain.secs);
    for sid in &sessions {
        let t = now_us();
        let r = control
            .notify("session/cancel", json!({"sessionId": sid}))
            .map(|_| Reply { v: Value::Null, bytes: 0 });
        ops.op("cancel", None, u32::MAX, t, &r);
    }
    // The last records reach the followers.
    std::thread::sleep(Duration::from_secs(2));
    stop.store(true, Ordering::Relaxed);
    for s in switchers {
        let _ = s.join();
    }
    let _ = sampler.join();
    control.close();
    for (_, f) in &followers {
        f.conn.close();
    }
    Ok((sessions, followers, ops, drain))
}

/// How the run's drain ended (`run.json` `drained`, `drain_s`).
struct Drain {
    drained: bool,
    secs: f64,
}

/// After every turn thread ended: waits until each driver-made turn and send is stored as a
/// `mux:user_message` and the store's tag count has not moved for 3 s, or until `end`.
fn wait_drained(home: &Path, end: u64) -> Drain {
    let started = now_us();
    let mut tail = StoreTail::default();
    let mut last = (usize::MAX, started);
    loop {
        tail.poll(home);
        let now = now_us();
        if tail.lines != last.0 {
            last = (tail.lines, now);
        }
        let want: Vec<(u32, u64, u32)> = DRIVER_EMITS
            .lock()
            .map(|e| e.iter().map(|r| (r.c, r.seq, r.k)).collect())
            .unwrap_or_default();
        let pending = want.iter().filter(|id| !tail.delivered.contains(id)).count();
        let still = now.saturating_sub(last.1) >= 3_000_000;
        if (pending == 0 && still) || now >= end {
            let secs = (now.saturating_sub(started) as f64 / 1e5).round() / 10.0;
            return Drain { drained: pending == 0 && still, secs };
        }
        std::thread::sleep(Duration::from_millis(500));
    }
}

/// Reads the daemon's session logs as they grow: each file from where the last poll stopped,
/// whole lines only.
#[derive(Default)]
struct StoreTail {
    offsets: HashMap<PathBuf, u64>,
    /// Lines holding a tag so far.
    lines: usize,
    /// Tags stored in a `mux:user_message` (a turn's or a send's delivery).
    delivered: std::collections::HashSet<(u32, u64, u32)>,
}

impl StoreTail {
    fn poll(&mut self, root: &Path) {
        use std::io::{Read, Seek, SeekFrom};
        for p in store_files(root) {
            let from = self.offsets.get(&p).copied().unwrap_or(0);
            let Ok(mut f) = std::fs::File::open(&p) else { continue };
            if f.seek(SeekFrom::Start(from)).is_err() {
                continue;
            }
            let mut buf = Vec::new();
            if f.read_to_end(&mut buf).is_err() {
                continue;
            }
            let Some(end) = buf.iter().rposition(|b| *b == b'\n') else { continue };
            let whole = buf.get(..=end).unwrap_or_default();
            self.offsets.insert(p, from + whole.len() as u64);
            for line in String::from_utf8_lossy(whole).lines() {
                if !line.contains("[[cs:") {
                    continue;
                }
                self.lines += 1;
                if line.contains("\"user_message\"") && line.contains("\"dir\":\"mux\"") {
                    for (c, seq, k, _) in find_tags(line) {
                        self.delivered.insert((c, seq, k));
                    }
                }
            }
        }
    }
}

/// Every `<root>/**/events/*.ndjson`.
fn store_files(root: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let Ok(rd) = std::fs::read_dir(&dir) else { continue };
        for e in rd.flatten() {
            let p = e.path();
            if p.is_dir() {
                stack.push(p);
                continue;
            }
            let in_events = p.parent().and_then(Path::file_name).is_some_and(|n| n == "events");
            if in_events && p.extension().is_some_and(|x| x == "ndjson") {
                out.push(p);
            }
        }
    }
    out
}

fn sleep_until(due: u64) {
    loop {
        let now = now_us();
        if now >= due {
            return;
        }
        std::thread::sleep(Duration::from_micros((due - now).min(100_000)));
    }
}

/// One coordinator's turns: a prompt per segment, each when its `user_turn` comes due, the next
/// only after the last one ended.
#[allow(clippy::too_many_arguments)]
fn turns<'s>(
    s: &'s std::thread::Scope<'s, '_>,
    socket: &Path,
    c: u32,
    sid: String,
    script: Vec<SimEvent>,
    rate: f64,
    t0: u64,
    deadline: u64,
    end: u64,
    ops: Ops,
) -> Result<std::thread::ScopedJoinHandle<'s, ()>, String> {
    let conn = Conn::connect(s, socket, Box::new(|_, _| {}))?;
    Ok(s.spawn(move || {
        let user_turns: Vec<&SimEvent> = script.iter().filter(|e| e.op == Op::UserTurn).collect();
        for j in 0..=user_turns.len() {
            let opener = j.checked_sub(1).and_then(|i| user_turns.get(i));
            let due = t0 + opener.map(|e| (e.at_ms as f64 * 1000.0 / rate) as u64).unwrap_or(0);
            if due >= deadline {
                break;
            }
            sleep_until(due);
            let emit_us = now_us();
            let mut text = format!("{RUN_PREFIX} t0={t0}");
            if let Some(e) = opener {
                text.push(' ');
                text.push_str(&tag(c, e.seq, 0, emit_us));
                driver_emit(EmitRecord {
                    c,
                    seq: e.seq,
                    k: 0,
                    kind: "user_turn".into(),
                    update: "turn".into(),
                    bytes: text.len() as u64,
                    due_us: due,
                    emit_us,
                });
            }
            let left = Duration::from_micros(end.saturating_sub(now_us()).max(1_000_000));
            let r = conn.call(
                "session/prompt",
                json!({"sessionId": sid, "prompt": [{"type": "text", "text": text}]}),
                left,
            );
            ops.op("turn", None, c, emit_us, &r);
            if r.is_err() {
                break;
            }
        }
        conn.close();
    }))
}

/// One coordinator's `send_to` ops, each a real `acpmux send --no-wait` CLI call.
#[allow(clippy::too_many_arguments)]
fn sends<'s>(
    s: &'s std::thread::Scope<'s, '_>,
    d: &daemon::Daemon,
    c: u32,
    sessions: Vec<String>,
    script: Vec<SimEvent>,
    rate: f64,
    t0: u64,
    deadline: u64,
    ops: Ops,
) -> std::thread::ScopedJoinHandle<'s, ()> {
    let bin = d.bin.clone();
    let env = d.env();
    s.spawn(move || {
        for e in &script {
            let Op::SendTo { to } = e.op else { continue };
            let due = t0 + (e.at_ms as f64 * 1000.0 / rate) as u64;
            if due >= deadline {
                break;
            }
            sleep_until(due);
            let Some(target) = sessions.get(to as usize % sessions.len().max(1)) else { continue };
            let emit_us = now_us();
            let text = format!(
                "coord-sim:msg {} {}",
                tag(c, e.seq, 0, emit_us),
                filler(e.seq, (e.bytes as usize).min(4096))
            );
            driver_emit(EmitRecord {
                c,
                seq: e.seq,
                k: 0,
                kind: format!("send_to:{to}"),
                update: "send".into(),
                bytes: text.len() as u64,
                due_us: due,
                emit_us,
            });
            let r = cli_send(&bin, &env, target, &text);
            ops.op("send", None, c, emit_us, &r);
        }
    })
}

/// `acpmux send --no-wait TARGET TEXT` against this run's daemon. One that gives no answer in 60 s
/// is ended (its `Child` drop: SIGTERM to its group, then SIGKILL) and recorded as such.
fn cli_send(
    bin: &Path,
    env: &[(String, String)],
    target: &str,
    text: &str,
) -> Result<Reply, String> {
    let mut child = cmux_process::Command::new(bin)
        .args(["send", "--no-wait", target, text])
        .env_clear()
        .envs(env.iter().cloned())
        .stdin(cmux_process::Stdio::null())
        .stdout(cmux_process::Stdio::piped())
        .stderr(cmux_process::Stdio::piped())
        .spawn()
        .map_err(|e| format!("acpmux send: {e}"))?;
    match child.wait_timeout(Duration::from_secs(60)) {
        Ok(Some(status)) => {
            let o = child.wait_with_output().map_err(|e| e.to_string())?;
            let stdout = String::from_utf8_lossy(&o.stdout).to_string();
            if status.success() {
                Ok(Reply { v: json!({"result": stdout.trim()}), bytes: stdout.len() })
            } else {
                Err(format!(
                    "exit {:?}: {}",
                    status.code(),
                    String::from_utf8_lossy(&o.stderr).trim()
                ))
            }
        }
        Ok(None) => Err("acpmux send: no answer in 60 s".into()),
        Err(e) => Err(format!("acpmux send: {e}")),
    }
}

fn read_emits(dir: &Path) -> Result<Vec<EmitRecord>, String> {
    let mut out = Vec::new();
    let Ok(rd) = std::fs::read_dir(dir) else { return Ok(out) };
    for e in rd.flatten() {
        let f = std::fs::File::open(e.path()).map_err(|e| e.to_string())?;
        for line in std::io::BufReader::new(f).lines().map_while(Result::ok) {
            if let Ok(r) = serde_json::from_str::<EmitRecord>(&line) {
                out.push(r);
            }
        }
    }
    Ok(out)
}

/// Store record holding a tag: (dir, kind, at ms).
type StoreHit = (String, String, u64);

/// Every tag in the daemon's session logs (`<ACPMUX_HOME>/**/events/*.ndjson`).
fn scan_store(root: &Path) -> HashMap<(u32, u64, u32), Vec<StoreHit>> {
    let mut out: HashMap<(u32, u64, u32), Vec<StoreHit>> = HashMap::new();
    for p in store_files(root) {
        let Ok(f) = std::fs::File::open(&p) else { continue };
        for line in std::io::BufReader::new(f).lines().map_while(Result::ok) {
            if !line.contains("[[cs:") {
                continue;
            }
            let Ok(v) = serde_json::from_str::<Value>(&line) else { continue };
            let s = |k: &str| v.get(k).and_then(Value::as_str).unwrap_or_default().to_owned();
            let at = v.get("at").and_then(Value::as_u64).unwrap_or(0);
            for (c, seq, k, _) in find_tags(&line) {
                out.entry((c, seq, k)).or_default().push((s("dir"), s("kind"), at));
            }
        }
    }
    out
}

fn join(
    emits: &[EmitRecord],
    store: &HashMap<(u32, u64, u32), Vec<StoreHit>>,
    seen: &[(Tag, u64)],
) -> Vec<Value> {
    let mut reader: HashMap<(u32, u64, u32), (u64, u64)> = HashMap::new();
    for ((c, seq, k, _), at) in seen {
        let e = reader.entry((*c, *seq, *k)).or_insert((*at, 0));
        e.0 = e.0.min(*at);
        e.1 += 1;
    }
    emits
        .iter()
        .map(|r| {
            let id = (r.c, r.seq, r.k);
            let src = match r.update.as_str() {
                "turn" => "turn",
                "send" => "send",
                _ => "agent",
            };
            let hits: Vec<&StoreHit> = store
                .get(&id)
                .map(|v| {
                    v.iter()
                        .filter(|(dir, kind, _)| {
                            if src == "agent" { dir == "in" } else { dir == "mux" && kind == "user_message" }
                        })
                        .collect()
                })
                .unwrap_or_default();
            let daemon_at = hits.iter().map(|h| h.2).min();
            let (reader_us, reader_n) = reader.get(&id).map(|(a, n)| (Some(*a), *n)).unwrap_or((None, 0));
            json!({"c": r.c, "seq": r.seq, "k": r.k, "kind": r.kind, "update": r.update, "src": src,
                "bytes": r.bytes, "due_us": r.due_us, "emit_us": r.emit_us, "daemon_at_ms": daemon_at,
                "daemon_n": hits.len(), "reader_us": reader_us, "reader_n": reader_n})
        })
        .collect()
}

fn pct(v: &mut [f64], p: f64) -> Option<f64> {
    if v.is_empty() {
        return None;
    }
    v.sort_by(|a, b| a.total_cmp(b));
    let i = ((v.len() as f64 - 1.0) * p).round() as usize;
    v.get(i).map(|x| (x * 10.0).round() / 10.0)
}

fn dist(mut v: Vec<f64>) -> Value {
    json!({"n": v.len(), "p50": pct(&mut v, 0.5), "p95": pct(&mut v, 0.95), "p99": pct(&mut v, 0.99),
        "max": pct(&mut v, 1.0)})
}

fn lines(path: &Path) -> Vec<Value> {
    std::fs::read_to_string(path)
        .unwrap_or_default()
        .lines()
        .filter_map(|l| serde_json::from_str(l).ok())
        .collect()
}

/// The numbers a run prints (milliseconds): delivery latency, loss, duplication, reader ops,
/// daemon peaks. `metrics` makes the report; this is a quick read of the same raw files.
pub fn summarize(run: &Path) -> Result<Value, String> {
    let events = lines(&run.join("events.ndjson"));
    let ops = lines(&run.join("ops.ndjson"));
    let procs = lines(&run.join("proc.ndjson"));
    let info = std::fs::read_to_string(run.join("run.json"))
        .ok()
        .and_then(|t| serde_json::from_str::<Value>(&t).ok())
        .unwrap_or(Value::Null);
    // A run that did not drain cut its last events off: not counted as the daemon's loss.
    let drained = info["drained"].as_bool().unwrap_or(true);
    let u = |v: &Value, k: &str| v.get(k).and_then(Value::as_u64);
    let mut by_src = serde_json::Map::new();
    for src in ["agent", "turn", "send"] {
        let es: Vec<&Value> = events.iter().filter(|e| e["src"] == src).collect();
        let reader: Vec<f64> = es
            .iter()
            .filter_map(|e| {
                Some(u(e, "reader_us")?.saturating_sub(u(e, "emit_us")?) as f64 / 1000.0)
            })
            .collect();
        let daemon: Vec<f64> = es
            .iter()
            .filter_map(|e| Some((u(e, "daemon_at_ms")? as f64) - u(e, "emit_us")? as f64 / 1000.0))
            .collect();
        let lag: Vec<f64> = es
            .iter()
            .filter_map(|e| Some(u(e, "emit_us")?.saturating_sub(u(e, "due_us")?) as f64 / 1000.0))
            .collect();
        let count = |f: &dyn Fn(&Value) -> bool| es.iter().filter(|e| f(e)).count();
        by_src.insert(
            src.into(),
            json!({
                "emitted": es.len(),
                "lost_in_daemon": if drained { count(&|e| u(e, "daemon_n") == Some(0)) } else { 0 },
                "cut_off": if drained { 0 } else { count(&|e| u(e, "daemon_n") == Some(0)) },
                "dup_in_daemon": count(&|e| u(e, "daemon_n").unwrap_or(0) > 1),
                "unseen_by_readers": count(&|e| u(e, "reader_n") == Some(0)),
                "dup_at_readers": count(&|e| u(e, "reader_n").unwrap_or(0) > 1),
                "emit_to_reader_ms": dist(reader),
                "emit_to_daemon_ms": dist(daemon),
                "emit_behind_schedule_ms": dist(lag),
            }),
        );
    }
    let mut by_op = serde_json::Map::new();
    let names: std::collections::BTreeSet<String> =
        ops.iter().filter_map(|o| o["op"].as_str().map(String::from)).collect();
    for name in names {
        let os: Vec<&Value> = ops.iter().filter(|o| o["op"] == name.as_str()).collect();
        if os.iter().all(|o| o.get("latency_us").is_none()) {
            continue;
        }
        let lat: Vec<f64> =
            os.iter().filter_map(|o| Some(u(o, "latency_us")? as f64 / 1000.0)).collect();
        let failed = os.iter().filter(|o| o["ok"] == false).count();
        let first_err = os.iter().find_map(|o| o["err"].as_str().map(String::from));
        by_op.insert(
            name,
            json!({"latency_ms": dist(lat), "failed": failed, "first_error": first_err}),
        );
    }
    let lagged: u64 =
        ops.iter().filter(|o| o["op"] == "follower").filter_map(|o| u(o, "lagged")).sum();
    let peak = |k: &str| procs.iter().filter_map(|p| p[k].as_f64()).fold(0.0, f64::max);
    let status_ms: Vec<f64> = procs.iter().filter_map(|p| p["status_ms"].as_f64()).collect();
    let mean_cpu = match (info["daemon_cpu_s"].as_f64(), info["daemon_wall_s"].as_f64()) {
        (Some(cpu), Some(wall)) if wall > 0.0 => Some((cpu / wall * 1000.0).round() / 10.0),
        _ => None,
    };
    Ok(json!({
        "drained": drained,
        "drain_s": info["drain_s"],
        "events": by_src,
        "ops": by_op,
        "follower_lagged_notes": lagged,
        "daemon": {"peak_rss_mb": (peak("rss_kb") / 1024.0).round(), "peak_queued_mb": (peak("queued_bytes") / 1048576.0 * 10.0).round() / 10.0,
            "cpu_s": info["daemon_cpu_s"], "mean_cpu_pct": mean_cpu, "status_call_ms": dist(status_ms)},
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn join_counts_loss_and_duplicates() {
        let emit = |seq, update: &str| EmitRecord {
            c: 1,
            seq,
            k: 0,
            kind: "in:plan".into(),
            update: update.into(),
            bytes: 10,
            due_us: 1000,
            emit_us: 2000,
        };
        let mut store = HashMap::new();
        store.insert(
            (1, 1, 0),
            vec![("in".to_string(), "plan".to_string(), 3), ("out".into(), "x".into(), 9)],
        );
        store.insert((1, 3, 0), vec![("mux".to_string(), "user_message".to_string(), 5)]);
        let seen = vec![((1, 1, 0, 2000), 4000), ((1, 1, 0, 2000), 4500)];
        let rows = join(&[emit(1, "plan"), emit(2, "plan"), emit(3, "turn")], &store, &seen);
        assert_eq!(rows[0]["daemon_n"], 1);
        assert_eq!(rows[0]["daemon_at_ms"], 3);
        assert_eq!(rows[0]["reader_us"], 4000);
        assert_eq!(rows[0]["reader_n"], 2);
        assert_eq!(rows[1]["daemon_n"], 0);
        assert_eq!(rows[2]["src"], "turn");
        assert_eq!(rows[2]["daemon_n"], 1);
    }
}
