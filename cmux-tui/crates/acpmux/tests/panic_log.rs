//! A panic in the acpmux daemon must never be lost (2026-10-14: a sort
//! panic in a request task left two lines in `daemon.log` and nothing in
//! Sentry). The daemon appends each panic to `$ACPMUX_HOME/panics.jsonl`
//! and each hang to `$ACPMUX_HOME/hangs.jsonl`, and keeps serving; the
//! cmux-next app sends new lines to Sentry (p10-stability-150).
#![cfg(all(unix, debug_assertions))]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process starts no agent.
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use std::path::{Path, PathBuf};
use std::process::Child;
use std::time::{Duration, Instant};

/// A daemon started with debug trigger `ACPMUX_TEST_PANIC=<trigger>` in its own home.
fn start(dir: &Path, trigger: &str) -> Child {
    let _ = std::fs::remove_dir_all(dir);
    std::fs::create_dir_all(dir).unwrap();
    daemon_env::command(dir, daemon_env::Agents::Deny, &[])
        .args(["daemon", "run", "--memory", "--listen", "127.0.0.1:0", "--log", "warn"])
        .env("ACPMUX_HOME", dir)
        .env("ACPMUX_SOCKET", dir.join("s.sock"))
        .env("ACPMUX_TEST_PANIC", trigger)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .unwrap()
}

/// The first line of `log`, once the daemon writes it; the daemon must stay up meanwhile.
fn first_record(child: &mut Child, log: &PathBuf) -> serde_json::Value {
    let deadline = Instant::now() + Duration::from_secs(30);
    let line = loop {
        if let Some(line) =
            std::fs::read_to_string(log).ok().and_then(|text| text.lines().next().map(String::from))
        {
            break line;
        }
        assert!(child.try_wait().unwrap().is_none(), "the daemon exited before {}", log.display());
        assert!(Instant::now() < deadline, "nothing in {}", log.display());
        std::thread::sleep(Duration::from_millis(50));
    };
    serde_json::from_str(&line).unwrap()
}

fn owner_only(log: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(log).unwrap().permissions().mode() & 0o777 == 0o600
}

#[test]
fn a_worker_thread_panic_is_logged_and_the_daemon_keeps_running() {
    // Short: the socket path must stay under the macOS limit.
    let dir = std::env::temp_dir().join(format!("amx-pl-{}", std::process::id()));
    let mut child = start(&dir, "thread");
    let log = dir.join("panics.jsonl");
    let record = first_record(&mut child, &log);
    assert_eq!(record["process"], "acpmux", "{record}");
    assert_eq!(record["message"], "acpmux test panic", "{record}");
    assert_eq!(record["thread"], "acpmux-panic-test", "{record}");
    assert_eq!(record["test"], true, "{record}");
    assert_eq!(record["pid"].as_u64(), Some(u64::from(child.id())), "{record}");
    // The platform tags of the Sentry event.
    assert_eq!(record["os"], std::env::consts::OS, "{record}");
    assert_eq!(record["arch"], std::env::consts::ARCH, "{record}");
    assert!(record["location"].as_str().unwrap_or_default().contains("panic_log.rs:"), "{record}");

    // The panic ended only its own thread: the daemon still runs.
    std::thread::sleep(Duration::from_millis(500));
    let alive = child.try_wait().unwrap().is_none();
    let private = owner_only(&log);
    let _ = child.kill();
    let _ = child.wait();
    let _ = std::fs::remove_dir_all(&dir);
    assert!(alive, "the daemon must keep running");
    assert!(private, "the panic log is owner-only");
}

#[test]
fn a_hang_record_reaches_the_hang_log_beside_the_panic_log() {
    let dir = std::env::temp_dir().join(format!("amx-hl-{}", std::process::id()));
    let mut child = start(&dir, "hang");
    let log = dir.join("hangs.jsonl");
    let record = first_record(&mut child, &log);
    let private = owner_only(&log);
    let _ = child.kill();
    let _ = child.wait();
    let _ = std::fs::remove_dir_all(&dir);
    assert_eq!(record["event"], "hang", "{record}");
    assert_eq!(record["scope"], "acpmux-test", "{record}");
    assert_eq!(record["process"], "acpmux", "{record}");
    assert_eq!(record["os"], std::env::consts::OS, "{record}");
    assert_eq!(record["test"], true, "{record}");
    assert!(private, "the hang log is owner-only");
}
