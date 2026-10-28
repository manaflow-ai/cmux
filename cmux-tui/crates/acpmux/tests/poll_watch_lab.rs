//! Lab builds (`cmux-tui/lab/stability.env`) time every task poll of the
//! daemon: a task that holds its worker past 2 ms is written once, with its
//! spawn site, to `$ACPMUX_HOME/hangs.jsonl`, and the
//! daemon writes its slow-poll totals there when it stops.
#![cfg(all(unix, debug_assertions, tokio_unstable, feature = "cmux-stability"))]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process starts no agent.
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use std::os::unix::fs::PermissionsExt;
use std::time::{Duration, Instant};

#[test]
fn a_sleeping_task_writes_one_slow_poll_with_its_spawn_site() {
    // Short: the socket path must stay under the macOS limit.
    let dir = std::env::temp_dir().join(format!("amx-pw-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    // The daemon refuses a home that group or others can write, whatever the umask.
    std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)).unwrap();
    let mut child = daemon_env::command(&dir, daemon_env::Agents::Deny, &[])
        .args(["daemon", "run", "--memory", "--listen", "127.0.0.1:0", "--log", "warn"])
        .env("ACPMUX_HOME", &dir)
        .env("ACPMUX_SOCKET", dir.join("s.sock"))
        // Debug lab builds only: one task sleeps 20 ms in its poll.
        .env("ACPMUX_TEST_SLOW_POLL", "1")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .unwrap();

    let log = dir.join("hangs.jsonl");
    let deadline = Instant::now() + Duration::from_secs(30);
    let read_log = || -> Vec<serde_json::Value> {
        std::fs::read_to_string(&log)
            .unwrap_or_default()
            .lines()
            .map(|line| serde_json::from_str::<serde_json::Value>(line).unwrap())
            .collect()
    };
    let slow_polls_at_test_site = || -> Vec<serde_json::Value> {
        read_log()
            .into_iter()
            .filter(|record| {
                record["kind"] == "slow_poll"
                    && record["spawned_at"]
                        .as_str()
                        .is_some_and(|at| at.contains("daemon/poll_watch_lab.rs:"))
            })
            .collect()
    };
    let records = loop {
        let records = slow_polls_at_test_site();
        if !records.is_empty() {
            break records;
        }
        assert!(child.try_wait().unwrap().is_none(), "the daemon exited");
        assert!(Instant::now() < deadline, "no slow poll in {}", log.display());
        std::thread::sleep(Duration::from_millis(50));
    };
    // The daemon keeps running; the site stays at one record.
    std::thread::sleep(Duration::from_millis(500));
    let alive = child.try_wait().unwrap().is_none();
    let records_later = slow_polls_at_test_site();
    // SIGTERM: the daemon stops cleanly and writes its totals.
    unsafe { libc::kill(child.id() as i32, libc::SIGTERM) };
    let stop_deadline = Instant::now() + Duration::from_secs(15);
    let stopped = loop {
        if let Some(status) = child.try_wait().unwrap() {
            break Some(status);
        }
        if Instant::now() >= stop_deadline {
            break None;
        }
        std::thread::sleep(Duration::from_millis(50));
    };
    if stopped.is_none() {
        let _ = child.kill();
        let _ = child.wait();
    }
    let summaries: Vec<serde_json::Value> =
        read_log().into_iter().filter(|record| record["kind"] == "slow_poll_summary").collect();
    let _ = std::fs::remove_dir_all(&dir);

    assert!(alive, "the daemon must keep running");
    assert!(stopped.is_some_and(|status| status.success()), "the daemon stops on SIGTERM");
    assert_eq!(records.len(), 1, "{records:?}");
    assert_eq!(records_later.len(), 1, "{records_later:?}");
    let record = &records[0];
    assert_eq!(record["process"], "acpmux", "{record}");
    assert_eq!(record["pid"].as_u64(), Some(u64::from(child.id())), "{record}");
    assert_eq!(record["runtime"], "multi_thread", "{record}");
    assert!(record["polled_us"].as_u64().is_some_and(|us| us >= 20_000), "{record}");
    assert_eq!(summaries.len(), 1, "{summaries:?}");
    let summary = &summaries[0];
    assert_eq!(summary["process"], "acpmux", "{summary}");
    assert!(summary["slow"].as_u64().is_some_and(|slow| slow >= 1), "{summary}");
    assert!(summary["recorded"].as_u64().is_some_and(|recorded| recorded >= 1), "{summary}");
}
