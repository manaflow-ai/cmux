//! An app run the app refused before it started prints the refusal and no
//! retry note. The app answers `not_found` (no such action), `unavailable`
//! (not in this context) and the like before anything runs, so "The change
//! may still apply" was false, and on a capture host a refusal of
//! `workspace.new` read as a timeout. A run that may have started (a
//! `timeout`) keeps the note and its key.
#![cfg(unix)]

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

fn temp_dir(name: &str) -> PathBuf {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let dir = Path::new("/tmp").join(format!("cmux-{name}-{}-{stamp}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// Runs `cmux <output> action run <action>` against an app that answers
/// every request with `error`.
fn run_against_error(output: &[&str], action: &str, error: Value) -> Output {
    let dir = temp_dir("refusal");
    let socket = dir.join("app.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let child = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .args(output)
        .arg("--app-socket")
        .arg(&socket)
        .args(["action", "run", action])
        .env_remove("CMUX_TUI_TERMINAL_ID")
        .env_remove("CMUX_AGENT_SESSION")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let (stream, _) = listener.accept().unwrap();
    let mut reader = BufReader::new(stream.try_clone().unwrap());
    let mut stream = stream;
    let mut line = String::new();
    while reader.read_line(&mut line).unwrap_or(0) > 0 {
        let request: Value = serde_json::from_str(&line).unwrap();
        line.clear();
        let answer = json!({ "id": request["id"], "ok": false, "error": error });
        if writeln!(stream, "{answer}").is_err() {
            break;
        }
    }
    let output = child.wait_with_output().unwrap();
    drop(listener);
    let _ = std::fs::remove_dir_all(&dir);
    output
}

#[test]
fn a_refusal_before_the_run_started_prints_no_retry_note() {
    let refusals = [
        (
            "workspace.new",
            json!({ "code": "not_found", "message": "Unknown action 'workspace.new'" }),
        ),
        (
            "splitBrowserRight",
            json!({ "code": "unavailable", "message": "splitBrowserRight unavailable: not enough room to split this pane",
                    "data": { "action": "splitBrowserRight" } }),
        ),
        (
            "window.new",
            json!({ "code": "busy", "message": "busy", "data": { "not_run": true, "retry_after_ms": 1 } }),
        ),
    ];
    for (action, error) in refusals {
        let message = error["message"].as_str().unwrap().to_owned();
        let human = run_against_error(&[], action, error.clone());
        let stderr = String::from_utf8_lossy(&human.stderr);
        assert_eq!(human.status.code(), Some(1), "{stderr}");
        assert!(stderr.contains(&message), "{stderr}");
        assert!(!stderr.contains("may still apply"), "{action}: {stderr}");
        assert!(!stderr.contains("idempotency key"), "{action}: {stderr}");

        let json = run_against_error(&["--json"], action, error);
        let text = String::from_utf8_lossy(&json.stderr);
        assert!(!text.contains("outcome_unknown"), "{action}: {text}");
    }
}

#[test]
fn a_run_that_may_have_started_keeps_the_retry_note() {
    let timeout = json!({ "code": "timeout", "message": "window.new did not answer",
                          "data": { "action": "window.new", "state": "in_progress" } });
    let human = run_against_error(&[], "window.new", timeout);
    let stderr = String::from_utf8_lossy(&human.stderr);
    assert_eq!(human.status.code(), Some(1), "{stderr}");
    assert!(stderr.contains("may still apply"), "{stderr}");
}
