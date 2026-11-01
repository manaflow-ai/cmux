//! The public client's capability hello is before its resource command. A
//! dropped hello must heal the connection without declaring the unsent command
//! outcome unknown.
#![cfg(unix)]
use cmux_tui_core::platform::transport;
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::process::Command;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

#[test]
fn newtab_agent_identity_retries_a_dropped_capability_hello() {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let dir = std::env::temp_dir().join(format!("cmux-hello-{}-{stamp}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("mux.sock");
    let listener = transport::listen(&socket).unwrap();
    let worker = std::thread::spawn(move || {
        let mut seen = Vec::new();
        for attempt in 0..2 {
            let mut stream = listener.accept().unwrap();
            // The cleanup connection may already be closed before it is accepted.
            if stream.set_read_timeout(Some(Duration::from_secs(5))).is_err() {
                return seen;
            }
            let mut reader = BufReader::new(stream.try_clone_box().unwrap());
            let mut line = String::new();
            // A cleanup connection unblocks accept if the unfixed client exits.
            if reader.read_line(&mut line).unwrap() == 0 {
                return seen;
            }
            let hello: Value = serde_json::from_str(&line).unwrap();
            assert_eq!(hello["cmd"], "set-client-info", "{hello}");
            seen.push(hello.clone());
            if attempt == 0 {
                continue;
            }
            writeln!(stream, "{}", json!({"id":hello["id"],"ok":true,"data":{}})).unwrap();
            stream.flush().unwrap();
            line.clear();
            reader.read_line(&mut line).unwrap();
            let request: Value = serde_json::from_str(&line).unwrap();
            seen.push(request.clone());
            writeln!(
                stream,
                "{}",
                json!({"protocol":"cmux.protocol/2","type":"response",
                "id":request["id"],"ok":true,"result":[]})
            )
            .unwrap();
            stream.flush().unwrap();
        }
        seen
    });
    let output = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .args(["--json", "--socket"])
        .arg(&socket)
        .args(["tab", "list"])
        .env("CMUX_TEST_RETRY_BACKOFF_MS", "1")
        .env_remove("CMUX_CLI_NO_RETRY")
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();
    drop(transport::connect(&socket));
    let seen = worker.join().unwrap();
    std::fs::remove_dir_all(dir).unwrap();
    assert!(
        output.status.success(),
        "dropped hello was not retried: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(seen.len(), 3, "two hellos and one resource command: {seen:?}");
    assert_eq!(seen[2]["operation"], "tab.list");
    assert_eq!(serde_json::from_slice::<Value>(&output.stdout).unwrap(), json!([]));
}

#[test]
fn refused_capability_hello_keeps_transport_exit_code() {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let dir =
        std::env::temp_dir().join(format!("cmux-refused-hello-{}-{stamp}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("mux.sock");
    let listener = transport::listen(&socket).unwrap();
    let worker = std::thread::spawn(move || {
        let mut stream = listener.accept().unwrap();
        let mut reader = BufReader::new(stream.try_clone_box().unwrap());
        let mut line = String::new();
        reader.read_line(&mut line).unwrap();
        let hello: Value = serde_json::from_str(&line).unwrap();
        assert_eq!(hello["cmd"], "set-client-info", "{hello}");
        writeln!(stream, "{}", json!({"type":"refused","reason":"connection limit"})).unwrap();
        stream.flush().unwrap();
    });
    let output = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .args(["--json", "--socket"])
        .arg(&socket)
        .args(["tab", "list"])
        .env("CMUX_CLI_NO_RETRY", "1")
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();
    worker.join().unwrap();
    std::fs::remove_dir_all(dir).unwrap();
    assert_eq!(output.status.code(), Some(3), "{}", String::from_utf8_lossy(&output.stderr));
    assert!(output.stdout.is_empty());
    let error: Value = serde_json::from_slice(&output.stderr).unwrap();
    assert_eq!(error["code"], "session.busy", "{error}");
}

#[test]
fn newtab_agent_identity_keeps_old_daemon_reads_after_hello_rejection() {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let dir = std::env::temp_dir().join(format!("cmux-old-hello-{}-{stamp}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("mux.sock");
    let listener = transport::listen(&socket).unwrap();
    let worker = std::thread::spawn(move || {
        let mut stream = listener.accept().unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        let mut reader = BufReader::new(stream.try_clone_box().unwrap());
        let mut line = String::new();
        reader.read_line(&mut line).unwrap();
        let hello: Value = serde_json::from_str(&line).unwrap();
        writeln!(stream, "{}", json!({"id":hello["id"],"ok":false,"error":"unknown command"}))
            .unwrap();
        stream.flush().unwrap();
        line.clear();
        if reader.read_line(&mut line).unwrap() == 0 {
            return;
        }
        let request: Value = serde_json::from_str(&line).unwrap();
        assert_eq!(request["operation"], "tab.list");
        writeln!(
            stream,
            "{}",
            json!({"protocol":"cmux.protocol/2","type":"response",
            "id":request["id"],"ok":true,"result":[]})
        )
        .unwrap();
        stream.flush().unwrap();
    });
    let output = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .args(["--json", "--socket"])
        .arg(&socket)
        .args(["tab", "list"])
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();
    worker.join().unwrap();
    std::fs::remove_dir_all(dir).unwrap();
    assert!(
        output.status.success(),
        "optional hello blocked old daemon: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(serde_json::from_slice::<Value>(&output.stdout).unwrap(), json!([]));
}
