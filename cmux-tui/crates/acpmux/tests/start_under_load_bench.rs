//! Agent start under machine load (hq W6, 2026-11-12): on Leo's Mac at load average 125 to 256,
//! waking an agent took 10 to 82 s, and one `agent_start` ran out its 90 s having used 1.8 s of
//! CPU. A start that gets CPU only after everything else on the machine waits on the machine, not
//! on its own work. The bar: send-to-first-token at load 100 within 1.2x of an idle machine.
//!
//! A real daemon (`daemon run`) with a stand-in harness (`fake_agent.py`) that spends
//! [`BOOT_CPU_MS`] of CPU time before it reads anything, as a real harness spends CPU loading its
//! code. Each sample:
//!
//! - cold: `session/new` (an agent host and its harness start) then `session/prompt`; from the
//!   `session/new` send to the turn's first `agent_message_chunk`;
//! - warm: a second prompt on the same session; from its send to its first chunk.
//!
//! First on an idle machine, then with [`LOAD`] busy loops this test starts (each a `/bin/sh`
//! spinning, at the test's own priority, as a build's compilers would be), and the p50 and p95 of
//! each are printed with the loaded/idle ratio.
//!
//! `cargo test -p acpmux --release --test start_under_load_bench -- --ignored --nocapture`
//! (`START_BENCH_LOAD`, `START_BENCH_SAMPLES` override the load and the sample count;
//! `START_BENCH_LOAD_NICE` runs the loops at that nice: 0 is load from outside acpmux, 5 (Linux)
//! the agent tier's, as the tools of other agents run; `START_BENCH_SPARE=1` lets the daemon keep its
//! warm spare harness (`hub/pool/spare.rs`), which the hermetic environment turns off;
//! `START_BENCH_ASSERT=1` fails when a loaded p95 is past 1.2x the idle one).
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// The daemon this test starts runs tests/fake_agent.py only.
// The knobs below are the bench's own, not the host's: kept through the hermetic re-start.
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in().keep(&[
    "START_BENCH_LOAD",
    "START_BENCH_SAMPLES",
    "START_BENCH_LOAD_NICE",
    "START_BENCH_SPARE",
    "START_BENCH_ASSERT",
]);

use serde_json::{Value, json};
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Stdio};
use std::time::{Duration, Instant};

/// Busy loops for the loaded half: load average about 100.
const LOAD: usize = 100;
/// Samples per half.
const SAMPLES: usize = 12;
/// The stand-in's CPU time before it reads its first line.
const BOOT_CPU_MS: u64 = 300;
/// The bar: a loaded p95 at most this times the idle one.
const BAR: f64 = 1.2;

