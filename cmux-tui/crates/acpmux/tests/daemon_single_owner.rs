//! One daemon per acpmux home (perf100, 2026-10-20). Lawrence's Mac ran two NIGHTLY
//! daemons: the app's (`~/.acpmux`) and the Chief brain's (`~/.cmux/chief/default/acpmux`,
//! started by `optchat-chief host`). They are two homes by design; within a home a
//! second daemon must never start, and a daemon of another home must never take a
//! live daemon's socket. The real binary, on Unix (Windows: `windows_daemon.rs`).
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Stdio};

fn scratch(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("amx-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn daemon(scratch: &Path, home: &Path, socket: &Path) -> std::process::Command {
    let mut cmd = daemon_env::acpmux(scratch);
    cmd.args(["daemon", "run", "--memory", "--log", "warn"])
        .env("ACPMUX_HOME", home)
        .env("ACPMUX_SOCKET", socket)
        .stdin(Stdio::null());
    cmd
}

fn start(scratch: &Path, home: &Path, socket: &Path) -> Child {
    let mut child = daemon(scratch, home, socket)
        .args(["--ready-fd", "1"])
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let stdout = child.stdout.take().unwrap();
    for line in BufReader::new(stdout).lines() {
        if serde_json::from_str::<Value>(&line.unwrap()).is_ok_and(|v| v["ready"] == true) {
            return child;
        }
    }
    let _ = child.kill();
    let _ = child.wait();
    panic!("daemon exited without a readiness line");
}

/// The pid the daemon at `socket` reports.
fn status_pid(socket: &Path) -> u64 {
    let mut s = UnixStream::connect(socket).expect("connect to daemon socket");
    s.set_read_timeout(Some(std::time::Duration::from_secs(30))).unwrap();
    let line = json!({"jsonrpc": "2.0", "id": 1, "method": "_acpmux/status", "params": {}});
    s.write_all(format!("{line}\n").as_bytes()).unwrap();
    let mut reader = BufReader::new(s);
    loop {
        let mut text = String::new();
        assert!(reader.read_line(&mut text).unwrap() > 0, "daemon closed the socket");
        let v: Value = serde_json::from_str(&text).unwrap();
        if v["id"] == 1 {
            return v["result"]["pid"].as_u64().expect("status names its pid");
        }
    }
}

fn stop(mut child: Child) {
    // SAFETY: the pid is this test's own child.
    unsafe { libc::kill(child.id() as i32, libc::SIGTERM) };
    let _ = child.wait();
}

#[test]
fn a_second_daemon_never_starts_in_a_home_or_takes_a_live_socket() {
    let dir = scratch("owner");
    let home = dir.join("home");
    let other = dir.join("other");
    for h in [&home, &other] {
        std::fs::create_dir_all(h).unwrap();
    }
    let socket = dir.join("a.sock");
    let first = start(&dir, &home, &socket);
    let pid = u64::from(first.id());
    assert_eq!(status_pid(&socket), pid);

    // The same home: the second daemon stops at the home's lock, before it binds.
    let same = daemon(&dir, &home, &dir.join("b.sock")).output().unwrap();
    assert!(!same.status.success(), "a second daemon started in the same home");
    let said = String::from_utf8_lossy(&same.stderr);
    assert!(said.contains("another acpmux daemon holds"), "{said}");
    assert!(!dir.join("b.sock").exists(), "the refused daemon bound a socket");

    // Another home naming the live socket: it refuses the socket and leaves it serving.
    let taken = daemon(&dir, &other, &socket).output().unwrap();
    assert!(!taken.status.success(), "a daemon of another home took a live socket");
    let said = String::from_utf8_lossy(&taken.stderr);
    assert!(said.contains("another acpmux daemon owns"), "{said}");
    assert_eq!(status_pid(&socket), pid, "the first daemon no longer answers its socket");

    // Another home with its own socket is its own scope and runs beside it.
    let beside = start(&dir, &other, &dir.join("c.sock"));
    assert_eq!(status_pid(&dir.join("c.sock")), u64::from(beside.id()));
    assert_eq!(status_pid(&socket), pid);
    stop(beside);
    stop(first);
    let _ = std::fs::remove_dir_all(&dir);
}
