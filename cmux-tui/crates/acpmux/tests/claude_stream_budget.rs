//! What one streamed Claude Code turn costs on the claude-stdio path (perf100, 2026-10-21):
//! the path Lawrence's chats use (about 8,300 sessions in 7 days). A recorded-shape turn
//! from a stand-in Claude Code (`fake_claude_stream.py`: 20,000 text deltas with
//! `--include-partial-messages`), at the CLI. Each delta is a raw `claude.stream_event`
//! record and a translated `agent_message_chunk`; the agent host translates and frames
//! them, the daemon logs and fans them out.
//!
//! Budgets are about 3x the measured debug values (below), so only a real regression fails.
//! Linux only (it reads /proc).
#![cfg(target_os = "linux")]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// The stand-in Claude Code is this test's agent.
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use serde_json::json;
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Output;

/// Text deltas in the measured turn.
const DELTAS: u64 = 20_000;
/// Agent host CPU per delta. Release on rbx: 27 us before the single-encode change
/// (26e79e1a8483), 13 us after. Debug `cargo test`: HOST_DEBUG.
const MAX_HOST_CPU_NS_PER_DELTA: u64 = 1_000_000;
/// Daemon CPU per delta (log, ring, fan-out to the CLI). Release on rbx: 90 us before,
/// 78 us after. Debug: DAEMON_DEBUG.
const MAX_DAEMON_CPU_NS_PER_DELTA: u64 = 1_000_000;

fn scratch() -> PathBuf {
    let dir = std::env::temp_dir().join(format!("amx-csb-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(dir.join("p")).unwrap();
    dir
}

fn cli(dir: &Path, args: &[&str]) -> Output {
    daemon_env::command(dir, daemon_env::Agents::StandIn, &[])
        .args(args)
        .env("ACPMUX_HOME", dir)
        .env("ACPMUX_LOGIN_ENV", "0")
        .current_dir(dir.join("p"))
        .output()
        .unwrap()
}

fn proc_ids() -> Vec<u32> {
    fs::read_dir("/proc")
        .unwrap()
        .filter_map(|e| e.ok()?.file_name().to_str()?.parse().ok())
        .collect()
}

fn parent(pid: u32) -> Option<u32> {
    let stat = fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    stat[stat.rfind(')')? + 2..].split(' ').nth(1)?.parse().ok()
}

fn cmdline(pid: u32) -> String {
    fs::read(format!("/proc/{pid}/cmdline"))
        .map(|b| String::from_utf8_lossy(&b).replace('\0', " "))
        .unwrap_or_default()
}

/// The daemon and every process under it.
fn tree(daemon: u32) -> Vec<u32> {
    let parents: HashMap<u32, Option<u32>> =
        proc_ids().into_iter().map(|p| (p, parent(p))).collect();
    let mut out = vec![daemon];
    let mut i = 0;
    while i < out.len() {
        let at = out[i];
        out.extend(parents.iter().filter(|(_, pp)| **pp == Some(at)).map(|(p, _)| *p));
        i += 1;
    }
    out
}

/// CPU time of `pid` (utime + stime, which keeps the time of threads that
/// already exited), in ns.
fn cpu_ns(pid: u32) -> u64 {
    let Ok(stat) = fs::read_to_string(format!("/proc/{pid}/stat")) else { return 0 };
    let Some(at) = stat.rfind(')') else { return 0 };
    let fields: Vec<&str> = stat[at + 2..].split(' ').collect();
    let ticks: u64 =
        fields.get(11..13).map_or(0, |f| f.iter().filter_map(|t| t.parse::<u64>().ok()).sum());
    // SAFETY: sysconf has no preconditions.
    let hz = unsafe { libc::sysconf(libc::_SC_CLK_TCK) }.max(1) as u64;
    ticks * 1_000_000_000 / hz
}

/// Ends the daemon and its agents however the test ends.
struct Shutdown<'a>(&'a Path);

impl Drop for Shutdown<'_> {
    fn drop(&mut self) {
        let _ = cli(self.0, &["daemon", "shutdown", "--end-agents"]);
        let _ = fs::remove_dir_all(self.0);
    }
}

fn rss_kib(pid: u32) -> u64 {
    fs::read_to_string(format!("/proc/{pid}/status"))
        .ok()
        .and_then(|s| {
            s.lines().find(|l| l.starts_with("VmRSS:"))?.split_whitespace().nth(1)?.parse().ok()
        })
        .unwrap_or(0)
}

#[test]
fn a_streamed_claude_turn_stays_within_its_cpu_budget() {
    let dir = scratch();
    let fixture = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fake_claude_stream.py");
    fs::write(
        dir.join("config.json"),
        json!({"harnesses": {"claude-fixture": {"kind": "claude-stdio", "argv": ["python3", fixture],
            "env": {"STREAM_TOKENS": DELTAS.to_string(), "FIX_TEXT": dir.join("reply.txt")}}}})
            .to_string(),
    )
    .unwrap();

    let _shutdown = Shutdown(&dir);
    // A first turn: the session, its agent host and the stand-in exist.
    let warm = cli(
        &dir,
        &[
            "--json",
            "run",
            "-m",
            "claude-fixture",
            "-n",
            "bench",
            "--policy",
            "approve-all",
            "warm up",
        ],
    );
    assert!(warm.status.success(), "warm-up turn: {}", String::from_utf8_lossy(&warm.stderr));
    let daemon: u32 = fs::read_to_string(dir.join("daemon.pid")).unwrap().trim().parse().unwrap();
    let before: HashMap<u32, u64> = tree(daemon).into_iter().map(|p| (p, cpu_ns(p))).collect();

    let sent = cli(&dir, &["--json", "send", "bench", "write the report"]);
    assert!(sent.status.success(), "measured turn: {}", String::from_utf8_lossy(&sent.stderr));

    let procs = tree(daemon);
    let spent = |p: u32| cpu_ns(p).saturating_sub(before.get(&p).copied().unwrap_or(0));
    let reply = String::from_utf8_lossy(&cli(&dir, &["last", "bench"]).stdout).trim().to_owned();
    let streamed = fs::read_to_string(dir.join("reply.txt")).unwrap_or_default();
    assert!(
        reply.len() > 1000 && streamed.trim_end().ends_with(&reply),
        "the reply ({} bytes) is not the end of the streamed message ({} bytes): {:.200}",
        reply.len(),
        streamed.len(),
        reply
    );
    let host = procs
        .iter()
        .copied()
        .find(|&p| cmdline(p).contains("__agent-host"))
        .expect("the session runs in an agent host");
    let host_ns = spent(host) / DELTAS;
    let daemon_ns = spent(daemon) / DELTAS;
    println!(
        "acpmux-claude-stream: {}",
        json!({"deltas": DELTAS, "host_ns_per_delta": host_ns, "daemon_ns_per_delta": daemon_ns,
               "host_rss_kib": rss_kib(host), "daemon_rss_kib": rss_kib(daemon)})
    );
    assert!(
        host_ns <= MAX_HOST_CPU_NS_PER_DELTA,
        "the agent host used {host_ns} ns of CPU per delta (budget {MAX_HOST_CPU_NS_PER_DELTA})"
    );
    assert!(
        daemon_ns <= MAX_DAEMON_CPU_NS_PER_DELTA,
        "the daemon used {daemon_ns} ns of CPU per delta (budget {MAX_DAEMON_CPU_NS_PER_DELTA})"
    );
}
