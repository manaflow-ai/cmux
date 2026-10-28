//! A panic in the acpmux daemon must never be lost (2026-10-14: a sort
//! panic in a request task left two lines in `daemon.log` and nothing in
//! Sentry). The daemon appends each panic to `$ACPMUX_HOME/panics.jsonl`
//! and keeps serving; the cmux-next app sends new lines to Sentry.
#![cfg(all(unix, debug_assertions))]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process starts no agent.
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use std::time::{Duration, Instant};

#[test]
fn a_worker_thread_panic_is_logged_and_the_daemon_keeps_running() {
    // Short: the socket path must stay under the macOS limit.
    let dir = std::env::temp_dir().join(format!("amx-pl-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let mut child = daemon_env::command(&dir, daemon_env::Agents::Deny, &[])
        .args(["daemon", "run", "--memory", "--listen", "127.0.0.1:0", "--log", "warn"])
        .env("ACPMUX_HOME", &dir)
        .env("ACPMUX_SOCKET", dir.join("s.sock"))
        // Debug builds only: a worker thread panics once the hook is installed.
        .env("ACPMUX_TEST_PANIC", "thread")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .unwrap();

    let log = dir.join("panics.jsonl");
    let deadline = Instant::now() + Duration::from_secs(30);
    let line = loop {
        if let Some(line) = std::fs::read_to_string(&log)
            .ok()
            .and_then(|text| text.lines().next().map(String::from))
        {
            break line;
        }
        assert!(
            child.try_wait().unwrap().is_none(),
            "the daemon exited after a worker-thread panic"
        );
        assert!(Instant::now() < deadline, "no acpmux panic log at {}", log.display());
        std::thread::sleep(Duration::from_millis(50));
    };
    let record: serde_json::Value = serde_json::from_str(&line).unwrap();
    assert_eq!(record["process"], "acpmux", "{record}");
    assert_eq!(record["message"], "acpmux test panic", "{record}");
    assert_eq!(record["thread"], "acpmux-panic-test", "{record}");
    assert_eq!(record["test"], true, "{record}");
    assert_eq!(record["pid"].as_u64(), Some(u64::from(child.id())), "{record}");
    assert!(record["location"].as_str().unwrap_or_default().contains("panic_log.rs:"), "{record}");

    // The panic ended only its own thread: the daemon still runs.
    std::thread::sleep(Duration::from_millis(500));
    let alive = child.try_wait().unwrap().is_none();
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(std::fs::metadata(&log).unwrap().permissions().mode() & 0o777, 0o600);
    }
    let _ = child.kill();
    let _ = child.wait();
    let _ = std::fs::remove_dir_all(&dir);
    assert!(alive, "the daemon must keep running");
}