fn knob(name: &str, default: usize) -> usize {
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
        s.set_read_timeout(Some(Duration::from_secs(300))).unwrap();
        Self { reader: BufReader::new(s.try_clone().unwrap()), writer: s, next: 0 }
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

    fn call(&mut self, method: &str, params: Value) -> Value {
        let id = self.send(method, params);
        loop {
            let v = self.line();
            if v.get("id") == Some(&json!(id)) && v.get("method").is_none() {
                assert!(v.get("error").is_none(), "{method} failed: {v}");
                return v["result"].clone();
            }
        }
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
}

struct Daemon(Child);

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn start(scratch: &Path, home: &Path) -> (Daemon, PathBuf) {
    let socket = scratch.join("s.sock");
    let mut child = daemon_env::command(scratch, daemon_env::Agents::StandIn, &[])
        .args(["daemon", "run", "--ready-fd", "1", "--log", "warn"])
        .env("ACPMUX_HOME", home)
        .env("ACPMUX_SOCKET", &socket)
        .env("ACPMUX_SPARE_HARNESS", if knob("START_BENCH_SPARE", 0) == 1 { "1" } else { "0" })
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
    (Daemon(child), socket)
}

/// The busy loops: each a `/bin/sh` spinning, ended by pid when dropped.
struct Load(Vec<Child>);

impl Load {
    fn start(n: usize, nice: usize) -> Self {
        let loops = (0..n)
            .map(|_| {
                // `nice -n` adds to this process's nice.
                std::process::Command::new("nice")
                    .args(["-n", &nice.to_string(), "/bin/sh", "-c", "while :; do :; done"])
                    .stdin(Stdio::null())
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .spawn()
                    .expect("start a busy loop")
            })
            .collect();
        // Let the scheduler's load settle on them.
        std::thread::sleep(Duration::from_secs(3));
        Self(loops)
    }
}

impl Drop for Load {
    fn drop(&mut self) {
        for child in &mut self.0 {
            let _ = child.kill();
        }
        for child in &mut self.0 {
            let _ = child.wait();
        }
    }
}

/// `samples` cold and warm sends: (cold, warm) times.
fn measure(socket: &Path, work: &Path, samples: usize) -> (Vec<Duration>, Vec<Duration>) {
    let mut cold = Vec::new();
    let mut warm = Vec::new();
    for i in 0..samples {
        let mut rpc = Rpc::connect(socket);
        rpc.call("initialize", json!({"protocolVersion": 1}));
        let from = Instant::now();
        let made = rpc.call("session/new", json!({"cwd": work, "mcpServers": []}));
        let id = made["sessionId"].as_str().expect("session/new gave no sessionId").to_owned();
        cold.push(rpc.prompt(&id, &format!("cold {i}"), from));
        warm.push(rpc.prompt(&id, &format!("warm {i}"), Instant::now()));
        // The session ends with its harness, so samples do not pile up processes.
        rpc.call("_acpmux/kill", json!({"sessionId": id}));
    }
    (cold, warm)
}

fn percentile(samples: &[Duration], p: f64) -> Duration {
    let mut sorted = samples.to_vec();
    sorted.sort_unstable();
    let at = ((sorted.len() as f64 - 1.0) * p).round() as usize;
    sorted[at]
}

fn ms(d: Duration) -> f64 {
    d.as_secs_f64() * 1000.0
}

#[test]
#[ignore = "bench: run by hand with --ignored --nocapture"]
fn send_to_first_token_at_load_100_is_within_1_2x_of_idle() {
    let load = knob("START_BENCH_LOAD", LOAD);
    let samples = knob("START_BENCH_SAMPLES", SAMPLES);
    let scratch = std::env::temp_dir().join(format!(
        "amx-startload-{}-{}",
        std::process::id(),
        uuid::Uuid::now_v7().simple()
    ));
    let home = scratch.join("acpmux");
    fs::create_dir_all(&home).unwrap();
    let work = scratch.join("work");
    fs::create_dir_all(&work).unwrap();
    let config = json!({
        "harnesses": {"fake": {
            "argv": ["python3", concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py")],
            "env": {"FAKE_BOOT_CPU_MS": BOOT_CPU_MS.to_string()}
        }},
        "defaultHarness": "fake", "permissionPolicy": "approve-all"
    });
    fs::write(home.join("config.json"), config.to_string()).unwrap();
    let (daemon, socket) = start(&scratch, &home);

    // One start first, so the daemon's own first-use work is not in a sample.
    measure(&socket, &work, 1);
    let (idle_cold, idle_warm) = measure(&socket, &work, samples);
    let load_nice = knob("START_BENCH_LOAD_NICE", 0);
    let busy = Load::start(load, load_nice);
    let (load_cold, load_warm) = measure(&socket, &work, samples);
    drop(busy);
    drop(daemon);
    let _ = fs::remove_dir_all(&scratch);

    let cpus = std::thread::available_parallelism().map_or(0, |n| n.get());
    println!(
        "start_under_load_bench: {cpus} CPUs, {load} busy loops at nice +{load_nice}, {samples} samples, spare {}, \
         harness boot {BOOT_CPU_MS} ms CPU",
        knob("START_BENCH_SPARE", 0) == 1
    );
    #[cfg(target_os = "linux")]
    println!(
        "  scheduler: autogroup {} ({}), cgroup {}",
        fs::read_to_string("/proc/sys/kernel/sched_autogroup_enabled").unwrap_or_default().trim(),
        fs::read_to_string("/proc/self/autogroup").unwrap_or_default().trim(),
        fs::read_to_string("/proc/self/cgroup").unwrap_or_default().trim()
    );
    let mut over = Vec::new();
    for (what, idle, loaded) in
        [("cold (start + send)", &idle_cold, &load_cold), ("warm (send)", &idle_warm, &load_warm)]
    {
        let (i50, i95) = (percentile(idle, 0.5), percentile(idle, 0.95));
        let (l50, l95) = (percentile(loaded, 0.5), percentile(loaded, 0.95));
        let ratio = ms(l95) / ms(i95).max(0.001);
        println!(
            "  {what}: idle p50 {:.0} ms p95 {:.0} ms | load p50 {:.0} ms p95 {:.0} ms | \
             p95 ratio {ratio:.2}x",
            ms(i50),
            ms(i95),
            ms(l50),
            ms(l95)
        );
        if ratio > BAR {
            over.push(format!("{what}: {ratio:.2}x"));
        }
    }
    if std::env::var_os("START_BENCH_ASSERT").is_some_and(|v| v == "1") {
        assert!(over.is_empty(), "past {BAR}x of idle at load {load}: {}", over.join(", "));
    }
}
