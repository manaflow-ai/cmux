//! An agent's start runs at the daemon's priority, and its harness yields once the start is over
//! (`qos.rs`, `cpu_class.rs`; W6, 2026-11-12). Under the utility clamp (macOS) or nice +5 (Linux)
//! from its host's first instruction, a start on a machine at load average 125 to 256 waited 10
//! to 82 s for the CPU, and one ran out its 90 s with 1.8 s of CPU used.
//!
//! A real daemon starts a hosted stand-in harness (`fake_agent.py`), which logs its own nice as it
//! answers `session/new` (`FAKE_CLASS_LOG`): the daemon's. After its first turn, its nice is the
//! agent tier's (`qos::AGENT_NICE`).
#![cfg(any(target_os = "linux", target_os = "macos"))]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// The daemon this test starts runs tests/fake_agent.py only.
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use serde_json::{Value, json};
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Stdio};
use std::time::{Duration, Instant};

struct Daemon(Child);

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn start(scratch: &Path, home: &Path) -> (Daemon, PathBuf) {
    let socket = scratch.join("s.sock");
    let mut child = daemon_env::command(scratch, daemon_env::Agents::StandIn, &["ps"])
        .args(["daemon", "run", "--ready-fd", "1", "--log", "warn"])
        .env("ACPMUX_HOME", home)
        .env("ACPMUX_SOCKET", &socket)
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

fn call(socket: &Path, calls: &[(&str, Value)]) -> Vec<Value> {
    let s = UnixStream::connect(socket).expect("connect to the daemon socket");
    s.set_read_timeout(Some(Duration::from_secs(120))).unwrap();
    let mut reader = BufReader::new(s.try_clone().unwrap());
    let mut writer = s;
    let mut out = Vec::new();
    let mut session = Value::Null;
    for (id, (method, params)) in calls.iter().enumerate() {
        let mut params = params.clone();
        if params.get("sessionId") == Some(&json!("$session")) {
            params["sessionId"] = session.clone();
        }
        let line = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
        writer.write_all(format!("{line}\n").as_bytes()).unwrap();
        let result = loop {
            let mut text = String::new();
            assert!(reader.read_line(&mut text).unwrap() > 0, "the daemon closed the socket");
            let Ok(v) = serde_json::from_str::<Value>(&text) else { continue };
            if v.get("id") == Some(&json!(id)) && v.get("method").is_none() {
                assert!(v.get("error").is_none(), "{method} failed: {v}");
                break v["result"].clone();
            }
        };
        if let Some(id) = result.get("sessionId") {
            session = id.clone();
        }
        out.push(result);
    }
    out
}

fn nice_of(pid: u32) -> Option<i32> {
    // Linux: field 19 of `/proc/<pid>/stat`, the main thread's nice (`ps` is not on the hermetic
    // PATH of this process).
    #[cfg(target_os = "linux")]
    {
        let stat = fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
        stat[stat.rfind(')')? + 2..].split(' ').nth(16)?.parse().ok()
    }
    #[cfg(target_os = "macos")]
    {
        let out = std::process::Command::new("/bin/ps")
            .args(["-o", "nice=", "-p", &pid.to_string()])
            .output()
            .ok()?;
        String::from_utf8_lossy(&out.stdout).trim().parse().ok()
    }
}

/// `normal`: what the hermetic environment gives a stand-in (`daemon_env::vars`).
#[test]
fn a_harness_starts_at_the_daemons_priority_and_yields_once_started() {
    starts_at_the_daemons_priority_and_yields("normal");
}

/// `background`: the product's default for every harness but a Claude Code launcher
/// (`cpu_class::DEFAULT`). Linux has no background class, so the agent tier's nice is all the
/// lowering it gets there; on macOS the harness is also in background class.
#[test]
fn a_background_class_harness_also_yields_to_the_agent_tier() {
    starts_at_the_daemons_priority_and_yields("background");
}

fn starts_at_the_daemons_priority_and_yields(class: &str) {
    let scratch = std::env::temp_dir().join(format!(
        "amx-startpri-{}-{}",
        std::process::id(),
        uuid::Uuid::now_v7().simple()
    ));
    let home = scratch.join("acpmux");
    fs::create_dir_all(&home).unwrap();
    let work = scratch.join("work");
    fs::create_dir_all(&work).unwrap();
    let log = scratch.join("class.jsonl");
    let config = json!({
        "harnesses": {"fake": {
            "argv": ["python3", concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py")],
            "env": {"FAKE_CLASS_LOG": log, "ACPMUX_SESSION_CPU_CLASS": class}
        }},
        "defaultHarness": "fake", "permissionPolicy": "approve-all"
    });
    fs::write(home.join("config.json"), config.to_string()).unwrap();
    let (daemon, socket) = start(&scratch, &home);
    // SAFETY: reads this process's own nice.
    let own = unsafe { libc::getpriority(libc::PRIO_PROCESS, 0) };
    // The agent tier's nice (`qos::AGENT_NICE`); a process already at it or past it is not lowered.
    let agent = if cfg!(target_os = "macos") { 11 } else { 5 };
    eprintln!("this process (and the daemon) at nice {own}; the agent tier at {agent}");

    call(
        &socket,
        &[
            ("initialize", json!({"protocolVersion": 1})),
            ("session/new", json!({"cwd": work, "mcpServers": []})),
            (
                "session/prompt",
                json!({"sessionId": "$session", "prompt": [{"type": "text", "text": "hi"}]}),
            ),
        ],
    );
    // Every harness that answered a `session/new` logged a line; the session's own is the one still
    // running (a daemon may start a harness of its own, a probe, which ends).
    let text = fs::read_to_string(&log).expect("the harness logged its start");
    eprintln!("harness starts logged: {text}");
    let logged: Value = text
        .lines()
        .filter_map(|line| serde_json::from_str::<Value>(line).ok())
        .rfind(|v| v["pid"].as_u64().is_some_and(|pid| nice_of(pid as u32).is_some()))
        .expect("no harness that answered session/new is still running");
    let pid = logged["pid"].as_u64().unwrap() as u32;
    let at_start = logged["nice"].as_i64().unwrap() as i32;
    // The start ran at the daemon's priority (this process's: the daemon inherits it), not under
    // the agent tier its host used to enter first thing.
    assert_eq!(at_start, own, "the harness answered session/new at nice {at_start}");
    // Once the start is over the harness yields; the daemon lowers it right after the start.
    let deadline = Instant::now() + Duration::from_secs(10);
    let expected = own.max(agent);
    let mut now = nice_of(pid);
    while now != Some(expected) && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(50));
        now = nice_of(pid);
    }
    #[cfg(target_os = "linux")]
    eprintln!(
        "harness autogroup: {:?}",
        fs::read_to_string(format!("/proc/{pid}/autogroup")).unwrap_or_default().trim()
    );
    drop(daemon);
    let _ = fs::remove_dir_all(&scratch);
    assert_eq!(now, Some(expected), "the started harness's nice");
}
