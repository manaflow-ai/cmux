//! An app run the app says never ran (`data.not_run`: refused before the
//! handler ran, or before any of its work started) prints the refusal and
//! no retry note. On a capture host an instant refusal of `workspace.new`
//! with "The change may still apply" read as a timeout. A refusal from the
//! action's work (which may have applied part of the change) and a
//! `timeout` keep the note and its key.
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
/// every request with `error`. The app is served from a thread, so a CLI
/// that exits before it connects fails the test instead of hanging it.
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
        .env("LC_ALL", "C")
        .env("LANG", "C")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    std::thread::spawn(move || {
        let Ok((stream, _)) = listener.accept() else { return };
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
    });
    let output = child.wait_with_output().unwrap();
    let _ = std::fs::remove_dir_all(&dir);
    output
}

/// The JSON error the CLI printed, with the key it reported if any.
fn json_error(output: &Output) -> Value {
    let text = String::from_utf8_lossy(&output.stdout);
    let text = if text.trim().is_empty() { String::from_utf8_lossy(&output.stderr) } else { text };
    serde_json::from_str(text.trim()).unwrap_or_else(|_| panic!("not JSON: {text}"))
}

#[test]
fn a_refusal_before_the_run_started_prints_no_retry_note() {
    let refusals = [
        (
            "workspace.new",
            json!({ "code": "not_found", "message": "Unknown action 'workspace.new'",
                    "data": { "action": "workspace.new", "not_run": true } }),
        ),
        (
            "splitBrowserRight",
            json!({ "code": "unavailable", "message": "splitBrowserRight unavailable: not enough room to split this pane",
                    "data": { "action": "splitBrowserRight", "not_run": true } }),
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
        assert_eq!(json.status.code(), Some(1), "{action}");
        let printed = json_error(&json);
        assert!(printed.pointer("/details/idempotency_key").is_none(), "{action}: {printed}");
    }
}

#[test]
fn a_refusal_from_the_actions_work_keeps_the_retry_note() {
    // `home.createGroup` made the group, then setting its replies failed.
    let refusal = json!({ "code": "unavailable", "message": "home.createGroup unavailable: replies not set",
                          "data": { "action": "home.createGroup", "reason": "replies not set" } });
    let human = run_against_error(&[], "home.createGroup", refusal.clone());
    let stderr = String::from_utf8_lossy(&human.stderr);
    assert_eq!(human.status.code(), Some(1), "{stderr}");
    assert!(stderr.contains("may still apply"), "{stderr}");

    let json = run_against_error(&["--json"], "home.createGroup", refusal);
    let printed = json_error(&json);
    assert!(printed.pointer("/details/idempotency_key").is_some(), "{printed}");
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
