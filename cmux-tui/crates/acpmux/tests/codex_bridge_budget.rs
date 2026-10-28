//! What one streamed Codex turn costs through the in-process bridge
//! (`codex_app_server.rs`, cmux-codex-acp), at the CLI: a recorded-shape turn
//! from a fixture `codex app-server` (`fake_codex_stream.py`: reasoning, a
//! command that asks permission, 20000 agent message deltas).
//!
//! Guards the perf100 acp-fork win (plans: /tmp/perf100/SPEC.md): Codex runs
//! with no adapter process between acpmux and `codex app-server` (the npm
//! adapter cost about 100 MB RSS and 40 us of CPU per delta per session), and
//! the agent host stays inside a CPU and memory budget. Budgets are several
//! times the measured values (below), so only a real regression fails.
//! Linux only (it reads /proc).
#![cfg(target_os = "linux")]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// The fixture app-server is this test's stand-in agent.
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use serde_json::{Value, json};
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Output;

/// Agent message deltas in the measured turn.
const DELTAS: u64 = 20_000;
/// Agent host CPU per delta. Measured: 22 us (release, Freestyle VM 8 vCPU)
/// and 15 us (debug `cargo test`, rbx).
const MAX_HOST_CPU_NS_PER_DELTA: u64 = 100_000;
/// Agent host resident memory after the turn: 21-24 MB release (Freestyle),
/// 32-58 MB debug (rbx; it varies with the entries the host still buffers).
const MAX_HOST_RSS_KIB: u64 = 128 * 1024;

fn scratch() -> PathBuf {
    let dir = std::env::temp_dir().join(format!("amx-cxb-{}", std::process::id()));
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
fn a_streamed_codex_turn_runs_in_process_within_budget() {
    let dir = scratch();
    let fixture = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fake_codex_stream.py");
    // The bridge takes a program named `codex` whose first argument is `app-server`.
    let codex = dir.join("codex");
    fs::write(
        &codex,
        format!("#!/bin/sh\nexec python3 {} \"$@\"\n", daemon_env::sh_quote(fixture.display())),
    )
    .unwrap();
    fs::set_permissions(&codex, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
    fs::write(
        dir.join("config.json"),
        json!({"harnesses": {"codex-fixture": {"argv": [codex, "app-server"], "family": "codex",
            "env": {"FIX_DELTAS": DELTAS.to_string(), "FIX_LOG": dir.join("fixture.log"), "FIX_TEXT": dir.join("reply.txt")}}}})
            .to_string(),
    )
    .unwrap();

    let _shutdown = Shutdown(&dir);
    // A short turn first: the session, its agent host and the app-server exist.
    let warm = cli(
        &dir,
        &[
            "--json",
            "run",
            "-m",
            "codex-fixture",
            "-n",
            "bench",
            "--policy",
            "approve-all",
            "short warm-up",
        ],
    );
    assert!(warm.status.success(), "warm-up turn: {}", String::from_utf8_lossy(&warm.stderr));
    let daemon: u32 = fs::read_to_string(dir.join("daemon.pid")).unwrap().trim().parse().unwrap();
    let before: HashMap<u32, u64> = tree(daemon).into_iter().map(|p| (p, cpu_ns(p))).collect();

    let sent = cli(&dir, &["--json", "send", "bench", "run the tests and explain"]);
    assert!(sent.status.success(), "measured turn: {}", String::from_utf8_lossy(&sent.stderr));

    let procs = tree(daemon);
    let reply = String::from_utf8_lossy(&cli(&dir, &["last", "bench"]).stdout).trim().to_owned();
    let log = fs::read_to_string(dir.join("fixture.log")).unwrap_or_default();
    let report: Vec<Value> = procs
        .iter()
        .map(|&p| {
            json!({"pid": p, "cmd": cmdline(p).chars().take(80).collect::<String>(),
                   "cpu_ms": cpu_ns(p).saturating_sub(before.get(&p).copied().unwrap_or(0)) as f64 / 1e6, "rss_kib": rss_kib(p)})
        })
        .collect();
    eprintln!("processes after the turn: {}", serde_json::to_string_pretty(&report).unwrap());

    // Behavior: the fixture streamed every delta, the reply is its message
    // (`last` may show only its end), and the permission reached the
    // app-server as approved.
    let sent_text = fs::read_to_string(dir.join("reply.txt")).unwrap_or_default();
    assert!(log.contains(&format!("agent-deltas {DELTAS}")), "the fixture saw: {log}");
    assert!(
        reply.len() > 1000 && sent_text.trim_end().ends_with(&reply),
        "the reply ({} bytes) is not the end of the streamed message ({} bytes): {:.200}",
        reply.len(),
        sent_text.len(),
        reply
    );
    assert!(log.contains("approval-decision accept"), "the fixture saw: {log}");

    // No adapter process: everything under the daemon is acpmux or the fixture.
    for p in &procs {
        let cmd = cmdline(*p);
        assert!(
            cmd.contains("acpmux") || cmd.contains("fake_codex_stream.py") || cmd.is_empty(),
            "an extra process runs under the daemon: {cmd}"
        );
    }
    let host = procs
        .iter()
        .copied()
        .find(|&p| cmdline(p).contains("__agent-host"))
        .expect("the session runs in an agent host");
    {
        let row = report.iter().find(|r| r["pid"] == host).unwrap();
        let ns_per_delta = (row["cpu_ms"].as_f64().unwrap() * 1e6) as u64 / DELTAS;
        assert!(
            ns_per_delta <= MAX_HOST_CPU_NS_PER_DELTA,
            "the agent host used {ns_per_delta} ns of CPU per delta (budget {MAX_HOST_CPU_NS_PER_DELTA})"
        );
        let rss = row["rss_kib"].as_u64().unwrap();
        assert!(
            rss <= MAX_HOST_RSS_KIB,
            "the agent host holds {rss} KiB (budget {MAX_HOST_RSS_KIB})"
        );
    }
}
