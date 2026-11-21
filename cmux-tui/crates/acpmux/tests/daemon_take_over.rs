//! The systemd unit's daemon takes over this home from a daemon a client started (2026-11-03,
//! chief-sub-a524): `acpmux daemon shutdown` stopped the unit's daemon, a client started a
//! detached one in the 3 s before systemd restarted the unit, and the unit's start found the lock
//! held, exited 75, and left `acpmux.service` failed with the home served outside it. The unit
//! runs `daemon run --take-over`: it asks the holder of this home's lock, when that holder serves
//! the same socket, to hand over (its agents keep running), then serves in its place. A start in
//! the same home that names another socket is still refused. The real binary, on Unix.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Stdio};
use std::time::{Duration, Instant};

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

/// A daemon as a client starts one: detached, reporting readiness on a pipe.
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

/// The pid the daemon at `socket` reports, or `None` while none answers there.
fn status_pid(socket: &Path) -> Option<u64> {
    let mut s = UnixStream::connect(socket).ok()?;
    s.set_read_timeout(Some(Duration::from_secs(10))).ok()?;
    let line = json!({"jsonrpc": "2.0", "id": 1, "method": "_acpmux/status", "params": {}});
    s.write_all(format!("{line}\n").as_bytes()).ok()?;
    let mut reader = BufReader::new(s);
    loop {
        let mut text = String::new();
        if reader.read_line(&mut text).ok()? == 0 {
            return None;
        }
        let v: Value = serde_json::from_str(&text).ok()?;
        if v["id"] == 1 {
            return v["result"]["pid"].as_u64();
        }
    }
}

/// Whether `child` has exited within `budget`, polled: the process gives no other signal here.
fn exited_within(child: &mut Child, budget: Duration) -> Option<std::process::ExitStatus> {
    let deadline = Instant::now() + budget;
    loop {
        if let Some(status) = child.try_wait().unwrap() {
            return Some(status);
        }
        if Instant::now() >= deadline {
            return None;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
}

fn stop(mut child: Child) {
    // SAFETY: the pid is this test's own child.
    unsafe { libc::kill(child.id() as i32, libc::SIGTERM) };
    let _ = child.wait();
}

#[test]
fn the_units_daemon_takes_over_from_a_client_started_one() {
    let dir = scratch("takeover");
    let home = dir.join("home");
    std::fs::create_dir_all(&home).unwrap();
    let socket = dir.join("a.sock");
    let mut stray = start(&dir, &home, &socket);
    assert_eq!(status_pid(&socket), Some(u64::from(stray.id())));

    // Another socket in the same home is still refused, and the stray keeps serving.
    let other = daemon(&dir, &home, &dir.join("b.sock")).arg("--take-over").output().unwrap();
    assert!(!other.status.success(), "--take-over started a second daemon for another socket");
    assert!(!dir.join("b.sock").exists(), "the refused daemon bound a socket");
    assert_eq!(status_pid(&socket), Some(u64::from(stray.id())));

    // The unit's start: same home, same socket, no readiness pipe.
    let mut unit = daemon(&dir, &home, &socket)
        .arg("--take-over")
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(60);
    let mut serving = None;
    while Instant::now() < deadline {
        if let Some(status) = unit.try_wait().unwrap() {
            let mut said = String::new();
            let _ = std::io::Read::read_to_string(&mut unit.stderr.take().unwrap(), &mut said);
            panic!("the unit's daemon exited ({status}) instead of taking over: {said}");
        }
        serving = status_pid(&socket);
        if serving == Some(u64::from(unit.id())) {
            break;
        }
        std::thread::sleep(Duration::from_millis(200));
    }
    assert_eq!(serving, Some(u64::from(unit.id())), "the unit's daemon never served the socket");
    let gone = exited_within(&mut stray, Duration::from_secs(30));
    assert!(
        gone.is_some_and(|s| s.success()),
        "the stray daemon did not hand over cleanly: {gone:?}"
    );
    stop(unit);
    let _ = std::fs::remove_dir_all(&dir);
}
