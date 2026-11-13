//! A one-shot read that waits long for the daemon says so once on stderr and keeps waiting;
//! stdout says nothing (`cli/slow_notice.rs`). aws-m4pro-5, 2026-11-10: an `acpmux ls` waited
//! 2 h 41 min on a daemon that had stopped answering, and said nothing.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process starts no agent; the acpmux it starts is a one-shot client.
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use std::io::Read as _;
use std::time::{Duration, Instant};

#[test]
fn a_status_the_daemon_does_not_answer_says_so_on_stderr_and_keeps_waiting() {
    let dir = std::env::temp_dir().join(format!("amx-sn-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("s.sock");
    // A daemon that takes the connection and the request and never answers.
    let listener = std::os::unix::net::UnixListener::bind(&socket).unwrap();
    let held = std::thread::spawn(move || {
        let (mut conn, _) = listener.accept().unwrap();
        let mut sink = [0u8; 4096];
        while conn.read(&mut sink).unwrap_or(0) > 0 {}
    });
    // The hermetic environment clears this test's own ACPMUX_SESSION_ID and caller token.
    let mut child = daemon_env::acpmux(&dir)
        .args(["status"])
        .env("ACPMUX_HOME", dir.join("home"))
        .env("ACPMUX_SOCKET", &socket)
        .env("ACPMUX_TEST_SLOW_NOTICE_MS", "300")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    // Well past the notice: the command still waits.
    let started = Instant::now();
    while started.elapsed() < Duration::from_secs(3) {
        assert!(child.try_wait().unwrap().is_none(), "the command stopped waiting");
        std::thread::sleep(Duration::from_millis(100));
    }
    let _ = child.kill();
    let out = child.wait_with_output().unwrap();
    let stderr = String::from_utf8_lossy(&out.stderr);
    let notices: Vec<&str> =
        stderr.lines().filter(|l| l.contains("the daemon has not answered")).collect();
    assert_eq!(notices.len(), 1, "one notice: {stderr}");
    // This silent daemon never answers the connection's hello, the first request of every
    // command; one that answers it and not the status gets "the status request".
    assert!(notices[0].contains("the connection's hello"), "{stderr}");
    assert!(notices[0].ends_with("daemon.log"), "{stderr}");
    assert!(out.stdout.is_empty(), "stdout: {}", String::from_utf8_lossy(&out.stdout));
    drop(held);
    let _ = std::fs::remove_dir_all(&dir);
}
