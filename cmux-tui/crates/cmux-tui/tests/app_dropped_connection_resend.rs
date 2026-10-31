//! A dropped connection heals itself (self-healing DESIGN, 2026-10-19): the
//! app closes the first connection after it read the request (a restart of its
//! control server, a refusal under load), and the CLI sends the same request
//! again on a new connection, with the same idempotency key, so the app replays
//! the run instead of running it twice. Before, the CLI stopped at "transport
//! closed" / `mutation.outcome_unknown` and the caller had to retry by hand.
#![cfg(unix)]

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

fn temp_dir(name: &str) -> PathBuf {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let dir = Path::new("/tmp").join(format!("cmux-{name}-{}-{stamp}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// Reads one request line from the next connection; answers it when `reply`
/// is set, else closes the connection without an answer.
fn serve_one(listener: &UnixListener, reply: Option<Value>) -> Value {
    let (stream, _) = listener.accept().unwrap();
    let mut reader = BufReader::new(stream.try_clone().unwrap());
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    let request: Value = serde_json::from_str(&line).unwrap();
    if let Some(result) = reply {
        let mut stream = stream;
        let answer = json!({ "id": request["id"], "ok": true, "result": result });
        writeln!(stream, "{answer}").unwrap();
    }
    request
}

#[test]
fn a_run_whose_connection_dropped_is_sent_again_with_the_same_key() {
    let dir = temp_dir("resend");
    let socket = dir.join("app.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let child = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .args(["--json", "--app-socket"])
        .arg(&socket)
        .args(["action", "run", "window.new"])
        .env_remove("CMUX_TUI_TERMINAL_ID")
        .env_remove("CMUX_AGENT_SESSION")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();

    let first = serve_one(&listener, None);
    let second = serve_one(
        &listener,
        Some(json!({ "action": "window.new", "ran": true, "replayed": true })),
    );
    let output = child.wait_with_output().unwrap();
    drop(listener);
    let _ = std::fs::remove_dir_all(&dir);

    let stderr = String::from_utf8_lossy(&output.stderr);
    assert_eq!(output.status.code(), Some(0), "{stderr}");
    assert_eq!(first["method"], "action.run");
    assert_eq!(second["method"], "action.run");
    let key = first["params"]["idempotency_key"].as_str().expect("a keyed run");
    assert_eq!(second["params"]["idempotency_key"].as_str(), Some(key));
    assert!(!stderr.contains("outcome_unknown"), "{stderr}");
}

#[test]
fn an_unkeyed_mutation_is_never_sent_twice() {
    // `errors.clear` carries no key: a resend could clear twice, so the CLI
    // reports the dropped connection instead.
    let dir = temp_dir("noresend");
    let socket = dir.join("app.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    listener.set_nonblocking(false).unwrap();
    let child = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .args(["--json", "--app-socket"])
        .arg(&socket)
        .args(["errors", "clear"])
        .env_remove("CMUX_TUI_TERMINAL_ID")
        .env_remove("CMUX_AGENT_SESSION")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let first = serve_one(&listener, None);
    let output = child.wait_with_output().unwrap();
    // No second connection came.
    listener.set_nonblocking(true).unwrap();
    let again = listener.accept();
    drop(listener);
    let _ = std::fs::remove_dir_all(&dir);

    assert_ne!(output.status.code(), Some(0));
    assert!(first["method"].as_str().is_some_and(|method| method.starts_with("errors.")));
    assert!(again.is_err(), "the CLI sent an unkeyed mutation again");
}
