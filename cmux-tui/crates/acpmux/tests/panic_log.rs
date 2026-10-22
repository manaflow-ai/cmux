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

/// One JSON-RPC request on `stream`; the reply for its id (30 s at most).
fn call(
    stream: &mut std::os::unix::net::UnixStream,
    lines: &mut impl Iterator<Item = std::io::Result<String>>,
    id: u64,
    method: &str,
) -> serde_json::Value {
    use std::io::Write;
    let request = serde_json::json!({"jsonrpc": "2.0", "id": id, "method": method, "params": {}});
    stream.write_all(format!("{request}\n").as_bytes()).unwrap();
    loop {
        let line = lines
            .next()
            .expect("the daemon closed the connection")
            .expect("the daemon answered within 30 s");
        let reply: serde_json::Value = serde_json::from_str(&line).unwrap();
        if reply["id"] == id {
            return reply;
        }
    }
}

#[test]
fn a_request_handler_panic_answers_that_request_and_the_daemon_keeps_serving() {
    use std::io::BufRead;
    let dir = std::env::temp_dir().join(format!("amx-pr-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let mut child = daemon_env::command(&dir, daemon_env::Agents::Deny, &[])
        .args(["daemon", "run", "--memory", "--ready-fd", "1", "--log", "warn"])
        .env("ACPMUX_HOME", &dir)
        .env("ACPMUX_SOCKET", dir.join("s.sock"))
        .env("ACPMUX_CATALOG_FETCH", "0")
        .env("ACPMUX_LOGIN_ENV", "0")
        // Debug builds only: a request of this method panics in its handler.
        .env("ACPMUX_TEST_PANIC", "request:_acpmux/test_panic")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn()
        .unwrap();
    let mut stdout = std::io::BufReader::new(child.stdout.take().unwrap());
    let mut ready = String::new();
    while stdout.read_line(&mut ready).unwrap() > 0 && !ready.contains("\"ready\":true") {
        ready.clear();
    }
    let ready: serde_json::Value = serde_json::from_str(&ready).expect("the ready line");
    let socket = ready["socket"].as_str().expect("the bound socket").to_string();

    let mut stream = std::os::unix::net::UnixStream::connect(&socket).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(30))).unwrap();
    let mut lines = std::io::BufReader::new(stream.try_clone().unwrap()).lines();
    // Before the boundary, the panic ended the request task and this reply
    // never came: the client waited forever.
    let reply = call(&mut stream, &mut lines, 1, "_acpmux/test_panic");
    assert_eq!(reply["error"]["message"], "internal error: the request panicked", "{reply}");
    // The same connection and the daemon keep answering.
    let status = call(&mut stream, &mut lines, 2, "_acpmux/status");
    assert!(status.get("error").is_none() && status.get("result").is_some(), "{status}");
    let mut other = std::os::unix::net::UnixStream::connect(&socket).unwrap();
    other.set_read_timeout(Some(Duration::from_secs(30))).unwrap();
    let mut other_lines = std::io::BufReader::new(other.try_clone().unwrap()).lines();
    let status = call(&mut other, &mut other_lines, 1, "_acpmux/status");
    assert!(status.get("result").is_some(), "{status}");

    let log = std::fs::read_to_string(dir.join("panics.jsonl")).unwrap_or_default();
    let record = log
        .lines()
        .filter_map(|line| serde_json::from_str::<serde_json::Value>(line).ok())
        .find(|record| record["message"] == "acpmux test request panic")
        .unwrap_or_else(|| panic!("no request panic in the panic log: {log}"));
    assert_eq!(record["pid"].as_u64(), Some(u64::from(child.id())), "{record}");
    let alive = child.try_wait().unwrap().is_none();
    let _ = child.kill();
    let _ = child.wait();
    let _ = std::fs::remove_dir_all(&dir);
    assert!(alive, "the daemon must keep running");
}
