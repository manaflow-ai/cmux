//! A waiting app command against an app that takes the request and never
//! answers: a person sees progress on stderr while the CLI waits, and the
//! timeout names the owner that did not answer, the socket tried and the next
//! command to run, also as fields of the JSON error (cx-cmux-agents item 3).
#![cfg(unix)]

use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::Value;

/// The test build's wait for `action.run`, instead of 45 s.
const WAIT_MS: &str = "3500";

fn spawn(socket: &Path, output: &[&str]) -> Child {
    spawn_command(socket, output, &["action", "run", "window.new"])
}

fn spawn_command(socket: &Path, output: &[&str], command: &[&str]) -> Child {
    Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .args(output)
        .arg("--app-socket")
        .arg(socket)
        .args(command)
        .env("CMUX_TEST_APP_WAIT_TIMEOUT_MS", WAIT_MS)
        .env_remove("CMUX_TUI_TERMINAL_ID")
        .env_remove("CMUX_AGENT_SESSION")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap()
}

#[test]
fn a_silent_app_shows_progress_and_times_out_with_the_next_command() {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let dir: PathBuf = Path::new("/tmp").join(format!("cmux-wait-{}-{stamp}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("app.sock");
    // Never accepted: the connection waits in the backlog, the request is
    // buffered, and no answer ever comes.
    let listener = UnixListener::bind(&socket).unwrap();

    let human = spawn(&socket, &[]);
    let json = spawn(&socket, &["--json"]);
    // A control-plane read (5 s outside tests) is short: no progress notes.
    let identify = spawn_command(&socket, &[], &["identify"]);
    let human = human.wait_with_output().unwrap();
    let json = json.wait_with_output().unwrap();
    let identify = identify.wait_with_output().unwrap();
    drop(listener);
    let _ = std::fs::remove_dir_all(&dir);

    let stderr = String::from_utf8_lossy(&human.stderr);
    assert_eq!(human.status.code(), Some(3), "{stderr}");
    assert!(
        stderr.contains("waiting for the cmux app to run window.new (2 s of 3 s)"),
        "no progress line: {stderr}"
    );
    // The next command keeps the route this call took.
    let next = format!("cmux --app-socket {} identify", socket.display());
    assert!(stderr.contains(&next), "no routed next command: {stderr}");
    let identify_stderr = String::from_utf8_lossy(&identify.stderr);
    assert_eq!(identify.status.code(), Some(3), "{identify_stderr}");
    assert!(
        !identify_stderr.contains("waiting for"),
        "a short read shows progress: {identify_stderr}"
    );
    assert!(human.stdout.is_empty());

    // JSON output: stdout stays empty and every stderr line is a JSON object
    // (a pipe is not a terminal, so no progress lines are mixed in): the
    // error, then the run's idempotency key report.
    assert_eq!(json.status.code(), Some(3));
    assert!(json.stdout.is_empty());
    let text = String::from_utf8_lossy(&json.stderr);
    let lines = text
        .lines()
        .map(|line| serde_json::from_str::<Value>(line).unwrap_or_else(|_| panic!("{text}")))
        .collect::<Vec<_>>();
    assert_eq!(lines.len(), 2, "{text}");
    assert_eq!(lines[1]["code"], "mutation.outcome_unknown", "{text}");
    let error = &lines[0];
    assert_eq!(error["code"], "app.transport", "{error}");
    let details = &error["details"];
    assert_eq!(details["owner"], "app", "{error}");
    assert_eq!(details["socket"], socket.to_string_lossy().as_ref(), "{error}");
    assert_eq!(details["method"], "action.run", "{error}");
    assert_eq!(details["waiting_for"], "window.new", "{error}");
    assert_eq!(details["timeout_seconds"], 3, "{error}");
    assert_eq!(details["next_command"], next.as_str(), "{error}");
}
