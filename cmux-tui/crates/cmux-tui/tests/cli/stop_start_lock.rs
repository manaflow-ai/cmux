//! `server stop` and the `<socket>.spawn-lock` start lock (W3-H).

use super::*;

/// W3-H: a stop removes the start lock an earlier owner left next to the
/// socket (`<socket>.spawn-lock`) and names it in `removed`.
#[test]
fn w3h_stop_removes_a_left_start_lock() {
    let dir = TestTempDir::create("server-stop-spawn-lock");
    let socket = dir.path().join("left.sock");
    let lock = dir.path().join("left.sock.spawn-lock");
    fs::write(&lock, b"").unwrap();
    let stopped = lifecycle_cli(&[
        "--json",
        "server",
        "stop",
        "--session",
        "left",
        "--socket",
        socket.to_str().unwrap(),
    ]);
    assert_success(&stopped);
    let result = json_output(&stopped);
    assert_eq!(result["status"], "not_running");
    assert_eq!(result["removed"], serde_json::json!([lock.to_str().unwrap()]));
    assert!(!lock.exists(), "the start lock is left behind");
    let again = lifecycle_cli(&["--json", "server", "stop", "--socket", socket.to_str().unwrap()]);
    assert_eq!(json_output(&again)["removed"], serde_json::json!([]));
}

/// W3-H review: a stop of a running owner returns at once and removes the
/// start lock, also when the stopped owner stays a zombie (its parent, here
/// the test, has not reaped it yet). `kill(pid, 0)` succeeds for a zombie, so
/// a pid wait made such a stop 5 s slower and removed nothing.
#[test]
fn w3h_stop_of_an_unreaped_owner_is_fast_and_removes_the_start_lock() {
    let server = HeadlessServer::start("w3h-stop-zombie");
    let socket = server.socket.to_str().unwrap().to_owned();
    let lock = format!("{socket}.spawn-lock");
    assert!(std::path::Path::new(&lock).exists(), "the owner made no start lock");
    // Terminal hosts outlive a stop; close them first, as the fixture's drop does.
    server.close_all_resources().unwrap();
    let started = Instant::now();
    let stopped = lifecycle_cli(&["--json", "server", "stop", "--socket", &socket]);
    let elapsed = started.elapsed();
    assert_success(&stopped);
    let result = json_output(&stopped);
    assert_eq!(result["status"], "stopped");
    assert_eq!(result["removed"], serde_json::json!([lock]));
    assert!(!std::path::Path::new(&lock).exists(), "the start lock is left behind");
    assert!(elapsed < Duration::from_secs(3), "stop took {elapsed:?}");
}
