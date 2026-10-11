//! The local router (`acpmux router serve`) lives only as long as the
//! daemon that started it: `acpmux daemon shutdown` stops it before the
//! daemon exits, and a daemon killed with SIGKILL takes it along through the
//! owner pipe. Real binaries, real sockets, a temporary home.
#![cfg(unix)]

use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

fn scratch(tag: &str) -> PathBuf {
    // Short: the socket paths must stay under the macOS limit.
    let dir = std::env::temp_dir().join(format!("amx-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// A daemon in `dir` with the local router on; returns after its readiness line.
fn start_daemon(dir: &Path) -> Child {
    std::fs::write(dir.join("config.json"), json!({"harnesses": {}}).to_string()).unwrap();
    let mut child = Command::new(env!("CARGO_BIN_EXE_acpmux"))
        .args(["daemon", "run", "--memory", "--listen", "127.0.0.1:0", "--ready-fd", "1"])
        .args(["--log", "warn"])
        .env("ACPMUX_HOME", dir)
        .env("ACPMUX_SOCKET", dir.join("s.sock"))
        .env("ACPMUX_LOCAL_ROUTER", "1")
        .env("ACPMUX_LOGIN_ENV", "0")
        .env_remove("XPC_SERVICE_NAME")
        .env_remove("CLAUDECODE")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let stdout = child.stdout.take().unwrap();
    for line in BufReader::new(stdout).lines() {
        let line = line.unwrap();
        if serde_json::from_str::<Value>(&line).is_ok_and(|v| v["ready"] == true) {
            return child;
        }
    }
    panic!("daemon exited without a readiness line");
}

/// The router's pid from its admin socket, and an idle admin connection
/// that reads EOF when the router process is gone.
fn router(dir: &Path) -> (i32, UnixStream) {
    let socket = dir.join("router").join("router.sock");
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        if let Ok(mut stream) = UnixStream::connect(&socket) {
            stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
            stream.write_all(b"{\"op\":\"status\"}\n").unwrap();
            let mut line = String::new();
            BufReader::new(stream.try_clone().unwrap()).read_line(&mut line).unwrap();
            let status: Value = serde_json::from_str(&line).unwrap();
            let pid = i32::try_from(status["pid"].as_u64().expect("status names the pid")).unwrap();
            return (pid, stream);
        }
        assert!(Instant::now() < deadline, "the daemon started no router");
        std::thread::sleep(Duration::from_millis(50));
    }
}

fn alive(pid: i32) -> bool {
    unsafe { libc::kill(pid, 0) == 0 }
}

fn wait_exit(child: &mut Child, within: Duration) {
    let deadline = Instant::now() + within;
    while child.try_wait().unwrap().is_none() {
        assert!(Instant::now() < deadline, "daemon still running");
        std::thread::sleep(Duration::from_millis(20));
    }
}

#[test]
fn daemon_shutdown_stops_its_router_before_it_exits() {
    let dir = scratch("rtst");
    let mut daemon = start_daemon(&dir);
    let (pid, _held) = router(&dir);
    assert!(alive(pid));
    let status = Command::new(env!("CARGO_BIN_EXE_acpmux"))
        .args(["daemon", "shutdown"])
        .env("ACPMUX_HOME", &dir)
        .env("ACPMUX_SOCKET", dir.join("s.sock"))
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .unwrap();
    assert!(status.success(), "{status:?}");
    wait_exit(&mut daemon, Duration::from_secs(10));
    // The daemon reaps its router before it exits: the pid is gone now, with
    // no wait (a leaked router would live on with parent pid 1).
    assert!(!alive(pid), "router pid {pid} outlived `acpmux daemon shutdown`");
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn router_exits_when_its_daemon_is_killed() {
    let dir = scratch("rkil");
    let mut daemon = start_daemon(&dir);
    let (pid, mut held) = router(&dir);
    assert!(alive(pid));
    // SIGKILL: no shutdown path runs; only the owner pipe can stop the router.
    daemon.kill().unwrap();
    daemon.wait().unwrap();
    held.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    let mut rest = Vec::new();
    held.read_to_end(&mut rest).expect("the router closed its admin connection in time");
    // EOF: the router process closed its sockets. Its new parent reaps it.
    let deadline = Instant::now() + Duration::from_secs(5);
    while alive(pid) {
        assert!(Instant::now() < deadline, "router pid {pid} outlived its killed daemon");
        std::thread::sleep(Duration::from_millis(20));
    }
    let _ = std::fs::remove_dir_all(&dir);
}
