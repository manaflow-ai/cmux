//! Every hook cmux installs answers its agent inside the timeout it was
//! installed with, with the safe default when its own work cannot finish
//! (leo-workspace#10655's class): an agent that waits past it kills the hook
//! and shows "A hook didn't answer in time". The stall here is the agent's
//! hook queue held by another process (a sender mid-write on a stalled disk),
//! which kept the provider-facing helper in its 5 s handoff wait, the whole
//! of a 5 s hook timeout.

#![cfg(unix)]

use std::fs::File;
use std::io::Write;
use std::path::Path;
use std::process::{Command, Output, Stdio};
use std::time::{Duration, Instant};

fn run_hook(socket: &Path, source: &str, event: &str, budget: Duration) -> (Output, Duration) {
    let started = Instant::now();
    let mut child = Command::new(env!("CARGO_BIN_EXE_cmux-tui-hook"))
        .args([source, event])
        .env("CMUX_TUI_SOCKET", socket)
        .env("CMUX_TUI_TERMINAL_ID", "term_7")
        .env("CMUX_TUI_HOOK_ROUTE", "launch")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(
            format!("{{\"session_id\":\"answers\",\"hook_event_name\":\"{event}\"}}").as_bytes(),
        )
        .unwrap();
    // What the agent waits for: exit and EOF on stdout.
    let (sender, receiver) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let _ = sender.send(child.wait_with_output());
    });
    let output = receiver
        .recv_timeout(budget)
        .unwrap_or_else(|_| panic!("{source} {event} did not answer within {budget:?}"))
        .unwrap();
    (output, started.elapsed())
}

/// Every queue file of the session at `socket`, locked as a sender holds it.
fn hold_queues(socket: &Path) -> Vec<File> {
    let spool = socket.parent().unwrap().join("hook-spool");
    let mut held = Vec::new();
    for entry in std::fs::read_dir(&spool).unwrap() {
        let path = entry.unwrap().path();
        if path.extension().is_some_and(|extension| extension == "jsonl") {
            let file = File::options().read(true).write(true).open(&path).unwrap();
            file.lock().unwrap();
            held.push(file);
        }
    }
    assert!(!held.is_empty(), "no hook queue in {}", spool.display());
    held
}

#[test]
fn a_hook_whose_queue_is_held_still_answers_before_its_timeout() {
    let dir = cmux_unix_socket::short_test_dir("answers");
    // No daemon: the first event stays in the terminal's queue.
    let socket = dir.path().join("s.sock");
    let (first, _) = run_hook(&socket, "claude", "Stop", Duration::from_secs(10));
    assert!(first.status.success(), "{first:?}");
    let held = hold_queues(&socket);
    // (agent, event, installed timeout, the safe answer the agent reads).
    // The helper gives it, or fails at once and the installed command echoes
    // it (`||echo {}`; a journal-only event's command always echoes `{}`).
    for (source, event, timeout, answer) in [
        ("claude", "UserPromptSubmit", 5, "{}"),
        ("codex", "Stop", 5, "{}"),
        ("gemini", "BeforeTool", 5, ""),
    ] {
        let timeout = Duration::from_secs(timeout);
        assert_eq!(cmux_tui_hooks::installed_hook_wait(source, event), timeout, "{source} {event}");
        let (output, took) = run_hook(&socket, source, event, timeout + Duration::from_secs(5));
        assert!(
            took < timeout - Duration::from_millis(500),
            "{source} {event} answered after {took:?}, its timeout is {timeout:?}"
        );
        let stdout = String::from_utf8_lossy(&output.stdout);
        if output.status.success() {
            assert_eq!(stdout.trim(), answer, "{source} {event}: {output:?}");
        } else {
            assert_eq!(
                stdout.trim(),
                "",
                "a failed helper prints nothing: {source} {event}: {output:?}"
            );
        }
    }
    drop(held);
}

#[test]
fn an_answering_daemon_still_gets_its_answer_in_full() {
    // The deadline is a ceiling, not a cost: with nothing held, a hook that
    // delivers messages answers from the daemon at once.
    let dir = cmux_unix_socket::short_test_dir("answerok");
    let socket = dir.path().join("s.sock");
    let listener = std::os::unix::net::UnixListener::bind(&socket).unwrap();
    std::thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            std::thread::spawn(move || {
                let mut reader = std::io::BufReader::new(stream.try_clone().unwrap());
                let mut stream = stream;
                loop {
                    let mut line = String::new();
                    if std::io::BufRead::read_line(&mut reader, &mut line).unwrap_or(0) == 0 {
                        return;
                    }
                    let request: serde_json::Value = serde_json::from_str(&line).unwrap();
                    let result = if request["operation"] == "agent.message.list" {
                        serde_json::json!([])
                    } else {
                        serde_json::json!({"value": {"sequence": "1"}})
                    };
                    let reply = serde_json::json!({"protocol": "cmux.protocol/2", "type": "response",
                        "id": request["id"], "ok": true, "result": result});
                    let _ = stream.write_all(format!("{reply}\n").as_bytes());
                }
            });
        }
    });
    let (output, took) = run_hook(&socket, "claude", "UserPromptSubmit", Duration::from_secs(10));
    assert!(output.status.success(), "{output:?}");
    assert_eq!(String::from_utf8_lossy(&output.stdout).trim(), "{}");
    assert!(took < Duration::from_secs(3), "{took:?}");
}
