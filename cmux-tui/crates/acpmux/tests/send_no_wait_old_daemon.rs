//! `acpmux send --no-wait` works against a daemon older than the CLI.
//!
//! On 2026-10-22 cosmic-gray's `acpmux` on PATH was a build with `_acpmux/send_queue` (#23880)
//! while the cmux app's daemon predated it: every `send --no-wait` failed with "Method not found:
//! _acpmux/send_queue" for about 2h40m. A daemon without the outbox still takes a prompt; the CLI
//! sends it the way it did before the outbox and says the daemon is older.
//!
//! The daemon here is a stand-in that knows only what a pre-outbox daemon answered for this send.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process starts no agent.
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::sync::mpsc;
use std::time::Duration;

fn scratch(tag: &str) -> PathBuf {
    let dir = PathBuf::from(env!("CARGO_TARGET_TMPDIR"))
        .join(format!("sqf-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(daemon_env::home(&dir)).unwrap();
    dir
}

fn reply(out: &mut UnixStream, msg: Value) {
    let mut line = msg.to_string();
    line.push('\n');
    out.write_all(line.as_bytes()).unwrap();
}

/// Serves one connection as a daemon from before `_acpmux/send_queue`: `_acpmux/info` and
/// `session/prompt` (accepted at once, the turn left running), Method not found for the rest.
/// Every method it was asked, and each prompt's text, go to `seen`.
fn old_daemon(listener: UnixListener, seen: mpsc::Sender<(String, Value)>) {
    std::thread::spawn(move || {
        let Ok((stream, _)) = listener.accept() else { return };
        let mut out = stream.try_clone().unwrap();
        for line in BufReader::new(stream).lines() {
            let Ok(line) = line else { return };
            let Ok(msg) = serde_json::from_str::<Value>(&line) else { continue };
            let (Some(id), Some(method)) =
                (msg.get("id").cloned(), msg.get("method").and_then(Value::as_str))
            else {
                continue;
            };
            let params = msg.get("params").cloned().unwrap_or(Value::Null);
            let _ = seen.send((method.to_owned(), params.clone()));
            match method {
                "initialize" => reply(
                    &mut out,
                    json!({"jsonrpc": "2.0", "id": id, "result": {"protocolVersion": 1, "_meta": {"acpmux": {"build": "eeb26d832"}}}}),
                ),
                "_acpmux/info" => reply(
                    &mut out,
                    json!({"jsonrpc": "2.0", "id": id, "result": {"sessionId": "s-old", "status": "ready", "queued": 0, "pendingPermissions": 0}}),
                ),
                "session/prompt" => {
                    let prompt_id = params
                        .pointer("/_meta/acpmux/promptId")
                        .or_else(|| params.get("promptId"))
                        .cloned();
                    reply(
                        &mut out,
                        json!({"jsonrpc": "2.0", "method": "_acpmux/prompt_accepted", "params": {"sessionId": "s-old", "promptId": prompt_id, "steer": false}}),
                    );
                }
                other => reply(
                    &mut out,
                    json!({"jsonrpc": "2.0", "id": id, "error": {"code": -32601, "message": format!("Method not found: {other}")}}),
                ),
            }
        }
    });
}

#[test]
fn send_no_wait_falls_back_when_the_daemon_has_no_outbox() {
    let dir = scratch("old");
    let socket = std::env::temp_dir().join(format!("sqf-{}.sock", std::process::id()));
    let _ = std::fs::remove_file(&socket);
    let listener = UnixListener::bind(&socket).unwrap();
    let (tx, rx) = mpsc::channel();
    old_daemon(listener, tx);

    let mut child = daemon_env::acpmux(&dir)
        .env("ACPMUX_SOCKET", &socket)
        .args(["send", "--no-wait", "s-old", "hello from a newer cli"])
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    let deadline = std::time::Instant::now() + Duration::from_secs(20);
    let status = loop {
        if let Some(status) = child.try_wait().unwrap() {
            break status;
        }
        if std::time::Instant::now() > deadline {
            let _ = child.kill();
            panic!("send --no-wait did not return against a daemon without the outbox");
        }
        std::thread::sleep(Duration::from_millis(50));
    };
    let out = child.wait_with_output().unwrap();
    let _ = std::fs::remove_file(&socket);
    let stdout = String::from_utf8_lossy(&out.stdout);
    let stderr = String::from_utf8_lossy(&out.stderr);
    let seen: Vec<(String, Value)> = rx.try_iter().collect();
    let methods: Vec<&str> = seen.iter().map(|(m, _)| m.as_str()).collect();

    assert!(
        status.success(),
        "send --no-wait failed: stdout {stdout:?} stderr {stderr:?} methods {methods:?}"
    );
    let prompt = seen.iter().find(|(m, _)| m == "session/prompt").map(|(_, p)| p.to_string());
    assert!(
        prompt.as_deref().is_some_and(|p| p.contains("hello from a newer cli")),
        "the old daemon never got the prompt: methods {methods:?}"
    );
    assert!(stdout.contains("queued"), "no acceptance printed: {stdout:?}");
    assert!(
        stderr.contains("older") && stderr.contains("eeb26d832"),
        "no warning that the daemon is older than the CLI: {stderr:?}"
    );
}
