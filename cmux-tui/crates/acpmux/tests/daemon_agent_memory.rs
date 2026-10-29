//! The daemon's memory per agent while many agents stream at once. With
//! about 110 agents a daemon held 2.6 GB, about 24 MB per agent
//! (plans/cmux-next/resource-efficiency-DESIGN.md, offender 6): each agent's host connection
//! queued up to 4096 decoded entries the daemon had not logged yet, and with more than 64
//! agents writing, every record closed and synced another chat's log, so the queues stayed full.
//!
//! The real daemon binary runs here with `ACPMUX_AGENTS_BENCH_N` (default 100) fake agents that
//! each stream `ACPMUX_AGENTS_BENCH_CHUNKS` chunks of `ACPMUX_AGENTS_BENCH_BYTES` bytes per
//! round, all at once. It is a bench, not a unit test (100 agent processes and their hosts):
//! `scripts/measure/acpmux-overhead.sh bench=agents` runs it on a quiet fleet Mac, before and
//! after a change. It prints one `ACPMUX-AGENTS {json}` line and fails when the daemon's resident
//! bytes over its idle start, per agent, exceed `ACPMUX_AGENTS_BUDGET_KB` (default 2048; 0
//! measures only). `ACPMUX_AGENTS_BENCH_WORKERS` sets the daemon's runtime threads
//! (`TOKIO_WORKER_THREADS`; default: one per core, as shipped), so a many-core Linux box can
//! measure what a Mac's 10 to 14 cores run: on 360 cores, glibc's malloc arenas per thread
//! alone hold about 3 MB per agent.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// The bench's own knobs, set by acpmux-overhead.sh bench=agents.
const HERMETIC: daemon_env::Process = daemon_env::Process::deny().keep(&[
    "ACPMUX_AGENTS_BENCH_N",
    "ACPMUX_AGENTS_BENCH_CHUNKS",
    "ACPMUX_AGENTS_BENCH_BYTES",
    "ACPMUX_AGENTS_BENCH_ROUNDS",
    "ACPMUX_AGENTS_BENCH_WORKERS",
    "ACPMUX_AGENTS_BUDGET_KB",
]);

use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Stdio};
use std::time::{Duration, Instant};

/// How long one round of every agent's stream may take.
const ROUND_TIMEOUT: Duration = Duration::from_secs(600);

struct Rpc {
    reader: BufReader<UnixStream>,
    writer: UnixStream,
    next: u64,
}

impl Rpc {
    fn connect(path: &Path) -> Self {
        let s = UnixStream::connect(path).expect("connect to daemon socket");
        s.set_read_timeout(Some(ROUND_TIMEOUT)).unwrap();
        Self { reader: BufReader::new(s.try_clone().unwrap()), writer: s, next: 0 }
    }

    fn call(&mut self, method: &str, params: Value) -> Value {
        self.next += 1;
        let line = json!({"jsonrpc": "2.0", "id": self.next, "method": method, "params": params});
        self.writer.write_all(format!("{line}\n").as_bytes()).unwrap();
        loop {
            let mut text = String::new();
            assert!(self.reader.read_line(&mut text).unwrap() > 0, "daemon closed the socket");
            let v: Value = serde_json::from_str(&text).unwrap();
            if v.get("id") == Some(&json!(self.next)) {
                assert!(v.get("error").is_none(), "{method} failed: {v}");
                return v["result"].clone();
            }
        }
    }
}

struct Daemon {
    child: Child,
    dir: PathBuf,
    socket: PathBuf,
}

impl Daemon {
    fn start(dir: PathBuf, workers: Option<u64>) -> Self {
        let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
        let config = json!({
            "harnesses": {"fake": {"argv": ["python3", fake]}},
            "defaultHarness": "fake",
        });
        private_file(&dir.join("config.json"), &config.to_string());
        let socket = dir.join("s.sock");
        let mut daemon = daemon_env::command(&dir, daemon_env::Agents::StandIn, &[]);
        if let Some(workers) = workers {
            daemon.env("TOKIO_WORKER_THREADS", workers.to_string());
        }
        let mut child = daemon
            .args(["daemon", "run", "--ready-fd", "1", "--log", "warn"])
            .env("ACPMUX_HOME", &dir)
            .env("ACPMUX_SOCKET", &socket)
            .env("ACPMUX_LOGIN_ENV", "0")
            // No catalog fetch: the bench never reaches the network.
            .env("ACPMUX_CATALOG_FETCH", "0")
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .unwrap();
        let stdout = child.stdout.take().unwrap();
        let ready = BufReader::new(stdout).lines().map_while(Result::ok).find_map(|line| {
            serde_json::from_str::<Value>(&line).ok().filter(|v| v["ready"] == true)
        });
        if ready.is_none() {
            let _ = child.kill();
            panic!("the daemon exited without a readiness line: {:?}", child.wait());
        }
        Self { child, dir, socket }
    }

