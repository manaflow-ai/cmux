//! The published benchmarks (RFD 0167 row 18): resume, fork and an hours-long session under load,
//! timed on the real daemon with the stand-in agent, so the numbers we publish are the daemon's
//! own and anyone can rerun them. Leo, 2026-11-24: "i never only want top x changes. you all need
//! to be working through all useful ones end to end to end."
//!
//! A real daemon (`daemon run`) over a scratch home, the stand-in harness (`fake_agent.py`), and
//! the real JSON-RPC socket a client uses. Three measurements, each a test of its own:
//!
//! - `resume`: a chat with history, the daemon stopped (SIGTERM) and started again over the same
//!   home, then `session/load` and a prompt; from the load's send to the prompt's first
//!   `agent_message_chunk` (`resume_ms`), and the daemon's start to ready beside it
//!   (`daemon_ready_ms`). What a person pays after a restart, an update or a reboot.
//! - `fork`: a chat with `PUBLISHED_BENCH_FORK_TURNS` turns (default 20), `session/fork`, then a
//!   prompt on the fork; from the fork's send to the fork's first chunk (`fork_ms`).
//! - `soak`: `PUBLISHED_BENCH_SOAK_LOAD` chats (default 8) streaming turns of
//!   `delta-chunks: 50 200` back to back for `PUBLISHED_BENCH_SOAK_SECS` (default 120; 28800 is
//!   the 8 h run), while a probe every `PUBLISHED_BENCH_SOAK_PROBE_SECS` (default 5) times a prompt
//!   on an idle chat to its first chunk (`input_ms`, the latency a person feels when they type
//!   into one chat while others stream) and `_acpmux/sessions` (`ls_ms`), and reads the daemon's
//!   RSS and its zombie children. A `window` line per `PUBLISHED_BENCH_SOAK_WINDOW_SECS` (default
//!   the duration / 8, at most an hour) shows drift; the end line has the whole run.
//!   No soak: the run ticks the session's time forward (Leo, 2026-11-10: "And I fucking hate
//!   soaks, by the way."). A paced calibration (`PUBLISHED_BENCH_SOAK_CALIBRATE_SECS`, default
//!   30) measures the turns a second of the paced session ends, then the chats run back to back
//!   and every probe, window and the end come at the turn counts the paced session reaches at
//!   those seconds, so the 8 h session's turns run in minutes. The row's `wall_s` and `speedup`
//!   say how long it took; `PUBLISHED_BENCH_SOAK_TICKED=0` is the wall-time run.
//!
//! Each prints `PUBLISHED-BENCH <json>` lines (schema `cmux.published-bench.v1`), which
//! `scripts/measure/published-benches-linux.sh` collects with the move and build numbers.
//! Samples: `PUBLISHED_BENCH_SAMPLES` (default 20). Run on a fleet Linux host, never a person's
//! machine:
//!
//! ```text
//! cmux-ci test -- 'cd cmux-tui && cargo test -p acpmux --release --test published_bench -- --ignored --nocapture --test-threads 1'
//! ```
#![cfg(target_os = "linux")]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// The daemon this test starts runs tests/fake_agent.py only. The knobs are the bench's own.
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in().keep(&[
    "PUBLISHED_BENCH_SAMPLES",
    "PUBLISHED_BENCH_FORK_TURNS",
    "PUBLISHED_BENCH_SOAK_SECS",
    "PUBLISHED_BENCH_SOAK_LOAD",
    "PUBLISHED_BENCH_SOAK_PROBE_SECS",
    "PUBLISHED_BENCH_SOAK_WINDOW_SECS",
    "PUBLISHED_BENCH_SOAK_TICKED",
    "PUBLISHED_BENCH_SOAK_CALIBRATE_SECS",
]);

use serde_json::{Value, json};
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::{Duration, Instant};

fn knob(name: &str, default: u64) -> u64 {
    std::env::var(name).ok().and_then(|v| v.parse().ok()).unwrap_or(default)
}

struct Rpc {
    reader: BufReader<UnixStream>,
    writer: UnixStream,
    next: u64,
}

impl Rpc {
    fn connect(path: &Path) -> Self {
        let s = UnixStream::connect(path).expect("connect to the daemon socket");
        s.set_read_timeout(Some(Duration::from_secs(120))).unwrap();
        let mut rpc = Self { reader: BufReader::new(s.try_clone().unwrap()), writer: s, next: 0 };
        rpc.call("initialize", json!({"protocolVersion": 1}));
        rpc
    }

