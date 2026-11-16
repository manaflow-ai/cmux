//! A daemon's start task sorts the list order first, before any chat log is read (`daemon.rs`,
//! `hub/list_order.rs`): a list page or usage pass that comes while the logs load waits for that
//! sort alone. The start's `list order` phase (`daemon status` `gauges.startup`) is the handle:
//! with the log load held by the load-delay seam, the phase has run and ended, and no log phase
//! has begun. Without the step the phase never shows and this fails.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::time::{Duration, Instant};

/// How long the seam holds the log load (`ACPMUX_TEST_DELAY_LOAD_LOGS_MS`, at most 10 s).
const HELD: Duration = Duration::from_secs(10);
/// The sort of an empty home ends in milliseconds; well inside the hold.
const SORTED_WITHIN: Duration = Duration::from_secs(6);

fn status(socket: &std::path::Path) -> Value {
    let mut s = UnixStream::connect(socket).expect("connect to the daemon's socket");
    s.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    let line = json!({"jsonrpc": "2.0", "id": 1, "method": "_acpmux/status", "params": {}});
    writeln!(s, "{line}").unwrap();
    for line in BufReader::new(s).lines() {
        let v: Value = serde_json::from_str(&line.expect("a status reply")).unwrap();
        if v.get("id") == Some(&json!(1)) {
            assert!(v.get("error").is_none(), "status failed: {v}");
            return v["result"].clone();
        }
    }
    panic!("the daemon closed the socket before its status");
}

fn phase<'a>(gauges: &'a Value, name: &str) -> Option<&'a Value> {
    gauges["startup"].as_array()?.iter().find(|p| p["name"] == name)
}

#[test]
fn the_start_task_sorts_the_list_order_before_any_log_is_read() {
    let _ = &HERMETIC;
    let dir = std::env::temp_dir().join(format!("amx-lo-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let home = dir.join("h");
    std::fs::create_dir_all(&home).unwrap();
    let socket = home.join("s.sock");
    let held = HELD.as_millis().to_string();
    let mut child = daemon_env::command(&dir, daemon_env::Agents::Deny, &[])
        .args(["daemon", "run", "--ready-fd", "1", "--log", "warn"])
        .env("ACPMUX_HOME", &home)
        .env("ACPMUX_SOCKET", &socket)
        .env("ACPMUX_LOGIN_ENV", "0")
        .env("ACPMUX_TEST_DELAY_LOAD_LOGS_MS", &held)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::inherit())
        .spawn()
        .unwrap();
    let started = Instant::now();
    let stdout = child.stdout.take().unwrap();
    // The readiness line, then the rest of stdout drained, so a log line never blocks the daemon.
    let (ready_tx, ready_rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let mut lines = BufReader::new(stdout).lines().map_while(Result::ok);
        let ready = lines.by_ref().any(|line| line.contains("\"ready\":true"));
        let _ = ready_tx.send(ready);
        lines.for_each(drop);
    });
    let ready = ready_rx.recv_timeout(Duration::from_secs(30)).unwrap_or(false);
    let outcome = std::panic::catch_unwind(|| {
        assert!(ready, "the daemon became ready");
        loop {
            let gauges = status(&socket)["gauges"].clone();
            let sorted = phase(&gauges, "list order").is_some_and(|p| p["ms"].is_u64());
            if sorted {
                // The log load is still held: no log phase has begun.
                for logs in ["live chat logs", "all chat logs"] {
                    let begun = phase(&gauges, logs);
                    assert!(begun.is_none(), "{logs} began before the sort: {gauges}");
                }
                assert!(started.elapsed() < HELD, "the hold ended before this read: {gauges}");
                return;
            }
            assert!(
                started.elapsed() < SORTED_WITHIN,
                "the start task sorted no list order while the logs were held: {gauges}"
            );
            std::thread::sleep(Duration::from_millis(50));
        }
    });
    let _ = child.kill();
    let _ = child.wait();
    let _ = std::fs::remove_dir_all(&dir);
    if let Err(panic) = outcome {
        std::panic::resume_unwind(panic);
    }
}
