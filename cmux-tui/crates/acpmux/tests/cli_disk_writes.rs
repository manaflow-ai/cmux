//! Bytes the daemon writes per CLI invocation (cmuxterm-hq#9263: macOS's "disk writes" limit
//! fired for `bin/cmux` on Leo's laptop, 549 GB in 23.6 h, in `JournalStore::append`). Each
//! invocation is `acpmux send` of one prompt to a Claude chat on the stand-in Claude Code
//! (`fake_claude_stream.py`): the prompt's `user_message`, the ACP `session/prompt` and Claude
//! Code's stdin line of it are logged, and the journal writes each line again.
//!
//! Prints `acpmux-cli-disk-writes: {...}` with the daemon's write counters (`/proc/<pid>/io`:
//! `wchar`, bytes passed to `write`, sockets included; `write_bytes`, bytes dirtied for the
//! disk) and the home's growth, per invocation and per 1,000. Linux only (it reads /proc).
//! It runs in the acpmux suite (100 calls, about 20 s in a debug build), so a change that copies
//! a prompt into the log again fails CI; `ACPMUX_DISK_BENCH_SENDS=1000` gives the PR numbers, and
//! `ACPMUX_DISK_BENCH_PROMPT_BYTES` changes the prompt.
#![cfg(target_os = "linux")]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// The stand-in Claude Code is this test's agent.
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use serde_json::json;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Output;

fn scratch() -> PathBuf {
    let dir = std::env::temp_dir().join(format!("amx-cdw-{}", std::process::id()));
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

/// `/proc/<pid>/io` field `key`.
fn io(pid: u32, key: &str) -> u64 {
    fs::read_to_string(format!("/proc/{pid}/io"))
        .ok()
        .and_then(|s| {
            s.lines().find_map(|l| l.strip_prefix(key)?.strip_prefix(": ")?.trim().parse().ok())
        })
        .unwrap_or(0)
}

/// Bytes of every file under `dir`.
fn tree_bytes(dir: &Path) -> u64 {
    let Ok(entries) = fs::read_dir(dir) else { return 0 };
    entries
        .filter_map(Result::ok)
        .map(|e| match e.file_type() {
            Ok(t) if t.is_dir() => tree_bytes(&e.path()),
            Ok(t) if t.is_file() => e.metadata().map_or(0, |m| m.len()),
            _ => 0,
        })
        .sum()
}

fn env_or(key: &str, default: usize) -> usize {
    std::env::var(key).ok().and_then(|v| v.parse().ok()).unwrap_or(default)
}

/// Ends the daemon and its agents however the test ends.
struct Shutdown<'a>(&'a Path);

impl Drop for Shutdown<'_> {
    fn drop(&mut self) {
        let _ = cli(self.0, &["daemon", "shutdown", "--end-agents"]);
        let _ = fs::remove_dir_all(self.0);
    }
}

#[test]
fn bytes_written_per_1000_cli_invocations() {
    let sends = env_or("ACPMUX_DISK_BENCH_SENDS", 100).max(1);
    let prompt_bytes = env_or("ACPMUX_DISK_BENCH_PROMPT_BYTES", 16 * 1024);
    let dir = scratch();
    let fixture = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fake_claude_stream.py");
    fs::write(
        dir.join("config.json"),
        json!({"harnesses": {"claude-fixture": {"kind": "claude-stdio", "argv": ["python3", fixture],
            "env": {"STREAM_TOKENS": "8"}}}, "titles": {"generate": false}})
        .to_string(),
    )
    .unwrap();
    let _shutdown = Shutdown(&dir);
    let warm = cli(
        &dir,
        &["--json", "run", "-m", "claude-fixture", "-n", "bench", "--policy", "approve-all", "hi"],
    );
    assert!(warm.status.success(), "warm-up turn: {}", String::from_utf8_lossy(&warm.stderr));
    let daemon: u32 = fs::read_to_string(dir.join("daemon.pid")).unwrap().trim().parse().unwrap();
    // A prompt as a script or a Chief compactor sends one: one long text, unique per call.
    let body: String = "The compactor folds this transcript into one node. "
        .repeat(prompt_bytes / 51 + 1)
        .chars()
        .take(prompt_bytes)
        .collect();
    let (wchar0, disk0, home0) = (io(daemon, "wchar"), io(daemon, "write_bytes"), tree_bytes(&dir));
    let started = std::time::Instant::now();
    for i in 0..sends {
        let prompt = format!("call {i}\n{body}");
        let sent = cli(&dir, &["--json", "send", "bench", &prompt]);
        assert!(sent.status.success(), "send {i}: {}", String::from_utf8_lossy(&sent.stderr));
    }
    let wchar = io(daemon, "wchar").saturating_sub(wchar0);
    let disk = io(daemon, "write_bytes").saturating_sub(disk0);
    let home = tree_bytes(&dir).saturating_sub(home0);
    let per = |v: u64| v / sends as u64;
    let report = json!({
        "sends": sends, "prompt_bytes": prompt_bytes, "secs": started.elapsed().as_secs(),
        "daemon_wchar": wchar, "daemon_write_bytes": disk, "home_growth": home,
        "wchar_per_call": per(wchar), "write_bytes_per_call": per(disk), "home_growth_per_call": per(home),
        "wchar_per_1000": per(wchar) * 1000, "home_growth_per_1000": per(home) * 1000,
    });
    println!("acpmux-cli-disk-writes: {report}");
    // Each call's prompt is in its log once (`user_message`) and in the log's kind index once,
    // with the records of its turn; the ACP request and the stdin line keep no copy of a long body
    // (`logged_bodies.rs`). On cmux-ci, 16 KiB prompts: 81,755 bytes a call before, 50,523 after.
    let budget = 3 * prompt_bytes as u64 + 16 * 1024;
    assert!(
        per(home) <= budget,
        "the home grew {} bytes per call (budget {budget}): {report}",
        per(home)
    );
    // What the daemon passed to `write` (files and sockets): a file rewritten at the same size
    // passes the growth check above and fails this one. 149,153 bytes a call before #41526,
    // 50,799 after, for 16 KiB prompts.
    let written = 4 * prompt_bytes as u64 + 32 * 1024;
    assert!(
        per(wchar) <= written,
        "the daemon wrote {} bytes per call (budget {written}): {report}",
        per(wchar)
    );
}
