//! `cmux-tui-hook` must never hold the provider hostage to the journal
//! server: it exits once the request is written, and a detached child waits
//! for the receipt. Providers block their agent on the hook's exit and on EOF
//! of its stdout, so both must happen before the server answers.

#![cfg(unix)]

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

fn socket_path(name: &str) -> PathBuf {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    PathBuf::from("/tmp").join(format!("cmux-hd-{name}-{}-{stamp}.sock", std::process::id()))
}

fn spawn_hook(socket: &PathBuf, event: &str) -> Child {
    let mut child = Command::new(env!("CARGO_BIN_EXE_cmux-tui-hook"))
        .args(["codex", event])
        .env("CMUX_TUI_SOCKET", socket)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(b"{\"session_id\":\"detach-test\"}\n").unwrap();
    child
}

/// Waits for exit AND stdout/stderr EOF, which is what a provider waits for.
fn wait_with_output(child: Child, budget: Duration) -> Option<std::process::Output> {
    let (sender, receiver) = std::sync::mpsc::channel();
    thread::spawn(move || {
        let _ = sender.send(child.wait_with_output());
    });
    receiver.recv_timeout(budget).ok().and_then(Result::ok)
}

fn read_request(stream: &UnixStream) -> String {
    stream
        .set_read_timeout(Some(Duration::from_secs(3)))
        .expect("set journal request read timeout");
    let mut line = String::new();
    BufReader::new(stream)
        .read_line(&mut line)
        .unwrap_or_else(|error| panic!("read journal request before timeout: {error}"));
    line
}

fn reply(mut stream: &UnixStream, request: &str) {
    let request: serde_json::Value = serde_json::from_str(request).unwrap();
    let response = serde_json::json!({
        "protocol":"cmux.protocol/2","type":"response","id":request["id"],"ok":true,
        "result":{"value":{"sequence":"1"}}
    });
    stream.write_all(format!("{response}\n").as_bytes()).unwrap();
}

#[test]
fn detached_hook_exits_before_the_server_answers() {
    let socket = socket_path("exit");
    let listener = UnixListener::bind(&socket).unwrap();
    let started = Instant::now();
    let child = spawn_hook(&socket, "Stop");
    let (stream, _) = listener.accept().unwrap();
    let request = read_request(&stream);
    assert!(request.contains("\"session.journal.append\""), "{request}");

    // The server has not answered yet; the provider-facing process must be
    // gone, with its stdout closed, without waiting for the receipt.
    let output = wait_with_output(child, Duration::from_secs(3))
        .expect("hook must exit before the journal receipt arrives");
    assert!(output.status.success(), "{output:?}");
    assert!(started.elapsed() < Duration::from_secs(3));

    reply(&stream, &request);
    let _ = std::fs::remove_file(&socket);
}

#[test]
fn detached_hook_writes_the_request_before_exiting_even_when_the_server_is_not_accepting() {
    let socket = socket_path("order");
    let listener = UnixListener::bind(&socket).unwrap();
    // Nothing accepts yet: the requests sit in the listen backlog. Each hook
    // still exits only after its own request is written, so provider order
    // becomes arrival order.
    for event in ["SessionStart", "UserPromptSubmit", "Stop"] {
        let output = wait_with_output(spawn_hook(&socket, event), Duration::from_secs(3))
            .expect("hook must exit while the server is not accepting");
        assert!(output.status.success(), "{event}: {output:?}");
    }
    let mut seen = Vec::new();
    for _ in 0..3 {
        let (stream, _) = listener.accept().unwrap();
        let request = read_request(&stream);
        let value: serde_json::Value = serde_json::from_str(&request).unwrap();
        seen.push(
            value["params"]["event"]["payload"]["native_event"].as_str().unwrap_or("").to_owned(),
        );
        reply(&stream, &request);
    }
    assert_eq!(seen, ["SessionStart", "UserPromptSubmit", "Stop"]);
    let _ = std::fs::remove_file(&socket);
}

#[test]
fn detached_hook_without_a_listener_fails_immediately() {
    let socket = socket_path("dead");
    let started = Instant::now();
    let output = wait_with_output(spawn_hook(&socket, "Stop"), Duration::from_secs(3))
        .expect("hook must exit when no server listens");
    // No listener means this terminal is not attached to a live cmux-tui: the
    // child gives up at once and the provider-facing process reports it,
    // without spending the retry deadline.
    assert!(!output.status.success(), "{output:?}");
    assert!(started.elapsed() < Duration::from_secs(2));
}

#[test]
fn detached_child_rejects_a_newline_free_request_id_before_reading_payload() {
    let socket = socket_path("missing-id-delimiter");
    let mut child = Command::new(env!("CARGO_BIN_EXE_cmux-tui-hook"))
        .args(["__detached-append"])
        .env("CMUX_TUI_SOCKET", &socket)
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(b"550e8400-e29b-41d4-a716-446655440000{}").unwrap();
    let output = child.wait_with_output().unwrap();

    assert!(!output.status.success(), "{output:?}");
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("detached request id is missing newline delimiter"), "{stderr}");
}