    fn send(&mut self, method: &str, params: Value) -> u64 {
        self.next += 1;
        let line = json!({"jsonrpc": "2.0", "id": self.next, "method": method, "params": params});
        self.writer.write_all(format!("{line}\n").as_bytes()).unwrap();
        self.next
    }

    fn line(&mut self) -> Value {
        loop {
            let mut text = String::new();
            assert!(self.reader.read_line(&mut text).unwrap() > 0, "the daemon closed the socket");
            if let Ok(v) = serde_json::from_str::<Value>(&text) {
                return v;
            }
        }
    }

    fn try_call(&mut self, method: &str, params: Value) -> Result<Value, Value> {
        let id = self.send(method, params);
        loop {
            let v = self.line();
            if v.get("id") == Some(&json!(id)) && v.get("method").is_none() {
                return match v.get("error") {
                    Some(e) => Err(e.clone()),
                    None => Ok(v["result"].clone()),
                };
            }
        }
    }

    fn call(&mut self, method: &str, params: Value) -> Value {
        self.try_call(method, params).unwrap_or_else(|e| panic!("{method} failed: {e}"))
    }

    /// Sends a prompt; the time its first chunk came, measured from `from`, once its turn ended.
    fn prompt(&mut self, session: &str, text: &str, from: Instant) -> Duration {
        let id = self.send(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": text}]}),
        );
        let mut first = None;
        loop {
            let v = self.line();
            if first.is_none()
                && v["method"] == "session/update"
                && v["params"]["sessionId"] == session
                && v["params"]["update"]["sessionUpdate"] == "agent_message_chunk"
            {
                first = Some(from.elapsed());
            }
            if v.get("id") == Some(&json!(id)) && v.get("method").is_none() {
                assert!(v.get("error").is_none(), "session/prompt failed: {v}");
                return first.expect("the turn ended with no agent_message_chunk");
            }
        }
    }

    fn new_session(&mut self, cwd: &Path) -> String {
        let made = self.call("session/new", json!({"cwd": cwd, "mcpServers": []}));
        made["sessionId"].as_str().expect("session/new gave no sessionId").to_owned()
    }
}

struct Daemon(Child);

impl Daemon {
    fn pid(&self) -> u32 {
        self.0.id()
    }

