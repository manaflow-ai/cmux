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
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

/// A new folder for one run. The clock alone does not name it: macOS counts in microseconds, and
/// two tests that start together got one folder, so the second `bind` failed with "File exists".
fn temp_dir(name: &str) -> PathBuf {
    static RUNS: AtomicUsize = AtomicUsize::new(0);
    let run = RUNS.fetch_add(1, Ordering::Relaxed);
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let dir = Path::new("/tmp").join(format!("cmux-{name}-{}-{stamp}-{run}", std::process::id()));
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
        // An app that refuses `busy` forever is asked again until the deadline: a short one for the test.
        .env("CMUX_TEST_NOT_RUN_DEADLINE_MS", "300")
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

/// How the CLI's run against [`refusing_app`] ended.
struct Refused {
    output: Output,
    /// How many times the app was asked to run the action.
    asked: usize,
    took: Duration,
}

/// Runs `cmux <output> action run <action>` against an app that answers its first `refusals`
/// requests with `error` and every later one with a finished run. The CLI's not-run deadline is
/// 3 s here: an app that is asked again until the deadline holds the command for those 3 s (45 s
/// for a person).
fn run_against_refusals(output: &[&str], action: &str, error: Value, refusals: usize) -> Refused {
    let dir = temp_dir("refusal-once");
    let socket = dir.join("app.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let asked = Arc::new(AtomicUsize::new(0));
    let started = Instant::now();
    let child = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .args(output)
        .arg("--app-socket")
        .arg(&socket)
        .args(["action", "run", action])
        .env_remove("CMUX_TUI_TERMINAL_ID")
        .env_remove("CMUX_AGENT_SESSION")
        .env("LC_ALL", "C")
        .env("LANG", "C")
        .env("CMUX_TEST_NOT_RUN_DEADLINE_MS", "3000")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let counter = Arc::clone(&asked);
    std::thread::spawn(move || {
        let Ok((stream, _)) = listener.accept() else { return };
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let mut stream = stream;
        let mut line = String::new();
        while reader.read_line(&mut line).unwrap_or(0) > 0 {
            let request: Value = serde_json::from_str(&line).unwrap();
            line.clear();
            // Only the run counts: a probe the CLI sends first is answered the same way.
            let run = usize::from(request["method"] == "action.run");
            let answer = if counter.fetch_add(run, Ordering::SeqCst) < refusals {
                json!({ "id": request["id"], "ok": false, "error": error })
            } else {
                json!({ "id": request["id"], "ok": true,
                        "result": { "action": request["params"]["action"], "ran": true, "created": [] } })
            };
            if writeln!(stream, "{answer}").is_err() {
                break;
            }
        }
    });
    let output = child.wait_with_output().unwrap();
    let took = started.elapsed();
    let _ = std::fs::remove_dir_all(&dir);
    Refused { output, asked: asked.load(Ordering::SeqCst), took }
}

/// SPLIT DOWN GARBAGE, 2026-11-10: `cmux action run splitDown` on the agent chat's pane answered
/// after 45 s. The app refuses that split at once and for good, but the CLI asked again until its
/// deadline, because the refusal has the code of a read barrier on a reconnecting daemon
/// (`unavailable`, `not_run`). A refusal the app decided is the answer: asked one time, the reason
/// on stderr, exit 1. Both shapes: the app that says `state: rejected`, and an app from before it.
#[test]
fn a_refusal_the_app_decided_is_the_answer_at_once() {
    let reason = "The agent chat can't be split.";
    let message = format!("splitDown unavailable: {reason}");
    let shapes = [
        json!({ "action": "splitDown", "reason": reason, "not_run": true, "state": "rejected" }),
        json!({ "action": "splitDown", "reason": reason, "not_run": true }),
    ];
    for data in shapes {
        let error = json!({ "code": "unavailable", "message": message, "data": data });
        let human = run_against_refusals(&[], "splitDown", error.clone(), usize::MAX);
        let stderr = String::from_utf8_lossy(&human.output.stderr);
        assert_eq!(human.asked, 1, "asked again for a refusal that cannot pass ({data}): {stderr}");
        assert!(human.took < Duration::from_secs(1), "{:?} ({data})", human.took);
        assert_eq!(human.output.status.code(), Some(1), "{stderr}");
        assert!(stderr.contains(reason), "{stderr}");
        assert!(!stderr.contains("may still apply"), "{stderr}");

        let json = run_against_refusals(&["--json"], "splitDown", error, usize::MAX);
        assert_eq!(json.asked, 1, "{data}");
        assert_eq!(json.output.status.code(), Some(1), "{data}");
        let printed = json_error(&json.output);
        assert_eq!(printed["code"], "unavailable", "{printed}");
        assert_eq!(printed["message"], message, "{printed}");
        assert!(printed.pointer("/data/not_run_waited_ms").is_none(), "{printed}");
    }
}

/// The causes that pass keep their retry (#32724): the app did not get to the request (the read
/// barrier of a daemon connection that is reconnecting says `state: not_run` and when to ask
/// again), so the CLI asks again and the caller sees only the run.
#[test]
fn a_request_the_app_did_not_get_to_is_still_asked_again() {
    let barrier = json!({ "code": "unavailable", "message": "after: \"sync\" is not available yet; retry",
                          "data": { "not_run": true, "state": "not_run", "retry_after_ms": 1 } });
    let ran = run_against_refusals(&[], "splitDown", barrier, 3);
    let stderr = String::from_utf8_lossy(&ran.output.stderr);
    assert_eq!(ran.output.status.code(), Some(0), "{stderr}");
    assert_eq!(ran.asked, 4, "{stderr}");
}
