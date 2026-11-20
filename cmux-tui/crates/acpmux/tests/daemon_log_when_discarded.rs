//! A daemon whose start discarded its output still writes `daemon.log` (2026-11-17): the NIGHTLY's
//! daemon, started by an update's `--take-over` handover with stdout and stderr on `/dev/null`, ran
//! a morning with no log, so the reason new chats did not start was written nowhere. The real
//! binary, on Unix: started with every stdio on `/dev/null`, it serves and its home has a log.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::{Duration, Instant};

fn scratch(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("amx-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// Whether a daemon answers `_acpmux/status` at `socket`.
fn answers(socket: &Path) -> bool {
    let Ok(mut s) = UnixStream::connect(socket) else { return false };
    if s.set_read_timeout(Some(Duration::from_secs(10))).is_err() {
        return false;
    }
    let line = json!({"jsonrpc": "2.0", "id": 1, "method": "_acpmux/status", "params": {}});
    if s.write_all(format!("{line}\n").as_bytes()).is_err() {
        return false;
    }
    let mut reader = BufReader::new(s);
    loop {
        let mut text = String::new();
        match reader.read_line(&mut text) {
            Ok(0) | Err(_) => return false,
            Ok(_) => {}
        }
        if serde_json::from_str::<Value>(&text).is_ok_and(|v| v["id"] == 1) {
            return true;
        }
    }
}

#[test]
fn a_daemon_started_with_its_output_discarded_still_writes_daemon_log() {
    let _ = &HERMETIC;
    let dir = scratch("discarded-log");
    let home = dir.join("home");
    std::fs::create_dir_all(&home).unwrap();
    let socket = dir.join("a.sock");
    // As the update's handover started the NIGHTLY's daemon: no readiness pipe, every stdio null.
    let mut child = daemon_env::acpmux(&dir)
        .args(["daemon", "run", "--memory", "--log", "warn"])
        .env("ACPMUX_HOME", &home)
        .env("ACPMUX_SOCKET", &socket)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(60);
    while !answers(&socket) {
        if let Some(status) = child.try_wait().unwrap() {
            panic!("the daemon exited ({status}) before it served");
        }
        assert!(Instant::now() < deadline, "the daemon never served its socket");
        std::thread::sleep(Duration::from_millis(200));
    }
    let log = std::fs::read_to_string(home.join("daemon.log")).unwrap_or_default();
    // SAFETY: the pid is this test's own child.
    unsafe { libc::kill(child.id() as i32, libc::SIGTERM) };
    let _ = child.wait();
    let _ = std::fs::remove_dir_all(&dir);
    assert!(
        log.contains("started with its output discarded"),
        "a daemon whose stdout and stderr were /dev/null wrote no daemon.log: {log:?}"
    );
}