    /// SIGTERM, as a service manager or an update stops it, then waits.
    fn stop(mut self) {
        // SAFETY: a plain signal to the child this bench spawned and still owns.
        unsafe { libc::kill(self.0.id() as i32, libc::SIGTERM) };
        let deadline = Instant::now() + Duration::from_secs(20);
        while Instant::now() < deadline {
            if let Ok(Some(_)) = self.0.try_wait() {
                return;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

struct Bench {
    _scratch: daemon_env::Scratch,
    scratch: PathBuf,
    home: PathBuf,
    work: PathBuf,
    socket: PathBuf,
}

impl Bench {
    fn new(tag: &str) -> Self {
        // Removed when the bench ends, passing or not (`ACPMUX_KEEP_SCRATCH=1` keeps it).
        let scratch = daemon_env::Scratch::new(tag);
        let path = scratch.to_path_buf();
        let home = path.join("acpmux");
        let work = path.join("work");
        fs::create_dir_all(&home).unwrap();
        fs::create_dir_all(&work).unwrap();
        let config = json!({
            "harnesses": {"fake": {
                "argv": ["python3", concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py")]
            }},
            "defaultHarness": "fake", "permissionPolicy": "approve-all"
        });
        fs::write(home.join("config.json"), config.to_string()).unwrap();
        let socket = path.join("s.sock");
        Self { _scratch: scratch, scratch: path, home, work, socket }
    }

    /// Starts the daemon; it and the time from spawn to its readiness line.
    fn start(&self) -> (Daemon, Duration) {
        let _ = fs::remove_file(&self.socket);
        let from = Instant::now();
        let mut child = daemon_env::command(&self.scratch, daemon_env::Agents::StandIn, &[])
            .args(["daemon", "run", "--ready-fd", "1", "--log", "warn"])
            .env("ACPMUX_HOME", &self.home)
            .env("ACPMUX_SOCKET", &self.socket)
            .env("ACPMUX_SPARE_HARNESS", "0")
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .unwrap();
        let stdout = child.stdout.take().unwrap();
        let ready = BufReader::new(stdout)
            .lines()
            .map_while(Result::ok)
            .any(|line| serde_json::from_str::<Value>(&line).is_ok_and(|v| v["ready"] == true));
        if !ready {
            let _ = child.kill();
            panic!("the daemon exited without a readiness line: {:?}", child.wait());
        }
        (Daemon(child), from.elapsed())
    }
}

fn ms(d: Duration) -> f64 {
    (d.as_secs_f64() * 1000.0 * 10.0).round() / 10.0
}

/// p50, p95, p99, max and n of millisecond samples.
fn stats(samples: &[f64]) -> Value {
    if samples.is_empty() {
        return json!({"n": 0});
    }
    let mut sorted = samples.to_vec();
    sorted.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let at = |p: f64| sorted[((sorted.len() as f64 - 1.0) * p).round() as usize];
    json!({"n": sorted.len(), "p50": at(0.5), "p95": at(0.95), "p99": at(0.99), "max": sorted[sorted.len() - 1]})
}

fn host() -> Value {
    let cpus = std::thread::available_parallelism().map_or(0, |n| n.get());
    let model = fs::read_to_string("/proc/cpuinfo")
        .unwrap_or_default()
        .lines()
        .find(|l| l.starts_with("model name"))
        .and_then(|l| l.split(':').nth(1))
        .map(|s| s.trim().to_owned())
        .unwrap_or_default();
    let mem_kb = fs::read_to_string("/proc/meminfo")
        .unwrap_or_default()
        .lines()
        .find(|l| l.starts_with("MemTotal:"))
        .and_then(|l| l.split_whitespace().nth(1).and_then(|v| v.parse::<u64>().ok()))
        .unwrap_or(0);
    let name =
        fs::read_to_string("/proc/sys/kernel/hostname").unwrap_or_default().trim().to_owned();
    json!({"name": name, "cpus": cpus, "cpu_model": model, "mem_gb": mem_kb / 1024 / 1024})
}

fn emit(kind: &str, body: Value) {
    let mut row = json!({"schema": "cmux.published-bench.v1", "bench": kind, "host": host(),
        "at": chrono_like_now()});
    if let (Some(r), Some(b)) = (row.as_object_mut(), body.as_object()) {
        r.extend(b.clone());
    }
    println!("PUBLISHED-BENCH {row}");
}

/// UTC now as RFC 3339 seconds, without a date crate (days to a civil date: Howard Hinnant's algorithm).
fn chrono_like_now() -> String {
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs()) as i64;
    let (days, rem) = (secs.div_euclid(86_400), secs.rem_euclid(86_400));
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z",
        rem / 3600,
        rem % 3600 / 60,
        rem % 60
    )
}

/// The daemon's resident set and its high-water mark, MB.
fn rss_mb(pid: u32) -> (f64, f64) {
    let status = fs::read_to_string(format!("/proc/{pid}/status")).unwrap_or_default();
    let field = |name: &str| {
        status
            .lines()
            .find(|l| l.starts_with(name))
            .and_then(|l| l.split_whitespace().nth(1).and_then(|v| v.parse::<f64>().ok()))
            .map_or(0.0, |kb| (kb / 1024.0 * 10.0).round() / 10.0)
    };
    (field("VmRSS:"), field("VmHWM:"))
}

/// The daemon's children: (live, zombie).
fn children(pid: u32) -> (u64, u64) {
    let (mut live, mut zombie) = (0, 0);
    let Ok(dir) = fs::read_dir("/proc") else { return (0, 0) };
    for entry in dir.flatten() {
        let Ok(stat) = fs::read_to_string(entry.path().join("stat")) else { continue };
        // pid (comm) state ppid ...: the comm may hold spaces, so read after its last ')'.
        let Some(rest) = stat.rsplit_once(')').map(|(_, r)| r) else { continue };
        let mut fields = rest.split_whitespace();
        let state = fields.next().unwrap_or("");
        let ppid: u32 = fields.next().and_then(|p| p.parse().ok()).unwrap_or(0);
        if ppid == pid {
            if state == "Z" {
                zombie += 1;
            } else {
                live += 1;
            }
        }
    }
    (live, zombie)
}

#[test]
#[ignore = "bench: run by hand with --ignored --nocapture"]
fn resume() {
    let samples = knob("PUBLISHED_BENCH_SAMPLES", 20);
    let bench = Bench::new("amx-pubresume");
    let (mut resume, mut ready, mut total) = (Vec::new(), Vec::new(), Vec::new());
    let mut load_errors = 0u64;
    for i in 0..samples {
        let (daemon, _) = bench.start();
        let id = {
            let mut rpc = Rpc::connect(&bench.socket);
            let id = rpc.new_session(&bench.work);
            for t in 0..5 {
                rpc.prompt(&id, &format!("history {i}.{t}"), Instant::now());
            }
            id
        };
        daemon.stop();
        let (daemon, ready_in) = bench.start();
        let mut rpc = Rpc::connect(&bench.socket);
        let from = Instant::now();
        if rpc
            .try_call("session/load", json!({"sessionId": id, "cwd": bench.work, "mcpServers": []}))
            .is_err()
        {
            load_errors += 1;
        }
        let first = rpc.prompt(&id, &format!("resumed {i}"), from);
        resume.push(ms(first));
        ready.push(ms(ready_in));
        total.push(ms(first + ready_in));
        drop(rpc);
        daemon.stop();
    }
    emit(
        "resume",
        json!({"what": "daemon restarted over a chat with 5 turns: session/load send to the next prompt's first chunk",
               "resume_ms": stats(&resume), "daemon_ready_ms": stats(&ready),
               "restart_to_first_chunk_ms": stats(&total), "load_errors": load_errors}),
    );
}

#[test]
#[ignore = "bench: run by hand with --ignored --nocapture"]
fn fork() {
    let samples = knob("PUBLISHED_BENCH_SAMPLES", 20);
    let turns = knob("PUBLISHED_BENCH_FORK_TURNS", 20);
    let bench = Bench::new("amx-pubfork");
    let (_daemon, _) = bench.start();
    let mut rpc = Rpc::connect(&bench.socket);
    let source = rpc.new_session(&bench.work);
    for t in 0..turns {
        rpc.prompt(&source, &format!("history {t}"), Instant::now());
    }
    let (mut fork_call, mut fork_first) = (Vec::new(), Vec::new());
    for i in 0..samples {
        let from = Instant::now();
        let made = rpc.call("session/fork", json!({"sessionId": source, "cwd": bench.work}));
        let called = from.elapsed();
        let id = made["sessionId"].as_str().expect("session/fork gave no sessionId").to_owned();
        let first = rpc.prompt(&id, &format!("forked {i}"), from);
        fork_call.push(ms(called));
        fork_first.push(ms(first));
        rpc.call("_acpmux/kill", json!({"sessionId": id}));
    }
    emit(
        "fork",
        json!({"what": format!("session/fork of a chat with {turns} turns: send to the fork's first chunk"),
               "fork_ms": stats(&fork_first), "fork_call_ms": stats(&fork_call), "history_turns": turns}),
    );
}

#[test]
#[ignore = "bench: run by hand with --ignored --nocapture"]
fn soak() {
    let secs = knob("PUBLISHED_BENCH_SOAK_SECS", 120);
    let load = knob("PUBLISHED_BENCH_SOAK_LOAD", 8);
    let probe_every = knob("PUBLISHED_BENCH_SOAK_PROBE_SECS", 5).max(1) as f64;
    let window = knob("PUBLISHED_BENCH_SOAK_WINDOW_SECS", (secs / 8).clamp(10, 3600)) as f64;
    // Ticked (the default): the session's clock is its turns, not the wall. A paced calibration
    // (the wall run's own pacing) gives the turns a second of that session; then the loaders run
    // back to back and every probe, window and the end fire at the turn counts the paced run
    // would reach at those seconds. `PUBLISHED_BENCH_SOAK_TICKED=0` is the old wall-time run.
    let ticked = knob("PUBLISHED_BENCH_SOAK_TICKED", 1) != 0;
    let calibrate = Duration::from_secs(knob("PUBLISHED_BENCH_SOAK_CALIBRATE_SECS", 30).max(1));
    let bench = Bench::new("amx-pubsoak");
    let (daemon, _) = bench.start();
    let pid = daemon.pid();
    let stop = Arc::new(AtomicBool::new(false));
    let paced = Arc::new(AtomicBool::new(true));
    let turns = Arc::new(AtomicU64::new(0));
    let turn_errors = Arc::new(AtomicU64::new(0));
    let mut threads = Vec::new();
    for n in 0..load {
        let (socket, work) = (bench.socket.clone(), bench.work.clone());
        let (stop, paced, turns, turn_errors) =
            (stop.clone(), paced.clone(), turns.clone(), turn_errors.clone());
        threads.push(std::thread::spawn(move || {
            let mut rpc = Rpc::connect(&socket);
            let id = rpc.new_session(&work);
            while !stop.load(Ordering::Relaxed) {
                let sent = rpc.send(
                    "session/prompt",
                    json!({"sessionId": id, "prompt": [{"type": "text", "text": "delta-chunks: 50 200"}]}),
                );
                loop {
                    let v = rpc.line();
                    if v.get("id") == Some(&json!(sent)) && v.get("method").is_none() {
                        if v.get("error").is_some() {
                            turn_errors.fetch_add(1, Ordering::Relaxed);
                        }
                        break;
                    }
                }
                turns.fetch_add(1, Ordering::Relaxed);
                if paced.load(Ordering::Relaxed) {
                    std::thread::sleep(Duration::from_millis(250 + n * 10));
                }
            }
        }));
    }
    let mut probe = Rpc::connect(&bench.socket);
    let idle = probe.new_session(&bench.work);
    probe.prompt(&idle, "warm", Instant::now());
    // Turns a second of the paced session: measured, in ticked mode, over `calibrate`.
    let rate = if ticked {
        let (from, at) = (turns.load(Ordering::Relaxed), Instant::now());
        std::thread::sleep(calibrate);
        let rate = (turns.load(Ordering::Relaxed) - from) as f64 / at.elapsed().as_secs_f64();
        assert!(rate > 0.0, "no turn ended in the {}s paced calibration", calibrate.as_secs());
        paced.store(false, Ordering::Relaxed);
        rate
    } else {
        0.0
    };
    let (rss_start, _) = rss_mb(pid);
    let started = Instant::now();
    let turns_at_start = turns.load(Ordering::Relaxed);
    // The session's seconds so far: the wall's, or (ticked) its turns at the paced rate.
    let now = || {
        if ticked {
            (turns.load(Ordering::Relaxed) - turns_at_start) as f64 / rate
        } else {
            started.elapsed().as_secs_f64()
        }
    };
    let (mut input, mut ls) = (Vec::new(), Vec::new());
    let (mut w_input, mut w_ls) = (Vec::new(), Vec::new());
    let (mut rss_max, mut zombies_max, mut children_max) = (rss_start, 0u64, 0u64);
    let (mut next_probe, mut next_window) = (0.0f64, window);
    let mut i = 0u64;
    while now() < secs as f64 {
        let first = ms(probe.prompt(&idle, &format!("probe {i}"), Instant::now()));
        let from = Instant::now();
        probe.call("_acpmux/sessions", json!({}));
        let listed = ms(from.elapsed());
        input.push(first);
        ls.push(listed);
        w_input.push(first);
        w_ls.push(listed);
        let (rss, _) = rss_mb(pid);
        let (live, zombie) = children(pid);
        rss_max = rss_max.max(rss);
        zombies_max = zombies_max.max(zombie);
        children_max = children_max.max(live);
        i += 1;
        if now() >= next_window {
            emit(
                "soak-window",
                json!({"elapsed_s": now().round() as u64, "wall_s": started.elapsed().as_secs(),
                       "input_ms": stats(&w_input), "ls_ms": stats(&w_ls), "rss_mb": rss,
                       "children": live, "zombies": zombie, "turns": turns.load(Ordering::Relaxed)}),
            );
            w_input.clear();
            w_ls.clear();
            next_window += window;
        }
        next_probe += probe_every;
        // Wait for the session's next probe second: the wall's, or the turns that reach it.
        while now() < next_probe.min(secs as f64) {
            std::thread::sleep(if ticked {
                Duration::from_millis(2)
            } else {
                Duration::from_secs_f64((next_probe - now()).clamp(0.001, probe_every))
            });
        }
    }
    let wall = started.elapsed().as_secs_f64();
    let simulated = now();
    let (rss_end, rss_hwm) = rss_mb(pid);
    stop.store(true, Ordering::Relaxed);
    for t in threads {
        let _ = t.join();
    }
    let what = if ticked {
        format!(
            "{load} chats streaming turns of 50 x 200 B, ticked: the turns of {secs} s of the paced session ({rate:.1} turns/s, 250 ms between a chat's turns, calibrated over {} s) back to back; a probe prompt on an idle chat to its first chunk every {probe_every} s of that session",
            calibrate.as_secs()
        )
    } else {
        format!(
            "{load} chats streaming turns of 50 x 200 B for {secs} s; a probe prompt on an idle chat to its first chunk every {probe_every} s"
        )
    };
    emit(
        "soak",
        json!({"what": what, "mode": if ticked { "ticked" } else { "wall" },
               "duration_s": simulated.round() as u64, "wall_s": (wall * 10.0).round() / 10.0,
               "speedup": ((simulated / wall.max(0.001)) * 10.0).round() / 10.0,
               "paced_turns_per_s": (rate * 10.0).round() / 10.0, "load_chats": load,
               "input_ms": stats(&input), "ls_ms": stats(&ls),
               "rss_mb": {"start": rss_start, "end": rss_end, "max_sampled": rss_max, "hwm": rss_hwm},
               "children_max": children_max, "zombies_max": zombies_max,
               "turns": turns.load(Ordering::Relaxed) - turns_at_start,
               "turn_errors": turn_errors.load(Ordering::Relaxed)}),
    );
    drop(probe);
    daemon.stop();
}