    /// Resident bytes of the daemon process (not its agents or their hosts).
    fn rss_bytes(&self) -> u64 {
        let out = std::process::Command::new("ps")
            .args(["-o", "rss=", "-p", &self.child.id().to_string()])
            .output()
            .unwrap();
        String::from_utf8_lossy(&out.stdout).trim().parse::<u64>().unwrap() * 1024
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        // SAFETY: the pid is this test's own child.
        unsafe { libc::kill(self.child.id() as i32, libc::SIGTERM) };
        let _ = self.child.wait();
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

fn scratch() -> PathBuf {
    // Short: the socket path must stay under the macOS limit.
    let dir = std::env::temp_dir().join(format!("amx-agents-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    private_dir(&dir);
    dir
}

fn private_dir(path: &Path) {
    use std::os::unix::fs::PermissionsExt;
    std::fs::create_dir_all(path).unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700)).unwrap();
}

fn private_file(path: &Path, text: &str) {
    use std::os::unix::fs::PermissionsExt;
    std::fs::write(path, text).unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600)).unwrap();
}

fn env_or(name: &str, default: u64) -> u64 {
    std::env::var(name).ok().and_then(|v| v.parse().ok()).unwrap_or(default)
}

/// Sends `text` to every session at once on one connection, as the app does, and waits for
/// every turn. (A connection per prompt measures the fan-out instead: each connection's task
/// reads every record of every chat, so 100 of them lag the event ring.)
fn prompt_all(rpc: &mut Rpc, sessions: &[String], text: &str) {
    let mut waiting = std::collections::HashSet::new();
    for id in sessions {
        rpc.next += 1;
        let params = json!({"sessionId": id, "prompt": [{"type": "text", "text": text}]});
        let line =
            json!({"jsonrpc": "2.0", "id": rpc.next, "method": "session/prompt", "params": params});
        rpc.writer.write_all(format!("{line}\n").as_bytes()).unwrap();
        waiting.insert(rpc.next);
    }
    while !waiting.is_empty() {
        let mut text = String::new();
        assert!(rpc.reader.read_line(&mut text).unwrap() > 0, "daemon closed the socket");
        let v: Value = serde_json::from_str(&text).unwrap();
        if let Some(id) = v.get("id").and_then(Value::as_u64)
            && waiting.remove(&id)
        {
            assert!(v.get("error").is_none(), "session/prompt failed: {v}");
        }
    }
}

fn mib(bytes: u64) -> f64 {
    bytes as f64 / f64::from(1 << 20)
}

#[test]
#[ignore = "a bench: 100 agent processes; scripts/measure/acpmux-overhead.sh bench=agents runs it"]
fn many_streaming_agents_stay_within_the_daemon_budget_per_agent() {
    let agents = env_or("ACPMUX_AGENTS_BENCH_N", 100);
    let chunks = env_or("ACPMUX_AGENTS_BENCH_CHUNKS", 1000);
    let bytes = env_or("ACPMUX_AGENTS_BENCH_BYTES", 2048);
    let rounds = env_or("ACPMUX_AGENTS_BENCH_ROUNDS", 2);
    let budget_kb = env_or("ACPMUX_AGENTS_BUDGET_KB", 2048);
    let workers = std::env::var("ACPMUX_AGENTS_BENCH_WORKERS").ok().and_then(|v| v.parse().ok());
    let dir = scratch();
    let daemon = Daemon::start(dir.clone(), workers);
    let idle = daemon.rss_bytes();
    let mut rpc = Rpc::connect(&daemon.socket);
    let sessions: Vec<String> = (0..agents)
        .map(|i| {
            let cwd = dir.join(format!("w{i}"));
            private_dir(&cwd);
            let created = rpc.call("session/new", json!({"cwd": cwd, "mcpServers": []}));
            created["sessionId"].as_str().unwrap_or_else(|| panic!("{created}")).to_owned()
        })
        .collect();
    // Every agent started and answered once: its host, its link and its record.
    prompt_all(&mut rpc, &sessions, "stream:1:16");
    let started = daemon.rss_bytes();
    let begun = Instant::now();
    let mut peak = started;
    for _ in 0..rounds {
        prompt_all(&mut rpc, &sessions, &format!("stream:{chunks}:{bytes}"));
        peak = peak.max(daemon.rss_bytes());
    }
    let streamed_s = begun.elapsed().as_secs_f64();
    let end = daemon.rss_bytes();
    let per_agent = end.saturating_sub(idle) / agents;
    let report = json!({
        "agents": agents, "chunks": chunks, "bytes": bytes, "rounds": rounds,
        "idle_mb": mib(idle), "started_mb": mib(started), "peak_mb": mib(peak), "end_mb": mib(end),
        "per_agent_kb": per_agent / 1024, "budget_kb": budget_kb, "streamed_s": streamed_s,
        "workers": workers,
    });
    println!("ACPMUX-AGENTS {report}");
    assert!(
        budget_kb == 0 || per_agent / 1024 <= budget_kb,
        "the daemon holds {} KB per agent over its idle start (budget {budget_kb} KB): {report}",
        per_agent / 1024
    );
}
