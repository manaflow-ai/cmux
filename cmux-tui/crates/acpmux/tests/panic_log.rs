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
    assert!(record["location"].as_str().unwrap_or_default().contains("daemon.rs:"), "{record}");

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

/// A test's daemon home must be private whatever umask the test was started with. With a
/// caller's umask of 002 (a lane VM's default) the home was group-writable and the daemon
/// refused it ("a non-sticky writable ancestor of the state directory"): every test that starts
/// a daemon failed in milliseconds, for a reason that had nothing to do with the test.
#[test]
fn a_callers_group_writable_umask_does_not_reach_a_tests_daemon_home() {
    let exe = std::env::current_exe().unwrap();
    let status = std::process::Command::new("/bin/sh")
        .args(["-c", r#"umask 002; exec "$0" "$@""#])
        .arg(&exe)
        .args(["--exact", "a_worker_thread_panic_is_logged_and_the_daemon_keeps_running"])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .unwrap();
    assert!(status.success(), "the daemon test failed when started with umask 002: {status}");
}

/// The daemon's exit status when a task it cannot run again panicked (`daemon::EXIT_TASK_PANIC`):
/// EX_SOFTWARE. A supervisor starts it again, and otherwise the next client does.
const EXIT_TASK_PANIC: i32 = 70;

/// A panic in the startup task ended that task only: startup never finished, so the daemon ran on
/// for good and refused every new session ("still starting"). It stops for a restart instead.
#[test]
fn a_startup_task_panic_ends_the_daemon_for_a_restart() {
    let dir = std::env::temp_dir().join(format!("amx-ps-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let mut child = daemon_env::command(&dir, daemon_env::Agents::Deny, &[])
        .args(["daemon", "run", "--memory", "--listen", "127.0.0.1:0", "--log", "warn"])
        .env("ACPMUX_HOME", &dir)
        .env("ACPMUX_SOCKET", dir.join("s.sock"))
        // Debug builds only: the startup task panics.
        .env("ACPMUX_TEST_PANIC", "startup")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(30);
    let status = loop {
        if let Some(status) = child.try_wait().unwrap() {
            break Some(status);
        }
        if Instant::now() >= deadline {
            break None;
        }
        std::thread::sleep(Duration::from_millis(50));
    };
    let _ = child.kill();
    let _ = child.wait();
    let logged = std::fs::read_to_string(dir.join("panics.jsonl")).unwrap_or_default();
    let _ = std::fs::remove_dir_all(&dir);
    assert!(logged.contains("acpmux test panic in startup"), "the panic was not logged: {logged}");
    let status = status.expect("the daemon ran on with a startup that can never finish");
    assert_eq!(status.code(), Some(EXIT_TASK_PANIC), "the daemon's exit status: {status:?}");
}
